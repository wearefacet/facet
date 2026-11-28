---
title: "Sauvegarde et restauration"
description: "Sauvegardez les quatre emplacements d’état de Facet et prouvez une restauration avant d’en avoir besoin."
type: how-to
audience: [operator]
features: [PLT-03, PLT-04]
verified_at: eee55a2
sidebar:
  order: 6
---

Le disque qui porte votre volume PostgreSQL vient de tomber en panne,
ou une mauvaise mise à niveau a rendu les données inutilisables. Ce qui
vous sauve, c’est la sauvegarde prise avant — et Facet ne la prend pas
pour vous. Facet n’embarque aucune fonction de sauvegarde : aucune
commande de sauvegarde, aucun dump planifié, aucune récupération à un
instant donné. La sauvegarde et la restauration sont le travail de
l’opérateur, par conception. PostgreSQL a déjà les outils ; Facet garde
son état dans des emplacements que vous sauvegardez avec ces outils.

Cette page liste exactement quoi protéger, ce que fournit
l’installation conteneurisée livrée, et comment prouver qu’une
restauration fonctionne.

## Avant de commencer

- [Exécuter avec des conteneurs](/fr/admin/install/containers/) — les volumes et les montages que cette page protège.

## Quoi sauvegarder

Quatre éléments portent l’état. Perdez-en un seul, et une partie de
l’installation disparaît définitivement.

| Quoi | Emplacement | Raison |
| --- | --- | --- |
| PostgreSQL | Le volume `pg-data` (ou votre base managée) | L’état durable : chaque document, chaque ligne d’historique, chaque emplacement de secret, les comptes, les rôles, les paramètres. Redis ne porte que des réactions — rien à sauvegarder. |
| Magasin d’artefacts | Le volume `artifact-store`, ou votre bucket S3 | Les fichiers téléversés et les bundles générés vivent hors de la base, par conception. |
| Fichiers de configuration | `config.{env}.yml`, plus tout fichier `.env` à côté | Le fichier est la seule source de vérité de la configuration d’exécution. |
| Secrets | La clé maîtresse du magasin de secrets, et les autres secrets d’environnement | La base stocke des secrets scellés avec AES-256-GCM sous cette clé. La clé ne vit que dans votre environnement. |

Deux de ces éléments méritent un examen plus proche.

**La clé maîtresse du magasin de secrets ouvre la sauvegarde, pas
seulement le démarrage.**
Hachages de mots de passe, identifiants API, graines TOTP — chaque
secret stocké se trouve dans le magasin de secrets PostgreSQL. Les
secrets `sealed` sont chiffrés avec AES-256-GCM sous
`secrets.master_key`. La configuration de production livrée lit cette
clé dans l’environnement : `master_key: !env FACET_SECRETS_MASTER_KEY`.
Restaurez une base sans la clé qui l’a scellée, et chaque emplacement
scellé reste illisible — les connexions échouent, les webhooks perdent
leurs identifiants. Sauvegardez la clé à côté du dump, dans un lieu aux
modes de défaillance différents de celui de la base. La même règle
couvre les autres secrets d’environnement dont le déploiement a besoin,
comme `JWT_SIGNING_KEY`.

**Redis est un bus de réactions, pas un enregistrement.**
Les événements, les verrous de shard et les baux cron passent par lui ;
PostgreSQL porte l’état durable. Un jeu de données Redis perdu coûte
des réactions transitoires, pas des données — les consommateurs se
réparent seuls ou sont réparés. Ne dépensez pas d’effort de sauvegarde
sur lui ; dépensez-le sur PostgreSQL.

## Ce que fournit l’installation livrée

La pile compose de production définit quatre volumes nommés :
`pg-data`, `redis-data`, `caddy-data` et `artifact-store`. Le contenu
d’un volume survit aux redémarrages des conteneurs — c’est tout ce
qu’un volume fait, ce n’est pas une sauvegarde. L’exemple de
configuration backend raccorde le magasin d’artefacts au volume
`artifact-store` à `/data/store`. Pointez `artifact.storage` vers S3 si
votre outillage de sauvegarde couvre déjà le stockage objet.

L’outillage de sauvegarde PostgreSQL fonctionne sans changement.
Utilisez `pg_dump` pour les dumps logiques, `pg_basebackup` ou les
instantanés du fournisseur pour les copies physiques, et l’archivage
WAL pour la récupération à un instant donné. Facet n’utilise que des
fonctions PostgreSQL standard — aucun moteur de stockage personnalisé
ne se met en travers.

## Étapes

### 1. Sauvegarder PostgreSQL sur un calendrier

```sh
docker compose -f docker/compose.prod.yml exec -T postgres \
  pg_dump -U facet -Fc facet > facet-$(date +%F).dump
```

Testez d’abord la commande exacte contre votre déploiement : le nom du
service, l’utilisateur et le nom de la base viennent de votre fichier
compose et de votre environnement. Stockez les dumps hors de la machine
— une sauvegarde sur le même disque que la base ne survit à rien.

### 2. Sauvegarder le magasin d’artefacts

Pour l’adaptateur système de fichiers, copiez ou synchronisez le
répertoire du magasin comme vous sauvegardez tout arbre de fichiers.
Pour S3, utilisez la réplication ou le versionnage de votre bucket.
Alignez la cadence sur la fréquence des téléversements.

### 3. Sauvegarder la configuration et les secrets

Gardez une copie de `config.{env}.yml` et du fichier `.env` portant les
secrets d’environnement — `FACET_SECRETS_MASTER_KEY` avant tout. Ils
changent rarement ; sauvegardez-les à chaque changement, et rangez-les
où seuls les opérateurs peuvent les lire.

### 4. Prouver la restauration avant d’en avoir besoin

Une sauvegarde que vous n’avez jamais restaurée est un espoir, pas une
sauvegarde. Répétez sur une machine jetable :

1. Démarrez un PostgreSQL vide et un magasin d’artefacts vide.
2. Restaurez le dump de la base, puis le contenu du magasin
   d’artefacts.
3. Restaurez le fichier de configuration et les secrets
   d’environnement, clé maîtresse incluse.
4. Démarrez la pile. Le point d’entrée exécute
   `facet migrate && facet seed:core` — les deux sont sûrs sur une base
   existante et à jour.
5. Vérifiez que `GET /Healthcheck` répond `200`, connectez-vous avec un
   compte réel, et ouvrez un document avec une entrée d’historique.

Les étapes 1 à 5 sont tout le test. Notez le temps qu’elles ont pris ;
ce nombre est votre temps de récupération réel, et il appartient à
votre plan de continuité.

### 5. Restaurer pour de vrai

Exécutez les mêmes cinq étapes contre les machines de production. Deux
avertissements :

- N’exécutez pas `db_reset`. Il détruit, recrée et re-migre la base —
  il détruit les données que vous restaurez.
- Laissez tourner les migrations du démarrage. Si la sauvegarde précède
  la version actuelle, le point d’entrée migre le schéma restauré vers
  l’avant au démarrage ; c’est normal et sûr.

## Ce que Facet ne fournit pas

Dites-le simplement, car un auditeur posera la question :

- Aucune commande de sauvegarde ni tâche de sauvegarde planifiée ne
  vient avec le produit.
- Aucune récupération à un instant donné n’est câblée ; si vous en avez
  besoin, configurez vous-même l’archivage WAL sur PostgreSQL.
- Aucune réplication inter-régions ne vient avec la pile.

Le groupe [Maintenir Facet opérationnel](/fr/admin/keep-running/)
couvre tout ce que le produit exécute pour vous ; la récupération après
perte de données n’est pas sur cette liste.

## Voir aussi

- [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/) — le contrôle à lancer en premier après toute restauration.
- [Mettre à niveau Facet](/fr/admin/keep-running/upgrades/) — la règle d’instantané avant annulation sur laquelle cette page s’appuie.
- [Exécuter avec des conteneurs](/fr/admin/install/containers/) — les volumes et les montages que cette page protège.
- [Passer en production](/fr/admin/install/production/) — la liste de contrôle qui vous mène ici avant la mise en service.
