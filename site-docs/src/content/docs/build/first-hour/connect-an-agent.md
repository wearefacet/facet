---
type: tutorial
title: Connect an AI agent
description: Connect an MCP client under the manager role, ask which tents are free, and read the trail in the audit.
audience: [developer, author]
features: [AI-05, APP-04, AI-04]
sidebar:
  order: 6
prev: /build/first-hour/team-access/
next: /build/apps/
verified_at: eee55a2
---

Nadia Bertrand runs Brightwater's operations, and one question returns every
week: which equipment is free on a date? You will connect an agent that
answers it — under Nadia's own `manager` role, never with rights of its own.
Facet speaks the Model Context Protocol (MCP): an external client signs in
under one pinned role and works on documents as that role.

**You will build:** an MCP session for the manager role that answers "Which
tents are free on 2026-12-13?" and books one — with the trail in the audit.
**Time:** about 15 minutes.
**You need:**

- [Give your team access](/build/first-hour/team-access/) — a running
  instance with the Brightwater example loaded.
- Node.js 20+, `curl`, and `openssl`.

:::note
No language model runs on the instance in this tutorial, and none is needed:
the model lives in your MCP client. Facet serves tools and data under the
pinned role; Claude Desktop or any MCP host plays the part the script below
plays. The built-in workspace assistant is the other way to ask — it needs a
model connected by an administrator, see
[Connect a model](/admin/assistant/connect-a-model/).
:::

One URL pins one role. Everything the client does after the sign-in answers
to that role alone:

*The connect sequence, from the first refused call to the working session.*

<!-- d2
direction: down
client: "Your MCP client" {class: external}
facet: Facet
client -> facet: First call, no token
facet -> client: 401 + where to sign in
client -> facet: Register (RFC 7591)
client -> facet: Consent as Nadia, manager role
facet -> client: Token, pinned to the role
client -> facet: JSON-RPC tools/call
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/4d7a5d48-light.svg" alt="Your MCP client" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/4d7a5d48-dark.svg" alt="Your MCP client" loading="lazy" />
</div>

## 1. Find the manager endpoint

Sign in as Nadia in the browser and open **Settings → MCP endpoints**. Facet
lists one URL per role she holds:

![The MCP endpoints panel in Settings: one URL for the manager role, with a Copy button.](/screens/build/connect-an-agent-1.png)

The API answers the same list. Every API call presents its own credential, and
the CLI pins one to a role you hold. From the folder where you ran
`setup-dev`, ask for a `manager` key (sign in as the admin in your browser and
elect the manager role on the consent screen):

```sh
NADIA_KEY=$(pnpx @facetapp/cli connect --role manager >/dev/null && pnpx @facetapp/cli apikey)
HOST=$(pnpx @facetapp/cli host)
```

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  "$HOST/Api/_mcp/endpoints"
```

```json
{
  "endpoints": [
    { "role": "iam.Roles.manager", "url": "https://facet.localhost:3443/Api/_mcp/iam.Roles.manager" }
  ]
}
```

The role id is qualified — `iam.Roles.manager`, never a bare `manager`. The
URL pins the role, and the token answers to exactly this URL later. Take it
verbatim; a URL built from memory fails.

## 2. Connect

MCP clients discover the sign-in themselves: a first call without a token
answers `401` with a pointer to the discovery documents. Register the client,
get Nadia's consent, and exchange a code for a token. In a real client these
steps run behind its UI; the transcript drives them with `curl` so you can
see each one.

Register the client. Facet mints an id and keeps no record — RFC 7591
dynamic registration, stateless by design:

```sh
CLIENT_ID=$(curl -sk -X POST https://facet.localhost:3443/OAuth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris": ["http://127.0.0.1:8765/callback"], "client_name": "brightwater-agent"}' \
  | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)
echo "$CLIENT_ID"
```

```json
{
  "client_id": "JdBoQuUsGwrRZFOh3DC6AYuyiNFy3oh9pLn-T8PeaSE",
  "client_id_issued_at": 1795702158,
  "redirect_uris": ["http://127.0.0.1:8765/callback"],
  "token_endpoint_auth_method": "none",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "client_name": "brightwater-agent"
}
```

Build a Proof Key for Code Exchange (PKCE) pair. The verifier must carry no
raw `+` or `=` — it travels form-encoded:

```sh
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary \
  | openssl base64 | tr '+/' '-_' | tr -d '=\n')
```

The consent step is where Nadia approves. In production her browser shows a
screen and she clicks; here her credential submits the same request. It
carries the role she elects and the MCP resource it applies to:

```sh
# What the consent screen shows (as JSON, from her credential).
curl -sk -H "Authorization: Bearer $NADIA_KEY" -H "Accept: application/json" \
  "https://facet.localhost:3443/OAuth/authorize?response_type=code&client_id=$CLIENT_ID&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&code_challenge=$CHALLENGE&code_challenge_method=S256&state=wp14c-tutorial&resource=https%3A%2F%2Ffacet.localhost%3A3443%2FApi%2F_mcp%2Fiam.Roles.manager"
```

```json
{
  "mcp": true,
  "resource": "https://facet.localhost:3443/Api/_mcp/iam.Roles.manager",
  "roles": [
    { "role_id": "iam.Roles.manager", "display_name": "Brightwater operations director. Reads and writes every business domain, sees costs (finance tag), assigns roles." }
  ],
  "pinned_role": "iam.Roles.manager",
  "state": "wp14c-tutorial"
}
```

```sh
# Nadia approves; the answer carries the one-time code.
CODE=$(curl -sk -X POST https://facet.localhost:3443/OAuth/authorize \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H "Content-Type: application/json" \
  -d '{"client_id": "'"$CLIENT_ID"'", "redirect_uri": "http://127.0.0.1:8765/callback", "state": "wp14c-tutorial", "code_challenge": "'"$CHALLENGE"'", "code_challenge_method": "S256", "resource": "https://facet.localhost:3443/Api/_mcp/iam.Roles.manager", "role": "iam.Roles.manager"}' \
  | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
echo "$CODE"

# Exchange the code for the token.
TOKEN=$(curl -sk -X POST https://facet.localhost:3443/OAuth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "code_verifier=$VERIFIER" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "redirect_uri=http://127.0.0.1:8765/callback" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
echo "${TOKEN:0:24}…"
```

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.…",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "4ed709fecffa3fc3…"
}
```

The token lives for 900 seconds and answers only on the MCP surface. Hand it
to the script in the next step:

```sh
export ACCESS_TOKEN=$TOKEN
```

## 3. Ask the question

Now the client itself. Save this script as `ask.mjs` — plain Node, no
dependencies:

```js
// ask.mjs — a minimal MCP client for Facet.
// Run: ACCESS_TOKEN=... node ask.mjs "Which tents are free on 2026-12-13?"
const BASE = 'https://facet.localhost:3443';
const MCP_URL = `${BASE}/Api/_mcp/iam.Roles.manager`;
const TOKEN = process.env.ACCESS_TOKEN;
if (!TOKEN) {
  console.error('Set ACCESS_TOKEN first — see the connect step.');
  process.exit(1);
}

const question = process.argv[2] ?? 'Which tents are free on 2026-12-13?';
const date = question.match(/\d{4}-\d{2}-\d{2}/)?.[0];
if (!date) {
  console.error('The question must carry a date in YYYY-MM-DD form.');
  process.exit(1);
}

let nextId = 0;
const rpcHeaders = {
  'Authorization': `Bearer ${TOKEN}`,
  'Content-Type': 'application/json',
  'Accept': 'application/json, text/event-stream'
};

async function rpc(method, params) {
  const id = ++nextId;
  const response = await fetch(MCP_URL, {
    method: 'POST',
    headers: rpcHeaders,
    body: JSON.stringify({ jsonrpc: '2.0', id, method, params })
  });
  const body = await response.json();
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error)}`);
  return body.result;
}

async function call(name, args) {
  const result = await rpc('tools/call', { name, arguments: args });
  return result.structuredContent ?? JSON.parse(result.content[0].text);
}

// ── Handshake ──────────────────────────────────────────────────────────────
await rpc('initialize', {
  protocolVersion: '2025-06-18',
  capabilities: {},
  clientInfo: { name: 'brightwater-agent', version: '0.1' }
});
await fetch(MCP_URL, {
  method: 'POST',
  headers: rpcHeaders,
  body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })
});

// ── The question ───────────────────────────────────────────────────────────
// 1. The Tents category.
const categories = await call('list_documents', {
  domain: 'equipment', doctype: 'Category', filters: { name__eq: 'Tents' }
});
const tentsCategory = categories.data[0];

// 2. The available items, narrowed to that category.
const stock = await call('list_documents', {
  domain: 'equipment', doctype: 'Item',
  filters: { status__eq: 'available' }, items: 100
});
const tentRows = stock.data.filter(
  (row) => row.data.category === `equipment.Category.${tentsCategory.meta.id}`
);

// 3. The confirmed bookings. The dates field serves no range operator, so
//    the script keeps the rows whose period covers the asked date.
const bookings = await call('list_documents', {
  domain: 'rentals', doctype: 'Booking',
  filters: { status__eq: 'confirmed' }, items: 100
});
const live = bookings.data.filter((row) => {
  const { start, end } = row.data.dates ?? {};
  return start <= date && date <= end;
});

// 4. The lines of each live booking name the booked items.
const bookedIds = new Set();
for (const booking of live) {
  const lines = await call('list_documents', {
    domain: 'rentals', doctype: 'BookingLine',
    parent_id: booking.meta.id, items: 100
  });
  for (const line of lines.data) bookedIds.add(line.data.item.split('.').pop());
}

const free = tentRows.filter((row) => !bookedIds.has(row.meta.id));

console.log(`Question: ${question}`);
console.log(`Confirmed bookings over ${date}: ${live.length}`);
console.log(`Free tents on ${date}: ${free.length} of ${tentRows.length}`);
for (const row of free) {
  console.log(`  ${row.meta.display_name} — ${row.data.serial_number}`);
}
```

The script needs the dev edge's certificate root — the edge issues its own:

```sh
export NODE_EXTRA_CA_CERTS=$HOME/.local/share/caddy/pki/authorities/local/root.crt
ACCESS_TOKEN=$ACCESS_TOKEN node ask.mjs "Which tents are free on 2026-12-13?"
```

```text
Question: Which tents are free on 2026-12-13?
Confirmed bookings over 2026-12-13: 2
Free tents on 2026-12-13: 2 of 2
  Pagoda tent 5x5 — TN-0505-B
  Festival tent 15x20 — TN-1520-A
```

Five of the seven tents sit on confirmed bookings, so two are available — and
neither is booked over the 13th. In production, Claude Desktop or another MCP
host runs this same session: it reads the tool list and picks the calls. The
manager role sees 24 tools — documents, queries, aggregates, history, and
more. The catalogue, with each tool's rules, is
[What agents can do](/build/apps/agents/agent-tools/).

One detail shows the role working: the tool results carry `purchase_price`.
Nadia's role holds the `finance` tag, so she sees costs — an agent connected
under Tom's `sales` role would not see them, on the same question.

## 4. Let the agent book one

Nadia pencils in the Festival tent for the weekend. The client calls the
`create_document` tool — one JSON-RPC call, shown here raw with `curl`:

```sh
curl -sk -X POST https://facet.localhost:3443/Api/_mcp/iam.Roles.manager \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"create_document","arguments":{"domain":"rentals","doctype":"Booking","content":{"client":"clients.Company.06H1FM1B90M4E9ZSVTKKNXJRXN","dates":{"start":"2026-12-12","end":"2026-12-14"},"status":"draft","notes":"Winter fair — Festival tent 15x20 (TN-1520-A) pencilled in by Nadia'"'"'s agent."}}}}'
```

The answer rides twice — as text and as structured content — and the booking
comes back with the client's name, copied live from the client domain:

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "result": {
    "content": [{ "type": "text", "text": "{\"data\":{…},\"meta\":{\"id\":\"BK-2026-0017\"…}}" }],
    "structuredContent": {
      "data": {
        "client": "clients.Company.06H1FM1B90M4E9ZSVTKKNXJRXN",
        "client_name": "Harbour Events Ltd",
        "dates": { "start": "2026-12-12", "end": "2026-12-14" },
        "status": "draft",
        "notes": "Winter fair — Festival tent 15x20 (TN-1520-A) pencilled in by Nadia's agent."
      },
      "meta": { "id": "BK-2026-0017" }
    },
    "isError": false
  }
}
```

The draft holds the date but moves no stock — items go out when a booking is
**confirmed**, through the named action and the stock hook from tutorial 2.

## 5. Read the trail

Everything the agent did is on the record. Sign in as Ravi and open
**Configure → Audit**. Filter the channel to `mcp`:

![The audit table filtered to the mcp channel: the booking create, with Nadia as the actor and the manager role.](/screens/build/connect-an-agent-2.png)

The API answers the same rows. Take the admin key back and read them:

```sh
RAVI_KEY=$(pnpx @facetapp/cli connect >/dev/null && pnpx @facetapp/cli apikey)

curl -skg -H "Authorization: Bearer $RAVI_KEY" \
  "$HOST/Api/Audit?filters%5Bchannel__eq%5D=mcp&items=5"
```

```json
{
  "data": [
    {
      "id": "06H1GCCJDRFFHCQNM7YDCGKBV7",
      "action": "create",
      "doc_type": "Booking",
      "doc_id": "BK-2026-0017",
      "actioner_id": "06H1FKXYWRXB0G3NW0DTDQ1MFH",
      "channel": "mcp",
      "acting_role": "iam.Roles.manager",
      "cause_kind": "request",
      "emitted_at": "2026-11-26T14:10:31Z"
    }
  ],
  "meta": { "count": 1, "more": false }
}
```

The row reads like any other: Nadia's account made it, through the `mcp`
channel, acting as `manager`. The query calls left no rows — the log records
writes, not reads. The sign-in itself is in the login-event log, where
Nadia's consent names the role and the resource it pinned:

```text
consent_granted   Role: iam.Roles.manager
                  Resource: https://facet.localhost:3443/Api/_mcp/iam.Roles.manager
```

How to read both logs, and what each row carries, is
[Auditing activity](/admin/history/audit/).

## 6. Clean up

The draft booking was a pencil mark. Delete it — from the workspace, or with
one call:

```sh
curl -skg -H "Authorization: Bearer $RAVI_KEY" \
  -X DELETE "$HOST/Api/rentals/Booking/BK-2026-0017"
```

The delete lands in the same audit, and the document history keeps both rows.
Nothing else lingers: the client registration was stateless, and the token
expires after 900 seconds.

## What you learned

- Facet serves MCP at one URL per role; the URL pins the role and the token
  answers to it alone.
- The client signs in over OAuth with PKCE — registration, consent, token —
  and then speaks JSON-RPC to the tool surface.
- The agent works exactly as its role: same permissions, same field tags,
  same row scopes.
- Writes land in the audit with the `mcp` channel and the acting role;
  the consent grant lands in the login-event log.

## Related

- [Connect agents over MCP](/build/apps/agents/mcp/) — the full protocol
  surface: discovery, limits, troubleshooting.
- [What agents can do](/build/apps/agents/agent-tools/) — the 24-tool
  catalogue and its error grammar.
- [Auditing activity](/admin/history/audit/) — the two logs behind step 5.
- [Ask the assistant](/use/assistant/) — the built-in surface, one layer
  away.
- [The assistant: AI with your rights](/discover/how-it-works/assistant/)
- [Agent tools](/reference/agent-tools/)
## Next

Your first hour ends here: an instance, a domain, an app, a governed team,
and an agent — all on one audit trail. The [Build section](/build/apps/)
goes deeper on everything you just touched, starting with
[Build apps](/build/apps/).
