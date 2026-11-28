---
title: Premier démarrage et amorçage
description: Amorcez une installation neuve — migrations, données initiales du domaine core, premier administrateur et tâches d’exploitation.
type: how-to
audience: [operator]
features: [IAM-12, DOM-24]
sidebar:
  order: 3
verified_at: eee55a2
---

Votre pile tourne et la base de données est vide. Facet livre un binaire qui fait deux métiers : il exécute le serveur, et il exécute chaque tâche d’amorçage et de maintenance. Le même binaire se trouve dans l’image de conteneur du backend, donc un conteneur ponctuel exécute n’importe quelle tâche contre la pile en place.

## Quand l’utiliser

Exécutez une tâche CLI quand :

- Vous déployez une installation neuve et il faut le schéma, les doctypes du domaine `core` et le premier administrateur.
- Vous créez des comptes ou attribuez des rôles depuis un script.
- Vous devez reprendre la main sur une installation qui s’est verrouillée.
- Vous lancez des tâches de maintenance : relances d’index, purge d’artefacts, déplacements de domaine.

## Avant de commencer

- `DATABASE_URL` pointe vers la base de données cible.
- La CLI charge `.env`, puis `.env.{APP_ENV}`, et conserve ensuite les valeurs déjà posées dans le shell. `APP_ENV` absent vaut `dev`.
- Une commande qui modifie des données publie ses événements vers Redis en quittant. Un échec de publication force le code de sortie 1 : l’écriture en base demeure, mais aucun consommateur n’a reçu le changement.
- Dans l’image de version, le binaire réside à `/app/facet` et n’est pas sur le `PATH`. Une tâche en conteneur ponctuel passe par l’entrypoint — voir [Passer en production](/fr/admin/install/production/) pour la forme exacte.

## Étapes

### 1. Amorcer une installation neuve

La chaîne sûre fonctionne sur une base vide comme sur une base existante :

```sh
facet migrate && facet seed:core
```

`migrate` applique chaque migration en attente. `seed:core` initialise les doctypes `core` et le registre des devises. Les deux étapes sont idempotentes : les relancer ne change rien. L’entrypoint du conteneur exécute cette chaîne à chaque démarrage du serveur.

Créez ensuite le premier administrateur :

```sh
facet seed:admin ops@your-company.tld
```

La commande affiche un mot de passe à usage unique. Il s’affiche une seule fois, seul un hachage est stocké, et un changement de mot de passe est imposé à la première connexion. Relancer la commande avec le même courriel sort en code non nul : l’amorçage ne réinitialise jamais un identifiant existant. Vous pouvez aussi définir `SEED_ADMIN_EMAIL` au lieu de passer l’adresse.

`facet db_reset` est l’alternative destructive. Il détruit la base, la recrée, applique les migrations et initialise les doctypes `core`. Il ne crée aucun compte. Utilisez-le seulement là où une suppression est acceptable, et passez `--yes` dans les scripts :

```sh
facet db_reset --yes
```

:::caution
`facet seed:dev` écrit l’identifiant de dev connu et est refusé quand `APP_ENV=production`. La création du premier administrateur en production passe uniquement par `seed:admin`. Lancez aussi `seed:dev` après `seed:core`, jamais seul : la connexion a besoin des documents de rôles que l’initialisation du `core` crée.
:::

### 2. Gérer les comptes et les rôles

```sh
facet accounts:list                      # chaque compte, une par ligne
facet accounts:create pat@example.tld --name "Pat Lee" --role editor
facet roles:list                         # chaque rôle, id et nom
facet roles:add pat@example.tld admin    # compte par id ou courriel, rôle par id ou nom
```

`accounts:create` affiche un mot de passe à usage unique généré, exactement comme `seed:admin`. Les deux commandes passent outre le RBAC : exécutez-les depuis un hôte de confiance.

### 3. Sortir d’un verrouillage d’authentification

`facet auth:mode {hybrid|oidc_only}` épingle le mode d’authentification sur le document de paramètres. C’est la récupération d’un verrouillage full-OIDC : le seul fournisseur d’identité activé est hors service et aucune session ne survit. Exécutez-le sur l’hôte, et le nouveau mode devient actif sur tous les serveurs en même temps :

```sh
facet auth:mode hybrid
```

### 4. Lancer les tâches de maintenance

| Commande | Tâche |
| --- | --- |
| `facet index:retry [--domain D] [--doctype T] [--dry-run]` | Relance les constructions d’index gérés en échec ou périmées. |
| `facet artifacts:prune [--hard]` | Marque comme supprimés les artefacts sans propriétaire. `--hard` retire les lignes et les octets. |
| `facet artifacts:reconcile [--dry-run]` | Supprime les objets du magasin sans ligne d’artefact, vieux de plus d’une heure. |
| `facet artifacts:revoke <artifact-id>` | Invalide toutes les URL signées d’un artefact. |
| `facet doctype:reproject <doctype>` | Recalcule la projection de chaque document en direct d’un doctype. |
| `facet doctype:migrate-retry <doctype>` | Efface une erreur de migration et relance la migration en retard. |
| `facet cron:list` | Affiche la table des tâches cron : id, clé de planification, expression, prochaine exécution (UTC). |

Voir [Index](/fr/admin/keep-running/indexes/) pour `index:retry` et [Stockage des fichiers](/fr/admin/configure/file-storage/) pour les commandes d’artefacts.

### 5. Déplacer un domaine entre installations

```sh
facet domain:export hr --output hr.facet-domain
facet domain:import hr.facet-domain --merge
```

L’export ne transporte que des définitions : le domaine, ses doctypes et ses vues. Aucune donnée de document ne voyage. `--merge` met à jour un domaine existant et crée celui qui manque, donc le passer est toujours sûr. `--into` renomme le domaine pendant l’import.

### 6. Enchaîner des commandes

Les commandes s’exécutent de gauche à droite en une seule invocation :

```sh
facet db_reset --yes seed:dev
```

Deux règles rendent un enchaînement sûr :

- Une commande qui prend des options doit être la dernière de la chaîne. Tout ce qui la suit lui appartient.
- La chaîne est validée avant l’exécution de la première commande. Une commande inconnue après une commande destructive sort en code non nul avant que quoi que ce soit ne s’exécute.

## Exemple

Un premier amorçage complet sur une base neuve, avec vérification :

```sh
facet migrate && facet seed:core
facet seed:admin ops@your-company.tld
facet accounts:list
```

`accounts:list` affiche le nouveau compte avec le rôle `iam.Roles.admin`. Connectez-vous avec le mot de passe à usage unique et définissez un vrai mot de passe quand c’est demandé.

## Dépannage

**La connexion répond `403 "Role not found or disabled"` après `seed:dev`.**

`seed:dev` a tourné avant `seed:core` : les documents de rôles n’existent pas. Lancez `facet seed:core`, puis réessayez.

**`db_reset` refuse de s’exécuter dans un script.**

L’entrée standard n’est pas un terminal. Passez `--yes`.

**`seed:admin` sort en code non nul.**

Un compte en direct porte déjà ce courriel. Récupérez plutôt l’accès par le flux de réinitialisation du mot de passe — il exige une livraison de courriel fonctionnelle.

**Une mutation CLI n’atteint le cache d’aucun serveur en cours.**

La commande sort avec le code 1 quand la publication de l’événement échoue. Vérifiez l’URL Redis et contrôlez l’état obtenu ; l’écriture en base, elle, a réussi.

## Voir aussi

- [Migrations de la base de données](/fr/admin/keep-running/migrations/) — ce que `migrate` et `db_reset` exécutent.
- [Passer en production](/fr/admin/install/production/) — l’amorçage à l’intérieur de la voie conteneurs.
- [Index](/fr/admin/keep-running/indexes/) — la commande `index:retry` en détail.
- [Stockage des fichiers](/fr/admin/configure/file-storage/) — les commandes d’artefacts en détail.
- [Gérer les comptes](/fr/admin/people/accounts/) — les états de compte que la CLI crée.
- Internes sur GitHub : [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md), [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md).
- [Sécurité et gouvernance](/fr/discover/security/)
- [facet CLI](/fr/reference/cli-facet/)
