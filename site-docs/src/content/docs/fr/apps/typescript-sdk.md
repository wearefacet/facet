---
title: Le SDK TypeScript (`@facetapp/sdk`)
description: Interroger, écrire et s’abonner depuis TypeScript avec le SDK @facetapp/sdk.
audience: [developer]
features: [APP-10]
sidebar:
  order: 9
verified_at: a77c6171
---

`@facetapp/sdk` est le SDK TypeScript des apps Facet. Il enveloppe l’API HTTP
et le socket realtime derrière un client typé unique. Il n’a aucune dépendance
à l’exécution et tourne dans les navigateurs comme sur Node 20 ou plus, avec le
`fetch` global. Il couvre les documents, les requêtes, les actions, les
enfants, les sidecars, les agrégats, l’historique, le retour arrière, la
restauration, les liens entrants, le realtime, les artifacts et le manifeste de
permissions de l’appelant.

> **Pour les agentsà :** installez avec `pnpm add @facetapp/sdk`. Clientà :
> `createFacetClient({ baseUrl, auth })` avec `staticKey(process.env.FACET_API_KEY!)`
> (app backend) ou `oauthBrowser({ slug, redirectUri })` (app navigateurà ; puis
> `await auth.signIn()` et `await auth.handleCallback(location.href)` sur la
> route de callback). Séquenceà : `facet.domain('crm').doctype('Company').list({ items: 50 })` →
> `page.next()` (null à la fin) → `.doc(id).show()` →
> `.doc(id).update({ status: 'archived' })` ; portée via `await facet.whoami()`
> et `await facet.can('read', 'crm.Company')` ; les erreurs sont des
> sous-classes d’`ApiError`, un refus local lève `UsageError`.

## Quand l’utiliser

Choisissez le SDK quandà :

- vous construisez un frontend TypeScript ou un service Node qui communique
  avec Facetà ;
- vous voulez des handles typés, la pagination et des erreurs typées plutôt que
  du HTTP brutà ;
- vous avez besoin des frames realtime, de l’envoi de fichiers ou du manifeste
  de permissions dans le code de l’app.

Pour un contrôle HTTP brut, ou pour un autre langage, utilisez
[Utiliser l’API REST](/fr/apps/rest-api/).

## Avant de commencer

- Une instance Facet qui tourne et une app enregistrée — voir
  [Enregistrer une app](/fr/apps/registering-app/).
- Une app backend a besoin d’une clé API propre à l’app — voir
  [comptes de service et clés API](/fr/apps/service-accounts/).
- Une app navigateur a besoin d’une connexion OAuth et d’une origine dans la
  liste d’autorisation — voir
  [Connexion utilisateurà : OAuth 2.1 + PKCE](/fr/apps/oauth-login/) et
  [CORS et origines autorisées](/fr/apps/cors-origins/).
- Le modèle de portéeà : [Apps, attributions et rôles](/fr/concepts/apps-grants-roles/).

## Installation et connexion

Installez avec `pnpm add @facetapp/sdk`. Deux canaux d’appel existent, et le
SDK sert les deux. La portée effective reste l’intersection de l’attribution de
l’app et du rôle. Le backend la recalcule à chaque requête.

### App backendà : une clé statique

Une app backend s’authentifie avec une clé API propre à l’app, lue depuis une
variable d’environnementà :

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.example.com',
	auth: staticKey(process.env.FACET_API_KEY!)
});
```

La clé appartient au compte de service de l’app — voir
[Comptes de service pour les apps backend](/fr/apps/service-accounts/).

### App navigateurà : OAuth avec PKCE

Le compte se connecte par l’écran de consentement. Cet écran élit un rôle pour
l’app.

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'my-app', redirectUri: `${location.origin}/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.example.com', auth });

await auth.signIn(); // une fois, sur la route de connexionà ; navigue vers l’écran de consentement
await auth.handleCallback(location.href); // sur la route de redirection
```

Le refresh token est stocké dans `localStorage` ; le token d’accès reste en
mémoire. Des réponses `401` concurrentes partagent un seul appel de refresh.
Une réponse `429 slow_down` attend la durée imposée par le serveur puis
réessaie une fois. Un refresh en échec lève `AuthError` ; le compte se
reconnecte. Les blocs de code qui suivent réutilisent ce client `facet`.

## Documents et requêtes

Chaque appel part d’un arbre de handlesà : `facet.domain('crm')` renvoie un
handle de domaine, `.doctype('Company')` un handle de collection, `.doc(id)`
une référence de document. Aucun appel réseau ne part tant que vous n’appelez
pas une méthode sur un handle.

```ts
const companies = facet.domain('crm').doctype('Company');

const page = await companies.list({
	filters: { status__eq: 'active', created_at__gte: '2026-01-01' },
	sort: ['-updated_at'],
	items: 50
});
await page.next(); // null quand meta.more vaut false
await companies.list({ aggregate: 'count', filters: { status__eq: 'active' } });

await companies.create({ name: 'Acme' });
await companies.create({
	$content: { name: 'Acme' },
	$children: { career_events: [{ event_type: 'hired' }] }
});

const doc = companies.doc(id);
await doc.show();
await doc.update({ status: 'archived' });
await doc.action('archive', { reason: 'done' });
await doc.history();
await doc.rollback(mutationId); // l’état à cette mutation
await doc.restore(); // annule la suppression d’un tombstone
await doc.backrefs(); // les documents vivants qui référencent celui-ci
await doc.children('contacts').list();
await doc.sidecars('comments').list();
```

`doc.delete()` supprime le document logiquementà ; `doc.restore()` ramène un
tombstone (document supprimé).

Les paramètres de `list` reflètent la grammaire `ListRequest` du backendà :

| Paramètre | Usage |
| --- | --- |
| `filters` | Clés `field__op` brutes, par exemple `status__eq`. Une clé nue comme `search` passe telle quelle. |
| `sort` | Noms de champs. Un préfixe `-` signifie un tri descendant. |
| `page`, `items` | Position et taille. `items` est borné à 1..1000. |
| `aggregate`, `field` | `count` n’a pas besoin de `field` ; `sum`, `avg`, `min` et `max` en prennent un. |
| `scope` | Le nom d’un périmètre nommé sur le doctype. |
| `select` | Projection de champs. Seuls ces champs sont renvoyés. |
| `includeDeleted` | Activez-le pour lister les tombstones — la corbeille. |

Le SDK valide les paramètres avant d’envoyer quoi que ce soit. Un suffixe
`__op` inconnu lève `UsageError` ; un mélange de `aggregate: 'count'` avec
`page` ou `items` aussi. Aucun appel réseau ne part. Les valeurs de pagination
hors bornes sont ramenées dans les bornesà : `items` à 1..1000, `page` à 1 ou
plus.

Pour des lectures plus rapides, mettez `cache: true` sur le clientà :
`createFacetClient({ baseUrl, auth, cache: true })`. Chaque `GET` stocke alors
le validateur ETag fort, et le prochain fetch de la même URL envoie
`If-None-Match`. Une réponse `304` sert l’enveloppe en cacheà ; une réponse
`200` remplace l’entrée. Les verbes de mutation ne touchent jamais le magasin.
Le cache est désactivé par défautà ; un magasin personnalisé implémente `get`,
`set` et `delete` sur une clé de type chaîne.

## Ce que le token peut faire

`GET /Api/iam/me` répond pour chaque credential que le SDK détient. Le
manifeste suit le credentialà : une session navigateur lit le manifeste du rôle
actifà ; un token d’app ou une clé propre à l’app lit l’attribution et le rôle
résolus. Un doctype que l’attribution ne nomme pas n’existe pas dans ce
manifeste — il n’y a pas de repli `*.*` pour les credentials d’app.

```ts
await facet.whoami(); // en cache après le premier appel
await facet.can('read', 'crm.Company'); // 'all' | 'scoped' | 'denied'
await facet.scopes('create', 'crm.Company'); // [] = sans restriction
await facet.refreshRights(); // à recharger après un changement de rôle ou d’attribution
```

Les réponses sont indicatives. Le serveur recalcule attribution et rôle à

chaque requête et ne relit jamais le manifeste. Utilisez `can` pour décider ce
que l’UI afficheà ; ne l’employez jamais comme garde-fou de sécurité. Le `404`
ou le `403` d’un appel refusé fait foi. Voir
[Piloter votre UI avec le manifeste](/fr/apps/permission-manifest/).

## Fichiers et artifacts

Il y a deux façons d’ajouter un fichier. Joignez-le à une création ou à une
mise à jour, ou envoyez-le seul puis reliez son id. Un upload seul ne donne
aucun droit de lecture aux autres. Un artifact devient lisible quand son id est
stocké dans un champ `file` ou lié comme `urn:facet:artifact:<id>` dans un
longtext.

```ts
// Joindreà : un seul appel multipartà ; l’upload et la mutation partagent une transaction.
await companies.create({ name: 'Acme' }, { files: { logo: file } });
await doc.update({ name: 'Acme' }, { files: { 'items[0].file': file } });

const { id } = await facet.artifacts.upload(file);
await facet.artifacts.uploadAsUrn(file); // urn:facet:artifact:<id> pour les longtexts

const grant = await facet.artifacts.grant(id); // éphémèreà ; le serveur déduit le TTL
await facet.artifacts.show(id);
await facet.artifacts.revoke(grant.grant_id);

await facet.artifacts.publish(id, { ownerId }); // permanentà ; demande l’action publish_artifact
facet.artifacts.downloadUrl(id); // pour <a href> et <img src> ; attribution fraîche par requête
facet.artifacts.downloadUrl(id, { appId }); // lectures depuis l’origine de l’app
await facet.artifacts.download(id); // suit le 302 et renvoie les octets
```

Une attribution est éphémèreà ; le serveur déduit sa durée de vie du type de
média. `downloadUrl` construit l’URL sans appel réseau. Voir
[Téléverser et servir des fichiers](/fr/apps/files/) pour le modèle.

## Realtime

Un socket unique vers `/Ws`, ouvert à la demande, multiplexe tous les
abonnements. `facet.realtime()` l’ouvre au premier subscribe. Les frames sont
des indices, jamais l’état d’un document. Le serveur n’envoie aucun replayà :
relisez ce à quoi vous vous abonnez.

```ts
const rt = facet.realtime();
rt.onReconnect(() => companies.list({ items: 50 })); // pas de replayà : relecture à la reconnexion

rt.subscribe('/crm/Company', (frame) => console.log(frame.event, frame.payload.id));
const off = await rt.subscribe(`/crm/Company/${id}`, (frame) => console.log(frame.event));

await rt.ensureConnected(); // facultatifà : ouvre le socket maintenant
rt.close(); // arrête le handle et abandonne tous les abonnements
```

La promesse de `subscribe` se résout au premier message du serveur que le
handle rattache à ce chemin. Une frame d’erreur in-band — un refus de droits
ou un abonnement au-del à du plafond du serveur — la rejette. Une frame de
données correspondante la résout. Sur un canal silencieux, elle reste en
attenteà ; ne l’attendez pas quand cela compteà ; le handler reçoit les frames
dans tous les cas. Les codes de fermeture sont des signauxà :

| Code de fermeture | Comportement |
| --- | --- |
| `4401` | Le handle rafraîchit le credential une fois puis se reconnecte. Un refresh en échec lève `AuthError`. |
| `4403` | L’origine n’est pas dans la liste d’autorisation. Le handle lève `AuthError` sans réessai. |

Les navigateurs proposent `["facet-ws-v1", accessToken]` dans la liste de
sous-protocoles. Node 20 n’a pas de `WebSocket` globalà ; làà, passez un
constructeur qui accepte des en-têtes. Le credential part alors dans l’en-tête
`Authorization` de la requête d’upgrade. Les clés statiques `fct_` sont
acceptées sur cette voieà ; le transport par sous-protocole les refuse.

```ts
import { WebSocket } from 'ws'; // npm i -D @types/ws
import type { RealtimeWebSocketConstructor } from '@facetapp/sdk';

// Node 20 : injectez un constructeur qui accepte des en-têtes.
const rt = facet.realtime({ WebSocket: WebSocket as unknown as RealtimeWebSocketConstructor });
```

Voir [Realtime avec WebSockets](/fr/apps/websockets/) pour la grammaire des
frames et les chemins de canaux.

## Erreurs

Une seule classe de base existeà ; le code de l’app se branche donc sur la
classe. `UsageError` n’est pas une `ApiError`.

| Classe | Levée quand | Données en plus |
| --- | --- | --- |
| `ApiError` | tout échange en échec | `status`, `message`, `details`, `meta` |
| `AuthError` | credential absent, refresh en échec ou credential de socket refusé | message d’aide pour se reconnecter |
| `NotFoundError` | `404` — le backend refuse avec `404`, il ne divulgue jamais l’existence | — |
| `DeletedError` | `410` tombstone | `displayName`, `deletedAt` |
| `NetworkError` | `fetch` a levéà ; la requête n’a jamais atteint le serveur | — |
| `UsageError` | le SDK a refusé l’appel localement — paramètres mauvais, handle fermé. Pas une `ApiError` ; aucun échange n’a eu lieu | — |

`details` porte les éléments de validation structurésà : `field`, `message`,
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

Facet revérifie la clé et le document de l’app à chaque requêteà ; une clé
révoquée ou une app désactivée répond `401`. Émettez une nouvelle clé — voir
[comptes de service et clés API](/fr/apps/service-accounts/).

**Un appel de comptage lève `UsageError`.**

`aggregate: 'count'` avec `page` ou `items` est refusé avant tout appel
réseau. Retirez les paramètres de pagination.

**Le socket se ferme avec `4403`.**

L’origine n’est pas dans la liste d’autorisation. Enregistrez-la — voir
[CORS et origines autorisées](/fr/apps/cors-origins/).

**Un appel répond `NotFoundError` pour un document qui existe.**

Les périmètres de lignes du rôle ou une attribution manquante cachent la
ligneà ; un `404` ne divulgue jamais l’existence. Vérifiez
`facet.can('read', 'crm.Company')` — voir
[Piloter votre UI avec le manifeste](/fr/apps/permission-manifest/).

## Voir aussi

- [Utiliser l’API REST](/fr/apps/rest-api/) — la surface HTTP que le SDK enveloppe.
- [Connexion utilisateurà : OAuth 2.1 + PKCE](/fr/apps/oauth-login/) — le parcours de connexion navigateur en détail.
- [Liaison DPoP des tokens](/fr/apps/dpop/) — comment un token d’app se lie à une clé.
- [Realtime avec WebSockets](/fr/apps/websockets/) — la grammaire des frames derrière `realtime()`.
- [Téléverser et servir des fichiers](/fr/apps/files/) — le modèle d’artifacts, les attributions et la publication.
- [Piloter votre UI avec le manifeste](/fr/apps/permission-manifest/) — le manifeste derrière `whoami`.
- Internes sur GitHubà : [packages/sdk/README.md](https://github.com/wearefacet/facet/blob/main/packages/sdk/README.md).
