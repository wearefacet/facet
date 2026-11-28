---
type: tutorial
title: Lancer Facet
description: Lancer Facet sur votre machine avec une commande, vous connecter comme administrateur et suivre la visite de bienvenue.
audience: [evaluator, operator]
features: [PLT-16, PLT-01, IAM-12, FE-01, FE-19, DOM-24]
sidebar:
  order: 1
verified_at: c34885a
---

Vous voulez Facet en marche devant vous, sans cloner le dépôt. Une commande
vous donne une instance complète : PostgreSQL, Redis, le backend, le frontend,
et Caddy qui termine TLS en périphérie — cinq conteneurs, tous démarrés pour
vous. Les deux images de Facet viennent de GHCR — vous ne les compilez pas.
À la fin de ce tutoriel, l’administrateur est connecté et la visite de
bienvenue a présenté le produit.

**Vous obtenez :** une instance Facet en marche avec un compte administrateur.
**Durée :** environ 10 minutes, plus le premier téléchargement des images.
**Prérequis :** [Docker avec Compose](https://docs.docker.com/compose/),
Node 20+ et un navigateur. Vérifiez les deux avec `docker compose version` et
`node --version`.

## 1. Démarrez la pile

Lancez la commande de la CLI dans un dossier vide. Elle écrit les fichiers de
la pile, démarre les conteneurs, crée l’administrateur et récupère une clé
API :

```sh
pnpx @facetapp/cli setup-dev
```

Trois questions, chacune avec une valeur par défaut — appuyez trois fois sur
Entrée :

```text
Hostname [facet.localhost]:
HTTPS port [3443]:
Watch a folder for domain bundles? (Y/n):
```

La commande écrit ensuite `compose.yml`, `.env` avec des secrets générés,
`config.dev.yml`, `Caddyfile.prod` et `facet.config.json`, puis lance
`docker compose up -d --wait`. Le premier lancement récupère cinq images, ce
qui prend quelques minutes. `--wait` rend la main quand chaque service se
déclare sain.

`setup-dev` écrit aussi `.gitignore` et lance `git init`, pour que les secrets
restent hors du contrôle de version. Pour générer les fichiers sans démarrer
la pile, ajoutez `--no-start` ; pour accepter toutes les valeurs par défaut
sans question, ajoutez `--yes`.

## 2. Connectez-vous

Ouvrez `https://facet.localhost:3443`.

Votre navigateur signale un problème de certificat. Caddy le délivre depuis
sa propre autorité de certification interne — c’est attendu pour un nom en
`.localhost`. Acceptez l’avertissement pour continuer.

Connectez-vous avec l’administrateur de dev :

- **E-mail** : `admin@example.tld`
- **Mot de passe** : `admin`

`setup-dev` a aussi affiché les deux, avec l’URL, dans son récapitulatif. Cet
identifiant est une valeur par défaut de dev : il saute l’étape de changement
de mot de passe, et la plateforme refuse de le créer sur une instance de
production.

:::note
La commande `setup-dev` récupère une clé API via l’écran de consentement OAuth
dans votre navigateur. Si cette demande apparaît, choisissez le rôle admin et
cliquez sur « Autoriser ». La clé atterrit dans `.facet.local.json` pour les
appels `facet-cli` ; vous n’en avez pas besoin pour ce tutoriel.
:::

Vous arrivez sur le tableau de bord, connecté comme administrateur.

## 3. Suivez la visite de bienvenue

La première connexion ouvre la visite de bienvenue : sept étapes qui
présentent Facet — la couche de gouvernance, les domaines, le Builder, les
rôles, le journal d’audit, les intégrations — et se terminent sur « Votre
premier domaine », avec trois boutons : « Créer un domaine », « Importer un
bundle » et « Terminé ».

![The welcome tour opens on the dashboard at its first step, A governance layer.](/screens/build/run-facet-2.png)

Cliquez sur « Suivant » à travers les sept étapes, ou cochez « Ne plus
afficher » pour qu’elle ne s’ouvre plus à votre prochaine connexion. La visite
vous laisse sur le tableau de bord, où la barre latérale propose « Builder »
et « Configurer ». Pour revoir la visite, réactivez « Afficher la visite de
bienvenue » dans « Paramètres → Visite de bienvenue ».

## Ce que vous avez appris

- Une commande, `facet-cli setup-dev`, démarre une instance Facet complète —
  cinq conteneurs, aucun clonage du dépôt, aucune compilation.
- Le backend crée son propre schéma — migrations et doctypes de base — au
  premier démarrage.
- L’administrateur de dev est `admin@example.tld` / `admin` ; une instance de
  production utilise `seed:admin` et un mot de passe à usage unique.
- La visite de bienvenue présente le produit à la première connexion.

## Dépannage

### La commande s’arrête avant le démarrage de la pile

`setup-dev` échoue quand Docker manque ou quand le dossier contient déjà une
pile. Vérifiez Docker avec `docker compose version`. Pour un dossier déjà
rempli, relancez avec `--force` pour écraser les fichiers de la pile, ou
passez `--dir` pour choisir un autre dossier.

### Le backend ne démarre pas

Lisez le journal de démarrage — il nomme la valeur manquante ou erronée :

```sh
docker compose logs backend
```

### Le navigateur n’atteint pas `facet.localhost`

Essayez l’adresse avec le port explicite, `https://facet.localhost:3443`. Si
vous avez répondu un autre port HTTPS à la première question, utilisez ce
port.

### La connexion est refusée

L’identifiant de dev est `admin@example.tld` / `admin`. Si vous réinitialisez
la base de données (`docker compose run --rm backend db_reset --yes
seed:dev`), le même identifiant fonctionne à nouveau.

## Voir aussi

- [Votre première heure](/fr/build/first-hour/) — le parcours que ce tutoriel
  ouvre.
- [Déployer en production](/fr/admin/install/production/) — un hôte réel, un
  nom d’hôte réel, et `seed:admin` au lieu de l’identifiant de dev.
- [Exécuter avec des conteneurs](/fr/admin/install/containers/) — les images,
  le montage de la configuration et la terminaison TLS en périphérie, en
  détail.
- [La CLI développeur `facet-cli`](/fr/reference/cli-npm/) — `setup-dev` et
  les autres commandes, avec leurs options.
- [Clés du fichier de configuration](/fr/reference/config-keys/) — chaque clé
  que le `config.dev.yml` généré pose, avec son type et sa valeur par défaut.
- [Sécurité et gouvernance](/fr/discover/security/)

## Pour aller plus loin

Facet tourne. Dans
[Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), vous
construisez le domaine `equipment` de Brightwater dans le Builder.
