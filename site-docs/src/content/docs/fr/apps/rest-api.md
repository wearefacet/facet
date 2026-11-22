---
title: Utiliser l’API REST
description: Appelez l’API de documents directement — structures, filtres, agrégations, ETags et erreurs.
audience: [developer]
features: [DOC-01, DOC-02, DOC-03, DOC-04, PLT-13]
sidebar:
  order: 10
verified_at: a77c6171
---

L’API de documents est du HTTP et du JSON simples. Une seule enveloppe sert
chaque lecture et chaque écriture, et une seule grammaire de filtre sert
chaque liste. Cette page présente les structures : corps de création et de
mise à jour, filtres de liste, agrégations, entity tags (ETags) et erreurs.
Le contrat lisible par la machine se trouve dans la
[Référence de l’API REST](/fr/reference/rest-api/).

> **Pour les agents :** Auth : `Authorization: Bearer fct_…` (clé statique) ou
> `Authorization: DPoP <token>` plus un en-tête de preuve `DPoP` (token
> d’app). Séquence : `POST /Api/crm/Company` avec les champs au premier niveau
> du corps JSON (`201`, enveloppe `{data, meta}`) →
> `GET /Api/crm/Company/<id>` (gardez l’`ETag`) → renvoyez-le en
> `If-None-Match: "<etag>"` pour un `304` →
> `GET /Api/crm/Company?items=50&filters[status__eq]=active&sort=-updated_at`
> → `PATCH` (merge patch ; `null` retire une clé) → `DELETE` (`204`). Les
> échecs de validation sont des `422` avec
> `{error, details:[{field, message, code, params?}]}`. Un document caché ou
> manquant répond `404` ; un document supprimé répond `410`.

## Quand l’utiliser

Utilisez l’API brute quand :

- Vous appelez Facet depuis un langage sans SDK.
- Vous voulez un contrôle direct sur les filtres, la pagination ou les
  validateurs de cache.
- Vous déboguez une intégration et devez voir les structures brutes.

Pour les apps TypeScript, préférez [le SDK TypeScript](/fr/apps/typescript-sdk/) : types,
pagination, erreurs typées.

## Avant de commencer

- Une instance Facet en fonctionnement et un identifiant avec une attribution
  de lecture sur le doctype visé. Les créations et les mises à jour exigent
  `write` ; la suppression exige `delete`.
- Trois identifiants fonctionnent sur chaque route :
  - `Authorization: Bearer fct_…` — une clé d’API statique
    ([Comptes de service et clés d’API](/fr/apps/service-accounts/)).
  - `Authorization: DPoP <token>` avec une preuve fraîche dans l’en-tête
    `DPoP` — un token d’app ([Liaison des tokens par DPoP](/fr/apps/dpop/)).
  - Un cookie de session navigateur.
- Une écriture avec session cookie doit porter
  `X-Requested-With: XMLHttpRequest`. Une requête Bearer ou DPoP sans cookie
  de session en est exempte.
- Les chemins portent d’abord un domaine en minuscules : `/Api/crm/Company`.
  Un premier segment en majuscules (`/OAuth`, `/Ws`) désigne une route
  d’infrastructure, jamais un domaine.

  Les exemples utilisent `https://facet.example.com` et le doctype
  `crm.Company`. Remplacez les deux par vos valeurs.

## Étapes

### 1. Lisez un document

```sh
curl "https://facet.example.com/Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

La réponse est une enveloppe `{ data, meta }`. `data` porte les champs que le
doctype déclare. `meta` porte les métadonnées système et n’est jamais
inscriptible :

```json
{
  "data": { "name": "Acme", "status": "active" },
  "meta": {
    "id": "crm.Company.01JD8W2G7Q5M2X9K4T6VBNR8D",
    "uri": "urn:facet:crm:Company:01JD8W2G7Q5M2X9K4T6VBNR8D",
    "mid": "01JD8W2G7Q5M2X9K4T6VBNR8E",
    "domain": "crm", "doc_type": "Company",
    "version": 1, "schema_version": 1,
    "display_name": "Acme",
    "created_at": "2026-01-01T12:00:00Z", "updated_at": "2026-01-01T12:00:00Z"
  }
}
```

| Champ                        | Signification |
| ---------------------------- | ------------- |
| `id`, `uri`                  | Id de document sous la forme à points `{domain}.{Doctype}.{id}` ; URN canonique. |
| `mid`                        | ULID de la dernière mutation appliquée au document. |
| `domain`, `doc_type`         | L’id du domaine et le nom du doctype. |
| `version`, `schema_version`  | La version du document et la version du schéma du doctype. |
| `display_name`               | Libellé humain issu du modèle du doctype ; `null` quand le doctype n’en déclare pas. |
| `created_at`, `updated_at`   | Horodatages en UTC. |

### 2. Créez un document

Les champs voyagent au premier niveau du corps JSON. Il n’y a pas de wrapper
`content` :

```sh
curl -X POST "https://facet.example.com/Api/crm/Company" \
  -H "Authorization: Bearer $FACET_API_KEY" -H "Content-Type: application/json" \
  -d '{ "name": "Acme", "status": "active" }'
```

La réponse est `201` avec l’enveloppe de l’étape 1. Un corps emballé dans un
wrapper ne nomme aucun champ du doctype, donc il échoue avec `422` :

```json
{
  "error": "Document validation failed",
  "details": [{ "field": "content", "code": "unknown_field",
    "message": "is not a defined field — this looks like a wrapped body: send the fields at the top level; there is no content wrapper" }]
}
```

Pour créer un parent avec ses enfants en un appel, envoyez `$content` et
`$children`. L’appel est une seule transaction : l’échec d’un enfant annule
tout l’appel. Les clés de `$children` sont des noms de relation sur le
doctype :

```sh
curl -X POST "https://facet.example.com/Api/crm/Company" \
  -H "Authorization: Bearer $FACET_API_KEY" -H "Content-Type: application/json" \
  -d '{ "$content": { "name": "Acme", "status": "active" },
    "$children": { "memberships": [
      { "role": "primary", "contact": "crm.Contact.01JD9K2G7Q5M2X9K4T6VBNR8E" } ] } }'
```

La réponse porte une clé `children` en plus, groupée par nom de relation.
Chaque entrée porte la même forme `{ data, meta }` que le parent :

```json
{ "children": { "memberships": [
  { "data": { "role": "primary" }, "meta": { "id": "crm.CompanyMembership.01JD9K2G7Q5M2X9K4T6VBNR8F" } } ] } }
```

### 3. Mettez à jour et supprimez

`PATCH` envoie un JSON merge patch (RFC 7386). Une valeur `null` retire une
clé du document ; le journal des mutations enregistre le retrait comme une
entrée `unset` :

```sh
curl -X PATCH "https://facet.example.com/Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D" \
  -H "Authorization: Bearer $FACET_API_KEY" -H "Content-Type: application/json" \
  -d '{ "status": "churned", "website": null }'
```

La réponse est `200` avec l’enveloppe mise à jour. Les routes de documents
n’acceptent que PATCH : un `PUT` répond `405` avec un en-tête `Allow`, car
`PUT` est réservé à la rédaction des définitions sur `core.DocType`.

`DELETE` applique une suppression douce au document et répond `204` sans
corps. Le document devient une pierre tombale ; un appel de restauration le
ramène (voir `410` sous [Erreurs](#erreurs)).

### 4. Listez et filtrez

```sh
curl "https://facet.example.com/Api/crm/Company?items=50&filters[status__eq]=active&sort=-updated_at" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

L’enveloppe de collection porte un tableau de lignes `{ data, meta }`. Le
`meta` de liste porte `count` et `more` :

```json
{
  "data": [
    { "data": { "name": "Acme", "status": "active" },
      "meta": { "id": "crm.Company.01JD8W2G7Q5M2X9K4T6VBNR8D", "created_at": "2026-01-01T12:00:00Z", "updated_at": "2026-01-02T09:30:00Z" } },
    { "data": { "name": "Globex", "status": "active" },
      "meta": { "id": "crm.Company.01JD9K2G7Q5M2X9K4T6VBNR8E", "created_at": "2026-01-03T08:00:00Z", "updated_at": "2026-01-03T15:11:42Z" } }
  ],
  "meta": { "count": 2, "more": false }
}
```

Pagination : `page` commence à 1 ; `items` est borné à 1..1000 ; les valeurs
par défaut sont page 1, 100 éléments, tri `id`. `count` plafonne à 1000 et
inclut une ligne sonde quand une page suivante existe — une page d’un seul
élément face à un ensemble plus grand rapporte `count: 2`. `more` vaut `true`
quand une page suivante existe.

Les clés de filtre sont des paires `field__operator` :

| Opérateur                                  | Correspondance |
| ------------------------------------------ | -------------- |
| `__eq`, `__ne`                             | Égal, différent. |
| `__gt`, `__gte`, `__lt`, `__lte`           | Comparaison. |
| `__match`                                  | Contient la sous-chaîne, sans tenir compte de la casse. |
| `__starts_with`                            | Commence par la valeur, sans tenir compte de la casse. |
| `__between`                                | Intervalle inclusif ; la valeur est un tableau à deux éléments. |
| `__in`                                     | Appartenance ; la valeur est un tableau d’au plus 100 entrées. |
| `__currency`                               | Montant monétaire dans une devise. |
| `__contains`, `__overlaps`, `__within`     | Tests d’intervalle sur les champs `period` et `dateperiod`. |
| `search` (clé nue, sans suffixe)           | Correspondance de sous-chaîne sur le corpus de recherche du document. |

Chaque doctype accepte aussi les cibles système `id`, `created_at`,
`updated_at` et `deleted_at`. Les valeurs de tableau sur la query string
voyagent encodées en JSON :
`filters[value__between]=%5B%22USD%202500%22%2C%22USD%201000%22%5D`. Les
entrées de tri prennent un préfixe `-` pour l’ordre décroissant. Les types
numériques (integer, money, duration) se trient comme des nombres, pas comme
du texte. Un champ de filtre inconnu répond `422` avec `unknown_filter_field` ;
un paramètre inconnu répond `422 Unknown parameter '<key>'`. Une faute de
frappe ne retombe jamais sur un résultat non filtré.

### 5. Agrégez

`aggregate=count` compte l’ensemble filtré complet. Il ignore `page` et
`items` et plafonne le compte à 1000. Il répond
`{ "data": [], "meta": { "count": 87, "more": false } }` :

```sh
curl "https://facet.example.com/Api/crm/Company?aggregate=count&filters[status__eq]=active" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

`aggregate=sum|avg|min|max` exige `field=`. Le champ doit être un champ
`integer`, `duration` ou `money` de premier niveau. Un agrégat de champ porte
sur l’ensemble filtré complet, sans plafond. Un champ money renvoie un sac
avec une entrée par devise présente, jamais un total unique toutes devises
confondues ; les montants sont des chaînes décimales :

```sh
curl "https://facet.example.com/Api/crm/Deal?aggregate=sum&field=value" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

```json
{ "data": { "value": { "USD": "123456.78" } }, "meta": { "count": 87, "more": false } }
```

Un ensemble vide répond `value: 0` pour `sum`, `value: null` pour `avg`, `min`
et `max`, et `value: {}` pour un champ money. `meta.count` compte les lignes
correspondantes ; les lignes qui omettent le champ comptent quand même.

### 6. Mettez les lectures en cache avec les ETags

Chaque lecture émet un `ETag` fort. Sur un document seul, le tag est l’ULID de
sa dernière mutation. Sur une collection, le tag combine le rôle, la requête
et la version du doctype. Renvoyez le tag dans `If-None-Match`, et le serveur
répond `304 Not Modified` quand rien n’a changé :

```http
GET /Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D
→ 200
ETag: "01JD8W2G7Q5M2X9K4T6VBNR8E"

GET /Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D
If-None-Match: "01JD8W2G7Q5M2X9K4T6VBNR8E"
→ 304
```

Un `304` porte `Cache-Control: no-cache`, donc le client revalide à la lecture
suivante. Une écriture donne au document un nouveau tag, pour qu’un client
périmé ne reçoive jamais un faux `304`.

### 7. Envoyez les paramètres de liste dans un corps QUERY

La méthode `QUERY` (RFC 10008) porte les paramètres de liste dans un corps
JSON uniquement. Préférez-la pour les nouveaux clients ; `GET` garde la fusion
du corps et de la query string pour la compatibilité ascendante, et la query
string l’emporte en cas de collision :

```sh
curl -X QUERY "https://facet.example.com/Api/crm/Company" \
  -H "Authorization: Bearer $FACET_API_KEY" -H "Content-Type: application/json" \
  -d '{ "items": 50, "filters": { "status__eq": "active" }, "sort": ["-updated_at"] }'
```

Tout paramètre de query string sur une requête `QUERY` répond `422`. Un corps
avec un `Content-Type` non JSON répond `415`. Un corps vide signifie les
valeurs par défaut : page 1, 100 éléments, tri `id`. Les réponses portent
`Accept-Query: application/json`, pour qu’un client puisse découvrir le format
depuis toute réponse de liste.

## Erreurs

| Statut | Signification |
| ------ | ------------- |
| `422`  | La validation a échoué, ou un nom de filtre, de tri, de select ou de paramètre est faux. |
| `403`  | Refus de classe : l’identifiant ne porte aucune permission sur le doctype. |
| `404`  | Sans divulgation : un document manquant et un document caché sont indiscernables. |
| `405`  | Méthode non autorisée ; l’en-tête `Allow` nomme les méthodes acceptées. |
| `409`  | Écriture concurrente sur le document. Réémettez la même requête. |
| `410`  | Pierre tombale : le document est supprimé. |
| `415`  | Un `Content-Type` non JSON sur une requête qui porte un corps. |

Un corps `422` porte une entrée par champ en échec. Chaque entrée contient
`field`, `message` et `code` ; une carte `params` porte les interpolations
d’un `code` à gabarit quand elles existent (l’étape 2 montre un exemple
complet). Une écriture concurrente répond
`{ "error": "Concurrent write on this document — retry the request" }`.
L’écriture perdante n’a jamais atterri, donc une nouvelle écriture prend le
prochain emplacement libre.

Une lecture d’une pierre tombale répond `410` avec le libellé survivant :

```json
{ "error": "Document 01JD8W2G7Q5M2X9K4T6VBNR8D was deleted", "display_name": "Acme", "deleted_at": "2026-01-01T12:00:00Z" }
```

Restaurez le document avec `POST /Api/crm/Company/<id>/restore` et un corps
JSON vide. Chaque réponse d’erreur pose `Cache-Control: no-store`, pour
qu’aucun cache ne garde un échec périmé.

## Exemple

Une séquence couvre le cycle complet créer, lire, mettre à jour et supprimer
(CRUD) :

```sh
BASE="https://facet.example.com"
AUTH="Authorization: Bearer $FACET_API_KEY"
ID="01JD8W2G7Q5M2X9K4T6VBNR8D"

curl -s -X POST "$BASE/Api/crm/Company" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{ "name": "Initech", "status": "lead" }'          # → 201 : meta.id, nouvel ETag
curl -s -D - -o /dev/null "$BASE/Api/crm/Company/$ID" -H "$AUTH"          # → 200 : copiez l’ETag
curl -s -D - -o /dev/null "$BASE/Api/crm/Company/$ID" -H "$AUTH" \
  -H 'If-None-Match: "01JD8W2G7Q5M2X9K4T6VBNR8E"'       # → 304 si inchangé
curl -s "$BASE/Api/crm/Company?filters[status__eq]=active&sort=-updated_at&items=10" -H "$AUTH"  # → 200
curl -s -X PATCH "$BASE/Api/crm/Company/$ID" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{ "status": "active" }'                           # → 200 : enveloppe mise à jour
curl -s -X DELETE "$BASE/Api/crm/Company/$ID" -H "$AUTH" -o /dev/null -w '%{http_code}\n'  # → 204
```

## Dépannage

**Un document que vous venez de créer répond `404`.**

Des périmètres de lignes sur le rôle, ou une attribution manquante, cachent
la ligne. Un `404` ne divulgue jamais l’existence. Vérifiez ce que
l’identifiant peut tenter — voir
[Contrôler votre UI avec le manifest](/fr/apps/permission-manifest/).

**Un appel de liste répond `422 Unknown parameter` ou `unknown_filter_field`.**

Une faute de frappe se cache dans la grammaire des paramètres. Vérifiez la
clé et l’opérateur contre la table de l’étape 4.

**Une lecture conditionnelle renvoie `200` à chaque fois.**

La valeur d’`If-None-Match` doit correspondre à l’`ETag` à l’identique,
guillemets compris.

**Une écriture répond `409`.**

Deux écritures concurrentes ont visé le même document. L’écriture perdante
n’a jamais atterri. Réémettez la même requête.

**Une création répond `422` avec `unknown_field` sur `content`.**

Le corps est emballé dans une clé `content`. Envoyez les champs au premier
niveau du corps JSON.

## Voir aussi

- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/apps/typescript-sdk/) — le wrapper
  typé de cette surface.
- [Recherche](/fr/apps/search/) — la recherche de libellés multi-doctypes en
  un appel.
- [Temps réel avec WebSockets](/fr/apps/websockets/) — des mises à jour
  poussées au lieu du polling.
- [Contrôler votre UI avec le manifest](/fr/apps/permission-manifest/) — ce
  que l’identifiant peut tenter.
- [Référence de l’API REST](/fr/reference/rest-api/) — le contrat lisible par
  la machine.
- Internes sur GitHub :
  [http-layer.md](https://github.com/wearefacet/facet/blob/main/doc/backend/http-layer.md).
