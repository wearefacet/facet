#!/bin/sh
# Smoke checks for the container images (doc/plans/container-release.md §5.8).
# Shared by `make docker_smoke` and the CI smoke job. One stack, five checks,
# plus the FACET_CONFIG_FILE override probe. Exits non-zero on the first
# failed check, so a green run is the only proof path.

set -eu

COMPOSE="docker compose -f docker/compose.smoke.yml"
BACKEND_URL="http://127.0.0.1:${SMOKE_BACKEND_PORT:-18081}"
FRONTEND_URL="http://127.0.0.1:${SMOKE_FRONTEND_PORT:-18082}"
OVERRIDE_PORT="${SMOKE_OVERRIDE_PORT:-18083}"

step() { printf 'smoke: %s\n' "$1"; }

for image in "${BACKEND_IMAGE:-facet}" "${FRONTEND_IMAGE:-facet-frontend}"; do
  if ! docker image inspect "$image" > /dev/null 2>&1; then
    echo "smoke: image $image not found — run make docker_images first (or pull it)" >&2
    exit 1
  fi
done

# A clean state on every run: previous smoke containers (and their throwaway
# data) go away before the stack boots.
$COMPOSE down --remove-orphans > /dev/null 2>&1 || true

# ── 1. the stack comes up green ─────────────────────────────────────────
step "up -d --wait"
$COMPOSE up -d --wait

# ── 2. backend /Healthcheck on the published port ───────────────────────
step "backend /Healthcheck"
curl -fsS "${BACKEND_URL}/Healthcheck" | grep -q '"status":"ok"'

# ── 3. the login page fetches end to end through the frontend ───────────
# Anonymous / redirects to /login; the SSR auth hook answers through the
# node adapter. A 200 final code proves the whole chain.
step "login page through the frontend"
code=$(curl -sS -o /dev/null -w '%{http_code}' -L "${FRONTEND_URL}/")
if [ "$code" != "200" ]; then
  echo "smoke: expected 200 for / through the frontend, got $code" >&2
  exit 1
fi

# ── 4. core doctypes: migrate + seed:core booted an empty volume ────────
step "core doctype rows"
doctype_count=$($COMPOSE exec -T postgres psql -U facet -d facet_smoke -tAc \
  "SELECT count(*) FROM projections WHERE domain='core' AND doc_type='DocType' AND deleted_at IS NULL")
if [ "$doctype_count" -le 0 ]; then
  echo "smoke: expected core doctype rows, got $doctype_count" >&2
  exit 1
fi

# ── 5. restart: the second boot re-runs the bootstrap and stays healthy ─
step "restart the stack"
$COMPOSE stop
$COMPOSE up -d --wait
curl -fsS "${BACKEND_URL}/Healthcheck" | grep -q '"status":"ok"'
doctype_count2=$($COMPOSE exec -T postgres psql -U facet -d facet_smoke -tAc \
  "SELECT count(*) FROM projections WHERE domain='core' AND doc_type='DocType' AND deleted_at IS NULL")
if [ "$doctype_count2" != "$doctype_count" ]; then
  echo "smoke: doctype count changed over the restart ($doctype_count -> $doctype_count2)" >&2
  exit 1
fi

# ── 6. FACET_CONFIG_FILE override ───────────────────────────────────────
# A copy of the shipped example with two values changed, mounted read-only,
# must boot through the explicit path: no render, the mounted file wins.
step "FACET_CONFIG_FILE override"
override_file=$(mktemp)
# The image user (uid 10001) reads the mount — mktemp's 600 mode would
# deny it (File::AccessDeniedError at config load). The file carries
# `!env` names only, never values, so 644 is safe here.
chmod 644 "$override_file"
cleanup() {
  docker rm -f facet-smoke-override > /dev/null 2>&1 || true
  rm -f "$override_file"
}
trap cleanup EXIT
$COMPOSE exec -T backend cat /app/config.production.example.yml > "$override_file"
sed -i.bak \
  -e 's/statement_timeout_ms: 5000/statement_timeout_ms: 4000/' \
  -e 's/default_language: en/default_language: fr/' \
  "$override_file"
rm -f "${override_file}.bak"
if ! grep -q 'statement_timeout_ms: 4000' "$override_file"; then
  echo "smoke: the override edit did not apply" >&2
  exit 1
fi
$COMPOSE run -d --name facet-smoke-override \
  -p "127.0.0.1:${OVERRIDE_PORT}:3000" \
  -e FACET_CONFIG_FILE=/etc/facet/facet.yml \
  -v "${override_file}:/etc/facet/facet.yml:ro" \
  backend server
i=0
until [ "$i" -ge 24 ]; do
  if curl -fsS "http://127.0.0.1:${OVERRIDE_PORT}/Healthcheck" 2> /dev/null | grep -q '"status":"ok"'; then
    break
  fi
  i=$((i + 1))
  sleep 5
done
if ! curl -fsS "http://127.0.0.1:${OVERRIDE_PORT}/Healthcheck" 2> /dev/null | grep -q '"status":"ok"'; then
  docker ps -a --filter name=facet-smoke-override --format 'smoke: override container state: {{.Status}}' >&2
  docker logs facet-smoke-override 2>&1 | tail -20 >&2 || true
  echo "smoke: the FACET_CONFIG_FILE override container never became healthy" >&2
  exit 1
fi
curl -fsS "http://127.0.0.1:${OVERRIDE_PORT}/Healthcheck" | grep -q '"status":"ok"'
docker logs facet-smoke-override 2>&1 | grep -q "FACET_CONFIG_FILE is set"
docker exec facet-smoke-override test ! -f /app/config.production.yml

step "all checks passed"
