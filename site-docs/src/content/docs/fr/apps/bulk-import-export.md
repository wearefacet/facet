---
title: Import/export en masse via l’API
description: Faites entrer et sortir les documents d’un doctype en CSV ou en JSON via les routes d’import/export.
audience: [developer]
features: [DOC-11]
sidebar:
  order: 14
verified_at: a77c6171
---

Ces routes font sortir les documents d’un doctype de Facet, puis les y
renvoient, en CSV ou en JSON. Un export tourne sur un instantané : il lit un
seul point dans le temps. Un import tourne dans une seule transaction :
toutes les lignes arrivent, ou aucune.

> **Pour les agents :** Export : `POST /Api/<domain>/<doctype>/export?format=csv`
> répond `202 {job_id, status_url}`. Interrogez
> `GET /Api/<domain>/<doctype>/import_export/<job_id>`, puis téléchargez depuis
> `GET /Api/<domain>/<doctype>/import_export/<job_id>/download` ; `wait=true`
> renvoie le fichier directement. Import : `POST /Api/<domain>/<doctype>/import`
> avec le corps CSV ou JSON ; un `422` nomme la ligne et le problème. L’upsert
> se base sur la colonne `id` ; une seule transaction ; la première ligne en
> échec annule tout. Les POST exigent `X-Requested-With` pour les sessions par
> cookie.

## Quand l’utiliser

Utilisez les routes d’import/export quand :

- Vous déplacez un doctype vers une instance Facet, ou hors d’elle.
- Vous remettez une vue tableur d’un doctype à quelqu’un qui n’utilise pas
  Facet.
- Vous chargez un jeu de données initial depuis un autre système.

## Avant de commencer

- Les exports exigent le droit `read` sur le doctype. Un import exige les
  droits `create` et `update`, car un upsert peut faire l’un ou l’autre.
- Les routes refusent les doctypes enfants (`member_of`) et les doctypes
  sidecar dans les deux sens.
- Les sessions par cookie doivent envoyer `X-Requested-With: XMLHttpRequest`
  sur les POST. Une authentification bearer sans cookie en est exemptée.

## Routes

| Méthode | Route | Objectif |
| --- | --- | --- |
| `POST` | `/Api/<domain>/<doctype>/export` | Exporter un doctype entier. `format=csv\|json` est requis. `wait=true` et les filtres de liste sont facultatifs. |
| `POST` | `/Api/<domain>/<doctype>/export_view` | Exporter la vue tableau actuelle. Corps JSON : `{columns, sort, filters, timezone}`. |
| `POST` | `/Api/<domain>/<doctype>/import` | Importer un fichier CSV ou JSON. L’analyse structurelle tourne à la mise en file. |
| `GET` | `/Api/<domain>/<doctype>/import_export/<job_id>` | Statut du job : `{id, status, error, result}`. |
| `GET` | `/Api/<domain>/<doctype>/import_export/<job_id>/download` | Le fichier résultat. Exports réussis seulement. |

## Étapes

### 1. Exporter un doctype

```sh
curl -s -X POST "https://facet.company.tld/Api/crm/Company/export?format=csv" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "X-Requested-With: XMLHttpRequest"
```

La réponse est `202` :

```json
{
  "job_id": "01JBK2M4N6P8R0T2V4X6Z8B2D4",
  "status_url": "/Api/crm/Company/import_export/01JBK2M4N6P8R0T2V4X6Z8B2D4"
}
```

Interrogez la route de statut jusqu’à ce que `status` vaille `succeeded` ou
`failed`. Téléchargez ensuite le fichier depuis la route de téléchargement.
Avec `wait=true`, l’appel bloque jusqu’à la fin du job : en cas de succès la
réponse est le fichier lui-même, en cas d’échec c’est `500` avec
`{"job_id", "error"}`.

Les filtres suivent la grammaire de liste, par exemple
`filters[status__eq]=active`. `sort`, `page`, `per_page` et `items` répondent
`422` : l’export est figé à l’ordre des id.

### 2. Exporter la vue tableau actuelle

```sh
curl -s -X POST "https://facet.company.tld/Api/crm/Company/export_view" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"columns": ["name", "status", "amount"], "sort": ["-created_at", "id"], "filters": {"status__eq": "active"}, "timezone": "Europe/Paris"}'
```

- `columns` est requis. Chaque clé doit être un champ du doctype ou une
  colonne système (`id`, `created_at`, `updated_at`). Une clé inconnue répond
  `422` et nomme la clé.
- `sort` utilise la grammaire de liste. Une entrée invalide répond `422`.
- Les cellules `datetime` se rendent dans la `timezone` demandée. Sans elle,
  elles restent en UTC.

:::note[Ce fichier est une vue, pas une source d’import]
Un export de vue rend les timestamps dans la zone demandée. Un ré-import de ce
fichier échoue sur les cellules sans zone.
:::

### 3. Importer un fichier

La route prend le format d’un paramètre `format=`, sinon du `Content-Type`,
sinon de la forme du corps : un `[` en tête se lit comme du JSON.

```sh
curl -s -X POST "https://facet.company.tld/Api/crm/Company/import" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: text/csv" \
  -H "X-Requested-With: XMLHttpRequest" \
  --data-binary @companies.csv
```

La réponse est `202` avec `{"job_id", "row_count", "status_url"}`.

L’analyse structurelle tourne avant le job. Un fichier mal formé répond `422`
et nomme la ligne :

```json
{ "error": "row 2: has 3 cells but the header declares 2 columns" }
```

Mauvais guillemets, colonne d’en-tête inconnue, nombre de cellules qui ne
correspond pas à l’en-tête : tout échoue ici. Un problème au niveau d’une
cellule, par exemple une valeur monétaire invalide à la ligne 900, apparaît
plutôt dans le résultat du job.

## Exemple

Un aller-retour complet : exportez avec `wait=true`, ré-importez le fichier,
interrogez le job :

```sh
# 1. Exportez et attendez : l’appel renvoie le fichier CSV directement.
curl -s -X POST "https://facet.company.tld/Api/crm/Company/export?format=csv&wait=true" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "X-Requested-With: XMLHttpRequest" \
  -o companies.csv

# 2. Ré-importez le fichier.
curl -s -X POST "https://facet.company.tld/Api/crm/Company/import" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: text/csv" \
  -H "X-Requested-With: XMLHttpRequest" \
  --data-binary @companies.csv

# 3. Interrogez le statut du job (le job_id de la réponse d’import).
curl -s "https://facet.company.tld/Api/crm/Company/import_export/01JBK2M4N6P8R0T2V4X6Z8B2D4" \
  -H "Authorization: Bearer $FACET_TOKEN"
```

Un job d’export réussi rapporte :

```json
{
  "id": "01JBK2M4N6P8R0T2V4X6Z8B2D4",
  "status": "succeeded",
  "error": null,
  "result": { "artifact_id": "01JARQ5G7X9K2M3N4P5Q6R7S8T", "row_count": 128, "format": "csv" }
}
```

## Le contrat d’import

- **Une seule transaction.** La première ligne en échec annule l’import. Zéro
  ligne ne persiste.
- **L’échec nomme la ligne.** Le rapport porte `{row, field, message}`.
- **Upsert sur la colonne `id`.** Un id vivant met le document à jour. Un id
  correspondant à un document supprimé (tombstone) est ignoré ; un import ne
  ressuscite jamais un document supprimé. Un id absent en crée un.
- **Les deux droits sont nécessaires.** La première ligne que votre rôle ne
  peut pas écrire fait échouer le fichier.
- **Attribution.** Chaque ligne enregistre `actioner_id: "import"` dans
  l’audit.
- **Les doctypes `genonly` refusent les id fournis.** Un doctype dont
  l’identifiant est généré par le système ne crée jamais un document à partir
  d’un id fourni.

  Un import en mode attente répond `200` avec `{row_count, created, updated,
  skipped}`. Un échec de ligne attendu répond `422` avec la ligne en cause.

## Le modèle de job

- Un job tourne une seule fois. Corrigez l’entrée et soumettez de nouveau.
- Les routes de statut et de téléchargement ne répondent qu’au compte
  demandeur. Les autres reçoivent `404` : pas de fuite d’id de job.
- À la fin, un événement est publié sur le flux du doctype, et le compte
  demandeur reçoit une notification avec un lien de téléchargement.

## Conventions des cellules CSV

| Cellule | Convention |
| --- | --- |
| Texte scalaire | Tel qu’il est stocké. |
| Types structurés | JSON dans la cellule. |
| Monétaire | `USD 1.0` — le préfixe de devise est requis à l’import. |
| Booléen | `true` / `false`. |
| Référence | Id qualifié, par exemple `crm.Company.abc`. |
| Fichier | L’id d’artifact seulement ; les octets ne bougent pas. |
| Cellule vide | Se décode en `null` ; elle vide le champ à la mise à jour. |
| Colonne absente | Laisse le champ intact. |
| Texte commençant par `=`, `+`, `-`, `@`, ou une tabulation | S’exporte avec un `'` en tête — le garde-fou anti-formule. Le décodage retire un `'` de tête. |

## Dépannage

**Le POST d’import répond `413`.**

Le corps dépasse le plafond de téléversement. Découpez le fichier et importez
les morceaux.

**La mise en file répond `422` et nomme une ligne.**

L’analyse structurelle a échoué : problème de guillemets, colonne d’en-tête
inconnue, ou nombre de cellules qui ne correspond pas à l’en-tête. Corrigez
cette ligne et soumettez de nouveau.

**Le job échoue sur un champ `money`.**

Une cellule monétaire exige le préfixe de devise : `USD 1.0`, pas `1.0`.

**Certaines lignes sont `skipped`.**

Leurs id pointent vers des documents supprimés. Un import ne ressuscite jamais
un document. Retirez les id pour créer de nouveaux documents.

**Le téléchargement répond `404`.**

Le fichier résultat a été purgé après la fenêtre de rétention — voir
[Rétention](/fr/govern/retention/). Exportez de nouveau.

## Voir aussi

- [Utiliser l’API REST](/fr/apps/rest-api/) — la grammaire de filtres de liste
  que les filtres d’export réutilisent.
- [Téléverser et servir des fichiers](/fr/apps/files/) — comment le fichier
  résultat est stocké et relu.
- [Rétention](/fr/govern/retention/) — la fenêtre qui borne un lien de
  téléchargement.
- Internes sur GitHub :
  [import-export.md](https://github.com/wearefacet/facet/blob/main/doc/backend/import-export.md).
