---
title: Le SDK TypeScript
description: Interrogez, écrivez et abonnez-vous depuis TypeScript avec le client typé @facetapp/sdk.
type: how-to
audience: [developer]
features: [APP-10]
verified_at: eee55a2
sidebar:
  order: 1
---

`@facetapp/sdk` est le SDK TypeScript des apps Facet. Il enveloppe l’API
HTTP et le socket temps réel derrière un seul client typé. Il n’emporte
aucune dépendance à l’exécution, fonctionne dans les navigateurs et sur
Node 20 ou plus récent, et couvre les documents, les requêtes, les actions,
les enfants, les sidecars, les agrégations, l’historique, le retour arrière,
les fichiers, le temps réel et le manifeste de permissions de l’appelant.
Chaque exemple de cette page passe la vérification de types avec la version
actuelle du paquet.

> **Pour les agents :** Installation : `pnpm add @facetapp/sdk`. Client :
> `createFacetClient({ baseUrl, auth })` avec
> `staticKey(process.env.FACET_API_KEY!)` (app backend) ou
> `oauthBrowser({ slug, redirectUri })` (app navigateur ; `await auth.signIn()`
> puis `await auth.handleCallback(location.href)` sur la route de callback).
> Séquence : `facet.domain('clients').doctype('Company').list({ items: 20 })` →
> `page.next()` (`null` à la fin) → `.doc(id).show()` →
> `.doc(id).update({ city: 'Annecy' })` ; droits via `await facet.whoami()` et
> `await facet.can('update', 'clients.Company')` ; les erreurs sont des
> sous-classes d’`ApiError` ; les refus locaux lèvent `UsageError` avant tout
> appel réseau.

## Quand l’utiliser

Choisissez le SDK quand :

- Vous construisez un frontend TypeScript ou un service Node qui parle à Facet.
- Vous voulez des handles typés, la pagination et des erreurs typées au lieu
  du HTTP brut.
- Vous avez besoin de frames temps réel, d’envois de fichiers ou du manifeste
  de permissions dans le code de l’app.

Pour un contrôle HTTP brut, ou pour un autre langage, utilisez
[Utiliser l’API REST](/fr/build/apps/data/rest-api/).

## Avant de commencer

- Node 20 ou plus récent, ou tout navigateur moderne.
- Une app backend a besoin d’une clé d’API possédée par l’app — voir
  [Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/).
- Une app navigateur a besoin d’une connexion OAuth et d’une origine en liste
  blanche — voir [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/).
- Le modèle de portée : [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/).

## Installer et se connecter

```sh
pnpm add @facetapp/sdk
```

Deux canaux d’appel existent et le SDK sert les deux. La portée effective
est toujours l’intersection de l’attribution de l’app et du rôle ; le
backend la recalcule à chaque requête.

### App backend : une clé statique

Une app backend s’authentifie avec une clé d’API possédée par l’app, lue
depuis une variable d’environnement :

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey(process.env.FACET_API_KEY!)
});
```

### App navigateur : OAuth avec PKCE

Le compte se connecte à travers l’écran de consentement. Cet écran élit un
rôle pour l’app :

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({
	slug: 'brightwater-portal',
	redirectUri: 'https://portal.brightwater.example/callback',
	baseUrl: 'https://facet.localhost:3443'
});

const facet = createFacetClient({ baseUrl: 'https://facet.localhost:3443', auth });

if (location.search.includes('code=')) {
	await auth.handleCallback(location.href);
} else {
	await auth.signIn();
}
```

Le refresh token est stocké dans `localStorage` ; l’access token reste en
mémoire. Des réponses `401` concurrentes partagent un seul appel de refresh.
Un refresh en échec lève `AuthError` ; le compte se reconnecte. Les exemples
ci-dessous réutilisent ce client `facet`.

## Documents et requêtes

Chaque appel part d’un arbre de handles : `facet.domain('clients')` renvoie
un handle de domaine, `.doctype('Company')` un handle de collection,
`.doc(id)` une référence de document. Aucun appel réseau ne s’exécute tant
que vous n’appelez pas une méthode sur un handle.

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});

const companies = facet.domain('clients').doctype('Company');

const page = await companies.list({
	filters: { city__eq: 'Lyon' },
	sort: ['-created_at'],
	items: 20
});

for (const row of page.data) {
	console.log(row.meta.display_name, row.data.city);
}

const nextPage = await page.next(); // null quand meta.more vaut false
```

Un aller-retour d’écriture complet, avec les deux cas d’erreur qui méritent
un traitement :

```ts
import { createFacetClient, staticKey, ApiError, DeletedError } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});
const companies = facet.domain('clients').doctype('Company');

const created = await companies.create({ name: 'Atelier Vermeil', city: 'Lyon' });
console.log(created.meta.id, created.meta.display_name);

const ref = companies.doc(created.meta.id);
await ref.update({ city: 'Annecy' });

try {
	await ref.show();
} catch (e) {
	if (e instanceof DeletedError) {
		console.log('deleted at', e.deletedAt, 'label', e.displayName);
	} else if (e instanceof ApiError && e.status === 404) {
		console.log('gone');
	}
}

await ref.delete();
```

Les références de documents portent le reste de la surface :

```ts
await doc.action('confirm', { note: 'deposit paid' }); // une action nommée
await doc.history();        // le journal des mutations, du plus récent au plus ancien
await doc.rollback(mutationId); // l’état à cette mutation
await doc.restore();        // annule la suppression d’une pierre tombale
await doc.backrefs();       // les documents réels qui référencent celui-ci
await doc.children('contacts').list();  // une collection enfant
await doc.sidecars('comments').list();  // un segment sidecar
```

`doc.delete()` applique une suppression douce au document ;
`doc.restore()` ramène une pierre tombale.

Les paramètres de `list` reflètent la grammaire de liste du backend :

| Paramètre | Rôle |
| --- | --- |
| `filters` | Clés bruts `field__op`, par exemple `status__eq`. Une clé nue telle que `search` passe sans changement. |
| `sort` | Noms de champs. Un préfixe `-` signifie décroissant. |
| `page`, `items` | Position et taille. `items` est borné à 1..1000. |
| `aggregate`, `field` | `count` n’a besoin d’aucun `field` ; `sum`, `avg`, `min` et `max` en prennent un. |
| `scope` | Le nom d’un périmètre nommé du doctype. |
| `select` | Projection de champs. Seuls ces champs sont renvoyés. |
| `includeDeleted` | Réglez-le pour lister les pierres tombales — la corbeille. |

Le SDK valide les paramètres avant tout envoi, si bien qu’une faute de
frappe n’atteint jamais le serveur :

```ts
import { createFacetClient, staticKey, UsageError } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});
const companies = facet.domain('clients').doctype('Company');

try {
	await companies.list({ aggregate: 'count', page: 2 });
} catch (e) {
	if (e instanceof UsageError) console.log('refused before any network call:', e.message);
}

try {
	await companies.list({ filters: { name__regex: 'x' } });
} catch (e) {
	if (e instanceof UsageError) console.log('unknown operator:', e.message);
}
```

Les messages nomment le correctif :

```text
refused before any network call: aggregate: 'count' ignores page and items. Drop them, so the call does not ask for a page the server will not serve.
unknown operator: Unknown filter operator 'regex' in 'name__regex'. Use one of: eq, ne, gt, gte, lt, lte, match, starts_with, between, in, currency, contains, overlaps, within.
```

Périmètres, projection et enfants voyagent dans le même appel :

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});
const bookings = facet.domain('rentals').doctype('Booking');

const count = await bookings.list({ aggregate: 'count' });
console.log(count.meta.count);

// Une réponse d’agrégation porte le sac dans `data.value`, pas le tableau de lignes.
const stock = facet.domain('equipment').doctype('Item');
const agg = await stock.list({ aggregate: 'sum', field: 'purchase_price' });
const bag = agg.data as unknown as { value: Record<string, string> };
console.log(bag.value); // { EUR: '72076.00' }

const mine = await facet
	.domain('clients')
	.doctype('Company')
	.list({ scope: 'my_clients', select: ['name'] });

const children = await facet
	.domain('clients')
	.doctype('Company')
	.doc('06H1FM1B3MXBPS0JYVM3BDD154')
	.children('contacts')
	.list({ items: 50 });
```

Le rôle de Tom porte le périmètre nommé `my_clients`, si bien que `mine`
renvoie ses cinq sociétés et rien d’autre.

Pour des lectures plus rapides, réglez `cache: true` sur le client. Chaque
`GET` stocke alors le validateur ETag fort, et la récupération suivante de
la même URL envoie `If-None-Match`. Une réponse `304` sert l’enveloppe en
cache ; une réponse `200` remplace l’entrée. Les verbes de mutation ne
touchent jamais le magasin. Le cache est désactivé par défaut ; un magasin
personnalisé implémente `get`, `set` et `delete` sur une clé de type chaîne.

## Ce que le token peut faire

`GET /Api/iam/me` répond pour chaque identifiant que le SDK détient. Le
manifeste suit l’identifiant : une session navigateur lit le manifeste du
rôle actif ; un token d’app ou une clé possédée par l’app lit l’attribution
et le rôle résolus. Un doctype que l’attribution ne nomme pas n’existe pas
dans ce manifeste — il n’y a pas de repli `*.*` pour les identifiants d’app.

```ts
await facet.whoami(); // en cache après le premier appel
await facet.can('update', 'clients.Company'); // 'all' | 'scoped' | 'denied'
await facet.scopes('create', 'clients.Company'); // [] = sans restriction
await facet.refreshRights(); // re-télécharge après un changement de rôle ou d’attribution
```

Les réponses sont indicatives. Le serveur recalcule attribution et rôle à
chaque requête et ne relit jamais le manifeste. Utilisez `can` pour décider
ce que l’UI affiche ; ne vous en servez jamais pour la sécurité. Considérez
le `404` ou le `403` d’un appel refusé comme la seule autorité. Voir
[Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/).

## Fichiers et artefacts

Deux voies existent pour ajouter un fichier. Joignez-le à une création ou à
une mise à jour, ou téléversez-le de façon autonome et liez l’id. Un
téléversement seul ne donne aucun accès en lecture aux autres. Un artefact
devient lisible quand son id est stocké dans un champ `file` ou lié sous la
forme `urn:facet:artifact:<id>` dans un longtext :

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});

const blob = new Blob(['Signed contract, season 2026'], { type: 'text/plain' });
const uploaded = await facet.artifacts.upload(blob, { filename: 'contract-2026.txt' });
console.log(uploaded.id);

const meta = await facet.artifacts.show(uploaded.id);
console.log(meta.mime_type, meta.size, meta.sha256);

// Une URL signée pour un lecteur hors Facet.
const grant = await facet.artifacts.grant(uploaded.id);
console.log(grant.url, grant.expires_at);

// Révoquez-la quand le lecteur a terminé.
await facet.artifacts.revoke(grant.grant_id);

// Une URL <a href> / <img src> qui repasse par la passerelle à chaque clic.
const href = facet.artifacts.downloadUrl(uploaded.id);

const bytes = await facet.artifacts.download(uploaded.id);
console.log(bytes.byteLength);
```

Une attribution signée est éphémère ; le serveur déduit sa durée de vie du
type de média — environ une heure pour les documents et les images, six
pour l’audio et la vidéo. `downloadUrl` construit l’URL sans appel réseau.
L’attachement à l’écriture prend un sac d’options sur `create` et
`update` :

```ts
await companies.create({ name: 'Café des Sports' }, { files: { logo: file } });
await doc.update({ name: 'Café des Sports' }, { files: { 'items[0].file': file } });
```

Voir [Téléverser et servir des fichiers](/fr/build/apps/data/files/) pour le
modèle.

## Temps réel

Un seul socket paresseux vers `/Ws` multiplexe tous les abonnements.
`facet.realtime()` l’ouvre au premier abonnement. Les frames sont des
indices, jamais l’état d’un document. Le serveur n’envoie aucune relecture :
re-téléchargez ce à quoi vous vous abonnez.

```ts
import { createFacetClient, staticKey, type WsFrame } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});

facet.realtime().onRefusal((error) => {
	console.error('realtime refused:', error.message);
});

const stop = await facet.realtime().subscribe('/clients/Company', (frame: WsFrame) => {
	console.log(frame.event, frame.payload.id);
});

facet.realtime().onReconnect(() => {
	console.log('socket re-opened — refetch your list');
});

setTimeout(() => stop(), 60_000);
facet.realtime().close();
```

La promesse de `subscribe` se résout au premier message du serveur que le
handle relie au chemin. Une frame d’erreur in-band — un refus de droits ou
un abonnement au-delà du plafond du serveur — la rejette. Une frame de
données correspondante la résout. Sur un canal silencieux, elle reste en
attente ; n’attendez pas son résultat quand cela compte ; le handler reçoit
les frames quoi qu’il arrive. Les codes de fermeture sont des signaux :

| Code de fermeture | Comportement |
| --- | --- |
| `4401` | Le handle rafraîchit l’identifiant une fois et se reconnecte. Un refresh en échec lève `AuthError`. |
| `4403` | L’origine n’est pas en liste blanche. Le handle lève `AuthError` sans nouvelle tentative. |

Les navigateurs proposent `["facet-ws-v1", accessToken]` dans la liste des
sous-protocoles. Node 20 n’a pas de WebSocket global ; là, passez un
constructeur capable de poser des en-têtes. L’identifiant part alors dans
l’en-tête `Authorization` de la requête d’upgrade :

```ts
import { WebSocket } from 'ws'; // npm i -D @types/ws
import type { RealtimeWebSocketConstructor } from '@facetapp/sdk';

const rt = facet.realtime({ WebSocket: WebSocket as unknown as RealtimeWebSocketConstructor });
```

Voir [Temps réel avec WebSockets](/fr/build/apps/data/realtime/) pour la
grammaire des frames et les chemins de canaux.

## Erreurs

Une seule classe de base existe, si bien que le code de l’app se branche
sur la classe ; `UsageError` n’est pas une `ApiError`.

| Classe | Levée sur | Données en plus |
| --- | --- | --- |
| `ApiError` | tout échange en échec | `status`, `message`, `details`, `meta` |
| `AuthError` | identifiant manquant, refresh en échec ou identifiant de socket refusé | message d’invitation à se reconnecter |
| `NotFoundError` | `404` — le backend refuse avec `404`, il ne divulgue donc jamais l’existence | — |
| `DeletedError` | pierre tombale `410` | `displayName`, `deletedAt` |
| `NetworkError` | `fetch` a levé ; la requête n’a jamais atteint le serveur | — |
| `UsageError` | le SDK a refusé l’appel localement — paramètres faux, handle fermé. Ce n’est pas une `ApiError` ; aucun échange n’a eu lieu | — |

`details` porte les éléments de validation structurés : `field`, `message`,
`code` et `params`.

```ts
try {
	await companies.doc(id).show();
} catch (error) {
	if (error instanceof NotFoundError) console.log('absent, or hidden from this credential');
	else if (error instanceof DeletedError) console.log(error.displayName, error.deletedAt);
	else throw error;
}
```

## Dépannage

**Chaque appel répond `401`.**

Facet revérifie la clé et le document d’app à chaque requête ; une clé
révoquée ou une app désactivée répond `401`. Émettez une nouvelle clé —
voir [Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/).

**Un appel de décompte lève `UsageError`.**

`aggregate: 'count'` avec `page` ou `items` est refusé avant tout appel
réseau. Retirez les paramètres de pagination.

**Le socket se ferme avec `4403`.**

L’origine n’est pas dans la liste blanche. Enregistrez-la — voir
[CORS et origines autorisées](/fr/build/apps/connect/cors/).

**Un appel répond `NotFoundError` pour un document qui existe.**

Des périmètres de lignes sur le rôle, ou une attribution manquante, cachent
la ligne ; un `404` ne divulgue jamais l’existence. Vérifiez
`facet.can('read', 'clients.Company')` — voir
[Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/).

## Voir aussi

- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — la surface HTTP que le SDK enveloppe.
- [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/) — le flux de connexion navigateur en détail.
- [Temps réel avec WebSockets](/fr/build/apps/data/realtime/) — la grammaire des frames derrière `realtime()`.
- [Téléverser et servir des fichiers](/fr/build/apps/data/files/) — le modèle d’artefact, les attributions signées et la publication.
- [Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/) — le manifeste derrière `whoami`.
- Internes sur GitHub : [packages/sdk/README.md](https://github.com/wearefacet/facet/blob/main/packages/sdk/README.md).
