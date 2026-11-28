---
type: how-to
title: Enregistrer une app
description: Enregistrez une app via le tableau de bord ou l’API REST, et choisissez le type de client qui convient.
audience: [developer]
features: [APP-01, FE-12]
sidebar:
  order: 0
verified_at: eee55a2
---

Chaque app commence par un enregistrement : un document `app.App`. L’enregistrement porte le type de client, les adresses de redirection et le plafond d’attribution. Vous enregistrez via l’assistant du tableau de bord, ou via l’API REST quand vous scriptez l’installation. Dans les deux cas, l’app devient utilisable quand son statut passe à `active`.

> **Pour les agents :** créez l’app avec `POST /Api/app/App`. Le corps JSON porte `slug`, `name`, `client_type`, `redirect_uris`, `allowed_origins` et `grants` ; envoyez une clé d’API dans `Authorization: Bearer`, ou un cookie de session plus `X-Requested-With: XMLHttpRequest`. La création répond `201` avec le document stocké et un `client_id` écrit par le hook. Publiez avec `PATCH /Api/app/App/{id}` et `{"status": "active"}`. Chaque entrée d’attribution ressemble à `{"target": "rentals.Booking", "actions": [{"name": "read", "required": true}]}` ; une cible joker répond `422 wildcard_target`.

## Quand l’utiliser

Utilisez cette page quand :

- vous ajoutez une nouvelle app à Facet ;
- vous devez choisir entre un enregistrement public, confidentiel ou headless ;
- vous scriptez l’installation d’une app et avez besoin du chemin API.

## Avant de commencer

- Vous avez besoin du droit `update` sur les documents `app.App`. Les rôles `admin` et `editor` créés par l’initialisation le détiennent.
- Listez les doctypes que l’app atteindra, les adresses de retour après connexion, et les origines du navigateur. Chaque [attribution](/fr/admin/apps-access/app-grants/) nomme un doctype concret.

## Étapes

### 1. Choisir le type de client

- **Public** — une application monopage (SPA) qui ne vit que dans le navigateur. Elle se connecte via l’écran de consentement avec Proof Key for Code Exchange (PKCE) et ne détient aucun secret.
- **Confidentiel** — se connecte via le même écran de consentement et ajoute un backend. Le backend agit par un compte de service et une clé d’API propre à l’app — voir [Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/).
- **Headless** — définit `no_launcher: true`. Il n’apparaît jamais dans le tableau de bord ; on y accède par son client. Un outil en ligne de commande qui ne déploie jamais de builds définit aussi `no_asset: true`.

  Les deux types apparaissent dans le lanceur du tableau de bord sauf si `no_launcher` est défini. Une app `no_asset` ne peut pas porter de `host`.

### 2. Enregistrer dans le tableau de bord

Ouvrez **Configurer → Apps** et lancez l’assistant. Choisissez un préréglage : une app web que vous hébergez se connecte par le navigateur ; une app backend se connecte avec une clé d’API. L’étape d’installation collecte le nom, les origines de connexion et les adresses de redirection.

L’étape des permissions liste chaque doctype par domaine. Réglez un niveau d’accès par doctype, et choisissez l’unique rôle de service pour une app backend. Les actions nommées qu’un doctype déclare apparaissent comme des interrupteurs supplémentaires.

La publication passe le statut à `active`. Une app web reçoit son `client_id`. Une app confidentielle émet une clé d’API ; la clé brute ne s’affiche qu’une fois.

### 3. Ou enregistrer via l’API REST

Connectez-vous comme opérateur et stockez une clé d’API pour votre rôle — la séquence complète figure dans [Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/). La CLI l’écrit ; gardez-la dans une variable :

```sh
pnpx @facetapp/cli connect
RAVI_KEY=$(pnpx @facetapp/cli apikey)
```

Créez ensuite le document d’app :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/app/App \
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

La création répond `201` avec le document stocké. Le hook de création a déjà écrit `client_id` :

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
  },
  "meta": {
    "id": "06H1FQF7NGDJJKSNHXPYT6627M",
    "uri": "urn:facet:app:App:06H1FQF7NGDJJKSNHXPYT6627M",
    "mid": "06H1FQF7N81797JT8AMSFRDGQX",
    "domain": "app",
    "doc_type": "App",
    "version": 1,
    "schema_version": 1,
    "display_name": "Brightwater Check-out",
    "created_at": "2026-11-26T12:39:08Z",
    "updated_at": "2026-11-26T12:39:08Z"
  }
}
```

Publiez quand l’app est prête. Une app a besoin de `status: active` avant que les connexions fonctionnent :

```sh
curl -sk -X PATCH \
  https://facet.localhost:3443/Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "active"}'
```

Le patch répond `200` avec le document stocké, `status` désormais `"active"` et `updated_at` avancé.

### 4. Vérifier comment la connexion voit l’app

Avant de câbler le côté navigateur, demandez au serveur ce que lit un formulaire de connexion. Le endpoint client-info prend le slug :

```sh
curl -sk 'https://facet.localhost:3443/OAuth/client-info?slug=brw-checkout'
```

```json
{"slug": "brw-checkout", "client_id": "06H1FQF7NG357EQ0P348Z2BEV5", "name": "Brightwater Check-out", "client_type": "public"}
```

Un slug inconnu ou inactif répond `404` :

```json
{"error": "unknown_client"}
```

:::note[Règles des URI de redirection]
Chaque entrée est une URI `http(s)` absolue, sans fragment, sans query, et sans userinfo. `https` est valide sur n’importe quel hôte. `http` n’est valide que sur les hôtes de loopback : `localhost`, tout sous-domaine `*.localhost`, `127.0.0.1`, et `::1`. Un port `*` n’est valide que sur une entrée `http` de loopback. À la requête, l’URI présentée doit correspondre exactement, sauf qu’une entrée à port `*` correspond à n’importe quel port.
:::

## Exemple

Le runner d’initialisation livre un enregistrement first-party : `facet-cli`, la CLI de dev. C’est un exemple headless complet :

```json
{
  "slug": "facet-cli",
  "name": "Facet CLI",
  "client_type": "public",
  "status": "active",
  "no_launcher": true,
  "no_asset": true,
  "redirect_uris": [
    "http://localhost:*",
    "http://127.0.0.1:*",
    "http://[::1]:*"
  ],
  "grants": [
    {
      "target": "app.App",
      "actions": [
        { "name": "read", "required": true }, { "name": "write", "required": true },
        { "name": "delete", "required": true }, { "name": "deploy", "required": true }
      ]
    },
    {
      "target": "app.Deployment",
      "actions": [{ "name": "read", "required": true }]
    }
  ]
}
```

La CLI attache un port local éphémère ; chaque entrée de redirection épingle donc un port `*` sur un hôte de loopback. Les attributions portent `deploy` sur `app.App` parce que la CLI déploie des builds. Il n’existe aucun rôle de service : le rôle élu vient de l’écran de consentement. Le endpoint confirme que l’app est active :

```sh
curl -sk 'https://facet.localhost:3443/OAuth/client-info?slug=facet-cli'
```

```json
{"slug": "facet-cli", "client_id": "06H1FKW4N4RVZWCQ2FR392QMW0", "name": "Facet CLI", "client_type": "public"}
```

## Dépannage

**La création répond `422` avec `wildcard_target`.**

```json
{"error": "Grant validation failed", "details": [{"field": "grants[0].target", "message": "Wildcard grant target 'rentals.*' is not allowed — name the concrete doctype the app uses", "code": "wildcard_target"}]}
```

Une attribution nomme `rentals.*` ou `*.*`. Nommez chaque doctype concret à la place — une entrée par doctype.

**Une entrée de redirection échoue à la validation avec `422`.**

```json
{"error": "Script validation failed", "details": [{"message": "redirect_uris entries must use https on any host or http on a loopback host (localhost, *.localhost, 127.0.0.1, ::1), without fragment, userinfo, or query; the only permitted wildcard is a '*' port on an http loopback host", "code": "script"}]}
```

Revoyez l’encadré ci-dessus : `https` partout, `http` en loopback seulement, `*` seulement comme port d’une entrée `http` de loopback, sans fragment ni query.

**Un PATCH qui change `slug` est refusé.**

```json
{"error": "Script validation failed", "details": [{"message": "slug is immutable after creation", "code": "script"}]}
```

Le slug est immuable après la création. Le hook de mise à jour refuse tout patch qui porte la clé. Créez une nouvelle app si vous avez besoin d’un autre slug.

**Fournir `client_id` répond `422 read_only`.**

```json
{"error": "Document validation failed", "details": [{"field": "client_id", "message": "is read-only and should not be set", "code": "read_only"}]}
```

Le hook de création est le seul écrivain. N’envoyez pas le champ.

**Un tableau `grants` vide se relit comme `{}`.**

Une particularité du hook de création Lua lors du va-et-vient. Le comportement est équivalent : les deux formes s’itèrent comme vides.

## Voir aussi

- [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/) — le modèle derrière l’enregistrement.
- [CORS et origines autorisées](/fr/build/apps/connect/cors/) — enregistrez les origines du navigateur.
- [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/) — la connexion que l’enregistrement rend possible.
- [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/) — l’éditeur d’attributions.
- Sources internes sur GitHub : [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
