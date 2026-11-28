---
title: Import/export en masse via l’API
description: Faites entrer et sortir les documents d’un doctype en CSV ou en JSON via les routes d’export et d’import par jobs.
type: how-to
audience: [developer]
features: [DOC-11]
verified_at: eee55a2
sidebar:
  order: 5
---

Ces routes font sortir les documents d’un doctype de Facet, puis les y
renvoient, en CSV ou en JSON. Un export tourne sur un instantané : il lit un
seul point dans le temps. Un import tourne dans une seule transaction :
toutes les lignes arrivent, ou aucune.

> **Pour les agents :** Export : `POST /Api/<domain>/<doctype>/export?format=csv`
> répond `202 {job_id, status_url}` (`wait=true` renvoie le fichier directement).
> Import : `POST /Api/<domain>/<doctype>/import` avec le corps CSV ou JSON répond
> `202 {job_id, row_count, status_url}` ; interrogez
> `GET /Api/<domain>/<doctype>/import_export/<job_id>` pour `{id, status, error, result}`.
> Une seule transaction : la première ligne en échec annule tout. L’upsert se base
> sur la colonne `id`. Les POST en session par cookie exigent
> `X-Requested-With: XMLHttpRequest` ; les appels par clé API n’ont besoin d’aucun
> en-tête CSRF.

## Quand l’utiliser

Utilisez les routes d’import/export quand :

- Vous déplacez un doctype vers une instance Facet, ou hors d’elle.
- Vous remettez une vue tableur d’un doctype à quelqu’un qui n’utilise pas
  Facet.
- Vous chargez un jeu de données initial depuis un autre système.

## Avant de commencer

- Les exports exigent le droit `read` sur le doctype. Un import exige les
  droits `create` et `update`, car un upsert peut faire l’un ou l’autre.
- Les routes refusent les doctypes enfants (`member_of`) et les
  [doctypes sidecar](/fr/build/model/relations/comments-attachments/) dans les
  deux sens.
- Les sessions par cookie doivent envoyer `X-Requested-With: XMLHttpRequest`
  sur les POST. Un identifiant bearer sans cookie en est exempté.

Les appels réels de cette page ont été exécutés sur une instance de dev à
l’adresse `https://facet.localhost:3443` avec les données Brightwater Rentals
chargées.

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

Chaque appel API présente son propre identifiant. Émettez une clé épinglée au
rôle `manager` de Nadia et gardez-la dans une variable :

```sh
NADIA_KEY=$(pnpx @facetapp/cli connect --role manager >/dev/null && pnpx @facetapp/cli apikey)
```

Un appel avec `wait=true` bloque jusqu’à la fin du job et renvoie le fichier
lui-même. Cette session a exporté les sociétés Brightwater :

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  -X POST 'https://facet.localhost:3443/Api/clients/Company/export?format=csv&wait=true' \
  -o companies.csv
```

`companies.csv` contient :

```csv
id,city,name,account_manager
06H1FM1B3MXBPS0JYVM3BDD154,Lyon,Maison Lumière,iam.Account.06H1FKYQFRDS3FBJ6HTX6FNQAE
06H1FM1B68KB1PJVVAM92B38YS,Annecy,Festival des Collines,iam.Account.06H1FKYQFRDS3FBJ6HTX6FNQAE
```

Sans `wait=true`, l’appel répond `202` :

```json
{
  "job_id": "01JBK2M4N6P8R0T2V4X6Z8B2D4",
  "status_url": "/Api/clients/Company/import_export/01JBK2M4N6P8R0T2V4X6Z8B2D4"
}
```

Interrogez la route de statut jusqu’à ce que `status` vale `succeeded` ou
`failed`, puis téléchargez le fichier depuis la route de téléchargement. Sur
un job en échec, la route de téléchargement n’est pas le fichier : lisez
`error` dans la réponse de statut.

`format=csv|json` choisit la sortie. Un format inconnu répond `422` :

```json
{ "error": "Unknown or missing format: xlsx (supported: csv, json)" }
```

Les filtres suivent la grammaire de liste, par exemple
`filters[status__eq]=confirmed`. `sort`, `page`, `per_page` et `items`
répondent `422` : l’export est figé à l’ordre des id.

### 2. Exporter la vue tableau actuelle

```sh
curl -sk -X POST \
  'https://facet.localhost:3443/Api/clients/Company/export_view' \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"columns": ["name", "city"], "sort": ["-created_at", "id"], "filters": {"city__eq": "Lyon"}, "timezone": "Europe/Paris"}'
```

- `columns` est requis. Chaque clé doit être un champ du doctype ou une
  colonne système (`id`, `created_at`, `updated_at`). Une clé inconnue répond
  `422` et nomme la clé.
- `sort` utilise la grammaire de liste. Une entrée invalide répond `422`.
- Les cellules `datetime` se rendent dans la `timezone` demandée. Sans elle,
  elles restent en UTC.

:::note[Ce fichier est une vue, pas une source d’import]
Un export de vue rend les timestamps dans la zone demandée. Un ré-import de
ce fichier échoue sur les cellules sans zone.
:::

### 3. Importer un fichier

La route prend le format d’un paramètre `format=`, sinon du
`Content-Type`, sinon de la forme du corps : un `[` en tête se lit comme du
JSON. Cette session a importé une ligne au format Brightwater :

```sh
cat > probe.json <<'EOF'
[{"content":{"name":"Import Probe Co","city":"Bastia"}}]
EOF

```sh
curl -sk -X POST \
  'https://facet.localhost:3443/Api/clients/Company/import' \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @probe.json
```

La réponse est `202` :

```json
{
  "job_id": "06H1FSDH1016A18QYX19T1YB79",
  "row_count": 1,
  "status_url": "/Api/clients/Company/import_export/06H1FSDH1016A18QYX19T1YB79"
}
```

Interrogez la route de statut :

```json
{
  "id": "06H1FSDH1016A18QYX19T1YB79",
  "status": "succeeded",
  "error": null,
  "result": { "created": 1, "skipped": 0, "updated": 0, "row_count": 1 }
}
```

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
BASE=https://facet.localhost:3443
AUTH="Authorization: Bearer $NADIA_KEY"

# 1. Exportez et attendez : l’appel renvoie le fichier CSV directement.
curl -sk -H "$AUTH" \
  -X POST "$BASE/Api/clients/Company/export?format=csv&wait=true" -o companies.csv

# 2. Ré-importez le fichier.
curl -sk -H "$AUTH" -H 'Content-Type: text/csv' \
  -X POST "$BASE/Api/clients/Company/import" --data-binary @companies.csv

# 3. Interrogez le statut du job (le job_id de la réponse d’import).
curl -sk -H "$AUTH" \
  "$BASE/Api/clients/Company/import_export/01JBK2M4N6P8R0T2V4X6Z8B2D4"
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
- **Attribution.** Chaque ligne enregistre l’import comme sa cause dans
  l’audit.

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
| Monétaire | `EUR 4800.00` — le préfixe de devise est requis à l’import. |
| Booléen | `true` / `false`. |
| Référence | Id qualifié, par exemple `clients.Company.<id>`. |
| Fichier | L’id d’artefact seulement ; les octets ne bougent pas. |
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

Une cellule monétaire exige le préfixe de devise : `EUR 4800.00`, pas
`4800.00`.

**Certaines lignes sont `skipped`.**

Leurs id pointent vers des documents supprimés. Un import ne ressuscite jamais
un document. Retirez les id pour créer de nouveaux documents.

**Le téléchargement répond `404`.**

Le fichier résultat a été purgé après la fenêtre de rétention — voir
[Rétention](/fr/admin/history/retention/). Exportez de nouveau.

## Voir aussi

- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — la grammaire de filtres de liste
  que les filtres d’export réutilisent.
- [Téléverser et servir des fichiers](/fr/build/apps/data/files/) — comment le fichier
  résultat est stocké et relu.
- [Rétention](/fr/admin/history/retention/) — la fenêtre qui borne un lien de
  téléchargement.
- Internes sur GitHub :
  [import-export.md](https://github.com/wearefacet/facet/blob/main/doc/backend/import-export.md).
