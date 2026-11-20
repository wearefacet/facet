#!/bin/sh
# Backend entrypoint for the release image (doc/plans/container-release.md §5.4).
#
# Renders the config file when absent, then — for the server command —
# runs the idempotent bootstrap chain (migrate → seed:core) and execs the
# server. Never db_reset: the bootstrap is safe on every boot and
# destructive on none, so an existing volume is only ever migrated and
# seeded, never dropped.
#
# Config resolution (the contract the smoke stack depends on), fail loud:
#   1. FACET_CONFIG_FILE — an explicit path, any mount point;
#   2. /app/config.{APP_ENV}.yml — the operator's mount, or the copy of
#      the shipped example written only when that file is absent;
#   3. nothing — the boot fails with the missing path in the message
#      (Facet::Config raises; this script then exits with its code).

set -eu

cd /app

APP_ENV_VALUE="${APP_ENV:-production}"
CONFIG_PATH="/app/config.${APP_ENV_VALUE}.yml"

# Render the config template only when the target file is absent. Three
# overwrite paths sit above the render and are never touched:
#   - FACET_CONFIG_FILE set: the operator owns the path — no render;
#   - the target file exists: a mounted file wins — no render;
#   - otherwise: copy the shipped example (every `!env NAME` in it must be
#     supplied by the environment — a missing one fails the boot loud).
if [ -n "${FACET_CONFIG_FILE:-}" ]; then
  echo "backend: FACET_CONFIG_FILE is set — skipping the config render (${FACET_CONFIG_FILE})"
elif [ -f "$CONFIG_PATH" ]; then
  echo "backend: ${CONFIG_PATH} exists — skipping the config render"
else
  echo "backend: rendering ${CONFIG_PATH} from the shipped example"
  cp /app/config.production.example.yml "$CONFIG_PATH"
fi

# The artifact store root — pre-created in the image, re-asserted here so
# a bind mount with a foreign owner still has its directory.
mkdir -p /data/store

if [ "${1:-}" = "server" ]; then
  attempt=1
  while :; do
    if echo "facet migrate (attempt $attempt)" && ./facet migrate; then
      break
    fi
    if [ "$attempt" -ge 3 ]; then
      echo "backend: migrate failed after $attempt attempts" >&2
      exit 1
    fi
    sleep 3
    attempt=$((attempt + 1))
  done

  echo "facet seed:core"
  ./facet seed:core
fi

exec ./facet "$@"
