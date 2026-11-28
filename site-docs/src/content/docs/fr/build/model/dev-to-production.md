---
type: how-to
title: De la dev à la production
description: Construisez un domaine dans des fichiers sur la dev, transportez-le en bundle et laissez les auteurs l’ajuster sur la cible.
audience: [author, developer]
features: [DOM-15, DOM-02, DOM-19]
sidebar:
  order: 3
verified_at: eee55a2
---

Brightwater Rentals exploite trois domaines : `equipment`, `clients` et
`rentals`. Sam les modélise en fichiers sur un serveur de dev, et le
watcher applique chaque enregistrement. Les trois mêmes domaines doivent
tourner sur l’instance de préproduction qu’utilisent les auteurs, puis
en production. Le pont est le **bundle** : une commande d’export, une
commande d’import, et une règle claire sur qui possède le domaine après
son arrivée.

## L’aller-retour

<!-- d2
direction: down
files: "Domain files on dev" {class: external}
export: "facet domain:export" {class: decision}
bundle: "Bundle: definitions, optional data" {class: store}
import: "Import on staging"
draft: "Authors adjust in a draft, publish" {class: ok}
reexport: "Export changed domains again" {class: decision}
prod: "Import on production" {class: ok}

files -> export
export -> bundle
bundle -> import
import -> draft
draft -> reexport: "publish changed the structure"
reexport -> bundle
bundle -> prod: "when staging is right"
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/1d738be7-light.svg" alt="Domain files on dev" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/1d738be7-dark.svg" alt="Domain files on dev" loading="lazy" />
</div>

Les fichiers sur la dev sont l’origine. L’export écrit un bundle — un
dossier ou un tarball qui transporte les définitions du domaine.
L’import crée ou met à jour le domaine sur la cible. Là, les auteurs
travaillent comme d’habitude : un brouillon, une vérification, une
publication. Quand leurs changements comptent pour la dev, exportez le
domaine de nouveau et commitez les nouveaux fichiers.

## Avant de commencer

- **Un serveur de dev avec le watcher actif** — voyez
  [Le watcher de domaines](/fr/build/model/in-files/domain-watcher/).
- **L’outil en ligne de commande `facet`** sur chaque machine du chemin,
  avec accès à sa base de données.
- **Une cible nommée.** Décidez des noms de domaine avant d’exporter ;
  un bundle transporte un domaine sous un nom.

## Étapes

### 1. Construire en fichiers sur la dev

Modélisez le domaine en fichiers, comme le décrit
[l’organisation des fichiers du domaine](/fr/build/model/in-files/domain-files/).
Le watcher synchronise chaque enregistrement et le rapport de
vérification nomme quoi corriger. Commitez les fichiers au fil de
l’eau — le contrôle de version est le filet de sécurité de ce mode.

### 2. Exporter le bundle

```sh
facet domain:export equipment --output bundles/equipment.facet-domain.tar.gz
```

Trois domaines partent en une commande chacun, ou en lot :

```sh
facet domain:export equipment,clients,rentals --output-dir bundles/
```

L’export transporte les définitions seules, sauf si vous passez
`--with-documents`. Les données initiales sont un choix. Brightwater
livre les définitions dans les tarballs et construit ses données de
démonstration avec un script, parce que le script reste lisible et
réexécutable. Voyez
[Déplacer des domaines avec des bundles](/fr/build/model/bundles/)
pour chaque option.

:::caution
Tenez les exports hors de la racine surveillée par le watcher. Un
dossier `.facet-domain` dans la racine surveillée se synchronise comme
un bundle ; un fichier `.tar.gz` est invisible pour le watcher.
Brightwater écrit ses tarballs dans `bundles/` à côté des dossiers de
domaine pour exactement cette raison.
:::

### 3. Créer les rôles et les comptes sur la cible

Les rôles, les comptes et les vues personnelles ne voyagent jamais dans
un bundle. Un bundle transporte un domaine ; les rôles vivent dans le
domaine `iam` séparé. Sur la cible :

- Créez chaque rôle par l’API — le script `load.sh` de Brightwater le
  fait de façon réexécutable.
- Créez les comptes avec `facet accounts:create`. La commande affiche un
  mot de passe à usage unique ; la première connexion en demande un
  nouveau.
- Attribuez les rôles aux comptes avec `facet roles:add`.

Les imports de bundle déposent aussi des **tickets d’octroi** pour les
liens inter-domaines du domaine. Ils démarrent inactifs ; un
administrateur du domaine producteur active chacun. Le `load.sh` de
Brightwater élargit et active ses octrois pour que les données de
démonstration circulent.

### 4. Importer sur la cible

```sh
facet domain:import bundles/equipment.facet-domain.tar.gz,bundles/clients.facet-domain.tar.gz,bundles/rentals.facet-domain.tar.gz --merge
```

`--merge` met à jour un domaine qui existe et en crée un qui n’existe
pas. Sans elle, une cible existante répond `409`. L’import complet
s’exécute en une seule transaction : un bundle rejeté laisse la cible
exactement en l’état. Pour installer un domaine sous un autre nom,
passez `--into newname`.

Si le bundle transportait des documents, l’import saute une ligne dont
l’id existe déjà — le relancement est sûr. Il ne met jamais à jour une
ligne existante ; rafraîchissez les données en les rechargeant sur une
cible propre.

### 5. Laisser les auteurs ajuster sur la cible

À partir d’ici, les auteurs de la cible possèdent le domaine. Ils
ouvrent un brouillon, changent ce dont l’équipe locale a besoin, lancent
la **Vérification** et publient — le flux de
[Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/).
La barrière de l’import les protège. Un doctype fusionné doit arriver
exactement à une version de schéma au-dessus de la version réelle, avec
une fonction de migration pour l’étape.

### 6. Ramener les changements vers la dev

Rien ne se synchronise de la préproduction vers vos fichiers. Après
qu’une publication a changé la structure sur la cible, exportez ce
domaine de nouveau et commitez les fichiers :

```sh
facet domain:export rentals --output bundles/rentals.facet-domain.tar.gz
```

La section suivante rend cette règle précise.

## Ce que transporte un bundle

| Contenu | Voyage ? |
| --- | --- |
| Le document du domaine, avec ses hooks en fichiers de script | Toujours |
| Chaque définition de doctype, avec son script Lua | Toujours |
| Chaque modèle de vue document de chaque doctype | Toujours |
| Chaque vue de liste partagée (générale) | Toujours |
| Documents des doctypes du domaine | Seulement avec `--with-documents` |
| Vues de liste personnelles | Jamais — elles appartiennent à leurs propriétaires |
| Rôles, comptes | Jamais — créez-les sur la cible |
| Consentements inter-domaines (octrois) | Comme tickets inactifs à accepter par le producteur |
| Valeurs secrètes | Seulement avec l’export ; `--omit-secrets` les vide |

Le `bundle.yml` du bundle nomme la release Facet de l’instance source,
pour que vous vérifiiez que la cible exécute la même.

## Un domaine, deux endroits

Le même domaine peut recevoir des modifications des deux côtés, et
aucun garde-fou du produit ne l’arrête. Les deux côtés se comportent
différemment :

- **Sur la dev, le watcher l’emporte.** Sa prochaine synchronisation
  réapplique le dossier au serveur en cours d’exécution, donc un
  changement fait dans un brouillon là-bas disparaît au prochain
  enregistrement. Avec `documents: discard`, même les données reviennent
  aux bundles.
- **Sur la préproduction ou la production, aucun watcher ne tourne.**
  Une publication de brouillon change le domaine, et vos fichiers ne
  l’apprennent jamais.

La règle de travail qui garde les deux côtés honnêtes : **les fichiers
sont la source de vérité.** Après tout changement fait dans un brouillon
sur une cible, exportez ce domaine de nouveau et commitez les fichiers.
Avant d’exporter, vérifiez `git status` — un dossier non commité plus un
export en vol, voilà comment commence la dérive.

## Quand le schéma importé diffère des documents réels

Une fusion peut changer un doctype qui porte déjà des documents sur la
cible. Les définitions arrivent d’un coup ; les documents rattrapent à
leur propre rythme : chacun migre à la prochaine lecture qui le touche.
Les libellés et le texte de recherche exigent une passe de reprojection
après un changement de modèle. Les deux sujets ont leurs pages :
[Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/)
et
[Comment les documents anciens suivent un nouveau schéma](/fr/build/deeper/schema-evolution/).

## Exemple

L’aller-retour Brightwater complet, depuis une instance propre :

```sh
# sur l’instance cible
facet domain:import bundles/equipment.facet-domain.tar.gz,bundles/clients.facet-domain.tar.gz,bundles/rentals.facet-domain.tar.gz --merge
./load.sh   # rôles, personnes, octrois et données de démonstration déterministes
```

L’import affiche une ligne de résumé par domaine, avec les compteurs
créés, mis à jour et inchangés. `load.sh` supporte d’être relancé :
chaque étape cherche d’abord sa cible. Les rôles et les personnes ne
sont pas dupliqués, et le script d’initialisation ne crée aucune ligne
dupliquée.

## Dépannage

**L’import répond : `Domain … already exists; pass --merge to overwrite.`**

La cible existe. Ajoutez `--merge`, ou renommez avec `--into newname`.

**L’import répond avec une erreur de barrière de version.**

Le doctype du bundle n’est pas exactement une version de schéma
au-dessus du doctype réel. Ramenez le bundle depuis une source qui porte
la version correspondante, ou corrigez la version et la migration sur la
source puis exportez de nouveau.

**Les références vers d’autres domaines semblent rompues.**

Un bundle ne déplace pas les autres domaines. Importez aussi les
domaines référencés ; les références se résolvent quand leurs cibles
existent.

**Les données de démonstration manquent sur la cible.**

Les définitions voyagent par défaut ; les documents exigent
`--with-documents` à l’export. Réexportez avec l’option, ou chargez les
données avec un script, comme le fait le `load.sh` de Brightwater.

**Les personnes ne voient rien après l’import.**

Les rôles et les octrois ne voyagent jamais. Créez les rôles, et activez
les tickets d’octroi déposés par l’import — un ticket inactif bloque
chaque flux inter-domaine qu’il couvre.

## Voir aussi

- [Déplacer des domaines avec des bundles](/fr/build/model/bundles/) — les commandes d’export et d’import, option par option.
- [L’organisation des fichiers du domaine](/fr/build/model/in-files/domain-files/) — les fichiers d’où part l’aller-retour.
- [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/) — ce que les auteurs font du domaine après son arrivée.
- [Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/) — ce qu’un changement de schéma coûte sur des données réelles.
- Documentation interne sur GitHub : [portable-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/portable-domains.md).
- [Choisir sa façon de construire](/fr/build/model/)
