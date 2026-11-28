---
type: tutorial
title: "Connecter un agent IA"
description: "Connectez un client MCP sous le rôle manager, demandez quelles tentes sont libres, puis lisez la trace dans le journal d’audit."
audience: [developer, author]
features: [AI-05, APP-04, AI-04]
sidebar:
  order: 6
verified_at: eee55a2
---

Nadia Bertrand dirige les opérations de Brightwater, et une question revient
chaque semaine : quel matériel est libre à une date donnée ? Vous allez
connecter un agent qui y répond — sous le rôle `manager` de Nadia elle-même,
jamais avec des droits qui lui seraient propres. Facet parle le Model Context
Protocol (MCP) : un client externe se connecte sous un seul rôle épinglé et
travaille sur les documents sous l’identité de ce rôle.

**Vous allez construire :** une session MCP pour le rôle manager qui répond à
« Which tents are free on 2026-12-13? » et en réserve une — avec la trace dans
le journal d’audit.
**Durée :** environ 15 minutes.
**Il vous faut :**

- [Donnez l’accès à votre équipe](/fr/build/first-hour/team-access/) — une
  instance en cours avec l’exemple Brightwater chargé.
- Node.js 20+, `curl` et `openssl`.

:::note
Aucun modèle de langage ne tourne sur l’instance dans ce tutoriel, et aucun
n’est nécessaire : le modèle vit dans votre client MCP. Facet sert les outils
et les données sous le rôle épinglé ; Claude Desktop ou n’importe quel hôte
MCP joue le rôle que joue le script ci-dessous. L’assistant intégré de
l’espace de travail est l’autre moyen de poser la question — il exige un
modèle connecté par un administrateur, voir
[Connecter un modèle](/fr/admin/assistant/connect-a-model/).
:::

Une URL épingle un rôle. Tout ce que fait le client après la connexion ne
répond qu’à ce rôle :

*La séquence de connexion, du premier appel refusé à la session fonctionnelle.*

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

## 1. Trouver le point de terminaison du rôle manager

Connectez-vous comme Nadia dans le navigateur et ouvrez
**Paramètres → Points de terminaison MCP**. Facet liste une URL par rôle
qu’elle détient :

![The MCP endpoints panel in Settings: one URL for the manager role, with a Copy button.](/screens/build/connect-an-agent-1.png)

L’API renvoie la même liste. Chaque appel API présente son propre identifiant,
et la CLI en épingle un sur un rôle que vous détenez. Depuis le dossier où
vous avez lancé `setup-dev`, demandez une clé `manager` (connectez-vous comme
administrateur dans votre navigateur et élisez le rôle manager sur l’écran de
consentement) :

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

L’identifiant du rôle est qualifié — `iam.Roles.manager`, jamais un simple
`manager`. L’URL épingle le rôle, et le token ne répond plus tard qu’à
exactement cette URL. Prenez-la telle quelle ; une URL reconstruite de
mémoire échoue.

## 2. Se connecter

Les clients MCP découvrent la connexion eux-mêmes : un premier appel sans
token répond `401` avec un renvoi vers les documents de découverte. Enregistrez
le client, obtenez le consentement de Nadia, puis échangez un code contre un
token. Dans un vrai client, ces étapes se déroulent derrière son interface ;
le pas-à-pas ci-dessous les pilote avec `curl` pour que vous voyiez chacune.

Enregistrez le client. Facet forge un identifiant et ne conserve aucune trace —
enregistrement dynamique RFC 7591, sans état par conception :

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

Construisez une paire Proof Key for Code Exchange (PKCE). Le verifier ne doit
contenir aucun `+` ni `=` bruts — il voyage en encodage de formulaire :

```sh
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary \
  | openssl base64 | tr '+/' '-_' | tr -d '=\n')
```

L’étape de consentement est celle où Nadia approuve. En production, son
navigateur affiche un écran et elle clique ; ici, son identifiant soumet la
même requête. Elle porte le rôle qu’elle élit et la ressource MCP à laquelle
il s’applique :

```sh
# Ce que montre l’écran de consentement (en JSON, depuis son identifiant).
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
# Nadia approuve ; la réponse porte le code à usage unique.
CODE=$(curl -sk -X POST https://facet.localhost:3443/OAuth/authorize \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H "Content-Type: application/json" \
  -d '{"client_id": "'"$CLIENT_ID"'", "redirect_uri": "http://127.0.0.1:8765/callback", "state": "wp14c-tutorial", "code_challenge": "'"$CHALLENGE"'", "code_challenge_method": "S256", "resource": "https://facet.localhost:3443/Api/_mcp/iam.Roles.manager", "role": "iam.Roles.manager"}' \
  | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
echo "$CODE"

# Échangez le code contre le token.
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

Le token vit 900 secondes et n’est valable que sur la surface MCP. Transmettez-le
au script de l’étape suivante :

```sh
export ACCESS_TOKEN=$TOKEN
```

## 3. Poser la question

Passons au client lui-même. Enregistrez ce script sous `ask.mjs` — Node pur,
sans dépendance :

```js
// ask.mjs — un client MCP minimal pour Facet.
// Exécution : ACCESS_TOKEN=... node ask.mjs "Which tents are free on 2026-12-13?"
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

// ── Initialisation ─────────────────────────────────────────────────────────
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

// ── La question ────────────────────────────────────────────────────────────
// 1. La catégorie Tents.
const categories = await call('list_documents', {
  domain: 'equipment', doctype: 'Category', filters: { name__eq: 'Tents' }
});
const tentsCategory = categories.data[0];

// 2. Les articles disponibles, restreints à cette catégorie.
const stock = await call('list_documents', {
  domain: 'equipment', doctype: 'Item',
  filters: { status__eq: 'available' }, items: 100
});
const tentRows = stock.data.filter(
  (row) => row.data.category === `equipment.Category.${tentsCategory.meta.id}`
);

// 3. Les réservations confirmées. Le champ dates n’offre aucun opérateur de
//    plage, le script garde donc les lignes dont la période couvre la date
//    demandée.
const bookings = await call('list_documents', {
  domain: 'rentals', doctype: 'Booking',
  filters: { status__eq: 'confirmed' }, items: 100
});
const live = bookings.data.filter((row) => {
  const { start, end } = row.data.dates ?? {};
  return start <= date && date <= end;
});

// 4. Les lignes de chaque réservation en cours nomment les articles réservés.
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

Le script a besoin du certificat racine de la passerelle de dev — elle émet
les siens :

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

Cinq des sept tentes portent des réservations confirmées, donc deux sont
disponibles — et aucune n’est réservée le 13. En production, Claude Desktop
ou un autre hôte MCP tient cette même session : il lit la liste des outils et
choisit les appels. Le rôle manager voit 24 outils — documents, requêtes,
agrégats, historique, et plus encore. Le catalogue, avec les règles de chaque
outil, se trouve dans
[Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/).

Un détail montre le rôle à l’œuvre : les résultats d’outils portent
`purchase_price`. Le rôle de Nadia porte l’étiquette `finance`, donc elle voit
les coûts — un agent connecté sous le rôle `sales` de Tom ne les verrait pas,
à la même question.

## 4. Laisser l’agent réserver une tente

Nadia pré-réserve la tente Festival pour le week-end. Le client appelle
l’outil `create_document` — un seul appel JSON-RPC, montré ici brut avec
`curl` :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/_mcp/iam.Roles.manager \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"create_document","arguments":{"domain":"rentals","doctype":"Booking","content":{"client":"clients.Company.06H1FM1B90M4E9ZSVTKKNXJRXN","dates":{"start":"2026-12-12","end":"2026-12-14"},"status":"draft","notes":"Winter fair — Festival tent 15x20 (TN-1520-A) pencilled in by Nadia'"'"'s agent."}}}}'
```

La réponse arrive deux fois — en texte et en contenu structuré — et la
réservation revient avec le nom du client, copié en direct depuis le domaine
`clients` :

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

Le brouillon porte la date mais ne bouge aucun stock — les articles sortent
quand une réservation est **confirmée**, via l’action nommée et le hook de
stock du tutoriel 2.

## 5. Lire la trace

Tout ce que l’agent a fait est consigné. Connectez-vous comme Ravi et ouvrez
**Configurer → Audit**. Filtrez le canal sur `mcp` :

![The audit table filtered to the mcp channel: the booking create, with Nadia as the actor and the manager role.](/screens/build/connect-an-agent-2.png)

L’API renvoie les mêmes lignes. Reprenez la clé d’administration et lisez-les :

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

La ligne se lit comme n’importe quelle autre : le compte de Nadia l’a
produite, via le canal `mcp`, en agissant comme `manager`. Les appels de
requête n’ont laissé aucune ligne — le journal enregistre les écritures, pas
les lectures. La connexion elle-même figure dans le journal des connexions,
où le consentement de Nadia nomme le rôle et la ressource qu’il épingle :

```text
consent_granted   Role: iam.Roles.manager
                  Resource: https://facet.localhost:3443/Api/_mcp/iam.Roles.manager
```

La lecture des deux journaux, et le contenu de chaque ligne, font l’objet de
[Auditer l’activité](/fr/admin/history/audit/).

## 6. Nettoyer

La réservation en brouillon n’était qu’une marque au crayon. Supprimez-la —
depuis l’espace de travail, ou avec un seul appel :

```sh
curl -skg -H "Authorization: Bearer $RAVI_KEY" \
  -X DELETE "$HOST/Api/rentals/Booking/BK-2026-0017"
```

La suppression atterrit dans le même audit, et l’historique du document garde
les deux lignes. Rien d’autre ne subsiste : l’enregistrement du client était
sans état, et le token expire après 900 secondes.

## Ce que vous avez appris

- Facet sert MCP à une URL par rôle ; l’URL épingle le rôle et le token ne
  répond qu’à elle.
- Le client se connecte par OAuth avec PKCE — enregistrement, consentement,
  token — puis parle JSON-RPC à la surface d’outils.
- L’agent agit exactement comme son rôle : mêmes permissions, mêmes étiquettes
  de champ, mêmes périmètres de lignes.
- Les écritures atterrissent dans l’audit avec le canal `mcp` et le rôle
  agissant ; le consentement accordé figure dans le journal des connexions.

## Voir aussi

- [Connecter des agents via MCP](/fr/build/apps/agents/mcp/) — la surface
  complète du protocole : découverte, limites, dépannage.
- [Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/) — le
  catalogue des 24 outils et sa grammaire d’erreurs.
- [Auditer l’activité](/fr/admin/history/audit/) — les deux journaux derrière
  l’étape 5.
- [Demander à l’assistant](/fr/use/assistant/) — la surface intégrée, à une
  couche de distance.
- [L’assistant : l’IA avec vos droits](/fr/discover/how-it-works/assistant/)
- [Outils d’agent](/fr/reference/agent-tools/)
## Pour aller plus loin

Votre première heure se termine ici : une instance, un domaine, une app, une
équipe gouvernée et un agent — le tout sur une seule piste d’audit. La
[section Build](/fr/build/apps/) approfondit tout ce que vous venez de
survoler, à commencer par [Construire des apps](/fr/build/apps/).
