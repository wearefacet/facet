---
type: how-to
title: Déplacer des domaines avec des bundles
description: Exportez un domaine sous forme de bundle et importez-le sur une autre instance, avec les options documents, secrets et renommages.
audience: [author, operator]
features: [DOM-15]
sidebar:
  order: 4
verified_at: eee55a2
---

Un bundle est un fichier qui transporte la définition d’un domaine : le
domaine lui-même, ses doctypes, ses scripts et ses vues partagées. Vous
l’exportez depuis une instance et vous l’importez sur une autre — de la
préproduction vers la production, ou un domaine vendu à un client. Pour
l’aller-retour complet et le sort des rôles et des personnes, voyez
[De la dev à la production](/fr/build/model/dev-to-production/).

## Quand l’utiliser

- Vous avez construit un domaine sur la préproduction et vous le livrez
  en production.
- Vous conservez les définitions de domaines dans un dépôt et vous les
  chargez sur les serveurs.
- Vous livrez un domaine prêt à l’emploi à une autre organisation.

## Avant de commencer

- **Un domaine publié.** Un brouillon ne peut pas être exporté — la
  commande répond `422`.
- **[L’outil en ligne de commande `facet`](/fr/reference/cli-facet/)** sur la
  machine, avec accès à sa base de données.
- **Une décision sur les documents.** Les définitions voyagent par
  défaut ; les données seulement avec `--with-documents`.

## Étapes

### 1. Exporter le domaine

```sh
facet domain:export crm --output crm.facet-domain
```

Le résultat est une arborescence de dossiers. Terminez le chemin par
`.tar.gz` ou `.tgz` pour obtenir une archive tar unique à la place.
Plusieurs domaines s’exportent en une seule exécution avec un dossier de
sortie :

```sh
facet domain:export crm,billing --output-dir out/
```

Cette commande écrit un bundle par domaine — `out/crm.facet-domain`,
`out/billing.facet-domain`. `--output` refuse plusieurs domaines ;
utilisez `--output-dir` pour un lot. Le bundle contient :

| Contenu | Toujours ? |
| --- | --- |
| Le document du domaine, avec ses hooks en fichiers de script | Oui |
| Chaque définition de doctype, avec son script Lua à côté | Oui |
| Chaque modèle de vue document de chaque doctype | Oui |
| Chaque vue de liste partagée (générale) | Oui |
| Chaque document | Seulement avec `--with-documents` |

Les vues de liste personnelles ne voyagent jamais ; elles appartiennent
à leurs propriétaires.

:::tip
Lisez le `bundle.yml` du bundle. Il nomme la release Facet de l’instance
source (`facet_version`), le domaine source et l’heure d’export. Vous
vérifiez ainsi que la cible exécute la même release.
:::

### 2. Importer sur la cible

```sh
facet domain:import crm.facet-domain
```

Sans option, l’import crée le domaine à neuf et refuse une cible
existante. Passez `--merge` pour mettre à jour un domaine existant, ou
`--into newname` pour l’installer sous un autre nom. Les deux se
combinent :

```sh
facet domain:import crm.facet-domain --into crm-prod --merge
```

L’import complet s’exécute en une seule transaction : un rejet laisse la
cible exactement en l’état. Chaque domaine importé affiche une ligne de
résumé préfixée par son nom, avec les compteurs créés, mis à jour et
inchangés. Un même flux montre donc quel domaine a cassé un lot.

Un lot avance domaine par domaine et s’arrête au premier échec. Un lot
d’export peut laisser un dossier partiel — supprimez-le et relancez. Un
lot d’import laisse les domaines précédents importés ; nettoyez les
cibles avant de réessayer.

### 3. Lire les règles de fusion

`--merge` compare chaque doctype du bundle avec le doctype réel :

| Situation | Résultat |
| --- | --- |
| Doctype absent sur la cible | Créé. |
| Même structure | Laissé inchangé. |
| Structure différente | La version du bundle doit être exactement un cran au-dessus de la version réelle, avec la migration de l’étape. |
| Modèle de vue document | Apparié par type : créé, mis à jour ou supprimé pour se caler sur le bundle. |
| Vue de liste partagée | Appariée par nom : créée ou mise à jour. Une vue qui n’existe que sur la cible n’est jamais supprimée. |

Deux garde-fous tiennent dans la fusion. Vues : le bundle ne supprime
les vues document d’une cible que si le bundle porte au moins une vue
pour ce doctype. Un bundle partiel ne peut pas vider un doctype de ses
vues. Données : l’import vérifie chaque document du bundle contre les
contraintes d’unicité de la cible, et une collision annule tout
l’import.

### 4. Accepter les tickets inter-domaines

Si le domaine lit d’autres domaines, l’import dépose des tickets de
consentement auprès de ces producteurs. Ils démarrent inactifs à
l’import ; un administrateur du producteur les active. La commande
affiche une ligne par ticket.

### Passer un bundle par HTTP

L’API transporte le même bundle. `POST /Api/core/Domain/:id/export`
renvoie une tâche qui produit un zip ;
`POST /Api/core/Domain/import` accepte un corps zip ou tarball avec les
paramètres `into` et `merge`. Les deux répondent `202` avec une URL de
statut, et l’export exige un accès en lecture au domaine, l’import un
accès en écriture. L’export HTTP ne transporte que les définitions — les
documents restent un choix en ligne de commande.

## Secrets

Un champ secret renseigné s’exporte comme un marqueur d’état, jamais
comme une valeur. L’import refuse un marqueur dont le secret n’existe
pas sur la cible, donc un bundle avec secrets ne s’importe que là où les
secrets existent. Pour emmener le domaine ailleurs, exportez avec
`--omit-secrets` : chaque marqueur devient vide, le bundle s’importe, et
les champs restent non renseignés. Saisissez de nouveau les valeurs sur
la cible.

## Exemple

Une construction de `crm` sur la préproduction part vers la production :

```sh
facet domain:export crm --output crm.facet-domain
tar -czf crm.facet-domain.tgz crm.facet-domain
scp crm.facet-domain.tgz ops@prod.example.com:
```

Sur l’hôte de production :

```sh
facet domain:import crm.facet-domain.tgz --merge
```

Le doctype mis à jour a franchi la barrière de version sur la
préproduction avant l’export, donc la production l’accepte en une
seule étape.

:::caution
Un export n’est pas une sauvegarde. Un bundle transporte les
définitions, pas l’historique. Utilisez vos outils de sauvegarde de base
de données pour la récupération.
:::

## Dépannage

**L’export refuse avec une erreur de brouillon.**

Publiez d’abord le brouillon. Les bundles ne transportent jamais de
brouillons.

**L’import répond : le domaine existe déjà.**

La cible existe et vous n’avez pas passé `--merge`. Ajoutez-le, ou
renommez avec `--into`.

**L’import répond avec une erreur de barrière de version.**

Le doctype du bundle est en retard ou en avance sur le doctype réel.
Ramenez le bundle depuis une source avec la version correspondante, ou
refusionnez après avoir corrigé les versions sur la source.

**L’import répond avec une erreur de version qui nomme `$force`.**

Une modification à version égale a supprimé ou retapé un champ. Le
produit ne l’autorise qu’avec un `$force: true` explicite sur la
définition du bundle. L’option détend seulement les rejets de forme. La
version doit toujours être exactement un cran au-dessus de la version
réelle, et une modification à version égale qui transporte des
migrations est toujours refusée.

**L’import refuse un document du bundle à cause d’un champ unique.**

La cible contient déjà une ligne avec cette valeur. Nettoyez la cible,
ou importez sans les documents en collision.

**L’import refuse un marqueur de secret.**

Le secret n’existe pas sur la cible. Saisissez de nouveau les valeurs
sur place, ou exportez de nouveau avec `--omit-secrets` et acceptez des
champs non renseignés.

**Le lecteur affiche un nom de fichier et un numéro de ligne.**

Un fichier du bundle ne s’analyse pas. Le message nomme le fichier et la
ligne — corrigez le YAML dans le bundle, ou exportez de nouveau depuis
la source.

**Les références vers d’autres domaines semblent rompues.**

Un bundle ne déplace pas les autres domaines. Importez aussi les
domaines référencés ; les références se résolvent quand leurs cibles
existent.

## Voir aussi

- [De la dev à la production](/fr/build/model/dev-to-production/) — l’aller-retour, rôles et personnes inclus.
- [Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/) — la barrière de version que la fusion impose.
- [Le watcher de domaines](/fr/build/model/in-files/domain-watcher/) — appliquez les mêmes fichiers automatiquement pendant le développement.
- Documentation interne sur GitHub : [portable-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/portable-domains.md) — le format du bundle et chaque barrière.
- [L’organisation des fichiers du domaine](/fr/build/model/in-files/domain-files/)
