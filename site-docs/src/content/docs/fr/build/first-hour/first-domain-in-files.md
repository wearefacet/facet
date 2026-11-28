---
type: tutorial
title: Le même domaine en fichiers
description: Faites tourner le domaine equipment de Brightwater depuis des fichiers sous le watcher de dev, modifiez l’un d’eux, puis exportez un bundle.
audience: [developer]
features: [DOM-19, DOM-15]
sidebar:
  order: 3
verified_at: eee55a2
---

Le tutoriel 2 a construit le domaine equipment dans le Builder, à la souris.
Ce tutoriel montre l’autre chemin : le même domaine vit dans un dossier de
fichiers, et le serveur de dev applique chaque enregistrement. Les
développeurs qui préfèrent un éditeur, un diff et une revue de code travaillent
ainsi — et c’est ainsi qu’un agent de code IA touche un domaine.

Vous ferez un changement dans le domaine equipment de Brightwater, vous
regarderez le serveur l’appliquer, puis vous exporterez le domaine en bundle.

**Vous construirez :** un doctype provisoire dans le domaine equipment, que
vous retirerez ensuite.
**Durée :** environ 15 minutes.
**Il vous faut :** [un environnement de
dev](/fr/build/dev-environment/) avec la pile en marche (`./scripts/dev`).
La configuration de dev surveille déjà le dossier d’exemples de ce dépôt. Pour
pointer le watcher vers votre propre dossier, définissez
`dev.domain_watch.path` dans votre configuration de dev — voir
[Le watcher de domaines en dev](/fr/build/model/in-files/domain-watcher/).
Une étape lit l’API avec `curl` et la clé d’API stockée par `setup-dev`.

:::caution
Le watcher applique chaque enregistrement à la base en marche. Le changement
de ce tutoriel est réversible — vous supprimez le fichier à la fin et le
serveur retire à nouveau le doctype. Ne pointez jamais le watcher vers un
dossier dont le contenu ne doit pas changer.
:::

## 1. Examiner le dossier du domaine

Les domaines d’exemple vivent sous `site-docs/examples/brightwater/`. Le
domaine equipment tient dans un dossier :

```text
equipment.facet-domain/
├── bundle.yml
├── domain.yml
├── doctypes/
│   ├── equipment.Category.yml
│   ├── equipment.Item.yml
│   ├── equipment.Item.lua
│   └── equipment.MaintenanceTicket.yml
├── hooks/
│   └── 1-booking-drives-stock.lua
└── views/
    ├── equipment.Item/
    └── equipment.MaintenanceTicket/
```

`bundle.yml` nomme le domaine. `domain.yml` est le document du domaine — son
libellé, sa couleur, sa description et ses hooks. Un fichier dans `doctypes/`
est une définition de doctype ; le fichier `.lua` à côté de
`equipment.Item.yml` est le script de cycle de vie de ce doctype. Le dossier
est un **bundle** : le même format qu’écrit `facet domain:export` et que lit
`facet domain:import`.

Regardez une petite définition, `equipment.Category.yml` :

```yaml
content:
  icon: tags
  color: "#0d9488"
  domain: equipment
  fields:
    name:
      type: string
      title: Name
      required: true
      unique: true
      filters:
        - equality
        - text_search
      description: "Category name, e.g. 'Tents', 'Sound', 'Lighting'."
  doctype: Category
  description: "A family of rental equipment."
  display_name: "{{ name }}"
  search: "{{ name }}"
  aggregate_root: true
  schema_version: 1
meta:
  parent_id: equipment
```

La forme est celle de la définition de doctype vue dans le Builder au tutoriel
2 — des champs avec des types, un modèle de libellé, la version de schéma.

## 2. Ajouter un doctype et observer la synchronisation

Créez un nouveau fichier dans `doctypes/`, à côté des autres. Ce tutoriel
ajoute un petit doctype provisoire, `ScratchNote` :

```yaml
---
content:
  icon: sticky-note
  color: "#64748b"
  domain: equipment
  fields:
    name:
      type: string
      title: Name
      required: true
      filters:
        - equality
    note:
      type: string
      title: Note
      description: "What the note says."
  doctype: ScratchNote
  description: "A warehouse scratch note."
  display_name: "{{ name }}"
  search: "{{ name }} {{ note }}"
  aggregate_root: true
  schema_version: 1
meta:
  parent_id: equipment
```

Enregistrez le fichier. Environ une seconde plus tard — le watcher scrute
toutes les 500 millisecondes — le journal du serveur montre la
synchronisation. L’exemple a été capturé depuis la pile démarrée par
`./scripts/dev` :

```text
[backend] … WARN  facet.dev.domain_watcher: [dev-sync] dropping managed domain 'equipment' — full rebuild
[backend] … INFO  facet.dev.domain_watcher: [dev-sync] synced 'equipment' from './site-docs/examples/brightwater/equipment.facet-domain': 4 doctype(s) created, 0 updated, 0 unchanged, 0 document(s) replayed
```

À chaque changement, le watcher remplace les définitions du domaine depuis le
dossier ; `4 doctype(s) created` compte les trois existants plus votre nouveau
`ScratchNote`.

Le nouveau doctype doit apparaître dans l’API. Chaque appel API présente son
propre justificatif, et la CLI en stocke un pour vous. Depuis le dossier où
vous avez lancé `setup-dev` :

```sh
AUTH="Authorization: Bearer $(pnpx @facetapp/cli apikey)"
HOST=$(pnpx @facetapp/cli host)
```

Lisez la définition :

```sh
curl -skg -H "$AUTH" \
  "$HOST/Api/core/DocType/equipment.ScratchNote"
```

```json
{"data":{"doctype":"ScratchNote","domain":"equipment","schema_version":1,…}
```

Créez-y un document, comme vous le feriez dans l’espace de travail :

```sh
curl -skg -H "$AUTH" -X POST \
  -H "Content-Type: application/json" \
  -d '{"name":"Winch check","note":"Tutorial test note"}' \
  "$HOST/Api/equipment/ScratchNote"
```

```json
{"data":{…,"name":"Winch check","note":"Tutorial test note"},"meta":{"id":"06H1G4M80CXBFN2MVM5AAZBJME",…,"display_name":"Winch check"}}
```

Le doctype est en direct dès l’enregistrement du fichier — sans redémarrage,
sans étape de publication.

### Si la synchronisation échoue

Le serveur conserve l’état précédent et journalise l’erreur exacte du champ.
Dans le fichier ci-dessus, passez le type du champ de `string` à `text`, puis
enregistrez :

```text
[backend] … ERROR facet.dev.domain_watcher: [dev-sync] import for 'equipment' (./site-docs/examples/brightwater/equipment.facet-domain) failed: 422 equipment.ScratchNote: bundle doctype definition is invalid: field 'note': Unknown field type: "text" (known types: any, array, boolean, color, data, date, dateperiod, datetime, dictionary, duration, enum, file, integer, longtext, money, object, period, phone, reference, secret, string, url) — keeping previous state
```

Corrigez le fichier (retour à `string`), enregistrez, et la synchronisation
passe.

## 3. Exporter le domaine en bundle

Le dossier a déjà le format bundle, mais la commande d’export sert à capturer
un domaine construit ou modifié ailleurs — par exemple après qu’un collègue
l’a modélisé dans le Builder. Exportez le domaine equipment :

```sh
scripts/facet domain:export equipment --output tmp/equipment.tar.gz
```

```text
== facet domain:export ==
[equipment] Exported to /home/you/facet/tmp/equipment.tar.gz
  doctypes:          4
  document views:    4
  collection views:  2 (general only; personal excluded)
```

Le bundle ne porte que des définitions : les doctypes, leurs vues de document
et les vues de collection générales. Les documents n’y sont pas —
`--with-documents` les ajoute. L’archive tar contient un dossier par doctype :

```sh
tar -tzf tmp/equipment.tar.gz | head
```

```text
./
./views/
./views/equipment.MaintenanceTicket/
./views/equipment.MaintenanceTicket/collection_views/…
./views/equipment.MaintenanceTicket/document_views/form.yml
./views/equipment.MaintenanceTicket/document_views/card.yml
./views/equipment.Item/
./views/equipment.Item/collection_views/…
```

Déplacez ce fichier vers une autre instance et importez-le — le même format
de bundle qu’utilise le `load.sh` de l’exemple sur une installation neuve.

## 4. Retirer le doctype et observer le retour arrière

Supprimez le fichier que vous avez créé :

```sh
rm site-docs/examples/brightwater/equipment.facet-domain/doctypes/equipment.ScratchNote.yml
```

Le watcher applique le retrait : le doctype quitte le domaine, et ses
documents passent en tombstone — supprimés, avec leur historique conservé
pendant la fenêtre de rétention. Le journal nomme les deux faits :

```text
[backend] … WARN  facet.dev.domain_watcher: [dev-sync] doctype 'equipment.ScratchNote' left the bundle — discarding its 1 document(s)
[backend] … INFO  facet.dev.domain_watcher: [dev-sync] synced 'equipment' from './site-docs/examples/brightwater/equipment.facet-domain': 3 doctype(s) created, 0 updated, 0 unchanged, 0 document(s) replayed
```

Relisez le doctype après le retour arrière : Facet répond `410 Gone` — la
ligne est un tombstone, pas une ligne qui n’a jamais existé :

```sh
curl -skg -o /dev/null -w "%{http_code}\n" -H "$AUTH" \
  "$HOST/Api/core/DocType/equipment.ScratchNote"
```

```text
410
```

Le domaine est revenu à ses trois doctypes. Rien d’autre n’a changé.

## Ce que vous avez appris

- Un domaine peut vivre sous forme de fichiers dans un dossier bundle, à côté
  du code de l’app.
- Le watcher de dev applique chaque enregistrement en moins d’une seconde, et
  une validation échouée conserve l’état précédent.
- `facet domain:export` capture un domaine réel en un bundle de définitions
  seules.
- Retirer un doctype du dossier le passe en tombstone, lui et ses documents.

## Voir aussi

- [Le watcher de domaines en dev](/fr/build/model/in-files/domain-watcher/) —
  le contrat de surveillance : clés de configuration, modes, comportement en
  cas d’échec.
- [Fichiers de domaine](/fr/build/model/in-files/domain-files/) — le format
  bundle, fichier par fichier.
- [Déplacer des domaines avec des bundles](/fr/build/model/bundles/) — export
  et import entre instances.
- [Installer l’environnement de dev](/fr/build/dev-environment/) —
  l’environnement de dev dans lequel tourne ce tutoriel.
- [Choisir votre façon de construire](/fr/build/model/)
## Pour aller plus loin

Le chemin des fichiers et le chemin du Builder convergent vers le même domaine
réel. Dans [Livrez votre première app](/fr/build/first-hour/first-app/), vous
construisez l’app de sortie de matériel de Brightwater sur les domaines que
vous connaissez maintenant.
