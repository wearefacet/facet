---
title: Amorçage et tâches CLI
description: Lancez la CLI facet pour amorcer une installation, gérer les comptes, récupérer un accès et assurer la maintenance.
audience: [operator]
features: [IAM-12, DOM-24]
sidebar:
  order: 6
verified_at: 008dd880
---

Le binaire du backend sert aussi de CLI d’exploitation. Une seule commande,
`facet`, lance le serveur et toutes les tâches d’amorçage et de maintenance.
Le même binaire se trouve dans l’image du conteneur backendà : un
conteneur éphémère peut donc exécuter n’importe quelle tâche CLI sur
l’instance en place.

## Quand l’utiliser

Exécutez une tâche CLI quandà :

- vous déployez une installation neuve et il faut créer le schéma, les
  doctypes du domaine `core` et le premier administrateur,
- vous créez des comptes ou attribuez des rôles depuis un script,
- vous devez reprendre la main sur une installation qui s’est verrouillée,
- vous lancez des tâches de maintenanceà : relances d’index, purge
  d’artifacts, déplacements de domaine.

## Avant de commencer

- `DATABASE_URL` pointe vers la base de données cible.
- La CLI charge `.env`, puis `.env.{APP_ENV}`, et conserve ensuite les
  valeurs déj à posées dans le shell. `APP_ENV` absent vaut `dev`.
- Une commande qui modifie des données publie ses événements vers Redis en
  quittant. Un échec de publication force le code de sortie 1 :
  l’écriture en base demeure, mais aucun consommateur n’a reçu le
  changement.

## Étapes

### 1. Amorcer une installation neuve

La chaîne sûre fonctionne sur une base vide comme sur une base existanteà :

```sh
facet migrate && facet seed:core
```

`migrate` applique chaque migration en attente. `seed:core` initialise les
doctypes du domaine `core` et le registre des devises. Les deux étapes sont
idempotentesà : les relancer ne change rien. Le point d’entrée du
conteneur exécute cette chaîne à chaque démarrage.

Créez ensuite le premier administrateurà :

```sh
facet seed:admin ops@your-company.tld
```

La commande affiche un mot de passe à usage unique. Il s’affiche une seule
fois, seul un hachage est stocké, et un changement de mot de passe est
imposé à la première connexion. Relancer la commande avec le même courriel
sort en code non nulà : l’amorçage ne réinitialise jamais un
identifiant existant.

`facet db_reset` est l’alternative destructive. Elle détruit la base de
données, la recrée, applique les migrations et initialise les doctypes
`core`. Elle ne crée aucun compte. Ne l’employez que l à où une suppression
est acceptable, et passez `--yes` dans les scriptsà :

```sh
facet db_reset --yes
```

:::caution
`facet seed:dev` écrit l’identifiant de dev connu et est refusée quand
`APP_ENV=production`. En production, la création du premier administrateur
passe uniquement par `seed:admin`. Lancez aussi `seed:dev` après
`seed:core`, jamais seulà : la connexion a besoin des documents de
rôles que `seed:core` crée.
:::

### 2. Gérer les comptes et les rôles

```sh
facet accounts:list                      # every account, one per line
facet accounts:create pat@example.tld --name "Pat Lee" --role editor
facet roles:list                         # every role, id and name
facet roles:add pat@example.tld admin    # account by id or email, role by id or name
```

`accounts:create` affiche un mot de passe à usage unique généré,
exactement comme `seed:admin`. Les deux commandes passent outre le
RBACà: exécutez-les depuis un hôte de confiance.

### 3. Sortir d’un verrouillage d’authentification

`facet auth:mode {hybrid|oidc_only}` épingle le mode d’authentification sur
le document de paramètres. C’est la récupération d’un verrouillage SSO
completà : le seul fournisseur d’identité activé est hors service et
aucune session ne survit. Exécutez-la sur l’hôte, et le nouveau mode
devient actif sur tous les serveurs en même tempsà :

```sh
facet auth:mode hybrid
```

### 4. Lancer les tâches de maintenance

| Commande | Tâche |
| --- | --- |
| `facet index:retry [--domain D] [--doctype T] [--dry-run]` | Relance les constructions d’index gérés qui ont échoué ou sont périmées. |
| `facet artifacts:prune [--hard]` | Marque comme supprimés les artifacts sans propriétaire. `--hard` retire les lignes et les octets. |
| `facet artifacts:reconcile [--dry-run]` | Supprime les objets du magasin sans ligne d’artifact, vieux de plus d’une heure. |
| `facet artifacts:revoke <artifact-id>` | Invalide toutes les URL signées d’un artifact. |
| `facet doctype:reproject <doctype>` | Recalcule la projection de chaque document non supprimé d’un doctype. |
| `facet doctype:migrate-retry <doctype>` | Efface une erreur de migration et relance la migration des documents en retard. |
| `facet cron:list` | Affiche la table des tâches cron : identifiant, clé de planification, expression, prochaine exécution (UTC). |

Voir [Index gérés](/fr/operate/indexes/) pour `index:retry` et
[Stockage des fichiersà : filesystem ou S3](/fr/operate/file-storage/)
pour les commandes d’artifacts.

### 5. Déplacer un domaine entre installations

```sh
facet domain:export hr --output hr.facet-domain
facet domain:import hr.facet-domain --merge
```

L’export ne transporte que des définitionsà : le domaine, ses doctypes
et ses vues. Aucune donnée de document ne voyage. `--merge` met à jour un
domaine existant et crée celui qui manqueà ; le passer est donc
toujours sûr. `--into` renomme le domaine pendant l’import.

### 6. Enchaîner des commandes

Les commandes s’exécutent de gauche à droite en une seule invocation :

```sh
facet db_reset --yes seed:dev
```

Deux règles rendent un enchaînement sûrà :

- une commande qui prend des options doit être la dernière de la
  chaîneà ; tout ce qui la suit lui appartient,
- la chaîne est validée avant l’exécution de la première commandeà ;
  une commande inconnue après une commande destructive sort en code non
  nul avant que quoi que ce soit ne s’exécute.

## Exemple

Un premier amorçage complet sur une base neuve, avec vérification :

```sh
facet migrate && facet seed:core
facet seed:admin ops@your-company.tld
facet accounts:list
```

`accounts:list` affiche le nouveau compte avec le rôle `iam.Roles.admin`.
Connectez-vous avec le mot de passe à usage unique et définissez un vrai
mot de passe quand c’est demandé.

## Dépannage

**La connexion répond `403 "Role not found or disabled"` après
`seed:dev`.**

`seed:dev` a tourné avant `seed:core` : les documents de rôles
n’existent pas. Lancez `facet seed:core`, puis réessayez.

**`db_reset` refuse de s’exécuter dans un script.**

L’entrée standard n’est pas un terminal. Passez `--yes`.

**`seed:admin` sort en code non nul.**

Un compte non supprimé porte déj à ce courriel. Récupérez plutôt l’accès
par le flux de réinitialisation du mot de passe — il exige une livraison
de courriel fonctionnelle.

**Une mutation CLI n’atteint le cache d’aucun serveur en cours.**

La commande sort avec le code 1 quand la publication de l’événement
échoue. Vérifiez l’URL Redis et contrôlez l’état obtenuà ; l’écriture
en base, elle, a réussi.

## Voir aussi

- [Migrations de la base de données](/fr/operate/migrations/) — ce que
  `migrate` et `db_reset` exécutent.
- [Déployer en production](/fr/operate/production/) — l’amorçage que le
  conteneur exécute au démarrage.
- [Index gérés](/fr/operate/indexes/) — la commande `index:retry` en
  détail.
- [Stockage des fichiersà : filesystem ou S3](/fr/operate/file-storage/) —
  les commandes d’artifacts en détail.
- [Gérer les comptes](/fr/govern/accounts-lifecycle/) — les états de
  compte que la CLI crée.
- Internes sur GitHubà :
  [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md),
  [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md).
