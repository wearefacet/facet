#!/bin/sh
# Backend entrypoint for the e2e stack (harness §4).
#
# Writes config.e2e.yml from the template, runs the baseline chain
# (`db_reset --yes seed:dev` + CRM + production + iam bundle imports) once,
# then execs the server. `--yes` is required: the container has no TTY, so
# the db_reset confirmation gate would refuse without it. The compose healthcheck gates the stack on
# /Healthcheck, so a failed boot turns into an unhealthy service instead of
# a half-alive one.

set -eu

cd /app

# Facet::Config fails loud when config.#{APP_ENV}.yml is missing — render
# it before anything touches the config.
cp /app/config.e2e.yml.tmpl /app/config.e2e.yml

# The artifact store lives on the stack's tmpfs (mounted at /data).
mkdir -p /data/store

attempt=1
while :; do
  if echo "facet db_reset --yes seed:dev (attempt $attempt)" && ./facet db_reset --yes seed:dev; then
    break
  fi
  if [ "$attempt" -ge 3 ]; then
    echo "backend: db_reset seed:dev failed after $attempt attempts" >&2
    exit 1
  fi
  sleep 3
  attempt=$((attempt + 1))
done

echo "importing the CRM bundle"
./facet domain:import /app/data/fixtures/crm.facet-domain

# The iam bundle's production_editor role carries $mine scopes on
# production.* doctypes. The import authoring gate (B-277) validates role
# scopes against registered doctypes, so the production bundle must land
# first — the same dependency order scripts/import-fixtures uses.
echo "importing the production bundle (iam.Roles.production_editor scopes resolve against it)"
./facet domain:import /app/data/fixtures/production.facet-domain

echo "importing the iam bundle (--merge: seed:dev pre-created the iam domain)"
./facet domain:import /app/data/fixtures/iam.facet-domain --merge

exec ./facet server
