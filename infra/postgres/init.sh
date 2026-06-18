#!/bin/sh
set -eu

# init.sh — first-boot bootstrap for a standalone, app-agnostic data layer.
#
# Mounted at /docker-entrypoint-initdb.d/01-init.sh. The official postgres image
# runs every *.sh / *.sql here EXACTLY ONCE: only on the first boot of an empty
# data volume. On later boots PGDATA already exists and this is skipped. At this
# point we are the bootstrap superuser ($POSTGRES_USER), connected over the
# local unix socket — no network auth involved.
#
# Least-privilege split: POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB are the
# SUPERUSER, used only here. The actual application connects as the unprivileged
# APP_DB_USER role created below. pgbouncer and the app never use the superuser.
#
# Per-app config (set these in the instance's env, see .env.example):
#   APP_DB_USER, APP_DB_NAME, APP_DB_PASSWORD

: "${APP_DB_USER:=app}"
: "${APP_DB_NAME:=app}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD must be set for first-boot bootstrap}"

# Create the app role if it does not already exist. The password is passed as a
# psql variable and quoted with %L so special characters are handled safely.
psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname "$POSTGRES_DB" \
     --set app_user="$APP_DB_USER" \
     --set app_password="$APP_DB_PASSWORD" <<-'EOSQL'
  SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
  \gexec
EOSQL

# CREATE DATABASE can't run in a transaction/DO block and its name can't be
# parameterised in DDL, so create it conditionally from the shell over the same
# superuser socket connection, owned by the app role.
if ! psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
      -tAc "SELECT 1 FROM pg_database WHERE datname = '$APP_DB_NAME'" | grep -q 1; then
  createdb --username "$POSTGRES_USER" --owner "$APP_DB_USER" "$APP_DB_NAME"
fi

echo "init.sh: bootstrapped role '$APP_DB_USER' and database '$APP_DB_NAME'."
