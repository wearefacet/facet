---
title: CORS et origines autorisées
description: Enregistrez les origines depuis lesquelles une app navigateur peut appeler Facet, et voyez comment la plateforme les reflète.
audience: [developer]
features: [APP-08]
sidebar:
  order: 6
verified_at: a77c6171
---

Une app navigateur appelle Facet depuis sa propre origine. Le navigateur
bloque l’appel tant que Facet ne nomme pas cette origine dans ses en-têtes
Cross-Origin Resource Sharing (CORS). Vous enregistrez les origines sur le
document de l’app, et Facet les reflète sur l’endpoint de token et sur toute
la surface `/Api/*`. La liste d’origines est active immédiatement : une
modification prend effet à la requête suivante.

> **Pour les agents :** Placez des origines nues dans `allowed_origins`
> sur `app.App` — par exemple `https://app.company.tld` et des origines de
> dev comme `http://localhost:5173`. Modifiez avec `PATCH /Api/app/App/{id}`
> (cookie de session plus `X-Requested-With: XMLHttpRequest`). Vérifiez avec
> `curl -X OPTIONS` en envoyant `Origin`, `Access-Control-Request-Method` et
> `Access-Control-Request-Headers: Authorization, DPoP` ; une origine
> enregistrée reçoit `Access-Control-Allow-Origin` en écho. Le changement est
> actif à la requête suivante — sans redémarrage.

## Quand l’utiliser

Consultez cette page quand :

- Un `fetch` navigateur échoue parce que la réponse ne porte aucun en-tête
  CORS.
- Vous déployez l’app sur un nouvel hôte et devez ajouter son origine.
- Vous ajoutez une origine de dev, ou une WebSocket refuse de s’ouvrir.

## Avant de commencer

- Une app est enregistrée — voir [Enregistrer une
  app](/fr/apps/registering-app/).
- Il vous faut le droit `update` sur `app.App` pour modifier les origines.
- Listez chaque origine depuis laquelle l’app navigateur est servie, origines
  de dev comprises.

## Étapes

### 1. Listez les origines

Chaque entrée est une origine nue : schéma, hôte et port facultatif.
Enregistrez chaque origine depuis laquelle l’app navigateur est servie.
Incluez les hôtes de production et les hôtes de dev, par exemple
`http://localhost:5173`.

### 2. Définissez-les sur l’app

L’étape de configuration de l’assistant recueille les origines à

l’enregistrement. Pour les changer plus tard, faites un PATCH sur le document
de l’app. Connectez-vous comme opérateur et conservez les cookies de
session :

```sh
curl -s -c cookies.txt -X POST https://facet.company.tld/Api/iam/login \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"email": "admin@company.tld", "password": "op-secret"}'
```

Puis définissez la liste d’origines :

```sh
curl -s -b cookies.txt -X PATCH \
  https://facet.company.tld/Api/app/App/01JHQ9M4T8C3XK2PB5WY6RD7QF \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"allowed_origins": ["https://deal-board.company.tld", "http://localhost:5173"]}'
```

### 3. Vérifiez avec une requête preflight

Envoyez une requête preflight et vérifiez l’en-tête renvoyé en écho :

```sh
curl -s -i -X OPTIONS https://facet.company.tld/Api/crm/Company \
  -H "Origin: https://deal-board.company.tld" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: Authorization, DPoP" \
  | grep -i access-control-allow-origin
```

Une origine enregistrée répond avec sa propre adresse :

```sh
Access-Control-Allow-Origin: https://deal-board.company.tld
```

Une origine non enregistrée répond sans cet en-tête. La même vérification
fonctionne sur l’endpoint de token, `/OAuth/token`.

## Explication

### Où Facet reflète les origines

Le gestionnaire CORS reflète les origines enregistrées sur `/OAuth/*` et
`/Api/*`, pour les réponses preflight comme pour les réponses réelles. Il
s’exécute avant la vérification d’authentification dans la chaîne de
gestionnaires ; une requête preflight n’a donc pas besoin
d’authentification. Facet renvoie en écho l’en-tête `Origin` de la requête
seulement s’il figure dans `allowed_origins` d’au moins une app `active`.

### Correspondance exacte, jamais de joker

Facet n’envoie jamais `Access-Control-Allow-Origin: *`. Les navigateurs
ignorent la forme `*` quand `Authorization` figure dans
`Access-Control-Allow-Headers`, donc un joker ne protégerait de rien.
Enregistrez plutôt chaque origine exacte.

### La liste d’origines est active immédiatement

Le cache d’origines se déclare périmé à chaque mutation de `app.App` et se
reconstruit à la lecture suivante. Une modification d’origine s’applique à la
requête suivante. Ni redémarrage, ni changement de configuration du backend.

### Les WebSockets utilisent la même liste

L’upgrade `/Ws` vérifie les mêmes origines enregistrées, plus l’hôte propre
de Facet. L’origine d’une app déployée peut ouvrir un socket sans
configuration du backend. Une origine enregistrée nulle part se ferme avec
`4403` — voir [Temps réel avec WebSockets](/fr/apps/websockets/).

### Ce que CORS ne couvre pas

Facet sert le build d’une app sur l’hôte propre de l’app. C’est une
distribution par hôte, pas du CORS — voir [Déployer votre
frontend](/fr/apps/hosting-deploy/). Les clients hors navigateur n’envoient
aucun en-tête `Origin` ; le CORS ne les concerne donc jamais.

## Exemple

Avec l’origine enregistrée, une app navigateur sur
`https://deal-board.company.tld` lit la liste des sociétés après la
connexion :

```ts
// L’app détient un access token venu de la connexion OAuth (voir /apps/oauth-login/).
const res = await fetch("https://facet.company.tld/Api/crm/Company?per_page=5", {
  headers: { Authorization: `Bearer ${accessToken}` },
});
if (!res.ok) throw new Error(`List failed: ${res.status}`);
const page = await res.json();
```

Un token lié par DPoP (Demonstrating Proof of Possession) ajoute le schéma
`DPoP` et un en-tête de preuve — voir [Liaison DPoP des
tokens](/fr/apps/dpop/). Le navigateur n’exécute l’appel que parce que
l’origine est enregistrée.

## Dépannage

**Le `fetch` répond sans `Access-Control-Allow-Origin`.**

L’origine n’est pas enregistrée, ou la seule app qui la porte n’est pas
`active`. Enregistrez l’origine sur une app active et renvoyez la requête.

**Le client réclame à Facet l’en-tête `*`.**

Facet n’envoie jamais `*`. Enregistrez l’origine exacte sur laquelle l’app
tourne.

**La WebSocket se ferme avec `4403`.**

L’origine n’est pas dans la liste autorisée. Enregistrez-la sur une app
active — voir [Temps réel avec WebSockets](/fr/apps/websockets/).

## Voir aussi

- [Enregistrer une app](/fr/apps/registering-app/) — où se définissent les
  origines.
- [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/apps/oauth-login/) —
  le flux que les origines déverrouillent.
- [Temps réel avec WebSockets](/fr/apps/websockets/) — la vérification
  d’origine de `/Ws`.
- Internes sur GitHub :
  [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
