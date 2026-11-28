---
title: Utiliser l’API REST
description: Créez, lisez, mettez à jour, listez et supprimez des documents en HTTP brut — une seule enveloppe, une grammaire de filtres.
type: how-to
audience: [developer]
features: [DOC-01, DOC-02, DOC-03, DOC-04, DOC-14, PLT-12, PLT-13]
verified_at: c34885a
sidebar:
  order: 0
---

L’API de documents repose sur du HTTP et du JSON simples. Une seule enveloppe
sert chaque lecture et chaque écriture. Une seule grammaire de filtres sert
chaque liste. Le calendrier de Nadia, la table clients de Tom et le tableau de
l’entrepôt de Lucía lisent tous cette surface — et votre app aussi.

> **Pour les agents :** Connexion : `POST /Api/iam/login` (cookie) ou
> `Authorization: Bearer fct_…` (une clé d’API issue de `POST /Api/iam/keys`,
> épinglée à un rôle, ou une clé d’API d’app) ou `Authorization: DPoP <token>`
> plus un en-tête de preuve `DPoP` (token d’app). Séquence :
> `POST /Api/clients/Company` avec les champs au premier niveau du corps JSON
> (`201`, enveloppe `{data, meta}`) → `GET /Api/clients/Company/<id>`
> (conservez l’`ETag` — le `mid`) → renvoyez-le en `If-None-Match` pour un
> `304` →
> `GET /Api/clients/Company?items=50&filters[status__eq]=confirmed&sort=-updated_at`
> → `PATCH` (merge patch ; `null` retire une clé) → `DELETE` (`204`) →
> `POST …/<id>/restore` ramène une pierre tombale. Les échecs de validation
> sont des `422` avec `{error, details:[{field, message, code}]}`. Un document
> caché ou manquant répond `404` ; un document supprimé répond `410`.

## Quand l’utiliser

Appelez l’API directement quand :

- Votre code tourne dans un langage sans SDK.
- Vous voulez un contrôle direct sur les filtres, la pagination ou les
  validateurs de cache.
- Vous déboguez une intégration et voulez voir les structures brutes.

Pour TypeScript, préférez [le SDK TypeScript](/fr/build/apps/data/sdk/) — il
enveloppe cette surface avec des handles typés et des erreurs typées.

## Avant de commencer

- Une instance Facet en fonctionnement et un identifiant capable de lire le
  doctype visé. Les écritures exigent l’action `write` ; la suppression
  exige `delete`.
- Trois identifiants fonctionnent sur chaque route :
  - `Authorization: Bearer fct_…` — une clé d’API d’app
    ([Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/)).
  - `Authorization: DPoP <token>` avec une preuve fraîche dans l’en-tête
    `DPoP` — un token d’app ([Liaison DPoP des tokens](/fr/build/apps/connect/dpop/)).
  - Un cookie de session navigateur issu de `POST /Api/iam/login`.
- Une écriture authentifiée par cookie doit porter
  `X-Requested-With: XMLHttpRequest`. Sans cet en-tête, le contrôle anti-CSRF
  rejette l’écriture avec `403` : un formulaire POST intersite ne peut poser
  aucun en-tête personnalisé. Les requêtes Bearer et DPoP ne portent pas de
  cookie et sont donc exemptées.
- Le chemin est `/Api/<domain>/<doctype>`. Le premier segment est en
  minuscules — un premier segment en majuscules (`/OAuth`, `/Ws`) désigne une
  route d’infrastructure, jamais un domaine.

Les exemples tournent sur une instance de dev à
`https://facet.localhost:3443` avec les données Brightwater Rentals chargées
([l’exemple fil rouge](/fr/build/apps/how-apps-work/)). Le certificat de dev
auto-signé explique le `-k` de chaque `curl`.

## Étapes

### 1. Lire un document

Connectez-vous une fois et conservez une clé d’API épinglée au rôle
`manager`. Chaque appel d’API présente son propre identifiant ; un appel
Bearer ne porte pas de cookie, il n’a donc pas besoin de l’en-tête
`X-Requested-With` :

```sh
pnpx @facetapp/cli connect --role manager   # se connecte, élit manager, stocke la clé
NADIA_KEY=$(pnpx @facetapp/cli apikey)
```

Une réservation du domaine rentals est `BK-2026-0001` — le mariage Maison
Lumière, du 11 au 13 décembre :

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  https://facet.localhost:3443/Api/rentals/Booking/BK-2026-0001
```

```json
{
  "data": {
    "dates": { "end": "2026-12-13", "start": "2026-12-11" },
    "notes": "Wedding — main lawn. Site contact: Claire.",
    "total": 1970,
    "client": "clients.Company.06H1FM1B3MXBPS0JYVM3BDD154",
    "status": "confirmed",
    "client_name": "Maison Lumière"
  },
  "meta": {
    "id": "BK-2026-0001",
    "uri": "urn:facet:rentals:Booking:BK-2026-0001",
    "mid": "06H1FM1DPGYWFD4D8RR2BXM2S9",
    "domain": "rentals",
    "doc_type": "Booking",
    "version": 1,
    "schema_version": 1,
    "display_name": "Maison Lumière",
    "created_at": "2026-11-26T12:24:08Z",
    "updated_at": "2026-11-26T12:24:08Z"
  }
}
```

La réponse est une enveloppe `{ data, meta }`. `data` porte les champs que le
doctype déclare. `meta` porte les métadonnées système et n’est jamais
inscriptible :

| Champ | Signification |
| --- | --- |
| `id`, `uri` | Id du document ; URN canonique `urn:facet:<domain>:<Doctype>:<id>`. |
| `mid` | ULID de la dernière mutation appliquée au document. C’est aussi l’`ETag` du document. |
| `domain`, `doc_type` | L’id du domaine et le nom du doctype. |
| `version`, `schema_version` | La version du document et la version du schéma du doctype. |
| `display_name` | Libellé lisible issu du modèle du doctype ; `null` quand le doctype n’en déclare pas. |
| `created_at`, `updated_at` | Horodatages en UTC. |

### 2. Créer un document

Les champs voyagent au premier niveau du corps JSON. Il n’existe pas de
wrapper `content` :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/clients/Company \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "name": "Atelier Vermeil", "city": "Lyon" }'
```

La réponse est `201` :

```json
{
  "data": { "city": "Lyon", "name": "Atelier Vermeil" },
  "meta": {
    "id": "06H1FRV45MM80SVH32K5JCA6BH",
    "uri": "urn:facet:clients:Company:06H1FRV45MM80SVH32K5JCA6BH",
    "mid": "06H1FRV45MKNZD49WQA7A843TW",
    "domain": "clients",
    "doc_type": "Company",
    "version": 1,
    "schema_version": 1,
    "display_name": "Atelier Vermeil",
    "created_at": "2026-11-26T12:45:08Z",
    "updated_at": "2026-11-26T12:45:08Z"
  }
}
```

Un corps qui emballe les champs dans une clé `content` ne nomme aucun champ
du doctype ; il échoue donc avec `422` :

```json
{
  "error": "Document validation failed",
  "details": [{ "field": "content", "code": "unknown_field",
    "message": "is not a defined field — this looks like a wrapped body: send the fields at the top level; there is no content wrapper" }]
}
```

Pour créer un parent avec ses enfants en un seul appel, envoyez `$content` et
`$children`. L’appel est une seule transaction : l’échec d’un enfant annule
tout l’appel. Les clés de `$children` sont des noms de relation du doctype :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/clients/Company \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "$content": { "name": "Café des Sports", "city": "Vienne" },
    "$children": { "contacts": [ { "name": "Léa Martin", "email": "lea@cafedesports.example" } ] } }'
```

La réponse porte une clé `children` en plus, groupée par nom de relation.
Chaque entrée porte la même forme `{ data, meta }` que le parent :

```json
{ "children": { "contacts": [
  { "data": { "name": "Léa Martin", "email": "lea@cafedesports.example" },
    "meta": { "id": "06H1G0A2B3C4D5E6F7G8H9J0K1L", "parent_id": "06H1G0Z9Y8X7W6V5U4T3S2R1Q0P" } } ] } }
```

### 3. Mettre à jour et supprimer

`PATCH` envoie un JSON merge patch (RFC 7386). Une valeur `null` retire une
clé du document :

```sh
curl -sk -X PATCH https://facet.localhost:3443/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "city": "Annecy", "name": null }'
```

La réponse est `200` avec l’enveloppe mise à jour. Les routes de documents
acceptent `GET`, `HEAD`, `PATCH` et `DELETE` — un `PUT` répond `405` avec
`allow: GET, HEAD, PATCH, DELETE`.

`DELETE` applique une suppression douce au document et répond `204` sans
corps :

```sh
curl -sk -X DELETE -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $NADIA_KEY" \
  https://facet.localhost:3443/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH
# 204
```

Le document devient une pierre tombale. Sa lecture répond désormais `410` et
conserve le libellé, pour qu’une vue d’audit puisse encore le nommer :

```json
{
  "error": "Document 06H1FRV45MM80SVH32K5JCA6BH was deleted",
  "deleted_at": "2026-11-26T12:45:27Z",
  "display_name": "Atelier Vermeil"
}
```

`POST /Api/clients/Company/<id>/restore` avec un corps JSON vide ramène le
document. La réponse porte l’enveloppe restaurée et une liste
`cascade_restored` pour les enfants que la suppression avait emportés.

### 4. Lister et filtrer

```sh
curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/rentals/Booking?filters[status__eq]=confirmed&select=client_name,status,dates&items=2'
```

L’option `curl -g` compte : elle empêche `curl` de déformer les crochets de
la clé de filtre. La réponse est `200` :

```json
{
  "data": [
    { "data": { "client_name": "Maison Lumière", "status": "confirmed", "dates": { "end": "2026-12-13", "start": "2026-12-11" } },
      "meta": { "id": "BK-2026-0001", "display_name": "Maison Lumière", "created_at": "2026-11-26T12:24:08Z", "updated_at": "2026-11-26T12:24:08Z" } },
    { "data": { "client_name": "Harbour Events Ltd", "status": "confirmed", "dates": { "end": "2026-12-20", "start": "2026-12-19" } },
      "meta": { "id": "BK-2026-0003", "display_name": "Harbour Events Ltd", "created_at": "2026-11-26T12:24:08Z", "updated_at": "2026-11-26T12:24:08Z" } }
  ],
  "meta": { "count": 6, "more": false }
}
```

Pagination : `page` commence à 1, `items` est borné à 1..1000, et les valeurs
par défaut sont page 1, 100 éléments, tri `id`. `count` plafonne à 1000.
`more` vaut `true` quand une page suivante existe.

Les clés de filtre ont un seul niveau de crochets,
`filters[field__operator]=value` :

| Opérateur | Correspondance |
| --- | --- |
| `__eq`, `__ne` | Égal, différent. |
| `__gt`, `__gte`, `__lt`, `__lte` | Comparaison. |
| `__match` | Contient la sous-chaîne, sans tenir compte de la casse. |
| `__starts_with` | Commence par la valeur, sans tenir compte de la casse. |
| `__between` | Intervalle inclusif ; la valeur est un tableau à deux éléments. |
| `__in` | Appartenance ; la valeur est un tableau d’au plus 100 entrées. |
| `__currency` | Montant monétaire dans une seule devise. |
| `__contains`, `__overlaps`, `__within` | Tests d’intervalle sur les champs `period` et `dateperiod`. |
| `search` (clé nue, sans suffixe) | Correspondance de sous-chaîne sur le corpus de recherche du document. |

Chaque doctype accepte aussi les cibles système `id`, `created_at`,
`updated_at` et `deleted_at`. Quand une clé ou un opérateur est faux, le
serveur nomme ce qu’il accepte — une faute de frappe ne retombe jamais sur un
résultat non filtré :

```json
{ "error": "Unknown filter field 'nope' (filterable: account_manager, city, created_at, deleted_at, id, name, search, updated_at)" }
```

```json
{ "error": "Filter operator 'regex' is not served for field 'name' (allowed: eq, in, match, ne, starts_with)" }
```

Les valeurs de tableau sur la query string voyagent encodées en JSON, par
exemple
`filters[dates__between]=%5B%222026-12-11%22%2C%222026-12-20%22%5D`. Les
entrées de tri prennent un préfixe `-` pour l’ordre décroissant :
`sort=-updated_at,id`.

**Dates relatives.** Toute borne datetime ou date accepte une date relative à
la place d’une date absolue : `filters[created_at__gte]=-7d`. La grammaire
est `[+|-]<n><unité>…` avec les unités `y`, `mo` (mois), `w`, `d`, `h`, `m`
(minute), `s` ; un `-` initial signifie le passé, `+` ou l’absence de signe
le futur, et le signe s’applique à chaque composant (`-1mo6d` vaut un mois
et six jours en arrière). **`m` est une minute et `mo` un mois.** Les mois et
les années sont des pas de calendrier — `-1mo` depuis le 31 mars donne le
28 février — tandis que les semaines, jours, heures, minutes et secondes
sont de longueur fixe. Sur un champ `datetime` ou sur
`created_at`/`updated_at`, la borne est l’instant exact ; sur un champ
`date`, elle est tronquée au jour calendaire. `__lte` couvre toute la
journée où tombe la borne et `__gt` commence à celle-ci :
`created_at__lte=-7d` signifie « jusqu’à il y a sept jours, journée entière
incluse ». Une borne relative avec `h`, `m` ou `s` sur un champ `date`
répond `422`.

Une seconde forme existe pour les filtres longs : la méthode `QUERY`
(étape 6) porte les mêmes paramètres dans un corps JSON.

### Lister les enfants d’un parent

La route imbriquée
`GET /Api/<domain>/<Doctype>/<id>/<relationship>` liste les enfants d’un
parent — par exemple `/Api/clients/Company/<id>/contacts`. Elle transmet
toute la grammaire de liste : `filters`, `sort`, `page`, `items`, `select`,
`aggregate`, `scope` et `deleted`, avec les valeurs par défaut de la route
plate (page 1, 100 éléments) et la même validation — un filtre mal formé
répond `422`, jamais un résultat non filtré. L’ETag de la réponse digère la
requête entière, si bien que deux pages ou deux tris différents ne
partagent jamais un validateur. Les listes sidecar — commentaires et pièces
jointes — font exception : elles restent non paginées.

### 5. Agréger

`aggregate=count` compte l’ensemble filtré complet. Il ignore `page` et
`items` :

```sh
curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/rentals/Booking?aggregate=count&filters[status__eq]=confirmed'
```

```json
{ "data": [], "meta": { "count": 6, "more": false } }
```

`aggregate=sum|avg|min|max` exige `field=`. Le champ doit être un champ
`integer`, `duration` ou `money` de premier niveau. Un champ money renvoie
un sac avec une entrée par devise présente, jamais un total toutes devises
confondues ; les montants sont des chaînes décimales. Les 44 lignes de
réservation de Brightwater totalisent 387 pièces louées :

```sh
curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/rentals/BookingLine?aggregate=sum&field=price'
```

```json
{ "data": { "value": { "EUR": "8128.00" } }, "meta": { "count": 44, "more": false } }
```

```sh
curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/rentals/BookingLine?aggregate=sum&field=quantity'
```

```json
{ "data": { "value": 387 }, "meta": { "count": 44, "more": false } }
```

Un ensemble vide répond `value: 0` pour `sum`, `value: null` pour `avg`,
`min` et `max`, et `value: {}` pour un champ money. Un champ que le doctype
ne déclare pas, ou un champ non numérique, répond `422` :

```json
{ "error": "field 'total' is not a numeric field (type: data)" }
```

### 6. Mettre les lectures en cache avec les ETags

Chaque lecture émet un `ETag` fort. Sur un document seul, le tag est l’ULID
de sa dernière mutation — le `mid`. Sur une collection, le tag combine le
compte, le rôle, la requête et la version du doctype. Renvoyez le tag dans
`If-None-Match` et le serveur répond `304 Not Modified` quand rien n’a
changé :

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" -D - -o /dev/null \
  https://facet.localhost:3443/Api/rentals/Booking/BK-2026-0001 | grep -i etag
# etag: "06H1FM1DPGYWFD4D8RR2BXM2S9"

curl -sk -H "Authorization: Bearer $NADIA_KEY" -o /dev/null -w '%{http_code}\n' \
  -H 'If-None-Match: "06H1FM1DPGYWFD4D8RR2BXM2S9"' \
  https://facet.localhost:3443/Api/rentals/Booking/BK-2026-0001
# 304
```

Un `304` porte `Cache-Control: no-cache`, si bien que le client revalide à
la lecture suivante. Une écriture donne au document un nouveau `mid`, pour
qu’un client périmé ne reçoive jamais un faux `304`.

### 7. Envoyer les paramètres de liste dans un corps QUERY

La méthode `QUERY` porte les paramètres de liste dans un corps JSON
uniquement. Elle garde les filtres longs lisibles et à l’abri des règles de
citation du shell :

```sh
curl -sk -X QUERY https://facet.localhost:3443/Api/clients/Company \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "items": 10, "filters": { "city__eq": "Lyon" }, "sort": ["-updated_at"] }'
```

Tout paramètre de query string sur une requête `QUERY` répond `422` :

```json
{ "error": "QUERY does not accept query parameters; put them in the request body" }
```

Un corps avec un `Content-Type` non JSON répond `415`. Un corps mal formé
répond `422` avec `{"error": "Invalid JSON body"}`. Un corps vide signifie
les valeurs par défaut : page 1, 100 éléments, tri `id`. Les réponses
portent `Accept-Query: application/json`, pour qu’un client puisse découvrir
le format depuis toute réponse de liste.

## La spécification lisible par la machine

Cette surface possède une description lisible par la machine : un fichier
OpenAPI. L’instance le sert à `GET /Api/openapi.json` à un appelant
connecté — sans identifiant, elle répond `401`. Le fichier couvre
volontairement un sous-ensemble de la surface REST ; la page de référence
l’intègre — voir [API REST](/fr/reference/rest-api/).

## Erreurs

| Statut | Signification |
| --- | --- |
| `401` | Aucun identifiant, ou un identifiant que la surface refuse (un token MCP sur REST, par exemple). |
| `403` | L’identifiant ne porte aucune permission sur le doctype ; ou l’en-tête CSRF manque sur une écriture avec cookie. |
| `404` | Sans divulgation : un document manquant et un document caché sont indiscernables. S’applique aussi à un domaine ou un doctype inconnu. |
| `405` | Méthode non autorisée ; l’en-tête `Allow` nomme les méthodes acceptées. |
| `410` | Pierre tombale : le document est supprimé. |
| `415` | Un `Content-Type` non JSON sur une requête qui consomme un corps. |
| `422` | La validation a échoué, ou un nom de filtre, de tri, de select ou de paramètre est faux. |

Un corps `422` porte une entrée par champ en échec. Chaque entrée contient
`field`, `message` et `code` :

```json
{
  "error": "Document validation failed",
  "details": [{ "field": "name", "message": "is missing", "code": "required" }]
}
```

Pour une erreur de paramètre, le serveur nomme les clés acceptées :

```json
{ "error": "Unknown parameter 'bogus' (accepted: page, items, sort, select, aggregate, field, scope, deleted)" }
```

```json
{ "error": "Unknown select key 'bogus' (accepted: client, client_name, dates, notes, status, total)" }
```

Chaque réponse d’erreur pose `Cache-Control: no-store`, pour qu’aucun cache
ne garde un échec périmé. Le catalogue complet se trouve dans la
[référence des réponses d’erreur](/fr/reference/error-responses/).

## Exemple

Un cycle complet sur l’instance de dev — créer, lire, mettre à jour,
vérifier le cache, supprimer, restaurer, supprimer à nouveau :

```sh
BASE=https://facet.localhost:3443
AUTH="Authorization: Bearer $NADIA_KEY"
CT='Content-Type: application/json'

# Création — notez meta.id dans la réponse 201.
curl -sk -H "$AUTH" -H "$CT" -X POST "$BASE/Api/clients/Company" \
  -d '{ "name": "Atelier Vermeil", "city": "Lyon" }'

# Lecture — copiez l’ETag (le mid) dans les en-têtes.
curl -sk -H "$AUTH" -D - -o /dev/null "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH"

# Lecture conditionnelle — 304 quand rien n’a changé.
curl -sk -H "$AUTH" -o /dev/null -w '%{http_code}\n' \
  -H 'If-None-Match: "06H1FRV45MKNZD49WQA7A843TW"' \
  "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH"

# Mise à jour — 200 avec l’enveloppe fraîche.
curl -sk -H "$AUTH" -H "$CT" -X PATCH "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH" \
  -d '{ "city": "Annecy" }'

# Liste — une page filtrée.
curl -skg -H "$AUTH" \
  "$BASE/Api/clients/Company?filters[name__match]=Vermeil&select=name,city"

# Suppression — 204. La lecture répond ensuite 410.
curl -sk -H "$AUTH" -X DELETE -o /dev/null -w '%{http_code}\n' \
  "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH"

# Restauration — 200 avec l’enveloppe restaurée.
curl -sk -H "$AUTH" -H "$CT" -X POST "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH/restore" -d '{}'

# Suppression à nouveau — l’enregistrement est une donnée jetable.
curl -sk -H "$AUTH" -X DELETE -o /dev/null -w '%{http_code}\n' \
  "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH"
```

## Dépannage

**Une création ou une suppression répond `403` avec
`{"error":"CSRF: Missing X-Requested-With header"}`.**

L’appel porte un cookie de session ; le contrôle CSRF s’applique donc.
Ajoutez `X-Requested-With: XMLHttpRequest`, ou envoyez une clé d’API en
`Authorization: Bearer`. Un appel Bearer ou DPoP sans cookie n’a pas besoin
de cet en-tête.

**Une liste répond `422 Unknown filter field 'name][match'`.**

L’imbrication à la Rack (`filters[name][match]`) n’est pas la grammaire. Un
seul niveau de crochets porte la clé entière : `filters[name__match]=value`
— avec `curl -g` pour que les crochets survivent.

**Un document créé il y a quelques instants répond `404`.**

Des périmètres de lignes sur le rôle, ou une attribution manquante, cachent
la ligne. Un `404` ne divulgue jamais l’existence. Vérifiez ce que
l’identifiant peut tenter — voir
[Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/).

**Une lecture conditionnelle renvoie `200` à chaque fois.**

La valeur d’`If-None-Match` doit correspondre à l’`ETag` à l’identique,
guillemets compris. Le `mid` du document change à chaque écriture — copiez
le tag après l’écriture.

**Une lecture répond `410`.**

Le document est une pierre tombale.
`POST /Api/<domain>/<doctype>/<id>/restore` le ramène. Un `410` porte
`display_name`, pour que l’UI puisse étiqueter la ligne.

**Une création répond `422` avec `unknown_field` sur `content`.**

Le corps est emballé dans une clé `content`. Envoyez les champs au premier
niveau du corps JSON.

**Un agrégat répond `422 field 'x' is not a numeric field`.**

`sum`, `avg`, `min` et `max` prennent un champ `integer`, `duration` ou
`money` de premier niveau. `aggregate=count` n’a besoin d’aucun champ.

## Voir aussi

- [Le SDK TypeScript](/fr/build/apps/data/sdk/) — le wrapper typé de cette surface.
- [Rechercher depuis une app](/fr/build/apps/data/search/) — la recherche de libellés multi-doctypes en un appel.
- [Temps réel avec WebSockets](/fr/build/apps/data/realtime/) — des mises à jour poussées au lieu du polling.
- [Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/) — ce que l’identifiant peut tenter.
- [Référence de l’API REST](/fr/reference/rest-api/) — la référence complète des routes et des paramètres.
- [Documents : des enregistrements avec une mémoire](/fr/discover/how-it-works/documents/)
