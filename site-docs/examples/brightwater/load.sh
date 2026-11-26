#!/usr/bin/env bash
#
# Load the Brightwater Rentals example into a running Facet instance.
#
# Creates the three business roles, the four people (with known passwords),
# and the two domain grants, then seeds the demo data with seed.py. Safe to
# re-run: every step looks its target up first and skips what exists.
#
# Prerequisites: the three domains (equipment, clients, rentals) are live on
# the instance. In development the domain watcher syncs them from this
# directory; on a fresh instance import the tarballs under bundles/ first.
# load.sh waits for the domains, then does the rest.
#
# Usage:  ./load.sh [base_url]     (default http://127.0.0.1:3000)
#
# People it creates (role, password):
#   nadia@brightwater.example   manager    brightwater-nadia
#   tom@brightwater.example     sales      brightwater-tom
#   lucia@brightwater.example   warehouse  brightwater-lucia
#   ravi@brightwater.example    admin      brightwater-ravi
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
FACET="$REPO_ROOT/scripts/facet"
BASE="${1:-http://127.0.0.1:3000}"
JAR="$(mktemp)"
trap 'rm -f "$JAR" "$JAR.login"' EXIT

step()  { printf '\n== %s ==\n' "$1"; }
ok()    { printf '  ok: %s\n' "$1"; }
die()   { printf '  FAIL: %s\n' "$1" >&2; exit 1; }

# Every call carries the XMLHttpRequest header — the CSRF gate requires it.
api() { # api METHOD PATH [BODY]
    local method="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl -skg -b "$JAR" -c "$JAR" -X "$method" \
            -H "X-Requested-With: XMLHttpRequest" -H "Content-Type: application/json" \
            -d "$body" "$BASE$path"
    else
        curl -skg -b "$JAR" -c "$JAR" -X "$method" \
            -H "X-Requested-With: XMLHttpRequest" "$BASE$path"
    fi
}

json_field() { # json_field JSON PYTHON_EXPRESSION
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(eval(sys.argv[2]))
" "$1" "$2" 2>/dev/null
}

# Prints the wanted doctypes missing from a grant document's resources.
missing_doctypes() { # missing_doctypes GRANT_DOC_JSON RESOURCES_JSON
    python3 - "$1" "$2" <<'PY'
import json, sys
grant = json.loads(sys.argv[1])
wanted = json.loads(sys.argv[2])
have = {r.get("doctype") for r in grant.get("data", {}).get("resources", [])}
missing = [r["doctype"] for r in wanted if r["doctype"] not in have]
print(" ".join(missing))
PY
}

# ── login as the dev admin ───────────────────────────────────────────────
step "admin login"
ADMIN_RES="$(api POST /Api/iam/login '{"email":"admin@example.tld","password":"admin"}')"
[ "$(json_field "$ADMIN_RES" "d.get('account',{}).get('id','')")" ] || die "admin login failed: $ADMIN_RES"
ok "session open"

# ── wait for the three domains ───────────────────────────────────────────
step "domains"
for i in $(seq 1 30); do
    DOMAINS="$(api GET "/Api/core/Domain?items=50")"
    HAVE=0
    for slug in equipment clients rentals; do
        json_field "$DOMAINS" "str([r['meta']['id'] for r in d.get('data',[])]).find('\"$slug\"') >= 0" >/dev/null 2>&1 && HAVE=$((HAVE+1))
    done
    [ "$HAVE" -eq 3 ] && break
    [ "$i" -eq 30 ] && die "domains not all live after 30s (got $HAVE/3). Start the dev watcher or import bundles/*.tar.gz first."
    sleep 1
done
ok "equipment, clients, rentals live"

# ── roles ────────────────────────────────────────────────────────────────
step "roles"

ensure_role() { # ensure_role NAME BODY
    local name="$1" body="$2"
    local found
    found="$(api GET "/Api/iam/Roles?filters[name__eq]=$name")"
    if [ "$(json_field "$found" "len(d.get('data',[]))")" != "0" ]; then
        ok "$name exists"
        return
    fi
    local res
    res="$(api POST /Api/iam/Roles "$body")"
    [ "$(json_field "$res" "d.get('data',{}).get('name','')")" = "$name" ] || die "role $name: $res"
    ok "$name created"
}

ensure_role manager '{
  "name": "manager",
  "level": 60,
  "description": "Brightwater operations director. Reads and writes every business domain, sees costs (finance tag), assigns roles.",
  "permissions": [
    {"on": "equipment", "action": "*"},
    {"on": "clients", "action": "*"},
    {"on": "rentals", "action": "*"},
    {"on": "iam.Account", "action": "read"},
    {"on": "iam.Roles", "action": "read"},
    {"on": "core.Comment", "action": "*"},
    {"on": "core.Attachment", "action": "read"}
  ],
  "connectivity": ["api", "mcp", "assistant"],
  "visible_tags": ["default", "finance"]
}'

ensure_role sales '{
  "name": "sales",
  "level": 40,
  "description": "Brightwater salesperson. Owns their own clients (row scope my_clients) and their bookings; cannot see purchase prices.",
  "permissions": [
    {"on": "clients.Company", "scope": ["$my_clients"], "action": "*"},
    {"on": "clients.Contact", "action": "*"},
    {"on": "rentals.Booking", "action": "*"},
    {"on": "rentals.BookingLine", "action": "*"},
    {"on": "equipment.Item", "action": "read"},
    {"on": "equipment.Category", "action": "read"},
    {"on": "core.Comment", "action": "*"},
    {"on": "core.Attachment", "action": "read"}
  ],
  "connectivity": ["api", "mcp", "assistant"],
  "visible_tags": ["default"]
}'

ensure_role warehouse '{
  "name": "warehouse",
  "level": 40,
  "description": "Brightwater warehouse lead. Runs equipment and maintenance; cannot see purchase prices (no finance tag).",
  "permissions": [
    {"on": "equipment", "action": "*"},
    {"on": "rentals.Booking", "action": "read"},
    {"on": "rentals.BookingLine", "action": "read"},
    {"on": "clients.Company", "action": "read"},
    {"on": "clients.Contact", "action": "read"},
    {"on": "core.Comment", "action": "*"},
    {"on": "core.Attachment", "action": "*"}
  ],
  "connectivity": ["api", "mcp", "assistant"],
  "visible_tags": ["default"]
}'

# ── people ───────────────────────────────────────────────────────────────
# accounts:create prints the one-time password (`password: XXXX-…`); the
# first login answers must_change_password with a change_token, and the
# change-password call swaps the OTP for the known demo password.
step "people"

ensure_account() { # ensure_account EMAIL NAME ROLE PASSWORD
    local email="$1" name="$2" role="$3" password="$4"
    local found
    found="$(api GET "/Api/iam/Account?filters[email__eq]=$email")"
    if [ "$(json_field "$found" "len(d.get('data',[]))")" != "0" ]; then
        ok "$email exists"
        return
    fi
    local otp
    otp="$("$FACET" accounts:create "$email" --name "$name" --role "$role" 2>/dev/null | grep -o 'password: [A-Z0-9-]*' | head -1 | sed 's/^password: //')"
    [ -n "$otp" ] || die "account $email: no one-time password in accounts:create output"

    local login_res token
    login_res="$(curl -skg -c "$JAR.login" -X POST -H "X-Requested-With: XMLHttpRequest" \
        -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$otp\"}" "$BASE/Api/iam/login")"
    token="$(json_field "$login_res" "d.get('change_token','')")"
    [ -n "$token" ] || die "account $email: no change_token in login response: $login_res"

    curl -skg -b "$JAR.login" -c "$JAR.login" -X POST \
        -H "X-Requested-With: XMLHttpRequest" -H "Content-Type: application/json" \
        -d "{\"change_token\":\"$token\",\"old_password\":\"$otp\",\"new_password\":\"$password\"}" \
        "$BASE/Api/iam/change-password" > /dev/null

    # Proof, not trust: a fresh login with the final password must answer 200.
    local verify
    verify="$(curl -skg -X POST -H "X-Requested-With: XMLHttpRequest" \
        -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$password\"}" \
        "$BASE/Api/iam/login")"
    [ "$(json_field "$verify" "d.get('account',{}).get('id','')")" ] || die "account $email: password login failed after change: $verify"
    ok "$email created ($role)"
}

ensure_account nadia@brightwater.example "Nadia Bertrand" manager   brightwater-nadia
ensure_account tom@brightwater.example   "Tom Aaland"    sales     brightwater-tom
ensure_account lucia@brightwater.example "Lucía Ferrer"  warehouse brightwater-lucia
ensure_account ravi@brightwater.example  "Ravi Menon"    admin     brightwater-ravi

# ── domain grants ────────────────────────────────────────────────────────
# rentals reads clients.Company (client_name replica); equipment reads the
# bookings (the stock hook). Grants live under the producer domain; the
# consumer activates them.
step "domain grants"

ensure_grant() { # ensure_grant PRODUCER CONSUMER RESOURCES_JSON
    local producer="$1" consumer="$2" resources="$3"
    local grants gid
    grants="$(api GET "/Api/core/Domain/$producer/grants")"
    gid="$(json_field "$grants" "next((r['meta']['id'] for r in d.get('data',[]) if r['data'].get('consumer_domain','').endswith('.$consumer')), '')")"
    if [ -z "$gid" ]; then
        local res
        res="$(api POST "/Api/core/Domain/$producer/grants" "{\"consumer_domain\":\"core.Domain.$consumer\",\"resources\":$resources}")"
        gid="$(json_field "$res" "d.get('meta',{}).get('id','')")"
        [ -n "$gid" ] || die "grant $producer→$consumer: $res"
        ok "$producer→$consumer filed"
    else
        # An import or publish may have auto-filed a narrower grant: the
        # scan knows the hook's declared source, not the doctypes its
        # script reads at runtime. Widen to the full resource set when the
        # current list misses any wanted doctype.
        local current missing
        current="$(api GET "/Api/core/DomainGrant/$gid")"
        missing="$(missing_doctypes "$current" "$resources")"
        if [ -n "$missing" ]; then
            local res
            res="$(api PATCH "/Api/core/DomainGrant/$gid" "{\"resources\":$resources}")"
            [ "$(json_field "$res" "d.get('data',{}).get('resources')")" ] || die "grant $producer→$consumer widen: $res"
            ok "$producer→$consumer widened (added: $missing)"
        else
            ok "$producer→$consumer exists"
        fi
    fi
    local active
    active="$(api GET "/Api/core/DomainGrant/$gid")"
    if [ "$(json_field "$active" "d.get('data',{}).get('active')")" != "True" ]; then
        local act
        act="$(api POST "/Api/core/DomainGrant/$gid/activate" '{}')"
        [ "$(json_field "$act" "d.get('data',{}).get('active')")" = "True" ] || die "grant $producer→$consumer activate: $act"
        ok "$producer→$consumer activated"
    else
        ok "$producer→$consumer active"
    fi
}

ensure_grant clients rentals '[{"doctype":"Company","tags":["default"]}]'
# BookingLine too: the hook lists the booking's lines at runtime, and the
# auto-filed ticket only covers the declared source (Booking).
ensure_grant rentals equipment '[{"doctype":"Booking","tags":["default"]},{"doctype":"BookingLine","tags":["default"]}]'

# ── data ─────────────────────────────────────────────────────────────────
step "data"
python3 "$DIR/seed.py" "$BASE" || die "seed.py failed"

step "summary"
cat <<'EOF'
  Loaded. Sign in at the workspace with:
    nadia@brightwater.example  / brightwater-nadia   (manager — sees costs)
    tom@brightwater.example    / brightwater-tom     (sales — own clients only)
    lucia@brightwater.example  / brightwater-lucia   (warehouse — no costs)
    ravi@brightwater.example   / brightwater-ravi    (admin)
EOF
