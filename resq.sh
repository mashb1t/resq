#!/usr/bin/env bash
set -euo pipefail

# ── Args ──
PRUNE_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prune-only) PRUNE_ONLY=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: resq.sh [--prune-only]

Default mode (backup):
  Discover containers with label resq.enable=true, dump DBs, back up
  volumes and bind mounts to each repo in repos.conf, then run
  `restic forget --host <hostname>` per repo. Pruning is opt-in via
  PRUNE=true in .env (takes an exclusive lock — only safe for
  single-host repos or when no other host is backing up).

--prune-only:
  Skip backup entirely; just run `restic prune` against each repo in
  repos.conf. Use from a single designated host on a weekly-ish
  schedule to reclaim space from snapshots forgotten by all hosts.
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1 (use --help)" >&2; exit 2 ;;
  esac
done

# ── Config ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSWORD_FILE="$SCRIPT_DIR/.restic-password"
REPOS_CONF="$SCRIPT_DIR/repos.conf"
ENV_FILE="$SCRIPT_DIR/.env"
DUMP_DIR="/tmp/docker-dumps"
PARALLEL=false
HOST=$(hostname)
# Backrest-compatible identification: every snapshot is stamped with the
# plan + instance tags so Backrest groups them rather than showing
# "_unassociated_". Other tools ignore these tags.
COMMON_TAGS=(--tag "plan:resq" --tag "instance:$HOST")

# Source config if env file exists. set -a auto-exports all variables
# so credentials like B2_ACCOUNT_ID reach restic's subprocesses.
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

# Where per-run logs are written (override in .env, e.g. LOG_DIR=/var/log/resq)
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

# Default bind mount exclusions (override in .env)
BIND_EXCLUDE="${BIND_EXCLUDE:-/etc/timezone|/etc/localtime|/etc/hosts|/etc/resolv.conf|/etc/hostname|/var/run/docker.sock|/dev/|/proc/|/sys/}"

mkdir -p "$LOG_DIR" "$DUMP_DIR"
ENV_LIST_DIR=$(mktemp -d -t backup-envlists.XXXXXX)
trap 'rm -rf "$ENV_LIST_DIR"' EXIT

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ── Helpers ──
log() { echo "[$(date '+%H:%M:%S')] $*"; }

default_if_empty() {
  local v="$1" d="$2"
  if [ -z "$v" ] || [ "$v" = "<no value>" ]; then printf '%s' "$d"; else printf '%s' "$v"; fi
}

# One docker inspect per container. Sets globals:
#   NAME DB_TYPE DB_USER DB_NAME STOP BIND_MOUNTS PROJECT_DIR
read_container_labels() {
  local cid="$1" raw fallback
  raw=$(docker inspect -f \
    '{{index .Config.Labels "resq.name"}}|{{index .Config.Labels "resq.db.type"}}|{{index .Config.Labels "resq.db.user"}}|{{index .Config.Labels "resq.db.name"}}|{{index .Config.Labels "resq.stop"}}|{{index .Config.Labels "resq.bind-mounts"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{.Name}}' \
    "$cid")
  IFS='|' read -r NAME DB_TYPE DB_USER DB_NAME STOP BIND_MOUNTS PROJECT_DIR fallback <<<"$raw"
  NAME=$(default_if_empty "$NAME" "${fallback#/}")
  DB_TYPE=$(default_if_empty "$DB_TYPE" "none")
  DB_USER=$(default_if_empty "$DB_USER" "")
  DB_NAME=$(default_if_empty "$DB_NAME" "all")
  STOP=$(default_if_empty "$STOP" "false")
  BIND_MOUNTS=$(default_if_empty "$BIND_MOUNTS" "")
  # Empty if the container has no compose-project label; callers that need
  # filesystem-relative resolution (env discovery, relative bind mounts)
  # check for non-empty before using it.
  PROJECT_DIR=$(default_if_empty "$PROJECT_DIR" "")
}

path_excluded() { [[ "$1" =~ $BIND_EXCLUDE ]]; }

# Returns the absolute path for $1, treating relative paths as relative to $2.
# If $1 is relative but $2 is empty (no compose project context for this
# container), prints the unresolved path so the caller can warn.
resolve_bind_path() {
  local p="$1" dir="$2"
  if [[ "$p" == ./* || "$p" == ../* ]]; then
    [ -n "$dir" ] && (cd "$dir" && realpath "$p") || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

add_backup() {  # path container kind db
  BACKUP_PATHS+=("$1"); BACKUP_CONTAINER+=("$2"); BACKUP_KIND+=("$3"); BACKUP_DB+=("$4")
}

add_dump() {  # path container db
  DUMP_PATHS+=("$1"); DUMP_CONTAINER+=("$2"); DUMP_DB+=("$3")
}

# Run restic, tee to current $logfile, surface exit code via PIPESTATUS.
# Usage: run_restic <human-desc> <restic args...>. Caller checks return code.
run_restic() {
  local desc="$1"; shift
  restic "$@" 2>&1 | tee -a "$logfile"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    log "    ERROR: [${name:-?}] restic $desc failed (exit $rc)"
    return "$rc"
  fi
}

# ── Load repos ──
declare -a REPO_NAMES=() REPO_URLS=() REPO_ENVS=() REPO_DAILY=() REPO_WEEKLY=() REPO_MONTHLY=()
while IFS='|' read -r name url envs daily weekly monthly || [ -n "$name" ]; do
  [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
  REPO_NAMES+=("$name")
  REPO_URLS+=("$url")
  REPO_ENVS+=("${envs:-}")
  REPO_DAILY+=("${daily:-7}")
  REPO_WEEKLY+=("${weekly:-4}")
  REPO_MONTHLY+=("${monthly:-6}")
done < "$REPOS_CONF"

if [ ${#REPO_NAMES[@]} -eq 0 ]; then
  log "ERROR: No repos found in $REPOS_CONF"
  exit 1
fi
log "Loaded ${#REPO_NAMES[@]} repos: ${REPO_NAMES[*]}"

# ── DB dump (runs once, not per-repo) ──
dump_db() {
  local CID="$1" DB_TYPE="$2" DB_USER="$3" DB_NAME="$4" DUMP_NAME="$5"
  local OUT="$DUMP_DIR/$DUMP_NAME"
  local dump_file=""

  local rc=0
  case "$DB_TYPE" in
    postgres)
      # PGPASSWORD passes auth. Local-socket trust auth works on official
      # postgres images too — PGPASSWORD is just a harmless fallback.
      local pg_cmd ext
      if [ "$DB_NAME" = "all" ]; then
        log "    Dumping: pg_dumpall (user=$DB_USER)"
        pg_cmd="pg_dumpall -U $DB_USER"; ext="sql"
      else
        log "    Dumping: pg_dump $DB_NAME (user=$DB_USER)"
        pg_cmd="pg_dump -U $DB_USER -Fc $DB_NAME"; ext="dump"
      fi
      docker exec "$CID" sh -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" $pg_cmd" > "${OUT}.${ext}" || rc=$?
      if [ "$rc" -eq 0 ]; then
        dump_file="${OUT}.${ext}"
      else
        log "    ERROR: pg dump failed (exit $rc) — falling back to file-level"
        rm -f "${OUT}.${ext}"
      fi
      ;;
    mysql)
      # MYSQL_PWD env var is used by mariadb-dump and mysqldump for auth.
      # When DB_USER=root, the standard image var is MYSQL_ROOT_PASSWORD.
      local args pw_env tool
      if [ "$DB_NAME" = "all" ]; then args="-u $DB_USER --all-databases"; else args="-u $DB_USER $DB_NAME"; fi
      pw_env="MYSQL_PWD"
      [ "$DB_USER" = "root" ] && pw_env="MYSQL_ROOT_PASSWORD"
      tool="mysqldump"
      docker exec "$CID" sh -c 'command -v mariadb-dump >/dev/null' && tool="mariadb-dump"
      log "    Dumping: $tool $args"
      docker exec "$CID" sh -c "MYSQL_PWD=\"\$$pw_env\" $tool $args" > "${OUT}.sql" || rc=$?
      if [ "$rc" -eq 0 ]; then
        dump_file="${OUT}.sql"
      else
        log "    ERROR: $tool failed (exit $rc) — falling back to file-level"
        rm -f "${OUT}.sql"
      fi
      ;;
    mongo)
      log "    Dumping: mongodump"
      local mongo_db_filter=""
      [ -n "$DB_NAME" ] && [ "$DB_NAME" != "all" ] && mongo_db_filter="--db=$DB_NAME"
      docker exec "$CID" sh -c "mongodump --archive --gzip --username=\"\$MONGO_INITDB_ROOT_USERNAME\" --password=\"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase=admin $mongo_db_filter" > "${OUT}.archive.gz" || rc=$?
      if [ "$rc" -eq 0 ]; then
        dump_file="${OUT}.archive.gz"
      else
        log "    ERROR: mongodump failed (exit $rc) — falling back to file-level"
        rm -f "${OUT}.archive.gz"
      fi
      ;;
    redis|redis-aof)
      if [ "$DB_TYPE" = "redis-aof" ]; then
        log "    Dumping: BGREWRITEAOF + BGSAVE"
        docker exec "$CID" redis-cli BGREWRITEAOF
        while docker exec "$CID" redis-cli INFO persistence | grep -q "aof_rewrite_in_progress:1"; do
          sleep 1
        done
      else
        log "    Dumping: BGSAVE"
      fi
      docker exec "$CID" redis-cli BGSAVE
      sleep 2
      # RDB/AOF stays inside container, captured via bind/volume backup
      ;;
    sqlite)
      local db_path host_db=""
      db_path=$(docker inspect -f '{{index .Config.Labels "resq.db.path"}}' "$CID")
      while IFS='|' read -r dest src; do
        [ -z "$dest" ] && continue
        if [[ "$db_path" == "$dest"* ]]; then
          host_db="${src}${db_path#$dest}"
          break
        fi
      done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}{{end}}' "$CID")

      if [ -z "$host_db" ]; then
        log "    ERROR: Could not resolve host path for $db_path"
      elif [ ! -f "$host_db" ]; then
        log "    ERROR: DB file not found at $host_db"
      else
        log "    Dumping: sqlite3 .backup ($host_db)"
        sqlite3 "$host_db" ".backup '${OUT}.db'"
        dump_file="${OUT}.db"
      fi
      ;;
    none)
      log "    No dump needed"
      ;;
    *)
      log "    WARNING: Unknown db.type '$DB_TYPE' — skipping dump"
      log "    Valid types: postgres, mysql, mongo, redis, redis-aof, sqlite, none"
      ;;
  esac

  if [ -n "$dump_file" ] && [ -f "$dump_file" ]; then
    add_dump "$dump_file" "$DUMP_NAME" "db:$DB_TYPE"
  fi
}

# ── Collect data (once) — backup mode only ──
declare -a BACKUP_PATHS=() BACKUP_CONTAINER=() BACKUP_KIND=() BACKUP_DB=()
declare -a DUMP_PATHS=() DUMP_CONTAINER=() DUMP_DB=()
declare -a ENV_STACK=() ENV_FILES=()
declare -A ENV_SEEN=()

if [ "$PRUNE_ONLY" = true ]; then
  log "==> Config: HOST=$HOST  LOG_DIR=$LOG_DIR  MODE=prune-only"
else
  log "==> Config: HOST=$HOST  LOG_DIR=$LOG_DIR  MODE=backup  PRUNE=${PRUNE:-false}"

  rm -rf "$DUMP_DIR" && mkdir -p "$DUMP_DIR"

  CONTAINERS=$(docker ps -q --filter "label=resq.enable=true" || true)
  if [ -z "$CONTAINERS" ]; then
    log "WARNING: No containers with resq.enable=true found"
    exit 0
  fi
  log "==> Found $(echo "$CONTAINERS" | wc -w | tr -d ' ') container(s) with resq.enable=true"

  for CID in $CONTAINERS; do
  read_container_labels "$CID"
  log "==> $NAME (db=$DB_TYPE, stop=$STOP)"

  # Per-stack .env discovery (dedupe across containers sharing a compose project).
  # Skip when there's no compose project label.
  if [ -n "$PROJECT_DIR" ] && [ -z "${ENV_SEEN[$PROJECT_DIR]:-}" ]; then
    ENV_SEEN[$PROJECT_DIR]=1
    stack_name=$(basename "$PROJECT_DIR")
    envlist="$ENV_LIST_DIR/$stack_name"
    find "$PROJECT_DIR" -maxdepth 2 -type f -name '*.env*' ! -name '*.env.example' -print > "$envlist"
    if [ -s "$envlist" ]; then
      log "    Stack .env files: $stack_name ($(wc -l <"$envlist"))"
      ENV_STACK+=("$stack_name")
      ENV_FILES+=("$envlist")
    fi
  fi

  # 1. Application-consistent dump
  dump_db "$CID" "$DB_TYPE" "$DB_USER" "$DB_NAME" "$NAME"

  # 2. Optional stop for raw backup
  [ "$STOP" = "true" ] && { log "    Stopping container"; docker stop "$CID"; }

  # 3. Named volumes
  for vol in $(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$CID"); do
    mp=$(docker volume inspect -f '{{.Mountpoint}}' "$vol")
    log "    Named volume: $vol -> $mp"
    add_backup "$mp" "$NAME" "vol:$vol" "db:$DB_TYPE"
  done

  # 4. Bind mounts: explicit label wins, else auto-discover.
  # Accept files AND directories — single-file mounts (e.g. traefik's acme.json)
  # must be captured too. Skip sockets/fifos/devices via -f || -d.
  if [ -n "$BIND_MOUNTS" ]; then
    IFS=',' read -ra BINDS <<< "$BIND_MOUNTS"
    for bind in "${BINDS[@]}"; do
      resolved=$(resolve_bind_path "$bind" "$PROJECT_DIR")
      if [ -d "$resolved" ] || [ -f "$resolved" ]; then
        log "    Bind mount (label): $resolved"
        add_backup "$resolved" "$NAME" "bind:$(basename "$resolved")" "db:$DB_TYPE"
      elif [[ "$bind" == ./* || "$bind" == ../* ]] && [ -z "$PROJECT_DIR" ]; then
        log "    WARNING: Bind mount '$bind' is relative but container has no compose-project label — use an absolute path in resq.bind-mounts"
      else
        log "    WARNING: Bind mount not found: $resolved"
      fi
    done
  else
    while IFS='|' read -r src _; do
      [ -z "$src" ] && continue
      path_excluded "$src" && continue
      if [ -d "$src" ] || [ -f "$src" ]; then
        log "    Bind mount (auto): $src"
        add_backup "$src" "$NAME" "bind:$(basename "$src")" "db:$DB_TYPE"
      fi
    done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.RW}}{{"\n"}}{{end}}{{end}}' "$CID")
  fi

  # 5. Restart if stopped
  [ "$STOP" = "true" ] && { log "    Starting container"; docker start "$CID"; }
  done
fi

# ── Push to each repo ──
backup_to_repo() {
  local idx="$1"
  local name="${REPO_NAMES[$idx]}"
  local url="${REPO_URLS[$idx]}"
  local envs="${REPO_ENVS[$idx]}"
  local daily="${REPO_DAILY[$idx]}"
  local weekly="${REPO_WEEKLY[$idx]}"
  local monthly="${REPO_MONTHLY[$idx]}"
  local logfile="$LOG_DIR/${name}_${TIMESTAMP}.log"
  # Shadow caller's $i so our inner for-loops don't clobber it
  local i

  if [ -n "$envs" ]; then
    IFS=',' read -ra PAIRS <<< "$envs"
    for pair in "${PAIRS[@]}"; do
      export "${pair?}"
    done
  fi
  export RESTIC_REPOSITORY="$url" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

  log "==> [$name] Backing up to $url"

  # Probe repo. Exit 10 means doesn't exist → init. Other non-zero means unreachable.
  local ec=0
  restic cat config > /dev/null 2>&1 || ec=$?
  if [ "$ec" -eq 10 ]; then
    log "    Repo not initialized — running restic init"
    run_restic "init" init || return 1
  elif [ "$ec" -ne 0 ]; then
    log "    ERROR: Cannot reach repo $name ($url) — restic exit $ec, skipping"
    return 1
  fi

  # Volumes + bind mounts
  for i in "${!BACKUP_PATHS[@]}"; do
    log "    [$name] ${BACKUP_PATHS[$i]}"
    run_restic "backup ${BACKUP_PATHS[$i]}" backup "${BACKUP_PATHS[$i]}" \
      "${COMMON_TAGS[@]}" \
      --tag "${BACKUP_CONTAINER[$i]}" \
      --tag "${BACKUP_KIND[$i]}" \
      --tag "${BACKUP_DB[$i]}" || return 1
  done

  # Per-container DB dumps
  for i in "${!DUMP_PATHS[@]}"; do
    log "    [$name] dump: ${DUMP_PATHS[$i]}"
    run_restic "backup ${DUMP_PATHS[$i]}" backup "${DUMP_PATHS[$i]}" \
      "${COMMON_TAGS[@]}" \
      --tag "${DUMP_CONTAINER[$i]}" \
      --tag "db-dump" \
      --tag "${DUMP_DB[$i]}" || return 1
  done

  # Per-stack .env files (tagged with stack/dir name)
  for i in "${!ENV_STACK[@]}"; do
    local fl="${ENV_FILES[$i]}" stk="${ENV_STACK[$i]}"
    log "    [$name] .env files: $stk ($(wc -l <"$fl"))"
    run_restic "backup .env [$stk]" backup --files-from "$fl" \
      "${COMMON_TAGS[@]}" \
      --tag "$stk" --tag "env-files" || return 1
  done

  # Retention — host-scoped so multi-server repos don't cross-prune.
  # `forget` alone takes a non-exclusive lock and never conflicts with
  # concurrent backups from other hosts. `--prune` (opt-in via PRUNE=true
  # in .env) takes an EXCLUSIVE lock that blocks every other host until
  # done — run it from one designated host on a separate schedule.
  local -a forget_args=(
    --host "$HOST"
    --keep-daily "$daily"
    --keep-weekly "$weekly"
    --keep-monthly "$monthly"
  )
  local op_desc="forget host=$HOST"
  if [ "${PRUNE:-false}" = "true" ]; then
    forget_args+=( --prune )
    op_desc="forget+prune host=$HOST"
  fi
  log "    [$name] $op_desc (daily=$daily, weekly=$weekly, monthly=$monthly)"
  run_restic "$op_desc" forget "${forget_args[@]}" || return 1

  log "==> [$name] Complete"
}

# Repo-wide reclamation. Takes an exclusive lock, so a designated host
# should run this on its own schedule, outside other hosts' backup windows.
prune_repo() {
  local idx="$1"
  local name="${REPO_NAMES[$idx]}"
  local url="${REPO_URLS[$idx]}"
  local envs="${REPO_ENVS[$idx]}"
  local logfile="$LOG_DIR/${name}_prune_${TIMESTAMP}.log"

  if [ -n "$envs" ]; then
    IFS=',' read -ra PAIRS <<< "$envs"
    for pair in "${PAIRS[@]}"; do
      export "${pair?}"
    done
  fi
  export RESTIC_REPOSITORY="$url" RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

  log "==> [$name] Pruning $url"
  run_restic "prune" prune || return 1
  log "==> [$name] Prune complete"
}

# ── Run (parallel or sequential) ──
FAILED=0
if [ "$PRUNE_ONLY" = true ]; then
  # Always sequential for prune — each prune holds an exclusive lock, so
  # running them in parallel would only serialize them at the restic layer
  # and obscure failures.
  for i in "${!REPO_NAMES[@]}"; do
    if ! prune_repo "$i"; then
      log "WARNING: ${REPO_NAMES[$i]} prune failed — continuing with next repo"
      FAILED=$((FAILED + 1))
    fi
  done
elif [ "$PARALLEL" = true ]; then
  for i in "${!REPO_NAMES[@]}"; do backup_to_repo "$i" & done
  wait
else
  for i in "${!REPO_NAMES[@]}"; do
    if ! backup_to_repo "$i"; then
      log "WARNING: ${REPO_NAMES[$i]} failed — continuing with next repo"
      FAILED=$((FAILED + 1))
    fi
  done
fi

# ── Cleanup ──
rm -rf "$DUMP_DIR"
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then
  log "==> Done with $FAILED repo failure(s) at $TIMESTAMP"
  exit 1
fi
log "==> All repos done at $TIMESTAMP"
