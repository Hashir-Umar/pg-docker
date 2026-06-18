#!/usr/bin/env bash
set -euo pipefail

# create-db.sh — single entry point for a Postgres + pgbouncer instance.
#
# Selects an environment (dev | prod), reads the matching env file, and drives
# the matching compose stack so you never type docker-compose flags by hand.
#
# Usage:
#   ./create-db.sh <env> [command]
#
#   <env>      dev | prod          (which docker-compose.<env>.yml to use)
#   [command]  default: up
#
# Commands:
#   up | create   create/start the instance, then print how to connect
#   down          stop & remove containers (KEEPS the data volume)
#   destroy       stop & remove containers AND the data volume (deletes data!)
#   restart       restart containers
#   logs          follow container logs
#   status | ps   show container status
#   psql          open a psql shell on the app database
#   backup        (prod only) run an on-demand backup now
#   config        render the fully-resolved compose config (debug)
#
# Env file resolution: defaults to .env.<env> next to this script.
# Override with ENV_FILE, e.g. to run a second instance:
#   ENV_FILE=./app-b.prod.env ./create-db.sh prod up

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

env="${1:-}"
cmd="${2:-up}"

case "$env" in
  dev|prod) ;;
  -h|--help|help) usage 0 ;;
  "") echo "✗ missing environment (dev|prod)" >&2; echo; usage 1 ;;
  *)  echo "✗ unknown environment: $env (expected dev|prod)" >&2; exit 1 ;;
esac

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.$env.yml"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.$env}"

[ -f "$COMPOSE_FILE" ] || { echo "✗ compose file not found: $COMPOSE_FILE" >&2; exit 1; }
if [ ! -f "$ENV_FILE" ]; then
  echo "✗ env file not found: $ENV_FILE" >&2
  echo "  create it first:   cp .env.example $ENV_FILE   then edit the values" >&2
  exit 1
fi

# Load the env file so this script (psql, messages) sees the same values that
# compose will use for substitution. Keep comments on their own lines in .env.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# Required.
: "${DB_PREFIX:?DB_PREFIX is required in $ENV_FILE}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required in $ENV_FILE}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD is required in $ENV_FILE}"

# Defaults mirror the compose files so printed info is accurate.
APP_DB_USER="${APP_DB_USER:-app}"
APP_DB_NAME="${APP_DB_NAME:-app}"
POSTGRES_HOST_BIND="${POSTGRES_HOST_BIND:-127.0.0.1}"
POSTGRES_HOST_PORT="${POSTGRES_HOST_PORT:-5432}"
PGBOUNCER_HOST_BIND="${PGBOUNCER_HOST_BIND:-127.0.0.1}"
PGBOUNCER_HOST_PORT="${PGBOUNCER_HOST_PORT:-6432}"

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

print_conn() {
  cat <<EOF

✓ [$env] instance '$DB_PREFIX' is up.

  App → pgbouncer (use this in your app):
    postgres://$APP_DB_USER:<APP_DB_PASSWORD>@$PGBOUNCER_HOST_BIND:$PGBOUNCER_HOST_PORT/$APP_DB_NAME

  Direct → postgres (migrations / GUI / psql):
    postgres://$APP_DB_USER:<APP_DB_PASSWORD>@$POSTGRES_HOST_BIND:$POSTGRES_HOST_PORT/$APP_DB_NAME

  Shell:   ./create-db.sh $env psql
  Logs:    ./create-db.sh $env logs
EOF
}

case "$cmd" in
  up|create)
    compose up -d
    print_conn
    ;;
  down)
    compose down
    ;;
  destroy)
    printf "This DELETES all data in the volume for [%s] '%s'. Continue? [y/N] " "$env" "$DB_PREFIX"
    read -r reply
    case "$reply" in
      y|Y) compose down -v ;;
      *)   echo "aborted." ;;
    esac
    ;;
  restart)
    compose restart
    ;;
  logs)
    compose logs -f
    ;;
  status|ps)
    compose ps
    ;;
  psql)
    compose exec postgres psql -U "$APP_DB_USER" -d "$APP_DB_NAME"
    ;;
  backup)
    if [ "$env" != "prod" ]; then
      echo "✗ backups are only configured in prod (no pg-backup service in dev)." >&2
      exit 1
    fi
    echo "running on-demand backup..."
    compose exec pg-backup /backup.sh
    echo "✓ done. dumps are in ${BACKUP_DIR:-./backups}"
    ;;
  config)
    compose config
    ;;
  *)
    echo "✗ unknown command: $cmd" >&2
    usage 1
    ;;
esac
