---
title: Enregistrer une app
description: Enregistrez une app via le tableau de bord ou l’API REST, et choisissez le type de client adapté.
audience: [developer]
features: [APP-01, FE-12]
sidebar:
  order: 3
verified_at: a77c6171
---

Chaque app commence comme un enregistrement : un document `app.App`.
L’enregistrement nomme le type de client, les adresses de redirection et le
plafond d’attributions. Vous passez par l’assistant du tableau de bord, ou
par l’API REST quand vous scriptez la configuration. Dans les deux cas,
l’app devient utilisable quand son `status` passe à `active`.

> **Pour les agents :** créez l’app avec `POST /Api/app/App`. Le corps JSON
> porte `slug`, `name`, `client_type`, `redirect_uris`, `allowed_origins`
> et `grants` ; envoyez un cookie de session et
> `X-Requested-With: XMLHttpRequest`. La création répond `201` avec le
> document stocké et un `client_id` écrit par le hook. Publiez avec
> `PATCH /Api/app/App/{id}` et `{"status": "active"}`. Chaque entrée
> d’attribution ressemble à

> `{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}` ;
> une cible générique répond `422 wildcard_target`.

## Quand l’utiliser

Utilisez cette page quand :

- Vous ajoutez une nouvelle app à Facet.
- Vous devez choisir entre un enregistrement public, confidentiel ou
  headless.
- Vous scriptez la configuration des apps et cherchez le chemin API.

## Avant de commencer

- Il vous faut les droits `update` sur les documents `app.App`. Les rôles
  `admin` et `editor` créés par l’initialisation les portent.
- Listez les doctypes que l’app atteindra, les adresses de retour après
  connexion, et les origines navigateur. Chaque attribution nomme un
  doctype concret.

## Étapes

### 1. Choisir le type de client

- **Public** — une application mono-page (SPA) qui vit dans le navigateur.
  Elle se connecte via l’écran de consentement avec le Proof Key for Code
  Exchange (PKCE) et ne détient aucun secret.
- **Confidentiel** — passe par le même écran de consentement et ajoute un
  backend. Le backend agit via un compte de service et une clé API propre
 à l’app — voir [Apps backend](/fr/apps/service-accounts/).
- **Headless** — définit `no_launcher: true`. Elle n’apparaît jamais dans
  le tableau de bord ; on y accède via son client. Un outil en ligne de
  commande qui ne déploie jamais de builds définit aussi `no_asset: true`.

  Les types public et confidentiel apparaissent dans le lanceur du tableau
  de bord tant que `no_launcher` n’est pas défini. Une app `no_asset` ne
  peut pas porter de `host`.

### 2. Enregistrer dans le tableau de bord

Ouvrez **Configurer → Applications** et lancez l’assistant. Choisissez une
forme de départ : une app web que vous hébergez se connecte via le
navigateur ; une app backend se connecte avec une clé API. L’étape Création
recueille le nom, les origines autorisées et les adresses de redirection.

L’étape Autorisations liste chaque doctype par domaine. Choisissez un
niveau d’accès par doctype, et sélectionnez l’unique rôle de service pour
une app backend. Les actions nommées que déclare un doctype apparaissent
comme capacités supplémentaires.

La publication passe le `status` à `active`. Une app web reçoit son
`client_id`. Une app confidentielle émet une clé API ; la clé brute ne
s’affiche qu’une seule fois.

### 3. Ou enregistrer via l’API REST

Connectez-vous comme opérateur et gardez les cookies de session dans
`cookies.txt` — la séquence complète figure sous
[Apps backend](/fr/apps/service-accounts/). Créez ensuite le document
d’app :

```sh
curl -s -b cookies.txt -X POST https://facet.company.tld/Api/app/App \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{
    "slug": "deal-board",
    "name": "Deal Board",
    "client_type": "public",
    "redirect_uris": ["https://deal-board.company.tld/auth/callback"],
    "allowed_origins": ["https://deal-board.company.tld"],
    "grants": [
      {
        "target": "crm.Deal",
        "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }]
      }
    ]
  }'
```

La création répond `201` avec le document stocké. Le hook de création a
déjà écrit `client_id` :

```json
{
  "data": {
    "slug": "deal-board",
    "name": "Deal Board",
    "client_type": "public",
    "status": "draft",
    "client_id": "01JHQ8ZV3M7Q2XK9PB4T5WY6RD",
    "redirect_uris": ["https://deal-board.company.tld/auth/callback"],
    "allowed_origins": ["https://deal-board.company.tld"],
    "grants": [
      {
        "target": "crm.Deal",
        "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }]
      }
    ]
  },
  "meta": {
    "id": "app.App.01JHQ9M4T8C3XK2PB5WY6RD7QF",
    "uri": "urn:facet:app:App:01JHQ9M4T8C3XK2PB5WY6RD7QF",
    "mid": "01JHQ9M5T8D4XK2PB5WY6RD8QG",
    "domain": "app",
    "doc_type": "App",
    "version": 1,
    "schema_version": 1,
    "created_at": "2026-11-13T09:00:00Z",
    "updated_at": "2026-11-13T09:00:00Z"
  }
}
```

Publiez quand l’app est prête. Une app a besoin de `status: active` avant
que les connexions fonctionnent :

```sh
curl -s -b cookies.txt -X PATCH \
  https://facet.company.tld/Api/app/App/01JHQ9M4T8C3XK2PB5WY6RD7QF \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"status": "active"}'
```

:::note[Règles des URI de redirection]
Chaque entrée est une URI `http(s)` absolue, sans fragment, sans query et
sans userinfo. `https` est valide sur n’importe quel hôte. `http` n’est
valide que sur les hôtes de bouclage : `localhost`, tout sous-domaine
`*.localhost`, `127.0.0.1`, et `::1`. Un port `*` n’est valide que sur une
entrée `http` de bouclage. À la requête, l’URI présentée doit correspondre
exactement, sauf qu’une entrée avec port `*` correspond à n’importe quel
port.
:::

## Exemple

Le script d’initialisation livre un enregistrement fourni avec Facet :
`facet-cli`, la CLI de dev. C’est un exemple headless complet :

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

La CLI se lie à un port local éphémère ; chaque entrée de redirection
épingle donc un port `*` sur un hôte de bouclage. Les attributions portent
`deploy` sur `app.App` parce que la CLI déploie des builds. Aucun rôle de
service n’existe : le rôle élu vient de l’écran de consentement.

## Dépannage

**La création répond `422 wildcard_target`.**

Une attribution nomme `crm.*` ou `*.*`. Nommez chaque doctype concret à la
place — une entrée par doctype.

**Une entrée de redirection échoue à la validation avec `422`.**

Vérifiez la note ci-dessus : `https` partout, `http` en bouclage seulement,
`*` seulement comme port sur une entrée `http` de bouclage, pas de fragment
ni de query.

**Un PATCH qui change `slug` est refusé.**

Le slug est immuable après la création. Le hook de mise à jour refuse tout
patch qui porte la clé. Créez une nouvelle app si vous avez besoin d’un
autre slug.

**Fournir `client_id` répond `422 read_only`.**

Le hook de création est le seul à écrire ce champ. Ne l’envoyez pas.

**Un tableau `grants` vide se relit sous forme `{}`.**

Une particularité du hook de création en Lua, au passage aller-retour. Le
comportement est équivalent : les deux formes donnent une itération vide.

## Voir aussi

- [Comment fonctionnent les apps sur Facet](/fr/apps/how-apps-work/) — le
  modèle sur lequel repose l’enregistrement.
- [CORS et origines autorisées](/fr/apps/cors-origins/) — enregistrez les
  origines navigateur.
- [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/apps/oauth-login/) — la
  connexion que l’enregistrement rend possible.
- [Maîtrer la portée des apps (attributions)](/fr/govern/app-grants/) —
  l’éditeur des attributions.
- Internes sur GitHub :
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
