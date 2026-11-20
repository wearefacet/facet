---
title: "MCPà: connecter des agents"
description: Connectez un agent externe à Facet via MCP sous un rôle épinglé unique.
audience: [developer]
features: [AI-05, APP-04]
sidebar:
  order: 17
verified_at: a77c6171
---

Facet est un serveur Model Context Protocol (MCP). Un agent externe se connecte
sous un rôle épinglé unique et agit sur les documents avec ce rôle. Facet est
le serveur de ressourcesà : il valide les tokens émis par ses propres endpoints
`/OAuth/*` et n’en émet aucun lui-même.

> **Pour les agentsà :** `POST /Api/_mcp/<role_slug>` — JSON-RPC 2.0, avec
> `Authorization: Bearer <token>`. Prenez l’URL telle quelle depuis
> `GET /Api/_mcp/endpoints` ; ne la déduisez jamais de votre propre origine.
> Un premier appel sans token répond `401` plus un défi `WWW-Authenticate` qui
> nomme `/.well-known/oauth-protected-resource`. Connexion : `POST /OAuth/register` →
> `GET /OAuth/authorize` avec `resource=<per-role MCP identifier>` et
> `role=<qualified role id>` → `POST /OAuth/token` (PKCE) → `initialize`,
> `tools/list`, `tools/call`. Les noms de rôles nus répondent
> `400 invalid_request` ; utilisez `iam.Roles.admin`, jamais `admin`.

## Quand l’utiliser

Connectez un agent externe via MCP quandà :

- vous pilotez Facet depuis un agent externe via MCPà;
- vous voulez le RBAC par rôle sans enregistrement d’appà ;
- vous voulez que l’audit montre un rôle épinglé unique par session.

## Avant de commencer

- Le compte détient le rôle, et la `connectivity` du rôle liste le canal `mcp`.
- MCP n’est pas une appà : pas de document d’enregistrement, pas de plafond
  d’attribution. Le rôle reste la seule limite.
- Il vous faut l’URL du endpoint. `GET /Api/_mcp/endpoints` (session
  navigateur, token d’app ou clé API) répond avec une URL par rôle détenu,
  triée par id de rôleà :

```json
{
  "endpoints": [
    { "role": "iam.Roles.editor", "url": "https://facet.example.com/Api/_mcp/iam.Roles.editor" }
  ]
}
```

- Utilisez l’URL telle quelle. Le `aud` du token doit lui correspondre
  exactementà ; une URL déduite de votre propre origine échoue.

## Étapes

La séquence de connexion :

<!-- d2
direction: down
Agent -> Facet: First call, no token
Facet -> Agent: 401 + WWW-Authenticate challenge
Agent -> Facet: GET /.well-known/oauth-protected-resource
Agent -> Facet: GET /OAuth/authorize (resource + role)
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

Un premier appel sans token répond `401`. L’en-tête `WWW-Authenticate` porte
une adresse `resource_metadata`. Récupérez ces métadonnées de ressource
protégée (PRM) de la RFC 9728 : l’identifiant par rôle dans `resource`, Facet
dans `authorization_servers`, et `"bearer_methods_supported": ["header"]`.

### 2. Enregistrer le client

`POST /OAuth/register` implémente l’enregistrement dynamique de client de la
RFC 7591. Il est sans étatà : Facet fabrique un id de client public opaque et ne
garde aucune trace. L’écran de consentement et PKCE portent la sécurité.

```sh
curl -sX POST https://facet.example.com/OAuth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://localhost:8765/callback"],"client_name":"my-agent"}'
```

La réponse porte le `client_id` — un id de client public opaque, sans secret.

### 3. Autoriser avec le paramètre resource

Envoyez le navigateur du compte vers `GET /OAuth/authorize`. Emportez les
paramètres PKCE de [Connexion utilisateur](/fr/apps/oauth-login/), plusà :

| Paramètre | Valeur |
| --- | --- |
| `resource` | l’identifiant MCP par rôleà : `https://<host>/Api/_mcp/<role_slug>` |
| `role` | l’id de rôle qualifié, par exemple `iam.Roles.editor` |

L’écran de consentement épingle ce rôle. Il refuse un rôle que le compte ne
détient pas, et un rôle dont la `connectivity` n’a pas le canal `mcp`. Les deux
refus portent la même réponse `access_denied` ; le code enregistre la ressource
et le rôle.

### 4. Échanger le code

Échangez le code à `POST /OAuth/token` comme le parcours de connexion. Le token
d’accès porte `aud` (l’identifiant par rôle, correspondance exacte), `role`
(l’id qualifié), `sub` (l’id du compte), `sid` (l’id de session), et aucun
claim `app`.

### 5. Appeler la surface de tools

JSON-RPC 2.0 passe par `POST /Api/_mcp/<role_slug>`. Une requête porte un seul
appelà ; la réponse est une seule réponse. Commencez par `initialize` ; le
serveur répond avec sa version de protocole et le rôle épinglé. Puis envoyez
`notifications/initialized` — il n’attend aucune réponse. Listez les tools du
rôleà :

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}
```

La réponse liste les tools avec `name`, `description` et `inputSchema` — voir
[Agent tools](/fr/apps/agent-tools/) pour le catalogue. Appelez-en un :

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "list_documents",
    "arguments": {
      "domain": "crm",
      "doctype": "Contact",
      "filters": { "status__eq": "active" },
      "sort": ["-created_at"]
    }
  }
}
```

### 6. Rafraîchir la session

Envoyez `grant_type=refresh_token` en POST vers `/OAuth/token`. Une session
MCP revalide le compte, le rôle détenu et le canal `mcp` du rôle. Un rôle qui
perd le canal perd ses sessions au prochain refreshà ; un token d’accès vivant
reste valable jusqu’à la fin de son TTL.

## Explication

### Le modèle

- **L’URL épingle le rôle.** Un `:role_slug` sert une seule session. Pas de
  changement en cours de sessionà ; un autre rôle signifie une autre URL.
- **Les ids de rôles sont qualifiés.** Le paramètre `role` et le slug d’URL
  portent `iam.Roles.admin` ; les noms nus restent ambigus entre domaines.
- **MCP n’est pas une app.** Aucune intersection d’attributions ne s’appliqueà ;
  le RBAC simple du rôle tourne, exactement comme en REST.
- **Aucun principal système.** La répartition refuse d’emblée un contexte
  système.
- **MCP est un plan de données.** Les tools agissent sur les documents des
  doctypes enregistrésà ; la conception de schémas reste en REST et dans
  l’assistant du builder.

### Limites

Le bloc optionnel `mcp:` dans `config.{env}.yml` fixe les plafondsà :

| Clé | Défaut | Bornes |
| --- | --- | --- |
| `max_concurrency_per_sid` | 4 | traitements en cours par sessionà ; au-del à du plafond, les requêtes attendent |
| `max_result_rows` | 200 | lignes qu’un tool de liste renvoie |
| `max_response_bytes` | 1048576 | octets de l’enveloppe de résultat d’un tool |
| `max_batch_ops` | 25 | opérations dans un appel `batch` |

La durée d’une requête suit le timeout d’instruction partagé
(`database.statement_timeout_ms`) ; il n’y a pas de pool MCP séparé. Les
fichiers ne passent jamais par JSON-RPCà: `request_artifact_upload` fabrique
une URL d’upload signée à usage unique — voir
[Agent tools](/fr/apps/agent-tools/) et
[Téléverser et servir des fichiers](/fr/apps/files/).

### Attribution

Chaque écriture marque `mutations.channel = "mcp"` plus le rôle épinglé comme
`acting_role`. L’audit montre l’unique rôle de la session — voir
[Auditer l’activité](/fr/govern/auditing-activity/).

## Exemple

Après le consentement, échangez le code puis appelez la surface. Construisez la
paire PKCE comme le montre [Connexion utilisateur](/fr/apps/oauth-login/) :

```sh
curl -sX POST https://facet.example.com/OAuth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&code=AUTH_CODE&client_id=CLIENT_ID&redirect_uri=http://localhost:8765/callback&code_verifier=VERIFIER"

curl -sX POST "https://facet.example.com/Api/_mcp/iam.Roles.editor" \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

## Dépannage

**Le premier appel répond `401` avec un défi `WWW-Authenticate`.**

Cette réponse est normale. Suivez `resource_metadata` vers le document PRM et
démarrez le parcours.

**`400 invalid_request` signale la forme du rôle.**

Le paramètre `role` de l’autorisation porte un nom nu. Envoyez l’id qualifiéà :
`iam.Roles.admin`, pas `admin`.

**L’écran de consentement refuse la connexion.**

Le compte ne détient pas le rôle, ou sa `connectivity` n’a pas le canal `mcp`.
Les deux refus portent `access_denied`.

**Le token passe en MCP, et REST le refuse.**

Par conception. Le `aud` du token nomme la surface MCPà; REST le refuse, et le
répertoire des endpoints aussi. Utilisez une session, un token d’app ou une
clé API.

**Une réponse porte l’en-tête `MCP-Tools-Changed`.**

Les permissions du rôle ont changé. Rappellez `tools/list` avant l’appel
suivant.

## Voir aussi

- [Agent tools](/fr/apps/agent-tools/) — le catalogue que ces routes servent.
- [Fonctionnement des apps sur Facet](/fr/apps/how-apps-work/) — le modèle d’appà ; MCP n’est pas une app.
- [Gouverner l’assistant](/fr/govern/governing-assistant/) — il expose le même catalogue.
- [L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/) — le modèle de droits.
- Internes sur GitHubà : [mcp.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mcp.md).
