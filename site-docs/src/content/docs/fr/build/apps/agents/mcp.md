---
title: Connecter des agents par MCP
description: Connectez un agent externe à Facet par MCP sous un rôle épinglé unique, de la découverte jusqu’à tools/call.
type: how-to
audience: [developer]
features: [AI-05, APP-04]
verified_at: eee55a2
sidebar:
  order: 1
---

Facet est un serveur Model Context Protocol (MCP). Un agent externe se
connecte sous un rôle épinglé unique et agit sur les documents avec ce
rôle. Facet est le serveur de ressources : il valide les tokens émis par
ses propres endpoints `/OAuth/*` et n’en émet aucun lui-même.

> **Pour les agents :** `POST /Api/_mcp/<role_slug>` — JSON-RPC 2.0, avec
> `Authorization: Bearer <token>`. Prenez l’URL telle quelle depuis
> `GET /Api/_mcp/endpoints` ; ne la déduisez jamais de votre propre origine. Un
> premier appel sans token répond `401` plus un défi `WWW-Authenticate` qui nomme
> `/.well-known/oauth-protected-resource`. Connexion : `POST /OAuth/register` →
> `POST /OAuth/authorize` avec `resource=<per-role MCP identifier>` et
> `role=<qualified role id>` (consentement navigateur) → `POST /OAuth/token` (PKCE)
> → `initialize`, `notifications/initialized` (202), `ping`, `tools/list`,
> `tools/call`. Les noms de rôles nus répondent `invalid_target` ; utilisez
> `iam.Roles.admin`, jamais `admin`.

## Quand l’utiliser

Connectez un agent externe par MCP quand :

- Vous pilotez Facet depuis un agent externe par MCP.
- Vous voulez le RBAC par rôle sans enregistrement d’app.
- Vous voulez que l’audit montre un rôle épinglé unique par session.

## Avant de commencer

- Le compte détient le rôle, et la `connectivity` du rôle liste le canal
  `mcp`.
- MCP n’est pas une app : pas de document d’enregistrement, pas de plafond
  d’attribution. Le rôle est la seule limite.
- Il vous faut l’URL du endpoint. `GET /Api/_mcp/endpoints` (session
  navigateur, token d’app ou clé API) répond avec une URL par rôle détenu :

```json
{
  "endpoints": [
    { "role": "iam.Roles.admin", "url": "https://facet.localhost:3443/Api/_mcp/iam.Roles.admin" }
  ]
}
```

- Utilisez l’URL telle quelle. Le `aud` du token doit lui correspondre
  exactement ; une URL déduite de votre propre origine échoue.

La session ci-dessous tourne contre une instance de dev à
`https://facet.localhost:3443` avec les données Brightwater Rentals
chargées. Le compte admin de Ravi la pilote : chaque appel API présente son
propre identifiant, donc la transcription émet une clé API pour le rôle
admin et la porte dans `Authorization: Bearer`. Un vrai client ouvre les
mêmes URL de consentement dans un navigateur.

## Étapes

La séquence de connexion :

<!-- d2
direction: down
Agent -> Facet: First call, no token
Facet -> Agent: 401 + WWW-Authenticate challenge
Agent -> Facet: GET /.well-known/oauth-protected-resource
Agent -> Facet: POST /OAuth/authorize (resource + role)
Facet -> Agent: The consent screen pins the role
Agent -> Facet: POST /OAuth/token with the code verifier
Facet -> Agent: Access token (aud + role)
Agent -> Facet: POST /Api/_mcp/:role_slug (JSON-RPC)
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9e5d826c-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9e5d826c-dark.svg" alt="Diagram" loading="lazy" />
</div>

### 1. Découvrir le serveur d’autorisation

Un premier appel sans token répond `401`. Le défi est le point d’entrée :

```sh
curl -sk -D - -o /dev/null -X POST \
  https://facet.localhost:3443/Api/_mcp/iam.Roles.admin \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
```

```text
HTTP/2 401
www-authenticate: Bearer resource_metadata="https://facet.localhost:3443/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.admin"

{"error":"Authentication required"}
```

Récupérez ce document de métadonnées de ressource protégée (PRM) de la
RFC 9728 :

```sh
curl -sk https://facet.localhost:3443/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.admin
```

```json
{
  "resource": "https://facet.localhost:3443/Api/_mcp/iam.Roles.admin",
  "authorization_servers": ["https://facet.localhost:3443"],
  "bearer_methods_supported": ["header"],
  "scopes_supported": [],
  "resource_documentation": "https://facet.localhost:3443/Api/_mcp"
}
```

Les métadonnées du serveur d’autorisation portent la carte des endpoints
(`/.well-known/oauth-authorization-server`) : `authorization_endpoint`,
`token_endpoint`, `registration_endpoint`,
`code_challenge_methods_supported: ["S256"]`,
`token_endpoint_auth_methods_supported: ["none"]` et
`dpop_signing_alg_values_supported: ["ES256"]`.

### 2. Enregistrer le client

`POST /OAuth/register` implémente l’enregistrement dynamique de client de
la RFC 7591. Il est sans état : Facet fabrique un id de client public
opaque et ne garde aucune trace. L’écran de consentement et PKCE portent
la sécurité. `redirect_uris` est requis ; seule
`token_endpoint_auth_method: "none"` est prise en charge :

```sh
curl -sk -X POST https://facet.localhost:3443/OAuth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://127.0.0.1:8765/callback"],"client_name":"brightwater-agent"}'
```

```json
{
  "client_id": "o-4ZmjY-zkPOT8w61Nzf0GJ55VfTq7Zkrk6TC2Iu8XU",
  "client_id_issued_at": 1795696890,
  "redirect_uris": ["http://127.0.0.1:8765/callback"],
  "token_endpoint_auth_method": "none",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "client_name": "brightwater-agent"
}
```

### 3. Autoriser avec le paramètre resource

L’agent envoie le navigateur du compte vers l’écran de consentement.
Emportez les paramètres Proof Key for Code Exchange (PKCE) de
[Connexion utilisateur](/fr/build/apps/connect/user-login/), plus :

| Paramètre | Valeur |
| --- | --- |
| `resource` | l’identifiant MCP par rôle : `https://<host>/Api/_mcp/<role_slug>` |
| `role` | l’id de rôle qualifié, par exemple `iam.Roles.admin` |

L’écran de consentement épingle ce rôle. Il refuse un rôle que le compte ne
détient pas, et un rôle dont la `connectivity` n’a pas le canal `mcp`. Les
deux refus portent la même réponse `access_denied` ; le code enregistre la
ressource et le rôle.

La confirmation du consentement est un `POST /OAuth/authorize` avec les
mêmes paramètres plus le `role` élu — c’est l’étape qu’un formulaire
navigateur soumet. Dans la session ci-dessous, une session opérateur
connectée la pilote via `curl`. La requête porte le rôle élu et
l’identifiant :

```sh
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary \
  | openssl base64 | tr '+/' '-_' | tr -d '=\n')

curl -sk -X POST https://facet.localhost:3443/OAuth/authorize \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "client_id": "o-4ZmjY-zkPOT8w61Nzf0GJ55VfTq7Zkrk6TC2Iu8XU",
    "redirect_uri": "http://127.0.0.1:8765/callback",
    "state": "consent-round-trip",
    "code_challenge": "'"$CHALLENGE"'",
    "code_challenge_method": "S256",
    "resource": "https://facet.localhost:3443/Api/_mcp/iam.Roles.admin",
    "role": "iam.Roles.admin"
  }'
```

```json
{
  "redirect_uri": "http://127.0.0.1:8765/callback",
  "code": "U_2Xcqxi-BslGQOnrRca0T4fqgqKWxuU3KsE77lntF0",
  "state": "consent-round-trip",
  "app_id": "",
  "role_id": "iam.Roles.admin",
  "iss": "https://facet.localhost:3443"
}
```

Un `resource` qui ne nomme aucun rôle répond `400` avant tout
consentement :

```json
{
  "error": "invalid_target",
  "error_description": "'resource' must name a role-pinned MCP endpoint (https://facet.localhost:3443/Api/_mcp/<role_slug>)"
}
```

### 4. Échanger le code

Échangez le code à `POST /OAuth/token` avec le vérificateur PKCE. Le
vérificateur voyage encodé en formulaire, donc il ne doit porter aucun `+`
ou `=` bruts — utilisez un alphabet compatible URL :

```sh
curl -sk -X POST https://facet.localhost:3443/OAuth/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=authorization_code&code=$CODE&code_verifier=$VERIFIER&client_id=$CLIENT_ID&redirect_uri=http://127.0.0.1:8765/callback"
```

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.…",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "4ed709fecffa3fc3…"
}
```

Le token d’accès porte `aud` (l’identifiant par rôle, correspondance
exacte), `role` (l’id qualifié), `sub` (l’id du compte), `sid` (l’id de
session), et aucun claim `app`. Un vérificateur faux, un code réutilisé,
ou un `redirect_uri` qui ne correspond pas répondent `400` :

```json
{ "error": "invalid_grant", "error_description": "PKCE verification failed" }
```

```json
{ "error": "invalid_grant", "error_description": "redirect_uri mismatch" }
```

### 5. Appeler la surface de tools

JSON-RPC 2.0 passe par `POST /Api/_mcp/<role_slug>`. Une requête porte un
seul appel ; la réponse est une seule réponse. Commencez par `initialize` ;
le serveur répond avec sa version de protocole et le rôle épinglé :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/_mcp/iam.Roles.admin \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"brightwater-agent","version":"0.1"}}}'
```

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": { "tools": {} },
    "serverInfo": { "name": "facet", "version": "1.0", "role": "iam.Roles.admin" }
  }
}
```

Puis envoyez `notifications/initialized` — il n’attend aucune réponse et
répond `202`. Un `ping` répond `{"jsonrpc":"2.0","id":2,"result":{}}`.
Listez les tools du rôle :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/_mcp/iam.Roles.admin \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
```

Le rôle admin voit 24 tools — `ping`, `list_domains`, `list_doctypes`,
`get_schema`, `whoami`, `list_documents`, `aggregate_documents`,
`get_document`, `resolve_refs`, `search_documents`, `create_document`,
`update_document`, `delete_document`, `call_action`, `batch`,
`list_mutations`, `get_links`, `get_backrefs`, `create_sidecar`,
`list_sidecars`, `request_artifact_upload`, `get_artifact`,
`list_artifact_refs`, `read_skill` — chacun avec `name`, `description` et
`inputSchema`. Voir
[Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/)
pour le catalogue. Appelez-en un :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/_mcp/iam.Roles.admin \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_documents","arguments":{"query":"Maison"}}}'
```

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [{ "type": "text", "text": "{\"data\":[…],\"meta\":{\"query\":\"Maison\",\"total\":5}}" }],
    "structuredContent": { "data": [ … ], "meta": { "query": "Maison", "total": 5, "domain": null } }
  }
}
```

Le payload voyage deux fois : sous forme de chaîne JSON dans
`result.content[0].text`, et sous forme d’objet dans
`result.structuredContent`.

### 6. Rafraîchir la session

Envoyez `grant_type=refresh_token` en POST vers `/OAuth/token`. Une session
MCP revalide le compte, le rôle détenu et le canal `mcp` du rôle. Un rôle
qui perd le canal perd ses sessions au prochain refresh ; un token d’accès
vivant reste valable jusqu’à la fin de son TTL (900 secondes dans la
session ci-dessus).

## Explication

### Le modèle

- **L’URL épingle le rôle.** Un `:role_slug` sert une seule session. Pas de
  changement en cours de session ; un autre rôle signifie une autre URL.
- **Les ids de rôles sont qualifiés.** Le paramètre `role` et le slug d’URL
  portent `iam.Roles.admin` ; les noms nus sont ambigus entre domaines.
- **MCP n’est pas une app.** Aucune intersection d’attributions ne
  s’applique ; le RBAC simple du rôle s’exécute, exactement comme en REST.
- **Aucun principal système.** La répartition refuse d’emblée un contexte
  système.
- **MCP est un plan de données.** Les tools agissent sur les documents des
  doctypes enregistrés ; la conception de schéma reste en REST et dans
  l’assistant du builder.
- **Bearer uniquement.** Un cookie de session sur une route `/Api/_mcp/`
  répond `401` — la surface accepte des tokens, jamais des cookies. La
  session navigateur ne sert qu’à l’écran de consentement.

### Limites

Le bloc optionnel `mcp:` dans `config.{env}.yml` fixe les plafonds :

| Clé | Défaut | Bornes |
| --- | --- | --- |
| `max_concurrency_per_sid` | 4 | dispatches en cours par session ; au-delà du plafond, les requêtes attendent |
| `max_result_rows` | 200 | lignes qu’un tool de liste renvoie |
| `max_response_bytes` | 1048576 | octets de l’enveloppe de résultat d’un tool |
| `max_batch_ops` | 25 | opérations dans un appel `batch` |

La durée d’une requête suit le timeout d’instruction partagé
(`database.statement_timeout_ms`) ; il n’y a pas de pool MCP séparé. Les
fichiers ne passent jamais par JSON-RPC : `request_artifact_upload`
fabrique une URL de téléversement signée à usage unique — voir
[Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/) et
[Téléverser et servir des fichiers](/fr/build/apps/data/files/).

### Attribution

Chaque écriture marque `mutations.channel = "mcp"` plus le rôle épinglé
comme `acting_role`. L’audit montre l’unique rôle de la session — voir
[Voir qui a fait quoi](/fr/admin/history/audit/).

## Exemple

La session complète, de bout en bout, sur une instance de dev Brightwater.
Les étapes 3 et 4 exigent un consentement navigateur en production ; le
script pilote le consentement avec une clé API admin à la place :

```sh
BASE=https://facet.localhost:3443
MCPURL=$BASE/Api/_mcp/iam.Roles.admin

# 0. Une clé API pour les étapes de consentement — épinglée au rôle admin.
RAVI_KEY=$(pnpx @facetapp/cli connect >/dev/null && pnpx @facetapp/cli apikey)

# 1. Découverte.
curl -sk -D - -o /dev/null -X POST $MCPURL \
  -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
curl -sk $BASE/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.admin

# 2. Enregistrement.
CLIENT_ID=$(curl -sk -X POST $BASE/OAuth/register \
  -H 'Content-Type: application/json' \
  -d '{"redirect_uris":["http://127.0.0.1:8765/callback"],"client_name":"brightwater-agent"}' \
  | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)

# 3. Paire PKCE, puis consentement (étape navigateur en production).
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary \
  | openssl base64 | tr '+/' '-_' | tr -d '=\n')
CODE=$(curl -sk -X POST $BASE/OAuth/authorize \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"client_id":"'"$CLIENT_ID"'","redirect_uri":"http://127.0.0.1:8765/callback","state":"consent-round-trip","code_challenge":"'"$CHALLENGE"'","code_challenge_method":"S256","resource":"'"$MCPURL"'","role":"iam.Roles.admin"}' \
  | grep -o '"code":"[^"]*"' | cut -d'"' -f4)

# 4. Token.
ACCESS_TOKEN=$(curl -sk -X POST $BASE/OAuth/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=authorization_code&code=$CODE&code_verifier=$VERIFIER&client_id=$CLIENT_ID&redirect_uri=http://127.0.0.1:8765/callback" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

# 5. Initialize, initialized, tools/list, tools/call.
curl -sk -X POST $MCPURL -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"brightwater-agent","version":"0.1"}}}'

curl -sk -o /dev/null -w '%{http_code}\n' -X POST $MCPURL \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

curl -sk -X POST $MCPURL -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'

curl -sk -X POST $MCPURL -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_documents","arguments":{"query":"Maison"}}}'
```

## Dépannage

**Le premier appel répond `401` avec un défi `WWW-Authenticate`.**

Cette réponse est normale. Suivez `resource_metadata` vers le document PRM
et démarrez le parcours.

**`400 invalid_target` à l’autorisation.**

Le paramètre `resource` se situe sous le préfixe MCP mais ne nomme aucun
rôle — par exemple le `…/Api/_mcp` nu. Nommez l’endpoint épinglé au rôle :
`…/Api/_mcp/iam.Roles.admin`.

**L’écran de consentement refuse la connexion.**

Le compte ne détient pas le rôle, ou sa `connectivity` n’a pas le canal
`mcp`. Les deux refus portent `access_denied`.

**`400` avec `{"error":"Missing 'role' field"}` à la confirmation du
consentement.**

La confirmation du consentement porte le rôle élu dans son corps — le même
id de rôle qualifié que la ressource épingle. Ajoutez
`"role": "iam.Roles.admin"`.

**Le token passe en MCP, et REST le refuse.**

Par conception. Le `aud` du token nomme la surface MCP ; REST le refuse, et
le répertoire des endpoints aussi. Utilisez une session, un token d’app ou
une clé API.

**Une réponse porte l’en-tête `MCP-Tools-Changed`.**

Les permissions du rôle ont changé. Rappellez `tools/list` avant l’appel
suivant.

## Voir aussi

- [Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/) — le catalogue que ces routes servent.
- [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/) — le modèle d’app ; MCP n’est pas une app.
- [Gouverner l’assistant](/fr/admin/assistant/govern/) — il monte le même catalogue.
- [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/) — le modèle de droits.
- Internes sur GitHub :
  [mcp.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mcp.md).
