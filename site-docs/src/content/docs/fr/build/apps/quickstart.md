---
type: how-to
title: "Démarrage rapide"
description: Enregistrez une petite app, connectez un utilisateur avec PKCE et passez le premier appel API — en un quart d’heure.
audience: [developer]
features: [APP-01, APP-02, APP-09]
sidebar:
  order: 2
verified_at: eee55a2
---

L’entrepôt de Brightwater veut une petite app web : les réservations du
jour, avec un bouton pour marquer les articles sortis puis remis. Cette
page mène cette app de zéro à son premier appel API réussi. Vous
enregistrez l’app, l’activez, connectez un utilisateur, puis lisez des
données réelles — chaque réponse ci-dessous vient d’une instance
Brightwater réelle.

> **Pour les agents :** tout le parcours tient en quatre appels :
> `POST /Api/app/App` (une clé API dans `Authorization: Bearer` —
> `facet-cli apikey` affiche la clé enregistrée — ou un cookie de session
> plus `X-Requested-With: XMLHttpRequest`) → `PATCH …/App/{id}` avec
> `{"status": "active"}` → `GET /OAuth/authorize` + `POST /OAuth/authorize`
> avec `role`, puis `POST /OAuth/token` avec le PKCE `code_verifier` →
> `GET /Api/<domain>/<Doctype>` avec `Authorization: Bearer <access_token>`.
> La création répond `201` et le `client_id` écrit par le hook. Une cible
> d’attribution générique répond `422 wildcard_target`.

## Quand l’utiliser

Utilisez cette page quand vous voulez une app qui fonctionne rapidement
entre les mains, et que les détails peuvent attendre. C’est la voie app
navigateur. Un service backend commence à
[Apps backend et comptes de service](/fr/build/apps/connect/backend-apps/) ;
un agent IA à [Connecter des agents via MCP](/fr/build/apps/agents/mcp/).

## Avant de commencer

- Une instance Facet qui tourne, et un compte qui détient `update` sur
  `app.App`. Le rôle `admin` créé par l’initialisation le détient. Sur
  l’exemple Brightwater, connectez-vous en Ravi Menon
  (`ravi@brightwater.example`).
- `curl` (ou n’importe quel client HTTP) et `pnpx @facetapp/cli` pour le
  parcours. L’app elle-même passe les mêmes appels depuis son propre code —
  voyez le client navigateur complet dans
  [Connecter les utilisateurs](/fr/build/apps/connect/user-login/).

## Étapes

### 1. Enregistrez l’app

Chaque appel API présente son propre identifiant, et la CLI en émet un
épinglé à un rôle que vous détenez. Depuis votre dossier de projet,
connectez-vous une fois via le navigateur (élisez le rôle admin sur l’écran
de consentement) :

```sh
pnpx @facetapp/cli connect
```

La commande vous connecte (le même flux OAuth que `login`), demande s’il
faut stocker une clé API, et écrit la clé dans `.facet.local.json`. Elle a
besoin d’un `facet.config.json` pour la cible — `init` en écrit un, ou
`connect` demande l’URL une fois. Gardez la clé et l’URL dans des
variables :

```sh
RAVI_KEY=$(pnpx @facetapp/cli apikey)
HOST=$(pnpx @facetapp/cli host)
```

Créez ensuite le document d’app. Les attributions nomment des doctypes
concrets — une cible générique est refusée :

```sh
curl -sk -X POST "$HOST/Api/app/App" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "slug": "brw-checkout",
    "name": "Brightwater Check-out",
    "client_type": "public",
    "redirect_uris": ["http://localhost:5173/auth/callback"],
    "allowed_origins": ["http://localhost:5173"],
    "grants": [
      {
        "target": "rentals.Booking",
        "actions": [{ "name": "read", "required": true }]
      },
      {
        "target": "rentals.BookingLine",
        "actions": [{ "name": "read", "required": true }]
      },
      {
        "target": "equipment.Item",
        "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }]
      }
    ]
  }'
```

La création répond `201`. Le hook a déjà écrit le `client_id` en lecture
seule :

```json
{
  "data": {
    "slug": "brw-checkout",
    "name": "Brightwater Check-out",
    "client_type": "public",
    "status": "draft",
    "client_id": "06H1FQF7NG357EQ0P348Z2BEV5",
    "redirect_uris": ["http://localhost:5173/auth/callback"],
    "allowed_origins": ["http://localhost:5173"],
    "grants": [
      { "target": "rentals.Booking", "actions": [{ "name": "read", "required": true }] },
      { "target": "rentals.BookingLine", "actions": [{ "name": "read", "required": true }] },
      { "target": "equipment.Item", "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }] }
    ]
  },
  "meta": {
    "id": "06H1FQF7NGDJJKSNHXPYT6627M",
    "uri": "urn:facet:app:App:06H1FQF7NGDJJKSNHXPYT6627M",
    "domain": "app",
    "doc_type": "App",
    "created_at": "2026-11-26T12:39:08Z",
    "updated_at": "2026-11-26T12:39:08Z"
  }
}
```

### 2. Activez l’app

Une app neuve est un `draft`. Les connexions et les clés ne fonctionnent
que quand le statut est `active` :

```sh
curl -sk -X PATCH \
  "$HOST/Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "active"}'
```

Le patch répond `200` avec le document enregistré ; `status` se relit
`"active"`.

### 3. Connectez un utilisateur

Le flux navigateur envoie l’utilisateur à l’écran de consentement et
renvoie un code. Construisez d’abord une paire PKCE :

```sh
openssl rand -base64 48 | tr '+/' '-_' | tr -d '='
# YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F  <- code_verifier

printf '%s' 'YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F' \
  | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
# JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc  <- code_challenge
```

Dans l’app qui tourne, le navigateur fait les deux sauts suivants. Depuis
un terminal, demandez à l’endpoint authorize ce que montrerait l’écran de
consentement :

```sh
curl -sk -H "Authorization: Bearer $RAVI_KEY" \
  "$HOST/OAuth/authorize?response_type=code&client_id=06H1FQF7NG357EQ0P348Z2BEV5&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fauth%2Fcallback&code_challenge=JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc&code_challenge_method=S256&state=winter-fair-43" \
  -H 'Accept: application/json'
```

La réponse décrit l’app et liste les rôles que le compte peut élire, avec
la portée que chaque rôle laisserait à l’app :

```json
{
  "app": {
    "slug": "brw-checkout",
    "display_name": "Brightwater Check-out",
    "status": "active"
  },
  "roles": [
    {
      "role_id": "iam.Roles.admin",
      "display_name": "Full administrative access to all resources.",
      "effective_scope": [
        { "target": "rentals.Booking", "actions": ["read"] },
        { "target": "rentals.BookingLine", "actions": ["read"] },
        { "target": "equipment.Item", "actions": ["read", "create", "update"] }
      ]
    }
  ],
  "state": "winter-fair-43"
}
```

L’utilisateur élit un rôle. Publiez l’élection avec les mêmes paramètres
plus `role` ; la réponse porte le code à usage unique :

```sh
curl -sk -X POST "$HOST/OAuth/authorize?response_type=code&client_id=06H1FQF7NG357EQ0P348Z2BEV5&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fauth%2Fcallback&code_challenge=JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc&code_challenge_method=S256&state=winter-fair-43" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "response_type": "code",
    "client_id": "06H1FQF7NG357EQ0P348Z2BEV5",
    "redirect_uri": "http://localhost:5173/auth/callback",
    "code_challenge": "JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc",
    "code_challenge_method": "S256",
    "state": "winter-fair-43",
    "role": "iam.Roles.admin"
  }'
```

```json
{
  "redirect_uri": "http://localhost:5173/auth/callback",
  "code": "5mmwDDXn58mmruIfJ_4INhGxmYgMXYupVqhH_AqToac",
  "state": "winter-fair-43",
  "app_id": "06H1FQF7NGDJJKSNHXPYT6627M",
  "role_id": "iam.Roles.admin",
  "iss": "https://facet.localhost:3443"
}
```

Le code vit 60 secondes et ne sert qu’une fois. Échangez-le maintenant :

```sh
curl -sk -X POST "$HOST/OAuth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode 'grant_type=authorization_code' \
  --data-urlencode 'code=5mmwDDXn58mmruIfJ_4INhGxmYgMXYupVqhH_AqToac' \
  --data-urlencode 'client_id=06H1FQF7NG357EQ0P348Z2BEV5' \
  --data-urlencode 'redirect_uri=http://localhost:5173/auth/callback' \
  --data-urlencode 'code_verifier=YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F'
```

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.eyJzdWIiOiIwNkgxRk0wOThXQjJCN1g1QkE0OTQ2Nks0TiIsInNpZCI6IjQyZTliY2I2MGVmMGI3ZmQ3OTY1M2UxNDFkNTMyMjI2NmY2ODE3ZjY2MWRjZjUwNjQzNmE1YWQ2ZDVjNGM4M2EiLCJyb2xlIjoiaWFtLlJvbGVzLmFkbWluIiwianRpIjoiMDZIMUc0RlY5Q05RSDNLOThFTURTTUFBWjkiLCJ0eXAiOiJhcHAiLCJpYXQiOjE3OTU3MDAxNjEsImV4cCI6MTc5NTcwMTA2MSwiYXBwIjoiMDZIMUZRRjdOR0RKSktTTkhYUFlUNjYyN00ifQ.AqrsiB6iDvRCasWYNdlauDPTOuXSBERFmV-baW1aAlgd-HUxXI7s81PiDBFEBcognYPtyDM5tGieS5-OvXafAw",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "42e9bcb60ef0b7fd79653e141d5322266f6817f661dcf506436a5ad6d5c4c83a.a91913d305aac321675056fd92fb5cf4be2e3827209e79cdf140f548f4b1538d"
}
```

Gardez le token d’accès dans une variable pour les appels ci-dessous :

```sh
export TOKEN=$(curl -sk -X POST "$HOST/OAuth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode 'grant_type=authorization_code' \
  --data-urlencode 'code=5mmwDDXn58mmruIfJ_4INhGxmYgMXYupVqhH_AqToac' \
  --data-urlencode 'client_id=06H1FQF7NG357EQ0P348Z2BEV5' \
  --data-urlencode 'redirect_uri=http://localhost:5173/auth/callback' \
  --data-urlencode 'code_verifier=YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F' \
  | jq -r .access_token)
```

Gardez aussi le refresh token : le token d’accès meurt après `expires_in`
secondes, et le refresh en frappe un nouveau — voir
[Connecter les utilisateurs](/fr/build/apps/connect/user-login/).

Le parcours complet, gestion du callback et plancher de refresh compris,
est [Connecter les utilisateurs](/fr/build/apps/connect/user-login/).

### 4. Lisez des données réelles

Appelez l’API avec le token d’accès. L’app lit les réservations :

```sh
curl -sk "$HOST/Api/rentals/Booking?items=2&sort=-created_at" \
  -H "Authorization: Bearer $TOKEN"
```

```json
{
  "data": [
    {
      "data": {
        "dates": { "end": "2026-11-29", "start": "2026-11-28" },
        "notes": "Press launch — done.",
        "total": 410,
        "client": "clients.Company.06H1FM1B68KB1PJVVAM92B38YS",
        "status": "returned",
        "client_name": "Festival des Collines"
      },
      "meta": { "id": "BK-2026-0015", "display_name": "Festival des Collines" }
    },
    {
      "data": {
        "dates": { "end": "2026-12-06", "start": "2026-12-05" },
        "notes": "Charity gala — done.",
        "total": 576,
        "client": "clients.Company.06H1FM1BNMKMN3PRSDK8B8FR7K",
        "status": "returned",
        "client_name": "Château de Vireloup"
      },
      "meta": { "id": "BK-2026-0014", "display_name": "Château de Vireloup" }
    }
  ],
  "meta": { "count": 15, "more": false }
}
```

Le même token sur un doctype en dehors de l’attribution est refusé :

```sh
curl -sk "$HOST/Api/clients/Company?items=1" \
  -H "Authorization: Bearer $TOKEN"
```

```
{"error": "Forbidden"}
```

C’est le plafond d’attributions à l’œuvre, alors même que l’utilisateur
qui se connecte est un admin. Le chemin de la requête derrière ce refus :
[Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/).

### 5. Voyez ce que l’app peut atteindre

Le token peut aussi lire ses propres limites. `GET /Api/iam/me` répond avec
le manifest effectif — les droits exacts que porte cet identifiant :

```sh
curl -sk "$HOST/Api/iam/me" \
  -H "Authorization: Bearer $TOKEN"
```

La carte `permissions` liste ce que l’app peut tenter :

```json
{
  "active_role": "iam.Roles.admin",
  "permissions": {
    "rentals.Booking": ["read"],
    "rentals.BookingLine": ["read"],
    "equipment.Item": ["read", "create", "update"]
  }
}
```

Dimensionnez votre UI d’après cette carte —
[Afficher uniquement ce que l’utilisateur peut faire](/fr/build/apps/connect/permission-manifest/).

### 6. Déployez l’app elle-même

L’app que vous avez construite est encore du code sur votre machine. La CLI
transforme un dossier de build en app servie sur l’instance :

```sh
pnpx @facetapp/cli init
pnpx @facetapp/cli login
pnpx @facetapp/cli deploy --note "first build"
```

Le modèle de déploiement complet — releases, retour arrière, hôtes
personnalisés — est
[Déployer votre app sur Facet](/fr/build/apps/host/deploy/).

## Dépannage

**La création répond `422` avec `wildcard_target`.**

```json
{"error": "Grant validation failed", "details": [{"field": "grants[0].target", "message": "Wildcard grant target 'rentals.*' is not allowed — name the concrete doctype the app uses", "code": "wildcard_target"}]}
```

Une attribution nomme `rentals.*` ou `*.*`. Nommez chaque doctype concret —
une entrée par doctype.

**Une entrée de redirection échoue avec `422` et `code: "script"`.**

```json
{"error": "Script validation failed", "details": [{"message": "redirect_uris entries must use https on any host or http on a loopback host (localhost, *.localhost, 127.0.0.1, ::1), without fragment, userinfo, or query; the only permitted wildcard is a '*' port on an http loopback host", "code": "script"}]}
```

Enregistrez l’adresse selon la règle du message : `https` sur n’importe
quel hôte, `http` sur les hôtes de bouclage seulement, ni fragment, ni
userinfo, ni query, et un `*` uniquement comme port d’une entrée `http` de
bouclage.

**L’échange de token répond `400 invalid_grant`.**

Le code ne sert qu’une fois et expire après 60 secondes. Une nouvelle
tentative avec le même code répond
`{"error": "invalid_grant", "error_description": "Authorization code is invalid, expired, or already used"}`.
Relancez la connexion.

**Un appel que l’app faisait avant répond maintenant
`403 {"error": "Forbidden"}`.**

L’attribution a été réduite, ou le rôle du token ne couvre plus une action
requise. Vérifiez le document d’app, puis reconnectez-vous si le rôle a
changé.

**Un déploiement répond `HTTP 422 from /Api/app/…/deploy`.**

Une app en brouillon ou désactivée ne peut pas recevoir un build. Activez-la
d’abord — étape 2 ci-dessus.

## Voir aussi

- [Connecter les utilisateurs](/fr/build/apps/connect/user-login/) — le flux
  de connexion, en entier.
- [Enregistrer une app](/fr/build/apps/connect/register/) — chaque champ
  d’enregistrement.
- [Déployer votre app sur Facet](/fr/build/apps/host/deploy/) — servir l’app
  construite.
- [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/) —
  pourquoi les limites tiennent.
- [La CLI des apps Facet](/fr/reference/cli-npm/)
