---
title: Déplacer des domaines avec des bundles
description: Exportez un domaine sous forme de bundle et importez-le sur une autre instance.
audience: [author, operator]
features: [DOM-15]
sidebar:
  order: 21
verified_at: fd345fe3
---

Un bundle est un fichier qui porte la définition d’un domaine : le domaine
lui-même, ses doctypes, ses scripts et ses vues partagées. Vous l’exportez
depuis une instance et l’importez sur une autre — de la préproduction vers
la production, ou un domaine vendu à un client.

## Quand l’utiliser

- Vous avez construit un domaine en préproduction et vous l’expédiez en
  production.
- Vous gardez les définitions de domaines dans un dépôt et les chargez sur
  les serveurs.
- Vous livrez un domaine prêt à l’emploi à une autre organisation.

## Avant de commencer

- **Un domaine publié.** Un brouillon ne peut pas être exporté.
- **L’outil en ligne de commande `facet`** sur la machine cible, avec
  accès à sa base de données.
- **Une décision sur les documents.** Les définitions sont toujours
  emportées ; les données seulement avec `--with-documents`.

## Étapes

### 1. Exporter le domaine

```sh
facet domain:export crm --output crm.facet-domain
```

La sortie est une arborescence de répertoires. Terminez le chemin par
`.tgz` pour obtenir une seule archive tar à la place. Le bundle contient :

| Contenu | Toujours ? |
| --- | --- |
| Le document du domaine, avec ses hooks en fichiers de script | Oui |
| Chaque définition de doctype, avec son script Lua à côté | Oui |
| Chaque modèle de vue de document de chaque doctype | Oui |
| Chaque vue de liste partagée (générale) | Oui |
| Chaque document | Seulement avec `--with-documents` |

Les vues de liste personnelles ne partent jamais ; elles appartiennent à

leurs propriétaires.

:::tip
Lisez le fichier `bundle.yml` dans le bundle. Il indique la version de
Facet de l’instance source, ce qui permet de vérifier que la cible tourne
sur la même.
:::

### 2. Importer sur la cible

```sh
facet domain:import crm.facet-domain
```

Sans option, l’import crée un domaine neuf et refuse une cible existante.
Passez `--merge` pour mettre à jour un domaine existant, ou `--into newname`
pour l’installer sous un autre nom. Les deux se combinent :

```sh
facet domain:import crm.facet-domain --into crm-prod --merge
```

Tout l’import s’exécute dans une seule transaction : un refus laisse la
cible exactement comme elle était.

### 3. Lire les règles de fusion

`--merge` compare chaque doctype du bundle avec celui du domaine réel :

| Situation | Résultat |
| --- | --- |
| Doctype absent sur la cible | Créé. |
| Même structure | Laissé inchangé. |
| Structure différente | La version du bundle doit être exactement supérieure d’un cran à celle du domaine réel, avec la migration correspondante. |
| Vue de liste partagée | Mise à jour par nom. Une vue qui n’existe que sur la cible n’est jamais supprimée. |

### 4. Accepter les tickets inter-domaines

Si le domaine lit des données dans d’autres domaines, l’import dépose des
tickets de consentement auprès de ces producteurs. Ils démarrent inactifs
à l’import ; un administrateur du domaine producteur les active. La
commande affiche une ligne par ticket.

## Exemple

Une construction de `crm` en préproduction part en production :

```sh
facet domain:export crm --output crm.facet-domain
tar -czf crm.facet-domain.tgz crm.facet-domain
scp crm.facet-domain.tgz ops@prod.example.com:
```

Sur l’hôte de production :

```sh
facet domain:import crm.facet-domain.tgz --merge
```

Le résumé détaille ce qui s’est appliqué, par exemple
`[crm] Imported domain 'crm'` avec
`doctypes: 4 created, 1 updated, 0 unchanged`. Un doctype mis à jour a
franchi la barrière de version en préproduction avant l’export ; la
production l’accepte donc en une étape.

:::caution
Un export n’est pas une sauvegarde. Un bundle porte des définitions, pas
d’historique. Utilisez vos outils de sauvegarde de base de données pour la
récupération.
:::

## Dépannage

**L’export refuse avec une erreur de brouillon.**

Publiez d’abord le brouillon. Les bundles ne portent jamais de brouillons.

**L’import répond : le domaine existe déjà.**

La cible existe et vous n’avez pas passé `--merge`. Ajoutez l’option, ou
renommez avec `--into`.

**L’import renvoie une erreur de barrière de version.**

Le doctype du bundle est en retard ou en avance sur celui du domaine réel.
Reconstruisez le bundle depuis une source à la version correspondante, ou
fusionnez de nouveau après avoir corrigé les versions sur la source.

**Les références vers d’autres domaines semblent cassées.**

Un bundle ne déplace pas les autres domaines. Importez aussi les domaines
référencés ; les références se résolvent quand leurs cibles existent.

## Voir aussi

- [portable-domains doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/portable-domains.md) —
  le format des bundles et chaque barrière.
- [Domaines et isolation](/fr/concepts/domains-and-isolation/) — ce que
  porte un bundle.
- [Le watcher du domaine de développement](/fr/build/dev-domain-watcher/) —
  appliquer les mêmes fichiers automatiquement pendant le développement.
