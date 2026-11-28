---
type: how-to
title: Dimensionner l’UI avec le manifeste
description: Lisez le manifeste de permissions de l’appelant et dimensionnez votre interface à partir de lui.
audience: [developer]
features: [RBC-11, IAM-14]
sidebar:
  order: 5
verified_at: eee55a2
---

Tout élément d’authentification capable d’appeler l’API peut aussi lire ce qu’il a le droit de tenter. Le manifeste de permissions de `GET /Api/iam/me` liste les chemins de doctypes, les actions et les périmètres de lignes que cet élément atteint. Servez-vous-en pour masquer des boutons et ajuster les éléments d’interface. Le manifeste n’a qu’une valeur indicative : le serveur revérifie chaque requête et ne tient jamais compte du manifeste.

> **Pour les agents :** endpoint : `GET /Api/iam/me` — renvoie `permissions` (une map des clés `"domain.Doctype"` vers des listes d’actions), `scopes` (doctype → action → alias de périmètre), `connectivity` et `assistant` (`{access, token_budget, name}`). SDK : `await facet.whoami()` (en cache) → `await facet.can('delete', 'rentals.Booking')` répond `'all' | 'scoped' | 'denied'` ; `await facet.scopes('update', 'rentals.Booking')` lit les alias ; `await facet.refreshRights()` après un changement de rôle ou d’attribution. Les clés réservées `"*.*"`, `"{domain}.*"` et `"*.*.except.<action>"` servent d’entrée au matcher, ce ne sont pas des doctypes.

## Quand l’utiliser

Utilisez le manifeste quand :

- vous masquez des boutons ou des entrées de menu que l’appelant ne peut pas utiliser ;
- vous affichez un indicateur de limite quand des périmètres de lignes restreignent une action ;
- vous adaptez votre app aux canaux et à l’assistant que le rôle autorise.

## Avant de commencer

- Un élément d’authentification qui appelle l’API : un token de session, un token d’app OAuth, ou une clé statique `fct_`. Les trois lisent le manifeste.
- Le modèle de portée que le manifeste décrit : [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/).
- Comment les apps reçoivent cette portée : [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/).

## Étapes

### 1. Lire le manifeste

Appelez le endpoint avec votre élément d’authentification. Une clé statique utilise le schéma bearer :

```sh
curl -sk $(facet-cli host)/Api/iam/me \
  -H "Authorization: Bearer $(facet-cli apikey)"
```

Un token d’app utilise le schéma DPoP avec une preuve à chaque appel — voir [Liaison DPoP des tokens](/fr/build/apps/connect/dpop/). Au-delà du profil du compte, la réponse porte quatre champs :

| Champ | Contenu |
| --- | --- |
| `permissions` | Une map des clés `"domain.Doctype"` vers des listes d’actions. |
| `scopes` | Une map du doctype vers l’action vers les alias de périmètre. `[]` signifie sans restriction. |
| `connectivity` | Les canaux du rôle actif : `mcp`, `webhook`, `api`, `assistant`. |
| `assistant` | `{access, token_budget, name}` — le contrôle d’accès au chat, le budget (`null` = illimité), et le nom affiché. |

### 2. Reconnaître les formes de clé

La map `permissions` condense les lignes de permission du rôle. Ces règles produisent chaque clé :

- Une ligne concrète sur `rentals.Booking` arrive sous la clé littérale `"rentals.Booking"`.
- Une ligne couvrant tout le domaine `equipment` arrive sous la clé à joker de domaine `"equipment.*"`.
- Une ligne joker garde sa liste d’actions sur le littéral `"*.*"`.
- Une ligne joker avec exceptions les condense action par action sous `"*.*.except.<action>"`, par exemple `"*.*.except.create"`. La valeur liste les chemins retranchés.
- Une clé n’apparaît que si son condensé n’est pas vide. Une clé de doctype ne contient jamais `*`.

La map `scopes` reflète les règles de lignes. `scopes["rentals.Booking"]["update"]` vaut `[]` quand le droit de mise à jour est sans restriction, ou une liste d’alias comme `["mine"]` quand des périmètres de lignes s’appliquent. Les lignes joker se condensent sous la clé `scopes` `"*.*"` ; les lignes couvrant tout un domaine se condensent sous la clé `"{domain}.*"`.

Ce manifeste est réel. Lucía Ferrer détient le rôle `warehouse` de Brightwater — des lignes couvrant tout `equipment` et `core`, des lignes de lecture concrètes ailleurs :

```json
{
  "active_role": "iam.Roles.warehouse",
  "channel": "session",
  "connectivity": ["api", "mcp", "assistant"],
  "permissions": {
    "equipment.*": ["*"],
    "rentals.Booking": ["read"],
    "rentals.BookingLine": ["read"],
    "clients.Company": ["read"],
    "clients.Contact": ["read"],
    "core.Comment": ["*"],
    "core.Attachment": ["*"]
  }
}
```

La ligne couvrant tout le domaine `{"on": "equipment", "action": "*"}` s’est condensée sous la clé `"equipment.*"`. Ravi détient le rôle `admin` créé par l’initialisation ; son manifeste est la totalité : `"*.*": ["*"]`.

### 3. Associer une clé dans le bon ordre

Si vous écrivez votre propre matcher, accordez dans cet ordre et arrêtez-vous à la première correspondance :

1. Court-circuit admin : la clé `"*.*"` avec les actions `["*"]` accorde tout.
2. Clé exacte : `"rentals.Booking"` accorde `rentals.Booking`. Une clé atteint aussi ses descendants — `"rentals.Booking"` atteint les doctypes enfants de type `rentals.Booking.Line`.
3. Clé à joker de domaine : `"equipment.*"` accorde chaque doctype du domaine. Les exceptions ne la suppriment jamais.
4. Repli joker : la liste d’actions de `"*.*"` accorde le chemin. Mais une entrée `"*.*.except.<action>"` pour l’action vérifiée la retranche quand elle égale le chemin ou en est un préfixe. Une entrée sur `core.DocType` exclut aussi `core.DocType.Comment`. Un accord par clé explicite n’est jamais supprimé.

Lisez les alias de périmètre à la clé qui a accordé l’action : la clé de doctype pour une correspondance exacte, `scopes["{domain}.*"]` pour un accord couvrant tout le domaine, et `scopes["*.*"]` pour le repli.

Un rôle de type éditeur montre la forme des exceptions en une seule image. Il lit et crée partout, ne peut pas créer les paramètres système, et met à jour et supprime les sociétés :

```json
{
  "permissions": {
    "*.*": ["create", "read"],
    "*.*.except.create": ["core.SystemSettings"],
    "crm.Company": ["update", "delete"],
    "hr.*": ["read"]
  },
  "scopes": {
    "*.*": { "create": [], "read": [] },
    "crm.Company": { "update": ["mine"], "delete": [] },
    "hr.*": { "read": ["team"] }
  }
}
```

### 4. Utiliser les aides du SDK

Le SDK associe les deux formes de manifeste pour vous :

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'brw-checkout', redirectUri: `${location.origin}/auth/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.localhost:3443', auth });

await facet.whoami(); // GET /Api/iam/me — en cache après le premier appel

facet.can('read', 'rentals.Booking'); // Promise<'all' | 'scoped' | 'denied'>
facet.scopes('update', 'rentals.Booking'); // Promise<string[]> — [] signifie sans restriction
await facet.refreshRights(); // re-télécharge après un changement de rôle ou d’attribution
```

`'all'` signifie sans restriction. `'scoped'` signifie que l’action existe mais que des périmètres de lignes s’appliquent côté serveur — lisez les alias avec `scopes`. `'denied'` signifie qu’aucune clé du manifeste n’atteint le chemin.

:::caution[Dimensionnez l’interface, ne contrôlez jamais la sécurité]
Le serveur revérifie chaque requête et ne tient jamais compte du manifeste. Considérez le `404` ou le `403` d’un appel refusé comme la décision. Une réponse `'scoped'` signifie que le serveur restreint les lignes ; lisez les alias avec `scopes` et nommez la limite dans l’interface.
:::

### 5. Les appelants limités par l’app lisent le manifeste effectif

Un token d’app ou une clé propre à l’app lit l’intersection résolue de l’attribution et du rôle, pas le manifeste du rôle lui-même :

- Les clés sont les doctypes concrets que l’attribution nomme, plus la forme à joker de domaine quand une cible d’attribution joker se recoupe avec une permission de rôle joker.
- Il n’y a pas de repli `"*.*"`.
- Un doctype retranché n’apparaît pas du tout. Le condensé qui couvre son propre chemin retire l’action.
- Une exception résiduelle sur des descendants apparaît sous la forme de clé réservée `"crm.Company.except.update"`, pour que le matcher la retranche.

Le token de l’app de check-out répond avec exactement les trois doctypes accordés — alors que Ravi, qui s’est connecté, détient le rôle `admin` :

```json
{
  "active_role": "iam.Roles.admin",
  "channel": "api",
  "permissions": {
    "rentals.Booking": ["read"],
    "rentals.BookingLine": ["read"],
    "equipment.Item": ["read", "create", "update"]
  }
}
```

La clé stock-sync répond de la même façon pour son rôle épinglé :

```json
{
  "active_role": "iam.Roles.stock_sync",
  "channel": "api",
  "expires_at": null,
  "permissions": {
    "equipment.Item": ["read", "create", "update"]
  }
}
```

Les aides du SDK associent aussi cette forme. Du point de vue de l’app, un document que son attribution ne nomme pas n’existe pas. Voir [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/) pour le modèle d’attribution et de rôle.

## Exemple

Cet exemple dimensionne une barre d’outils à partir du manifeste. Il retire la barre d’outils quand le droit de lecture est refusé, masque le bouton de suppression quand le droit de suppression est refusé, et affiche un indicateur quand le droit de mise à jour est soumis à un périmètre :

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'brw-checkout', redirectUri: `${location.origin}/auth/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.localhost:3443', auth });

// Sur la route de redirection, après la connexion :
await auth.handleCallback(location.href);

await facet.whoami(); // charge et met en cache le manifeste

const toolbar = document.querySelector('#booking-toolbar') as HTMLElement;
const deleteButton = toolbar.querySelector('#delete-booking') as HTMLButtonElement;
const hint = toolbar.querySelector('#scope-hint') as HTMLElement;

if ((await facet.can('read', 'rentals.Booking')) === 'denied') {
	toolbar.remove();
} else {
	deleteButton.hidden = (await facet.can('delete', 'rentals.Booking')) === 'denied';

	const updateScopes = await facet.scopes('update', 'rentals.Booking');
	hint.hidden = updateScopes.length === 0;
	if (updateScopes.length > 0) hint.textContent = 'You can change bookings you own.';
}
```

Avec le token d’app de Ravi de l’étape 5, ce code garde la barre d’outils visible (`read` se trouve sur la clé exacte), masque le bouton de suppression (aucune clé du manifeste n’accorde `delete` — l’attribution ne le nomme pas), et laisse l’indicateur masqué (les périmètres sont vides).

## Dépannage

**L’élément d’interface s’affiche, mais l’appel répond `403`.**

Le manifeste n’a qu’une valeur indicative ; le serveur refuse. La portée a changé — appelez `await facet.refreshRights()` et réaffichez l’interface.

**Un bouton manque alors que le rôle accorde l’action.**

Une exception joker couvre le chemin, ou le manifeste est périmé. Vérifiez les clés `"*.*.except.<action>"` et appelez `refreshRights`.

**`*.*` manque pour un token d’app.**

Le manifeste effectif ne porte jamais le repli joker. C’est correct — l’attribution est le plafond.

**Une itération sur les clés du manifeste affiche les clés réservées.**

N’iterez jamais l’une des maps pour afficher un doctype. Les clés réservées `"*.*"`, `"{domain}.*"` et `"*.*.except.create"` ne sont pas des doctypes. Affichez plutôt à partir des définitions de doctypes.

## Voir aussi

- [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/) — le modèle d’attribution et de rôle derrière le manifeste effectif.
- [Le SDK TypeScript](/fr/build/apps/data/sdk/) — le client qui fournit `whoami`, `can` et `scopes`.
- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) — la grammaire de lignes que le manifeste condense.
- [Les périmètres de lignes](/fr/admin/people/row-scopes/) — ce que signifient les alias de périmètre.
- [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/) — le concept.
- Sources internes sur GitHub : [doc/backend/iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
- [Sécurité et gouvernance](/fr/discover/security/)
- [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/)
