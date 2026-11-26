---
title: Migrations de base de données
description: Appliquez et annulez les migrations de base de données, et gardez chaque session en UTC.
audience: [operator]
features: [PLT-11]
sidebar:
  order: 10
verified_at: 008dd880
---

Le binaire porte son propre schéma. Chaque fichier de migration est lu à la
compilation et embarqué dans le binaire ; un binaire déployé n’a donc
pas besoin de l’arborescence `db/` sur le disque. Le moteur applique les
migrations en attente dans l’ordre des noms de fichiers et consigne les
fichiers appliqués dans une table `_migrations`. Un fichier de migration
modifié ou ajouté exige une recompilation.

## Quand l’utiliser

Vous aurez affaire aux migrations dans trois cas :

- vous mettez une installation à niveau vers une nouvelle version,
- vous devez annuler une migration,
- vous connectez un client qui ne doit pas fausser les timestamps.

## Avant de commencer

- `DATABASE_URL` pointe vers la base cible.
- Prenez un instantané de la base avant d’annuler une migration. Une
  annulation exécute du DDL ; seul un instantané permet ensuite de le
  défaire.
- Sachez distinguer les deux chaînes d’amorçage : `migrate` plus
  `seed:core` est sûr partout ; `db_reset` détruit la base de données.

## Étapes

### 1. Appliquer les migrations en attente

```sh
facet migrate
```

Le moteur trie les fichiers en attente par nom, applique la section
`-- UP` de chacun, puis consigne le fichier dans `_migrations`. Les
fichiers déjà appliqués sont ignorés : la commande est idempotente. Au
démarrage, le point d’entrée du conteneur lance
`facet migrate && facet seed:core` : trois tentatives de migration,
puis l’initialisation, puis le serveur démarre.

Après un simple `facet migrate` sur une base neuve, lancez
l’initialisation :

```sh
facet seed:core
```

Cette commande initialise les doctypes du noyau et le registre des devises.
Elle est idempotente et sans risque à chaque démarrage.

### 2. Annuler une migration au besoin

```sh
facet migrate:down            # annule la dernière migration appliquée
facet migrate:down 0008       # annule tout ce qui a été appliqué après 0008 ; 0008 reste appliqué
facet migrate:down --yes      # passe la demande de confirmation
```

Règles :

- La cible accepte le nom de fichier complet ou son préfixe numérique
  `NNNN`.
- Les migrations s’annulent dans l’ordre inverse des noms de fichiers.
  Chaque annulation exécute la section `-- DOWN` du fichier et supprime sa
  ligne de `_migrations` dans une seule transaction.
- La commande affiche le plan et demande confirmation. Elle refuse de poser
  la question quand stdin n’est pas un terminal : les appels scriptés
  passent `--yes`.
- Le plan est validé avant toute exécution. Une cible inconnue, une cible
  non appliquée ou une migration sans section `-- DOWN` exploitable
  interrompt la commande sans aucun changement.
- Une migration annulée se réapplique normalement au prochain
  `facet migrate`.

### 3. Respecter la règle de l’ajout seul

Après la première mise en production, le dossier `db/migrations/` n’accepte
que les ajouts. Ne modifiez, ne renumérotez et ne fusionnez jamais une
migration qu’une base installée a déjà appliquée. La table `_migrations`
conserve les noms des fichiers appliqués. Un fichier modifié désynchronise
chaque base déployée de l’historique du dépôt, et un binaire recompilé
embarque alors un SQL en désaccord avec son propre historique.

### 4. Garder chaque session en UTC

Chaque colonne de timestamp stocke l’heure en UTC, sans fuseau horaire
attaché. Deux couches fixent le fuseau de la session :

1. L’application ajoute `TimeZone=UTC` aux options de chaque connexion du
   pool.
2. La migration `0001_document_store.sql` a défini la valeur par défaut du
   rôle applicatif avec `ALTER ROLE CURRENT_USER SET timezone TO 'UTC'`.

  Un client qui se connecte avec un autre rôle reçoit la valeur par défaut
  du serveur. Il doit alors fixer `TimeZone=UTC` lui-même, dans les options
  de connexion ou avec `ALTER ROLE ... SET`.

:::caution
Une session hors UTC ne corrompt pas les lectures, mais elle fausse les
écritures. Les valeurs par défaut de `now()` et les conversions
`text::timestamp` enregistrent l’heure locale, et PostgreSQL abandonne le
décalage sans avertissement. Fixez le fuseau sur chaque client externe :
`psql`, les outils de BI et les scripts ponctuels.
:::

## Exemple

Une mise à niveau d’une version à la suivante sur une installation en
conteneurs :

```sh
docker compose -f docker/compose.prod.yml pull
docker compose -f docker/compose.prod.yml up -d
```

La nouvelle image du backend s’amorce, applique ses migrations embarquées,
réexécute l’initialisation des doctypes du noyau, puis le serveur démarre.
Aucune étape de schéma manuelle n’existe. Si le démarrage signale un échec
de migration après trois tentatives, lisez les logs du backend et corrigez
la cause avant de réessayer.

L’équivalent en passant par les sources :

```sh
make build_release
facet migrate && facet seed:core
# puis redémarrez le processus du serveur
```

## Dépannage

**`migrate:down` s’interrompt sans rien changer.**

La validation du plan a refusé la cible : nom de fichier inconnu,
cible non appliquée, ou section `-- DOWN` inexploitable. Rien n’a été
modifié.

**Une migration ne peut pas être annulée.**

Sa section `-- DOWN` est absente ou vide. Passez par un instantané pour
restaurer.

**Les timestamps sont décalés d’un écart fixe.**

Un client externe écrit avec une session hors UTC. Fixez `TimeZone=UTC`
pour ce rôle ou cette connexion, puis corrigez les lignes faussées à partir
d’un instantané ou d’une réimportation.

**Le démarrage du conteneur échoue à l’étape de migration.**

Le point d’entrée a tenté trois fois. Lisez les logs du backend : une
migration verrouillée, un problème de permissions ou une base injoignable
en sont les causes habituelles.

## Voir aussi

- [Déployer avec des conteneurs](/fr/admin/install/containers/) — la chaîne du
  point d’entrée qui applique les migrations.
- [Amorçage et tâches CLI](/fr/admin/install/bootstrap/) — `migrate`,
  `seed:core` et `db_reset` en contexte.
- [Prérequis système et topologie](/fr/admin/install/requirements/) — la
  version de PostgreSQL dont le schéma a besoin.
- [Revenir en arrière](/fr/admin/history/roll-back/) — le retour arrière des
  documents, un mécanisme distinct de l’annulation des migrations.
- [Faire évoluer un schéma](/fr/build/model/change-a-live-domain/) — le flux côté
  auteur pour les changements de doctypes.
- Internes sur GitHub :
  [migrations.md](https://github.com/wearefacet/facet/blob/main/doc/backend/migrations.md),
  [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md).
