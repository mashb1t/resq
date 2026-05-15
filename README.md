# 🚨 resq - before it's too late 🚨

Or short: Restic backup via docker labels.

Add a `resq.enable=true` label on a docker container, and `resq` figures out the rest: which volumes and bind mounts to
snapshot, how to take an application-consistent dump of the database it's running, which `.env` files in the compose
stack to capture, and which restic backends to push to.

```yaml
# in any docker-compose.yml
# backs up .env files, volumes, and bind mounts of this container
labels:
  - "resq.enable=true"
```

Or, if you are running a specific database and want the dumps included in the backup:

```yaml
# backs up .env files, volumes, bind mounts, and an application-consistent pg_dumpall of every database
labels:
  - "resq.enable=true"
  - "resq.db.type=mysql"
  - "resq.db.user=app"
  - "resq.db.name=all"
```

That's it. Run `./resq.sh` and every labeled container is backed up to every configured restic repository, with
retention and per-stack tagging applied automatically.

You can find a list of all labels and their purposes in the [configuration](#configuration) section below.

## Why this exists

Personal story: I've fucked up my databases more than once by forgetting to update backup configs after
adding new services, and the restore process (if even possible due to lack of backup) was always a nightmare of finding
the right backup, copying it somewhere, and running `restic restore` with the right tags and paths.

It got so bad that at one point I even wrote about it [on LinkedIn](https://www.linkedin.com/posts/mashb1t_devops-backups-restic-share-7461136100397428736-y4Gh).

I needed a backup solution that followed the infrastructure instead of adding manual work.

Most backup tools work like this: like "back up these paths on this schedule".
Container infrastructure should IMHO work like "back up the state of every running service without me touching the
backup config."

I didn't find a solution that fully suited my needs, there only was a weird combination of tools that got close but
never fully delivered.
One solution came very close and would have involved https://github.com/offen/docker-volume-backup with custom pre- and
post-export commands, but this would lead to full backup zip files being created in addition to the exports, which would
have to be cleaned up manually.

So I built `resq` to be the backup tool I wanted to use, and I'm sharing it in case it can save someone else the same
headache.

Trade-offs:

|                                              | resq                                     | Backrest           | Duplicati      | restic + cron           | Docker Volume Backup |
|----------------------------------------------|------------------------------------------|--------------------|----------------|-------------------------|----------------------|
| Discovers backup targets from docker labels  | ✅                                        | ❌                  | ❌              | ❌                       | partial              |
| Application-consistent DB dumps built in     | ✅ (pg, mysql, mongo, sqlite, redis)      | hooks              | hooks          | ❌                       | ❌                    |
| Stop-and-restart for cold-consistent volumes | ✅ (`resq.stop=true`)                     | ❌                  | ❌              | ❌                       | ❌                    |
| Per-stack `.env` file capture                | ✅                                        | ❌                  | ❌              | ❌                       | ❌                    |
| Multiple restic backends in one run          | ✅                                        | ✅                  | ✅              | manual                  | ❌                    |
| Standard restic repo format                  | ✅                                        | ✅                  | ❌ (own format) | ✅                       | ✅                    |
| Multi-host into one deduped repo             | ✅ (`--host` scoped retention)            | ✅                  | partial        | ✅                       | ✅                    |
| Auto-init repos on first use                 | ✅                                        | manual             | manual         | manual                  | manual               |
| Strict failure surfacing                     | ✅ (any restic op fails → repo run fails) | ✅                  | ✅              | depends on cron wrapper | ❌                    |
| Runtime weight                               | bash + restic                            | restic + Go server | .NET runtime   | restic                  | bash + restic        |
| Lines to read before trusting it             | ~400                                     | ~50k               | ~250k          | n/a                     | ~150                 |
| Web UI                                       | ❌ (pair with Backrest as viewer)         | ✅                  | ✅              | ❌                       | ❌                    |

`resq` is the simplest and most effective tool when the running docker compose stack *is* the source of truth for what
should be backed up, and you want backups to follow the infrastructure automatically.

## How it works

1. **Discovers** containers with `resq.enable=true` via `docker ps`.
2. **Dumps** each container's database into `/tmp/docker-dumps/` using the tool that matches `resq.db.type` and
   credentials from the container's own environment variables (no per-tool secret storage).
3. **Stops** the container if `resq.stop=true`, snapshot its volumes, then start it again after collection.
4. **Collects** named docker volumes (mountpoint lookup) and bind mounts (explicit list or auto-discovery with
   system-path exclusions). Single-file mounts like Traefik's `acme.json` are included.
5. **Scopes `.env`** capture to compose project directories of the enabled containers, deduped per stack.

Then per restic repository in `repos.conf`:

6. **Probes** the repo. Exit 10 (doesn't exist) triggers `restic init`. Any other non-zero skips the repo.
7. **Pushes** every collected target with consistent tag schema: `<container> <kind> <db>` for content +
   `plan:resq instance:<host>` for Backrest grouping.
8. **Forgets + prunes** scoped to this host so multiserver repos don't cross-prune snapshots from other machines.

Any restic step that fails returns non-zero from the repo loop, the warning is logged, and the next repository is still
attempted.

## Setup

```bash
git clone https://gitlab.com/mashb1t/resq.git
cd resq
cp .env.example .env          # optional, edit if using AWS S3 / Backblaze B2 or similar cloud storage
cp repos.conf.example repos.conf
openssl rand -hex 64 > .restic-password
chmod 600 .restic-password .env

# edit repos.conf to add your restic repositories and retention settings

# manually run
./resq.sh

# and/or add to cron for nightly runs
echo "0 3 * * *  /path/to/resq.sh >> /var/log/resq.log 2>&1" | crontab -
```

Requirements on the host:

- `restic` (1.7+ recommended)
- `bash` 4+, `docker` CLI
- Network access to whatever backends are listed in `repos.conf`

The script auto-runs `restic init` on first push to an empty repo, so no manual bootstrap per backend.

## Configuration

### Docker labels

| Label              | Default        | Purpose                                                               |
|--------------------|----------------|-----------------------------------------------------------------------|
| `resq.enable`      | `false`        | Master switch, required.                                              |
| `resq.name`        | container name | Override the name used in tags + dump filenames.                      |
| `resq.db.type`     | `none`         | `postgres`, `mysql`, `mongo`, `redis`, `redis-aof`, `sqlite`, `none`. |
| `resq.db.user`     | ``             | Username for postgres/mysql/mongo dumps.                              |
| `resq.db.name`     | `all`          | Database to dump. `all` uses pg_dumpall / `--all-databases`.          |
| `resq.db.path`     | ``             | For sqlite: in-container path to the .db file.                        |
| `resq.stop`        | `false`        | Stop the container around volume snapshotting.                        |
| `resq.bind-mounts` | (auto)         | Comma-separated explicit list of paths. Overrides auto-discovery.     |

Credentials for DB dumps are read from the container's existing environment variables (`POSTGRES_PASSWORD`,
`MYSQL_ROOT_PASSWORD`, `MONGO_INITDB_ROOT_PASSWORD`), so no secret has to be duplicated into labels.

### `repos.conf`

```
NAME|REPO_URL|ENV_VARS|DAILY|WEEKLY|MONTHLY
```

See `repos.conf.example` for all ten supported backends (local, SFTP, REST, B2, S3, S3-compatible, Azure, GCS, Swift,
rclone). Credentials belong in `.env` (gitignored) rather than the `ENV_VARS` column.

### `.env`

Auto-sourced at startup with `set -a`, so any variable defined here is exported and reaches restic and its
sub-processes.
See `.env.example` for the supported credential vars per backend.

## Snapshot layout

Every snapshot carries enough tags to find it without remembering filenames.

For container content:

```
plan:resq  instance:<host>  <service>  bind:data  db:sqlite
plan:resq  instance:<host>  <service>  db-dump    db:sqlite
plan:resq  instance:<host>  <database>  bind:pgdata  db:postgres
```

For env files, per compose project:

```
plan:resq  instance:<host>  <service>  env-files
plan:resq  instance:<host>  <service>  env-files
```

Useful queries:

```bash
restic snapshots --tag plan:resq                       # everything from this tool
restic snapshots --tag instance:<host>                 # everything from this host
restic snapshots --tag <service>                       # one container
restic snapshots --tag <service> --tag db-dump         # just the app-consistent dump
restic snapshots --tag env-files                       # all env-file captures
```

## Pairing with Backrest

`resq` is CLI-only by design. For a web UI, point [Backrest](https://github.com/garethgeorge/backrest) at the same
restic repositories as a read-only viewer:

- Add each repo via *Add Repository* form in Backrest, password file `/restic-password`.
- Don't create Backrest plans, let `resq` keep producing snapshots.
- Disable Backrest auto-prune (the script prunes per-host already).

The `plan:resq` + `instance:<host>` tags group all script-produced snapshots under one named plan in Backrest's UI,
instead of the default "_unassociated_" bucket.

A working compose for the companion Backrest container can be found at `docker-compose.yml`.

## Multi-host setups

Multiple hosts can write into the same restic repository safely:

- Same `.restic-password` deployed to every host.
- restic deduplicates content blobs across hosts (one copy of identical files).
- `restic forget` is invoked with `--host "$(hostname)"`, so each host only prunes snapshots it produced.

## Cron

Run nightly:

```cron
0 3 * * *  /opt/resq/backup.sh >> /var/log/resq.log 2>&1
```

The script's own retention (`DAILY|WEEKLY|MONTHLY` in `repos.conf`) handles forgetting, so a single cron entry is all
you need.

## License

GPL-3.0 — see [LICENSE](LICENSE).
