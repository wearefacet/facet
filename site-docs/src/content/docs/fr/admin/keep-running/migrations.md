---
title: "Migrations de base de données"
description: "Appliquez et annulez les migrations de base de données, et gardez chaque session sur UTC."
type: how-to
audience: [operator]
features: [PLT-11]
verified_at: eee55a2
sidebar:
  order: 3
---

Une nouvelle version livre un nouveau schéma, et le changement doit
arriver sans toucher les données. Facet porte ses propres migrations.
Le binaire lit chaque fichier de migration à la compilation et
l’embarque, si bien qu’un binaire déployé n’a pas besoin de l’arbre
`db/` sur disque. Le runner applique les migrations en attente dans
l’ordre des noms de fichiers et suit les fichiers appliqués dans une
table `_migrations`. Un fichier de migration changé ou ajouté demande
une reconstruction.

## Quand l’utiliser

- Vous passez une installation à une nouvelle version.
- Vous devez annuler une migration.
- Vous connectez un client qui ne doit pas fausser les horodatages.

## Avant de commencer

- `DATABASE_URL` pointe vers la base cible.
- Prenez un instantané de la base avant d’annuler une migration. Une annulation exécute du DDL qu’un instantané peut défaire.
- Connaissez la différence entre les deux chaînes d’initialisation : `migrate` plus `seed:core` est sûr partout ; `db_reset` détruit la base.

## Étapes

### 1. Appliquer les migrations en attente

```sh
facet migrate
```

Le runner trie les fichiers en attente par nom, applique la section
`-- UP` de chacun, et enregistre le fichier dans `_migrations`. Les
fichiers appliqués sont sautés, si bien que la commande est idempotente.
Le point d’entrée du conteneur exécute
`facet migrate && facet seed:core` à chaque démarrage : trois
tentatives de migrate, puis la seed, puis le serveur démarre.

Après un `facet migrate` simple sur une base neuve, lancez la seed :

```sh
facet seed:core
```

Elle initialise les doctypes core et le registre des devises. Elle est
idempotente et sûre à chaque démarrage.

### 2. Annuler une migration au besoin

```sh
facet migrate:down            # annule la dernière migration appliquée
facet migrate:down 0008       # annule tout ce qui a été appliqué après 0008 ; 0008 reste appliqué
facet migrate:down --yes      # saute la demande de confirmation
```

Règles :

- La cible prend le nom de fichier complet ou son préfixe numérique
  `NNNN`.
- Les migrations s’annulent dans l’ordre inverse des noms de fichiers.
  Chaque annulation exécute la section `-- DOWN` du fichier et détruit
  sa ligne `_migrations` dans une seule transaction, si bien que le
  schéma et la liste des appliqués ne se contredisent jamais.
- La commande imprime le plan et demande une confirmation. Elle refuse
  d’afficher une demande quand stdin n’est pas un terminal : les
  appelants scriptés passent `--yes`.
- Le plan est validé avant toute exécution. Une cible inconnue, une
  cible non appliquée, ou une migration sans section `-- DOWN`
  utilisable interrompt sans aucun changement.
- Une migration annulée se réapplique normalement au prochain
  `facet migrate`.

### 3. Suivre la règle d’append-only

Après la première version, `db/migrations/` est en append-only.
N’éditez, ne renumérotez, ne fusionnez jamais une migration qu’une base
installée a appliqué.

La raison est la table de suivi. `_migrations` porte les noms des
fichiers appliqués. Un fichier édité désynchronise chaque base déployée
de l’historique du dépôt, et un binaire reconstruit porte alors du SQL
qui contredit son propre historique. La même règle protège
l’embarquement : le binaire et l’historique doivent toujours raconter
la même histoire.

### 4. Garder chaque session sur UTC

Chaque colonne d’horodatage stocke l’UTC sans marque de fuseau. Deux
couches épinglent le fuseau de la session :

1. L’application ajoute `TimeZone=UTC` aux options de connexion de
   chaque connexion du pool.
2. La migration `0001_document_store.sql` a posé le défaut du rôle
   applicatif avec `ALTER ROLE CURRENT_USER SET timezone TO 'UTC'`.

Un client qui se connecte avec un autre rôle reçoit le défaut du
serveur. Il doit poser `TimeZone=UTC` lui-même, dans les options de
connexion ou avec `ALTER ROLE ... SET`.

:::caution
Une session hors UTC ne corrompt pas les lectures, mais elle fausse les
écritures. Les défauts de `now()` et les conversions `text::timestamp`
stockent l’heure locale du mur, et PostgreSQL abandonne le décalage
sans avertissement. Épinglez le fuseau sur chaque client externe :
`psql`, outils BI, et scripts à usage unique.
:::

## Exemple

Une mise à niveau d’une version à la suivante sur une installation
conteneur :

```sh
docker compose -f docker/compose.prod.yml pull
docker compose -f docker/compose.prod.yml up -d
```

La nouvelle image backend démarre, exécute ses migrations embarquées,
relance la seed des doctypes core, et démarre le serveur. Aucune étape
de schéma manuelle n’existe. Si le démarrage rapporte un migrate en
échec après trois tentatives, lisez les journaux backend et corrigez la
cause avant de réessayer.

Le chemin source équivalent :

```sh
make build_release
facet migrate && facet seed:core
# puis redémarrez le processus serveur
```

## Dépannage

**`migrate:down` s’interrompt et ne change rien.**

La validation du plan a refusé la cible : nom de fichier inconnu, non
appliqué, ou pas de section `-- DOWN` utilisable. Aucun changement n’a
tourné.

**Une migration ne peut pas être annulée.**

Sa section `-- DOWN` manque ou est vide. Restaurez plutôt depuis un
instantané.

**Les horodatages prennent un décalage fixe.**

Un client externe écrit avec une session hors UTC. Posez
`TimeZone=UTC` pour ce rôle ou cette connexion, puis corrigez les
lignes décalées depuis un instantané ou un réimport.

**Le démarrage du conteneur échoue à l’étape migrate.**

Le point d’entrée a essayé trois fois. Lisez les journaux backend : une
migration verrouillée, un problème de permissions, ou une base
injoignable sont les causes habituelles.

## Voir aussi

- [Mettre à niveau Facet](/fr/admin/keep-running/upgrades/) — le runbook de version qui exécute ces migrations.
- [Exécuter avec des conteneurs](/fr/admin/install/containers/) — la chaîne de point d’entrée qui exécute les migrations.
- [Premier démarrage et initialisation](/fr/admin/install/bootstrap/) — `migrate`, `seed:core` et `db_reset` en contexte.
- [Revenir en arrière sur un changement](/fr/admin/history/roll-back/) — le retour arrière de document, un mécanisme différent de l’annulation de schéma.
- [Modifier un domaine en direct sans risque](/fr/build/model/change-a-live-domain/) — le flux côté auteur pour les changements de doctype.
- Documentation interne sur GitHub : [migrations.md](https://github.com/wearefacet/facet/blob/main/doc/backend/migrations.md), [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md).
- [CLI facet](/fr/reference/cli-facet/)
