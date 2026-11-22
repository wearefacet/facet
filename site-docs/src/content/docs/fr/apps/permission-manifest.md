---
title: Dimensionner l’UI avec le manifeste
description: Lisez le manifeste de permissions de l’appelant et dimensionnez votre interface avec lui.
audience: [developer]
features: [RBC-11, IAM-14]
sidebar:
  order: 15
verified_at: a77c6171
---

Tout appelant de l’API peut aussi lire ce qu’il a le droit de tenter. Le
manifeste de permissions de `GET /Api/iam/me` liste les chemins de doctypes,
les actions et les périmètres de lignes que l’appelant atteint. Utilisez-le
pour cacher des boutons et pour dimensionner l’interface. Le manifeste n’a
qu’une valeur indicative : le serveur revérifie chaque requête et ne relit
jamais le manifeste.

> **Pour les agents :** point de terminaison : `GET /Api/iam/me` — renvoie
> `permissions` (une map des clés `"domain.Doctype"` vers des listes
> d’actions), `scopes` (doctype → action → alias de périmètres),
> `connectivity` et `assistant` (`{access, token_budget, name}`). SDK :
> `await facet.whoami()` (en cache) → `await facet.can('delete', 'crm.Company')`
> répond `'all' | 'scoped' | 'denied'` ;
> `await facet.scopes('update', 'crm.Company')` lit les alias ;
> `await facet.refreshRights()` après un changement de rôle ou d’attribution.
> Les clés réservées `"*.*"`, `"{domain}.*"` et `"*.*.except.<action>"` sont
> une entrée du matcher, pas des doctypes.

## Quand l’utiliser

Utilisez le manifeste quand :

- vous cachez des boutons ou des entrées de menu que l’appelant ne peut pas
  utiliser,
- vous affichez une indication de limite quand des périmètres de lignes
  restreignent une action,
- vous adaptez votre app aux canaux et à l’assistant que le rôle permet.

## Avant de commencer

- Un moyen de s’authentifier auprès de l’API : un token de session, un token
  d’app OAuth, ou une clé `fct_` statique. Les trois lisent le manifeste.
- Le modèle de portée qui sous-tend le manifeste :
  [Apps : attributions ∩ rôles](/fr/concepts/apps-grants-roles/).
- Comment les apps reçoivent cette portée :
  [Le fonctionnement des apps sur Facet](/fr/apps/how-apps-work/).

## Étapes

### 1. Lire le manifeste

Appelez le point de terminaison avec votre moyen d’authentification. Une clé
statique emprunte le schéma bearer :

```sh
curl -s https://facet.example.com/Api/iam/me \
  -H "Authorization: Bearer $FACET_API_KEY"
```

Un token d’app emprunte le schéma DPoP avec une preuve à chaque appel — voir
[Liaison de token DPoP](/fr/apps/dpop/). La réponse porte quatre champs en
plus du profil du compte :

| Champ | Contenu |
| --- | --- |
| `permissions` | Une map des clés `"domain.Doctype"` vers des listes d’actions. |
| `scopes` | Une map du doctype vers l’action vers les alias de périmètres. `[]` signifie sans restriction. |
| `connectivity` | Les canaux du rôle actif : `mcp`, `webhook`, `api`, `assistant`. |
| `assistant` | `{access, token_budget, name}` — la porte d’accès au chat, le budget (`null` = illimité) et le nom d’affichage. |

### 2. Reconnaître les formes de clés

La map `permissions` regroupe les lignes de permission du rôle. Ces règles
produisent chaque clé :

- Une ligne concrète sur `crm.Company` atterrit sous la clé littérale
  `"crm.Company"`.
- Une ligne à l’échelle du domaine sur `hr` atterrit sous la clé joker de
  domaine `"hr.*"`.
- Une ligne joker garde sa liste d’actions sur la clé littérale `"*.*"`.
- Une ligne joker avec des retranchements range ceux-ci par action sous
  `"*.*.except.<action>"`, par exemple `"*.*.except.create"`. La valeur liste
  les chemins soustraits.
- Une clé n’apparaît que si son regroupement n’est pas vide. Une clé de
  doctype ne contient jamais `*`.

La map `scopes` reflète les règles de lignes.
`scopes["crm.Company"]["update"]` vaut `[]` quand le droit de mise à jour est
sans restriction, ou une liste d’alias comme `["mine"]` quand des périmètres
de lignes s’appliquent. Les lignes joker se rangent sous la clé `"*.*"` de
`scopes` ; les lignes à l’échelle du domaine sous la clé `"{domain}.*"`.

Ce manifeste vient d’un rôle proche d’un éditeur. Il lit et crée partout, ne
peut pas créer de paramètres système, et met à jour et supprime des sociétés.
Une ligne à l’échelle du domaine ajoute la lecture sur `hr`, limitée à l’alias
`team` :

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

### 3. Associer une clé dans le bon ordre

Si vous écrivez votre propre matcher, accordez dans cet ordre et arrêtez-vous
à la première correspondance :

1. Court-circuit admin : la clé `"*.*"` avec les actions `["*"]` donne tout.
2. Clé exacte : `"crm.Company"` donne `crm.Company`. Une clé atteint aussi ses
   descendants — `"crm.Contact"` atteint `crm.Contact.Comment`.
3. Clé joker de domaine : `"hr.*"` donne chaque doctype du domaine. Les
   retranchements ne la suppriment jamais.
4. Repli joker : la liste d’actions de `"*.*"` donne le chemin. Mais une
   entrée `"*.*.except.<action>"` pour l’action vérifiée la soustrait quand
   elle est égale au chemin ou lui correspond par préfixe. Une entrée sur
   `core.DocType` exclut aussi `core.DocType.Comment`. Ce qu’une clé explicite
   accorde n’est jamais supprimé.

Lisez les alias de périmètres à la clé qui a donné l’action : la clé de
doctype derrière une correspondance exacte, `scopes["{domain}.*"]` derrière
une ligne à l’échelle du domaine, et `scopes["*.*"]` derrière le repli joker.

### 4. Utiliser les helpers du SDK

Le SDK associe les deux formes de manifeste pour vous :

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'crm-console', redirectUri: `${location.origin}/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.example.com', auth });

await facet.whoami(); // GET /Api/iam/me — en cache après le premier appel

facet.can('read', 'crm.Company'); // Promise<'all' | 'scoped' | 'denied'>
facet.scopes('update', 'crm.Company'); // Promise<string[]> — [] signifie sans restriction
await facet.refreshRights(); // re-fetch après un changement de rôle ou d’attribution
```

`'all'` signifie sans restriction. `'scoped'` signifie que l’action existe
mais que des périmètres de lignes s’appliquent côté serveur — lisez les alias
avec `scopes`. `'denied'` signifie qu’aucune clé du manifeste n’atteint le
chemin.

:::caution[Dimensionnez l’UI, jamais la sécurité]
Le serveur revérifie chaque requête et ne relit jamais le manifeste.
Considérez le `404` ou le `403` d’un appel refusé comme faisant foi. Une
réponse `'scoped'` signifie que le serveur restreint les lignes ; lisez les
alias avec `scopes` et nommez la limite dans l’UI.
:::

### 5. Les appelants d’app lisent le manifeste effectif

Un token d’app ou une clé d’app lit l’intersection résolue de l’attribution et
du rôle, pas le manifeste propre du rôle :

- Les clés sont les doctypes concrets que l’attribution nomme, plus la forme
  joker de domaine quand une cible d’attribution joker se combine avec une
  permission de rôle joker.
- Il n’y a pas de repli joker `"*.*"`.
- Un doctype retranché n’apparaît pas du tout. Le regroupement qui couvre son
  propre chemin retire l’action.
- Un retranchement résiduel sur les descendants apparaît sous la forme de clé
  réservée `"crm.Company.except.update"`, pour que le matcher le soustraie.

Les helpers du SDK associent aussi cette forme. Du point de vue de l’app, un
document que son attribution ne nomme pas n’existe pas. Voir
[Le fonctionnement des apps sur Facet](/fr/apps/how-apps-work/) pour le
modèle attribution et rôle.

## Exemple

Cet exemple dimensionne une barre d’outils d’après le manifeste. Il retire la
barre d’outils quand la lecture est refusée, cache le bouton supprimer quand
la suppression est refusée, et affiche une indication quand la mise à jour est
limitée par des périmètres :

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'crm-console', redirectUri: `${location.origin}/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.example.com', auth });

// Sur la route de redirection, après la connexion :
await auth.handleCallback(location.href);

await facet.whoami(); // charge et met en cache le manifeste

const toolbar = document.querySelector('#company-toolbar') as HTMLElement;
const deleteButton = toolbar.querySelector('#delete-company') as HTMLButtonElement;
const hint = toolbar.querySelector('#scope-hint') as HTMLElement;

if ((await facet.can('read', 'crm.Company')) === 'denied') {
	toolbar.remove();
} else {
	deleteButton.hidden = (await facet.can('delete', 'crm.Company')) === 'denied';

	const updateScopes = await facet.scopes('update', 'crm.Company');
	hint.hidden = updateScopes.length === 0;
	if (updateScopes.length > 0) hint.textContent = 'You can change companies you own.';
}
```

Contre le manifeste de l’étape 2, ce code garde la barre d’outils visible (le
repli joker donne `read`), garde le bouton supprimer (la clé exacte donne
`delete`) et affiche l’indication (le droit de mise à jour porte l’alias
`mine`).

## Dépannage

**L’élément s’affiche, mais l’appel répond `403`.**

Le manifeste est indicatif ; le serveur refuse. La portée a changé — appelez
`await facet.refreshRights()` et refaites le rendu.

**Un bouton manque alors que le rôle donne l’action.**

Un retranchement joker couvre le chemin, ou le manifeste est périmé. Vérifiez
les clés `"*.*.except.<action>"` et appelez `refreshRights`.

**`*.*` est absent pour un token d’app.**

Le manifeste effectif ne porte jamais le repli joker. C’est correct —
l’attribution est le plafond.

**Une itération sur les clés du manifeste rend les clés réservées.**

N’iterez jamais l’une des maps pour rendre un doctype. Les clés réservées
`"*.*"`, `"{domain}.*"` et `"*.*.except.create"` ne sont pas des doctypes.
Faites le rendu à partir des définitions de doctypes.

## Voir aussi

- [Le fonctionnement des apps sur Facet](/fr/apps/how-apps-work/) — le modèle
  attribution et rôle qui sous-tend le manifeste effectif.
- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/apps/typescript-sdk/) — le client
  qui fournit `whoami`, `can` et `scopes`.
- [Rôles et lignes de permission](/fr/govern/roles-permission-lines/) — la
  grammaire des lignes que le manifeste regroupe.
- [Les périmètres de lignes](/fr/govern/row-scopes/) — ce que signifient les
  alias de périmètres.
- [Apps : attributions ∩ rôles](/fr/concepts/apps-grants-roles/) — le concept.
- Internes sur GitHub :
  [doc/backend/iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
