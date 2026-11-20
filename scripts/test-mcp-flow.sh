#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Manual end-to-end test of the MCP OAuth flow — no Inspector, no client
# library, just curl + openssl + jq. Exercises the five stages:
#
#   1. 401 challenge        — WWW-Authenticate with resource_metadata pointer
#   2. Discovery documents  — PRM (RFC 9728) + AS metadata (RFC 8414)
#   3. Authorize (browser)  — PKCE + resource + role; you paste the code back
#   4. Token exchange       — code + verifier → aud-pinned access token
#   5. MCP calls            — initialize / tools/list / tools/call ping
#
# Usage:
#   ./scripts/test-mcp-flow.sh [role_slug] [redirect_port]
#
#   role_slug      defaults to iam.Roles.admin
#   redirect_port  defaults to 9999 — the script starts a callback HTTP
#                  server on it and prints the authorize URL; open it in a
#                  browser, log in, approve consent, and the redirect lands
#                  on the listener.
#
# Requires: curl, openssl, jq, crystal. Server assumed at
# https://facet.localhost:3443 (the Caddy dev proxy) — override with BASE_URL.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_URL="${BASE_URL:-https://facet.localhost:3443}"
ROLE_SLUG="${1:-iam.Roles.admin}"
CB_PORT="${2:-9999}"
CB_URI="http://127.0.0.1:${CB_PORT}/cb"
CLIENT_ID="manual-test-client"
RESOURCE="${BASE_URL}/Api/_mcp/${ROLE_SLUG}"

CURL="curl -sk"   # -k: the local Caddy cert is self-signed-trusted

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; exit 1; }

command -v jq     >/dev/null || { echo "jq is required";  exit 1; }
command -v openssl >/dev/null || { echo "openssl is required"; exit 1; }
command -v crystal >/dev/null || { echo "crystal is required"; exit 1; }

# Resolve this script's directory so the callback server (a sibling .cr file)
# is found regardless of the caller's working directory.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CALLBACK_SERVER="${SCRIPT_DIR}/callback_server.cr"

# ── 1. Challenge ─────────────────────────────────────────────────────
step "1. Unauthenticated MCP call — expect 401 + WWW-Authenticate"
headers=$($CURL -i -X POST "${BASE_URL}/Api/_mcp/${ROLE_SLUG}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}')

echo "$headers" | head -1
www=$(echo "$headers" | grep -i '^WWW-Authenticate:' || true)
if [ -z "$www" ]; then fail "no WWW-Authenticate header on 401"; fi
echo "$www"
echo "$www" | grep -q 'Bearer resource_metadata=' \
  || fail "WWW-Authenticate lacks resource_metadata"
ok "challenge advertises the PRM document"

# ── 2. Discovery ─────────────────────────────────────────────────────────────
step "2. Discovery documents"
prm=$($CURL "${BASE_URL}/.well-known/oauth-protected-resource?resource=${RESOURCE}")
echo "$prm" | jq .
echo "$prm" | jq -e '.resource' >/dev/null || fail "PRM has no resource field"
echo "$prm" | jq -e '.authorization_servers' >/dev/null || fail "PRM has no authorization_servers"
ok "PRM (RFC 9728) complete"

asm=$($CURL "${BASE_URL}/.well-known/oauth-authorization-server")
echo "$asm" | jq .
echo "$asm" | jq -e '.authorization_endpoint' >/dev/null || fail "AS metadata has no authorization_endpoint"
echo "$asm" | jq -e '.token_endpoint' >/dev/null || fail "AS metadata has no token_endpoint"
echo "$asm" | jq -e '.code_challenge_methods_supported | index("S256")' >/dev/null \
  || fail "AS metadata does not advertise S256"
echo "$asm" | jq -e '.authorization_response_iss_parameter_supported == true' >/dev/null \
  || fail "AS metadata does not advertise RFC 9207 iss support"
ok "AS metadata (RFC 8414 + 9207) complete"

# ── 3. Authorize ─────────────────────────────────────────────────────
step "3. Authorize — PKCE pair + browser consent"
VERIFIER=$(openssl rand -base64 60 | tr -d '\n=+/' | cut -c1-64)
CHALLENGE=$(printf %s "$VERIFIER" | openssl dgst -sha256 -binary \
  | openssl base64 | tr '+/' '-_' | tr -d '=')
STATE="manual-$(date +%s)"

AUTH_URL="${BASE_URL}/OAuth/authorize?response_type=code&client_id=${CLIENT_ID}&redirect_uri=$(printf %s "$CB_URI" | jq -sRr @uri)&code_challenge=${CHALLENGE}&code_challenge_method=S256&state=${STATE}&resource=$(printf %s "$RESOURCE" | jq -sRr @uri)&role=${ROLE_SLUG}"

# The pre-check follows redirects: with no browser session the authorize
# endpoint now bounces to the frontend login (302) instead of returning the
# consent JSON directly. A 200/302/303 all prove the endpoint is alive; only
# a hard error (4xx/5xx without a login redirect) fails the stage.
http_code=$($CURL -o /dev/null -w '%{http_code}' "$AUTH_URL")
case "$http_code" in
  200|301|302|303) ok "authorize GET responds (HTTP $http_code — consent data or login bounce)" ;;
  *) fail "authorize GET failed (HTTP $http_code)" ;;
esac

# Wait for the redirect: the callback server prints the raw HTTP request line
# containing ?code= AND replies with a 200 HTML page so the browser tab closes
# instead of hanging on "keep loading" (the failure mode of a bare `nc -l`
# listener, which never sends an HTTP response).
echo "  Opening the authorize URL in your browser…"
echo "  $AUTH_URL"
echo
echo "  If your session has expired you will land on the login page first —"
echo "  sign in and you return to the authorize flow automatically."
echo "  Waiting for the redirect on 127.0.0.1:${CB_PORT} — Ctrl+C to cancel."

request_file=$(mktemp)
trap 'rm -f "$request_file" "${request_file}.err"; kill "${listener_pid:-}" 2>/dev/null || true' EXIT

"$CALLBACK_SERVER" "${CB_PORT}" > "$request_file" 2>"${request_file}.err" &
listener_pid=$!

# Give the listener a moment to bind, then open the browser. We background
# and disown `xdg-open` because on some desktop environments it blocks until
# the launched application exits — holding the script hostage until the browser
# is closed. Detaching lets the wait loop below proceed independently.
sleep 1
if ! kill -0 "$listener_pid" 2>/dev/null; then
  cat "${request_file}.err" >&2
  fail "callback server failed to start"
fi
if command -v xdg-open >/dev/null 2>&1; then
  (xdg-open "$AUTH_URL" >/dev/null 2>&1 &) ||
    echo "  (xdg-open failed — open the URL above manually)"
else
  echo "  (xdg-open not found — open the URL above manually)"
fi

# Bounded wait so a hung browser cannot stall the script forever.
waited=0
while kill -0 "$listener_pid" 2>/dev/null; do
  if [ "$waited" -ge 120 ]; then
    fail "no redirect received within 120s"
  fi
  sleep 1
  waited=$((waited + 1))
done
wait "$listener_pid" 2>/dev/null || true

request_line=$(head -1 "$request_file")
echo "  $request_line"

CODE=$(echo "$request_line" | grep -o 'code=[^& ]*' | cut -d= -f2)
[ -n "$CODE" ] || fail "no code parameter on the redirect"
returned_state=$(echo "$request_line" | grep -o 'state=[^& ]*' | cut -d= -f2)
[ "$returned_state" = "$STATE" ] || fail "state mismatch on the redirect (CSRF?)"
ok "authorization code captured, state verified"

# ── 4. Token exchange ────────────────────────────────────────────────────────
step "4. Token exchange"
token_response=$($CURL -X POST "${BASE_URL}/OAuth/token" \
  -d grant_type=authorization_code \
  -d "code=${CODE}" \
  -d "client_id=${CLIENT_ID}" \
  -d "redirect_uri=${CB_URI}" \
  -d "code_verifier=${VERIFIER}" \
  -d "resource=${RESOURCE}")
echo "$token_response" | jq .

TOKEN=$(echo "$token_response" | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || fail "no access_token in the response"

# Decode the payload and verify the claims that matter.
payload=$(echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' )
payload="${payload}==="
claims=$(echo "$payload" | base64 -d 2>/dev/null | jq .)
echo "$claims"
echo "$claims" | jq -e --arg r "$RESOURCE" '.aud == $r' >/dev/null \
  || fail "token aud does not equal the resource identifier"
echo "$claims" | jq -e --arg role "$ROLE_SLUG" '.role == $role' >/dev/null \
  || fail "token role does not equal the mounted role"
echo "$claims" | jq -e '.app == null' >/dev/null \
  || fail "token carries an app claim — MCP tokens must not"
echo "$claims" | jq -e '.typ == "access"' >/dev/null \
  || fail "token typ is not access"
ok "token claims correct (aud pinned, role pinned, no app claim)"

REFRESH_TOKEN=$(echo "$token_response" | jq -r '.refresh_token // empty')

# ── 5. MCP calls ─────────────────────────────────────────────────────────────
step "5. MCP calls with the token"

init=$($CURL -X POST "${BASE_URL}/Api/_mcp/${ROLE_SLUG}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual-test","version":"0.0.0"}}}')
echo "$init" | jq .
echo "$init" | jq -e '.result.serverInfo.name' >/dev/null || fail "initialize failed"
ok "initialize"

tools=$($CURL -X POST "${BASE_URL}/Api/_mcp/${ROLE_SLUG}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
echo "$tools" | jq .
echo "$tools" | jq -e '.result.tools | length > 0' >/dev/null || fail "tools/list empty"
ok "tools/list (role-filtered)"

ping=$($CURL -X POST "${BASE_URL}/Api/_mcp/${ROLE_SLUG}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping","arguments":{}}}')
echo "$ping" | jq .
echo "$ping" | jq -e '.result.isError == false' >/dev/null || fail "tools/call ping failed"
ok "tools/call ping"

# ── 6. Replay guards (bonus) ─────────────────────────────────────────────────
step "6. Negative checks"
replay=$($CURL -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/OAuth/token" \
  -d grant_type=authorization_code \
  -d "code=${CODE}" \
  -d "client_id=${CLIENT_ID}" \
  -d "redirect_uri=${CB_URI}" \
  -d "code_verifier=${VERIFIER}" \
  -d "resource=${RESOURCE}")
[ "$replay" = "400" ] || fail "code replay did not fail (got HTTP $replay)"
ok "authorization code is single-use"

wrong_aud=$($CURL -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/Api/_mcp/${ROLE_SLUG}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"ping"}')
# Wrong-aud check: call the OTHER role's URL with this token. Only meaningful
# when a second role exists; skipped gracefully when the slug equals the role.
if [ "${ROLE_SLUG}" != "iam.Roles.admin" ]; then
  other=$($CURL -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/Api/_mcp/iam.Roles.admin" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":5,"method":"ping"}')
  [ "$other" = "401" ] || fail "token accepted on another role's URL (got HTTP $other)"
  ok "token rejected on another role's URL (role pinning)"
else
  echo "  (skipped — running against admin; pass another role_slug to test pinning)"
fi

echo
printf '\033[1;32mALL CHECKS PASSED\033[0m — server-side flow is correct.\n'
[ -n "$REFRESH_TOKEN" ] && echo "Refresh token (for later use): $REFRESH_TOKEN"
