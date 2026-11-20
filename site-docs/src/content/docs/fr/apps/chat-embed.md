---
title: Intégrer l’assistant
description: Montez le chat de l’assistant Facet dans votre app avec le package @facetapp/chat.
audience: [developer]
features: [APP-11, AI-03]
sidebar:
  order: 16
verified_at: a77c6171
---

`@facetapp/chat` monte l’assistant Facet dans votre app, attaché à

l’assistant propre à votre app. Le backend possède le modèle, le prompt et
les outils. Le package possède l’interfaceà : deux custom elements, une façade
à un appel, et un driver HTTP. Votre app fournit ses identifiants au travers
d’une seule fonction, et le package ne les voit jamais.

> **Pour les agentsà :** Contrôle d’accèsà : `const gate = await facet.assistant()`
> — `{access, token_budget, name}` ; masquez le lanceur quand `gate.access`
> est faux. Installation : `pnpm add @facetapp/chat`. Authà : passez un `fetch`
> qui ajoute `Authorization: DPoP <token>` (une preuve `DPoP` fraîche par
> requête quand le token est lié) et `X-Requested-With: XMLHttpRequest` —
> POST/PATCH sans lui répond `403`. Montageà : `FacetAssistant.open({ baseUrl,
> fetch: hostFetch, appId })` ou `FacetAssistant.mount('#chat-root', config)` ;
> `close()` masque, `destroy()` retire. Routeà :
> `POST /Api/assistant/app/conversations`, puis flux (SSE).

## Quand l’utiliser

Intégrez l’assistant quandà :

- Vous donnez un assistant aux comptes de votre app sans construire
  d’interface de chat.
- Vous voulez que le rail des conversations, le streaming et le rendu des
  outils soient gérés pour vous.
- Vous avez besoin d’un mock scripté pour les tests et le travail hors ligne.

## Avant de commencer

Trois contrôles doivent passer avant qu’une conversation s’ouvreà :

- L’appelant est attaché à une appà : un token d’app OAuth. Voir
  [Connexion utilisateurà : OAuth 2.1 + PKCE](/fr/apps/oauth-login/) et
  [Liaison des tokens par DPoP](/fr/apps/dpop/).
- Le drapeau `assistant_enabled` de l’app est actif. L’admin de l’app le règle
  sur l’onglet Paramètresà ; l’enregistrement exige `update` sur `app.App`. Le
  champ facultatif `assistant_prompt` sur le même onglet ajoute au prompt des
  instructions propres à l’app.
- La connectivité du rôle de l’appelant liste le canal `assistant`.

Vérifiez ce contrôle depuis votre app avec le SDKà:

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'crm-console', redirectUri: `${location.origin}/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.example.com', auth });

const gate = await facet.assistant(); // { access, token_budget, name }
if (!gate.access) {
	// Le chat afficherait son panneau de refus. Masquez plutôt le lanceur.
}
```

`token_budget` vaut `null` quand le budget est illimité.

## Étapes

### 1. Installer le package

```sh
pnpm add @facetapp/chat
```

L’import enregistre deux custom elements et exporte la façade
`FacetAssistant`.

### 2. Passer un fetch authentifié

Le package ne touche jamais aux tokens. Vous passez un `fetch` qui ajoute vos
en-têtes d’authentification, et chaque appel du driver passe par luià :

```js
async function hostFetch(input, init = {}) {
	const token = await getAppToken(); // votre token d’app OAuth (lié par DPoP)
	return fetch(input, {
		...init,
		headers: {
			...init.headers,
			Authorization: `DPoP ${token}`,
			DPoP: await makeDpopProof(input, init), // une preuve par requête
			'X-Requested-With': 'XMLHttpRequest' // l’en-tête CSRF de Facet
		}
	});
}
```

`getAppToken` et `makeDpopProof` restent à votre charge — voir
[Liaison des tokens par DPoP](/fr/apps/dpop/) pour le contrat de preuve. La
preuve doit couvrir la méthode et l’URL de la requête. Un token émis sans
preuve DPoP est un token bearerà ; envoyez-le sous
`Authorization: Bearer <token>` sans en-tête `DPoP`.

`X-Requested-With` doit accompagner chaque appel qui change l’état. Facet
refuse POST/PATCH sans lui avec `403`. Le driver envoie POST pour create,
stream, cancel et record, et PATCH pour archive.

### 3. Ouvrir la fenêtre flottante

```js
import { FacetAssistant } from '@facetapp/chat';

FacetAssistant.open({
	baseUrl: 'https://facet.company.tld',
	fetch: hostFetch,
	appId: 'core.app_123', // l’app à laquelle cet assistant est attaché
	bubble: true
});
```

Le premier appel enregistre la configuration et affiche la fenêtre, ancrée en
bas à droite. `bubble: true` affiche un bouton lanceur rond tant que la
fenêtre est fermée. `FacetAssistant.close()` la masqueà ;
`FacetAssistant.destroy()` retire chaque montage et efface l’état enregistré.

### 4. Ou monter dans la page

```js
FacetAssistant.mount('#chat-root', {
	baseUrl: 'https://facet.company.tld',
	fetch: hostFetch,
	appId: 'core.app_123'
});
```

Le panneau remplit `#chat-root` ; votre CSS possède la mise en page. Rien ne
persisteà : `close()` masque le panneau pour la session seulement.

Un seul chat tourne à la fois. `open()` active la fenêtreà ; `mount()` active
le panneau dans la page. Activer l’un retire l’autre, si bien qu’il n’y a
jamais un second flux d’événements.

### 5. Configurer le montage

La configuration de la façade, l’argument de `open()` / `mount()`, et les
propriétés des éléments portent les mêmes champsà :

| Option | Type | Défaut | Objectif |
| --- | --- | --- | --- |
| `baseUrl` | `string` | — | Origine Facet, avec un préfixe de chemin facultatif, pour le driver HTTP. Requis. |
| `fetch` | `typeof fetch` | global `fetch` | Votre fetch authentifié — étape 2. |
| `appId` | `string` | — | L’id `app.App` auquel cet assistant est attaché. Pilote le filtre du rail. |
| `language` | `string` | — | Étiquette BCP-47. Incorporée au prompt du backend. |
| `name` | `string` | `'Assistant'` | Nom affiché dans l’en-tête de la fenêtre et les en-têtes des tours. |
| `driver` | `AssistantDriver` | `HttpAssistantDriver` | Remplacement du transport — voir l’exemple ci-dessous. |
| `tokens` | `Record<string, string>` | — | Remplacements des tokens `--facet-*`, posés sur les éléments montés. |
| `bubble` | `boolean` | `false` | Montage flottant seulementà : le lanceur tant que la fenêtre est fermée. |

## Explication

### Ce que le package gère

Le chat se limite à une app. Le rail des conversations liste avec les filtres
`context.kind__eq=app` et `context.app_id__eq`. Les nouvelles conversations
passent par `POST /Api/assistant/app/conversations`. Le backend construit le
contexte de la conversation à partir de l’appelant authentifiéà ; le corps ne
porte que la langue.

Le streaming passe par des server-sent events (SSE) : une trame `meta`, puis
des trames `chunk`, puis `done`, `error` ou `cancelled`. Chaque appel d’outil
se rend, y compris les appels que le backend a refusés avant exécution. Un
appel refusé se résout en barre d’erreur, si bien qu’aucun appel n’est
invisible.

Les états de refus et de budget sont intégrés. Un `403` à la création de
conversation affiche le panneau "Assistant unavailable" et masque la zone de
saisie. Un `429` sur le flux affiche l’avis de budget sur le tour.

### Éléments et thème

L’import du package enregistre `<facet-assistant>` (panneau dans la page) et
`<facet-assistant-window>` (fenêtre flottante). Utilisez les éléments
directement quand vous voulez un contrôle total. Le thème traverse la
frontière du shadow DOM sous forme de propriétés personnalisées CSSà; chaque
token porte le préfixe `--facet-*` :

```css
facet-assistant {
	--facet-accent: #008f79;
}
```

Les diagrammes Mermaid sont une peer dependency facultative. Installez
`mermaid` dans le projet hôte, et les blocs `mermaid` délimités se rendent en
diagrammesà ; sans lui, ils se rendent en blocs de code.

## Exemple

Le package livre un driver réel et un mock scripté. Cet exemple diffuse un
tour contre le mock, sans backendà :

```ts
import { createMockAssistant, FacetAssistant } from '@facetapp/chat';

const driver = createMockAssistant(); // en mémoire, réponses scriptées

const conversation = await driver.createAppConversation({ language: 'en-GB' });
for await (const event of driver.streamAsk(conversation.id, { content: 'Liste les expéditions actives' })) {
	console.log(event); // meta → chunk* → done | error | cancelled
}

// Remettez le mock à la façade pour styliser et tester l’interface sans backend.
FacetAssistant.open({ baseUrl: 'https://facet.example.com', driver, appId: 'core.app_123' });
```

Contre un vrai backend, construisez le driver HTTP avec votre fetch
authentifié et passez-le de la même façon :

```ts
import { HttpAssistantDriver } from '@facetapp/chat';

const driver = new HttpAssistantDriver('https://facet.company.tld', hostFetch);
```

## Dépannage

**Le chat affiche le panneau "Assistant unavailable".**

Le drapeau de l’app est éteint, le rôle manque du canal `assistant`, ou
l’appelant n’est pas attaché à une app. Vérifiez `await facet.assistant()` —
le champ `access` reflète le même contrôle.

**Chaque POST répond `403`.**

Votre fetch omet `X-Requested-With`. Facet refuse POST/PATCH sans lui.

**Les tours échouent aussitôt.**

Votre fetch omet l’en-tête `Authorization` ou la preuve `DPoP`. Un échec DPoP
répond `401` sans détail sur le contrôle qui a échoué.

**Le compteur d’usage n’apparaît jamais.**

L’appelant a un budget illimité. Le compteur n’apparaît que pour un budget
fini.

## Voir aussi

- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/apps/typescript-sdk/) — le
  contrôle `facet.assistant()`.
- [Liaison des tokens par DPoP](/fr/apps/dpop/) — le schéma de tokens et le
  contrat de preuve.
- [Le fonctionnement des apps sur Facet](/fr/apps/how-apps-work/) —
  l’attachement aux apps et le plafond d’attribution sur les appels d’outils.
- [Gouverner l’assistant](/fr/govern/governing-assistant/) — budgets, noms et
  instructions dans l’app principale.
- Internes sur GitHubà :
  [packages/chat/README.md](https://github.com/wearefacet/facet/blob/main/packages/chat/README.md).
