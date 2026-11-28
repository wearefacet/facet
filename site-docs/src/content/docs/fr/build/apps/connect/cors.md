---
type: how-to
title: Origines autorisées et CORS
description: Enregistrez les origines depuis lesquelles une app navigateur peut appeler Facet, et voyez comment Facet les reflète.
audience: [developer]
features: [APP-08]
sidebar:
  order: 3
verified_at: eee55a2
---

Une app navigateur appelle Facet depuis sa propre origine. Le navigateur
bloque l’appel tant que Facet ne nomme pas cette origine dans ses en-têtes
Cross-Origin Resource Sharing (CORS). Vous enregistrez les origines sur le
document de l’app, et Facet les reflète sur l’endpoint de token et sur
toute la surface `/Api/*`. La liste autorisée est active immédiatement :
une modification d’origine s’applique à la requête suivante.

> **Pour les agents :** placez des origines nues dans `allowed_origins`
> sur `app.App` — par exemple `https://app.company.tld` et des origines de
> dev comme `http://localhost:5173`. Modifiez avec
> `PATCH /Api/app/App/{id}` (une clé d’API dans `Authorization: Bearer`,
> ou un cookie de session plus `X-Requested-With: XMLHttpRequest`).
> Vérifiez avec `curl -X OPTIONS` en envoyant `Origin`,
> `Access-Control-Request-Method` et
> `Access-Control-Request-Headers: Authorization, DPoP` ; une origine
> enregistrée reçoit `Access-Control-Allow-Origin` en écho. Le changement
> est actif à la requête suivante — sans redémarrage.

## Quand l’utiliser

Consultez cette page quand :

- un `fetch` navigateur échoue parce que la réponse ne porte aucun en-tête
  CORS,
- vous déployez l’app sur un nouvel hôte et devez ajouter son origine,
- vous ajoutez une origine de dev, ou une WebSocket refuse de s’ouvrir.

## Avant de commencer

- Un enregistrement d’app existe — voir
  [Enregistrer une app](/fr/build/apps/connect/register/).
- Vous avez besoin du droit `update` sur `app.App` pour modifier les
  origines.
- Listez chaque origine depuis laquelle l’app navigateur est servie,
  origines de dev comprises.

## Étapes

### 1. Listez les origines

Chaque entrée est une origine nue : schéma, hôte et port facultatif.
Enregistrez chaque origine depuis laquelle l’app navigateur est servie.
Incluez les hôtes de production et les hôtes de dev, par exemple
`http://localhost:5173`.

### 2. Définissez-les sur l’app

L’étape Création de l’assistant recueille les origines à l’enregistrement.
Pour les changer plus tard, faites un PATCH sur le document de l’app.
Chaque appel d’API porte son propre identifiant — connectez-vous une fois
et stockez une clé depuis la CLI :

```sh
pnpx @facetapp/cli connect   # connexion, élection du rôle admin, stockage de la clé
RAVI_KEY=$(pnpx @facetapp/cli apikey)
```

Puis définissez la liste d’origines :

```sh
curl -sk -X PATCH \
  https://facet.localhost:3443/Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"allowed_origins": ["https://checkout.brightwater.example", "http://localhost:5173"]}'
```

Le PATCH répond `200` avec le document enregistré ; `allowed_origins`
relit la nouvelle liste, active à la requête suivante.

### 3. Vérifiez avec une requête preflight

Envoyez une requête preflight et vérifiez l’en-tête renvoyé en écho.
L’app de check-out est enregistrée avec l’origine de dev
`http://localhost:5173` :

```sh
curl -sk -i -X OPTIONS https://facet.localhost:3443/Api/rentals/Booking \
  -H "Origin: http://localhost:5173" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: Authorization, DPoP"
```

Une origine enregistrée répond `204` avec sa propre adresse en écho :

```text
HTTP/2 204
access-control-allow-credentials: true
access-control-allow-headers: Authorization, Content-Type, X-Requested-With, DPoP
access-control-allow-methods: GET, POST, PATCH, PUT, DELETE, QUERY, OPTIONS
access-control-allow-origin: http://localhost:5173
access-control-max-age: 600
vary: Origin
```

Une origine non enregistrée répond le même `204` — mais sans ligne
`access-control-allow-origin` :

```text
HTTP/2 204
access-control-allow-headers: Authorization, Content-Type, X-Requested-With, DPoP
access-control-allow-methods: GET, POST, PATCH, PUT, DELETE, QUERY, OPTIONS
access-control-max-age: 600
vary: Origin
```

Le preflight « réussit », et le navigateur bloque quand même l’appel
réel : sans l’origine en écho, rien n’autorise à l’envoyer. La même
vérification fonctionne sur l’endpoint de token, `/OAuth/token`.

## Explication

### Où Facet reflète les origines

Le gestionnaire CORS reflète les origines enregistrées sur `/OAuth/*` et
`/Api/*`, pour les réponses preflight comme pour les réponses réelles. Il
s’exécute avant la vérification d’authentification dans la chaîne de
gestionnaires ; une requête preflight n’a donc pas besoin
d’identifiants. Facet renvoie en écho l’en-tête `Origin` de la requête
seulement s’il figure dans `allowed_origins` d’au moins une app
`active`.

### Correspondance exacte, jamais de joker

Facet n’envoie jamais `Access-Control-Allow-Origin: *`. Les navigateurs
ignorent la forme `*` quand `Authorization` figure dans
`Access-Control-Allow-Headers`, donc un joker ne protégerait de rien.
Enregistrez plutôt chaque origine exacte.

### La liste autorisée est active immédiatement

Le cache d’origines se déclare périmé à chaque mutation de `app.App` et
se reconstruit à la lecture suivante. Une modification d’origine
s’applique à la requête suivante. Ni redémarrage, ni changement de
configuration du backend.

### Les WebSockets utilisent la même liste

L’upgrade `/Ws` vérifie les mêmes origines enregistrées, plus l’hôte
propre de Facet. L’origine d’une app déployée peut ouvrir un socket sans
configuration du backend. Une origine enregistrée nulle part se ferme
avec `4403` — voir
[Mises à jour en direct](/fr/build/apps/data/realtime/).

### Ce que CORS ne couvre pas

Facet sert le build d’une app sur l’hôte propre de l’app. C’est une
distribution par hôte, pas du CORS — voir
[Déployer votre app sur Facet](/fr/build/apps/host/deploy/). Les clients
hors navigateur n’envoient aucun en-tête `Origin` ; le CORS ne les
concerne donc jamais.

## Exemple

Avec l’origine enregistrée, une app navigateur sur
`http://localhost:5173` lit les réservations après la connexion :

```ts
// L’app détient un access token venu de la connexion OAuth (voir /build/apps/connect/user-login/).
const res = await fetch("https://facet.localhost:3443/Api/rentals/Booking?items=5", {
  headers: { Authorization: `Bearer ${accessToken}` },
});
if (!res.ok) throw new Error(`List failed: ${res.status}`);
const page = await res.json();
```

Le navigateur n’exécute l’appel que parce que l’origine est enregistrée.
Un token lié par DPoP (Demonstrating Proof of Possession) ajoute le
schéma `DPoP` et un en-tête de preuve — voir
[Lier les tokens à votre app (DPoP)](/fr/build/apps/connect/dpop/).

## Dépannage

**Le `fetch` répond sans `Access-Control-Allow-Origin`.**

L’origine n’est pas enregistrée, ou la seule app qui la porte n’est pas
`active`. Enregistrez l’origine sur une app active et renvoyez la
requête.

**Le client réclame à Facet l’en-tête `*`.**

Facet n’envoie jamais `*`. Enregistrez l’origine exacte sur laquelle
l’app tourne.

**La WebSocket se ferme avec `4403`.**

L’origine n’est pas dans la liste autorisée. Enregistrez-la sur une app
active — voir [Mises à jour en direct](/fr/build/apps/data/realtime/).

## Voir aussi

- [Enregistrer une app](/fr/build/apps/connect/register/) — où se
  définissent les origines.
- [Connecter les utilisateurs](/fr/build/apps/connect/user-login/) — le
  flux que les origines autorisent.
- [Mises à jour en direct](/fr/build/apps/data/realtime/) — la
  vérification d’origine de `/Ws`.
- Internes sur GitHub :
  [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
