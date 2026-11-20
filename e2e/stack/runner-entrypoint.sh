#!/bin/sh
# Runner entrypoint: wait for Caddy's internal root CA, then exec the
# given command (usually `pnpm exec playwright test --project=…`).
#
# The runner mounts Caddy's /data read-only as /caddy-data and gets
# NODE_EXTRA_CA_CERTS=<root.crt> — Node clients (Playwright request
# fixture, the facet CLI later) then trust the stack's TLS without
# disabling verification. The root CA is written when Caddy provisions
# its internal PKI; force one handshake so the wait cannot hang on a
# stack that never received a browser visit.
set -eu

root_ca=/caddy-data/caddy/pki/authorities/local/root.crt

i=0
while [ ! -f "$root_ca" ] && [ "$i" -lt 30 ]; do
  # One unverified child fetch — Caddy keeps serving; the parent process
  # is unaffected.
  NODE_TLS_REJECT_UNAUTHORIZED=0 node -e "fetch('https://facet.localhost:3443/Login').catch(() => process.exit(1))" >/dev/null 2>&1 || true
  sleep 1
  i=$((i + 1))
done

if [ ! -f "$root_ca" ]; then
  echo "runner: Caddy root CA did not appear at $root_ca" >&2
  exit 1
fi

exec "$@"
