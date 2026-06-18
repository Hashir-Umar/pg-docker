# pg-docker

A standalone, **app-agnostic** PostgreSQL + pgbouncer data layer you can self-host
and spawn multiple times on a single machine — one instance per app, with separate
**dev** and **prod** profiles.

Each instance is namespaced by `DB_PREFIX`, so containers, network and the data
volume never collide. You drive everything through one script: **`create-db.sh`**.

```
./create-db.sh dev  up      # lean local stack
./create-db.sh prod up      # hardened stack (tuning + limits + backups)
```

---

## Contents

- [Architecture](#architecture)
- [Files](#files)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Dev vs prod](#dev-vs-prod)
- [Configuration](#configuration)
- [Performance tuning (prod)](#performance-tuning-prod)
- [Backups (prod)](#backups-prod)
- [Running several instances](#running-several-instances)
- [Application requirements (transaction pooling)](#application-requirements-transaction-pooling)
- [Security & remote access](#security--remote-access)
- [Scaling & limits — is this production-ready?](#scaling--limits--is-this-production-ready)
- [Verifying an instance](#verifying-an-instance)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
            host loopback                         docker network
  app ───────────────────────►  pgbouncer  ───────────────────►  postgres
        127.0.0.1:PGB_PORT      (txn pool)        :5432         (app role owns app db)
                                                                      ▲
  migrations / GUI / psql ──────────────────────────────────────────┘
        127.0.0.1:PG_PORT  (direct — bypasses the pool)         pg-backup (prod, nightly)
```

- **pgbouncer** (transaction pool) funnels many client connections into a small
  server-side pool — this is what lets you serve lots of connections.
- **postgres** holds the data. A superuser bootstraps once; the app then uses an
  unprivileged role (**least privilege**).
- **pg-backup** (prod only) takes nightly logical dumps with retention.

## Files

```
create-db.sh             # the one command you run (takes: dev|prod)
docker-compose.dev.yml   # DEV: lean, exposed loopback ports, stock tuning
docker-compose.prod.yml  # PROD: tuning + resource limits + healthchecks + backups
infra/postgres/init.sh   # shared first-boot bootstrap: creates app role + database
.env.example             # documented template for every knob
.env.dev / .env.prod     # your actual configs (git-ignored)
backups/                 # prod backup output (git-ignored)
.gitignore
README.md
```

## Quick start

```bash
# DEV
cp .env.example .env.dev     # (a ready-made .env.dev is already included)
./create-db.sh dev up

# PROD — edit passwords/tuning first!
cp .env.example .env.prod
$EDITOR .env.prod            # set strong passwords, size the tuning to your box
./create-db.sh prod up
```

Your app connects through pgbouncer:

```
postgres://<APP_DB_USER>:<APP_DB_PASSWORD>@127.0.0.1:<PGBOUNCER_HOST_PORT>/<APP_DB_NAME>
```

## Commands

```bash
./create-db.sh <env> up        # create / start (default command)
./create-db.sh <env> down      # stop & remove containers (keeps data volume)
./create-db.sh <env> destroy   # stop & remove containers AND volume (deletes data)
./create-db.sh <env> restart   # restart containers
./create-db.sh <env> logs      # follow logs
./create-db.sh <env> status    # container status
./create-db.sh <env> psql      # psql shell on the app database
./create-db.sh prod backup     # on-demand backup now (prod only)
./create-db.sh <env> config    # render the resolved compose config (debug)
```

## Dev vs prod

| Aspect             | `dev`                          | `prod`                                             |
| ------------------ | ------------------------------ | -------------------------------------------------- |
| Postgres tuning    | stock image defaults           | env-driven (`shared_buffers`, `work_mem`, …)       |
| Resource limits    | none                           | CPU + memory limits/reservations                   |
| Backups            | none                           | nightly `pg-backup` with retention                 |
| pgbouncer health   | —                              | healthcheck enabled                                |
| Pool defaults      | 100 clients / 20 server conns  | 1000 clients / 25 server conns + reserve pool      |
| Host ports (sample)| 5432 / 6432                    | 5544 / 6544 (so both can run together)             |
| Both share         | same `init.sh`, role split, SCRAM auth, loopback binds |                                 |

## Configuration

Set in `.env.<env>`. **Bold** = required.

| Variable                | Default       | Purpose                                          |
| ----------------------- | ------------- | ------------------------------------------------ |
| **`DB_PREFIX`**         | `pgdb-*`      | Namespaces project / containers / volume / net   |
| `POSTGRES_USER`         | `postgres`    | Superuser (bootstrap only)                       |
| **`POSTGRES_PASSWORD`** | —             | Superuser password                               |
| `POSTGRES_DB`           | `postgres`    | Superuser maintenance DB                         |
| `APP_DB_USER`           | `app`         | App role (created on first boot)                 |
| `APP_DB_NAME`           | `app`         | App database (owned by `APP_DB_USER`)            |
| **`APP_DB_PASSWORD`**   | —             | App role password                                |
| `POSTGRES_HOST_PORT`    | `5432`        | Host port → postgres (direct)                    |
| `PGBOUNCER_HOST_PORT`   | `6432`        | Host port → pgbouncer (app connects here)        |
| `*_HOST_BIND`           | `127.0.0.1`   | Bind addr (`0.0.0.0` to expose — needs TLS)      |
| `PGBOUNCER_*`           | see example   | Pool mode/size/auth/prepared-statements          |

Prod-only knobs (`PG_*` tuning, `*_CPU_LIMIT`/`*_MEMORY_LIMIT`, `BACKUP_*`) are
documented inline in `.env.example`.

## Performance tuning (prod)

`docker-compose.prod.yml` passes tuning as `-c` flags, all overridable from
`.env.prod`. Defaults assume **~2 GB RAM** allotted to postgres. Size to your box:

| Setting                  | Guideline                          | Default     |
| ------------------------ | ---------------------------------- | ----------- |
| `PG_SHARED_BUFFERS`      | ~25% of RAM                        | `512MB`     |
| `PG_EFFECTIVE_CACHE_SIZE`| ~75% of RAM                        | `1536MB`    |
| `PG_WORK_MEM`            | RAM ÷ (max_conns × ~2..4)          | `8MB`       |
| `PG_MAINTENANCE_WORK_MEM`| 5–10% of RAM (cap ~1GB)            | `128MB`     |
| `PG_MAX_CONNECTIONS`     | keep modest; pgbouncer pools       | `100`       |
| `PG_RANDOM_PAGE_COST`    | `1.1` for SSD/NVMe                 | `1.1`       |
| `PG_EFFECTIVE_IO_CONCURRENCY` | `200` for SSD/NVMe            | `200`       |

> Keep `PGBOUNCER_DEFAULT_POOL_SIZE` **well below** `PG_MAX_CONNECTIONS` —
> pgbouncer opens at most `pool_size × num_databases` server connections.

Resource limits (`POSTGRES_CPU_LIMIT`, `POSTGRES_MEMORY_LIMIT`, …) cap what the
containers can consume so a runaway query can't starve the host.

## Backups (prod)

The `pg-backup` service runs `pg_dump` on `BACKUP_SCHEDULE` (default `@daily`),
writing compressed dumps to `BACKUP_DIR` (default `./backups`) with day/week/month
retention (`BACKUP_KEEP_DAYS/WEEKS/MONTHS`).

```bash
./create-db.sh prod backup           # take a dump right now
ls backups/last/                     # latest dump per db
```

Restore (example):

```bash
gunzip -c backups/last/<db>-latest.sql.gz \
  | docker exec -i <DB_PREFIX>-postgres psql -U <APP_DB_USER> -d <APP_DB_NAME>
```

> ⚠️ These are **on-VPS logical dumps**. For real disaster recovery you must ship
> them **off-host** (S3/R2/B2) and ideally add WAL archiving / PITR
> (e.g. pgBackRest or `wal-g`). See [Scaling & limits](#scaling--limits--is-this-production-ready).

## Running several instances

Give each instance a unique `DB_PREFIX` **and** unique host ports, then select an
env file with `ENV_FILE`:

```bash
cp .env.example app-a.prod.env   # DB_PREFIX=app-a  ports 5601/6601
cp .env.example app-b.prod.env   # DB_PREFIX=app-b  ports 5602/6602

ENV_FILE=./app-a.prod.env ./create-db.sh prod up
ENV_FILE=./app-b.prod.env ./create-db.sh prod up
```

`DB_PREFIX` namespaces everything automatically (`app-a-postgres`, `app-a_pgdata`,
`app-a_default`, …), so instances never collide.

## Application requirements (transaction pooling)

pgbouncer runs in **transaction** mode (best for high connection counts). Your app
must be pool-compatible:

- **Prepared statements**: allowed via `PGBOUNCER_MAX_PREPARED_STATEMENTS` (pgbouncer
  ≥1.21). If you set it to `0`, disable client-side prepared statements
  (e.g. `postgres-js` `prepare: false`, node-postgres unnamed statements, JDBC
  `prepareThreshold=0`).
- **No session state across queries**: `SET`, session advisory locks, `LISTEN/NOTIFY`,
  `WITH HOLD` cursors don't survive between transactions in a pool.
- **Migrations / DDL**: connect **directly to postgres** (`POSTGRES_HOST_PORT`), not
  pgbouncer.

If your app genuinely needs session features, set `PGBOUNCER_POOL_MODE=session`
(fewer multiplexing benefits).

## Security & remote access

- Host ports bind to **`127.0.0.1`** by default — not publicly reachable.
- Auth is **SCRAM**; the app uses a least-privilege role, never the superuser.
- **App on another host?** Do **not** just set `*_HOST_BIND=0.0.0.0` — that exposes
  unencrypted Postgres traffic. Instead either:
  - keep it private and reach it over a VPN / private network, or
  - terminate TLS in front (nginx stream / stunnel / spider), or
  - run postgres with server certificates and require `sslmode=verify-full`.
- Never commit real `.env.*` files — they're git-ignored; only `.env.example` is tracked.

## Scaling & limits — is this production-ready?

**Yes for a single-node, self-hosted deployment** that scales *connections* (via
pgbouncer) and *load vertically* (via tuning + a bigger box). Suitable for small-to-
mid production workloads.

**What it deliberately does NOT provide** (single-node by design):

| Need                        | This stack            | For production-grade, add…                     |
| --------------------------- | --------------------- | ---------------------------------------------- |
| Many client connections     | ✅ pgbouncer          | —                                              |
| Vertical scaling / tuning   | ✅ env-driven         | a bigger machine                               |
| Crash-consistent backups    | ✅ nightly dumps      | **off-host** copies (S3/R2) + WAL/PITR         |
| High availability / failover| ❌ single node        | primary + replica, Patroni/repmgr, a load-balancer |
| Read scaling                | ❌                    | read replicas                                  |
| Point-in-time recovery      | ❌ (logical dumps)    | pgBackRest / wal-g with WAL archiving          |

If you need HA or PITR, that's a multi-node architecture change — out of scope for
this single-node stack, but the role/auth/tuning conventions here carry over.

## Verifying an instance

```bash
./create-db.sh prod status     # both containers up; postgres healthy
./create-db.sh prod psql       # opens psql as the app role on the app db
docker logs <DB_PREFIX>-postgres | grep init.sh   # confirms first-boot bootstrap
# confirm tuning took effect:
./create-db.sh prod psql -c "show shared_buffers;"   # (or run SHOW inside psql)
```

A healthy instance shows the app role owning the app database (`owner=app`) and the
superuser unused at runtime.

## Troubleshooting

- **`container ... is unhealthy` on first `up`** — usually a stale/old data volume.
  `./create-db.sh <env> destroy` then `up` (deletes data).
- **`port is already allocated`** — another instance uses the same host port. Change
  `POSTGRES_HOST_PORT` / `PGBOUNCER_HOST_PORT` in your env file.
- **postgres 18+ data-dir error** (`PostgreSQL data ... unused mount/volume`) — the
  volume must mount at `/var/lib/postgresql` (the parent), which these compose files
  already do. Don't change it back to `/var/lib/postgresql/data`.
- **Config change to `APP_DB_*` had no effect** — `init.sh` only runs on the *first*
  boot of an empty volume. Alter the role manually or `destroy` + recreate.
- **App errors about prepared statements** — see
  [Application requirements](#application-requirements-transaction-pooling).
- **Keep `.env` comments on their own line** — inline comments can leak into values.
