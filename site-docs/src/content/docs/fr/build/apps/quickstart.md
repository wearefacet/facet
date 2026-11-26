---
title: Démarrage rapide avec la CLI dev
description: Installez, connectez-vous et déployez un premier build avec la CLI facet en quelques commandes.
audience: [developer]
features: [APP-09]
sidebar:
  order: 2
verified_at: a77c6171
---

L’interface en ligne de commande (CLI) `@facetapp/cli` transforme un dossier
de build statique en révision déployée d’une app Facet. Il n’y a pas d’étape
d’installation : lancez chaque commande via `pnpx`. La CLI demande Node 20 ou
plus récent.

> **Pour les agents :** tout le parcours tient en trois commandes :
> `pnpx @facetapp/cli init`, puis `pnpx @facetapp/cli login`, puis
> `pnpx @facetapp/cli deploy --note "first build"`. La configuration se trouve
> dans `facet.config.json` (clés `app`, `outDir`) ; la session, dans
> `~/.config/facet/auth.json` (mode 600). Pour l’automatisation, mettez un
> token d’accès dans `FACET_TOKEN` ; il gagne sur toute session enregistrée et
> n’est jamais rafraîchi. Le déploiement est un `POST /Api/app/:id/deploy`
> multipart ; la route répond `{id, revision, activated, files}`.

## Quand l’utiliser

Utilisez la CLI quand :

- Vous déployez un premier build statique sur une instance Facet.
- Vous poussez un nouveau build depuis votre machine ou depuis l’intégration
  continue (CI).
- Vous listez les releases et ramenez un build défectueux en arrière.

## Avant de commencer

- Une instance Facet que vous pouvez joindre en HTTPS, et un compte dessus.
- Un rôle qui porte `deploy` sur `app.App`. La CLI se connecte avec votre
  compte, et vous élisez un rôle sur l’écran de consentement. Le rôle `admin`
  créé par l’initialisation porte `deploy` ; le rôle `editor` pré-créé non.
- Un dossier de build statique. N’importe quel générateur de site statique
  convient.
- Node 20 ou plus récent.

## Étapes

### 1. Écrivez la configuration

```sh
pnpx @facetapp/cli init
```

La commande demande trois valeurs : le slug de l’app, le dossier de build et
l’URL de l’instance. Elle écrit `facet.config.json` à la racine du projet.

Avec une session enregistrée, `init` lit l’app par son slug. Quand cette app
n’existe pas, la CLI propose de la créer. La création demande `write` sur
`app.App`. Une app créée est un brouillon : activez-la dans le tableau de
bord avant le premier déploiement — voir
[Enregistrer une app](/fr/build/apps/connect/register/).

Sans session enregistrée, `init` écrit la configuration et s’arrête. Lancez
`login` ensuite.

### 2. Connectez-vous

```sh
pnpx @facetapp/cli login
```

La commande ouvre un navigateur sur l’écran de consentement OAuth. Le flux
est celui du code d’autorisation avec PKCE (Proof Key for Code Exchange). La
méthode de challenge est S256. La CLI démarre un serveur de bouclage à usage
unique et y reçoit le code.

La CLI se connecte par l’enregistrement `facet-cli` pré-créé. Cet
enregistrement n’accepte que des adresses de redirection en bouclage :
`http://localhost:*`, `http://127.0.0.1:*` et `http://[::1]:*`.

La session atterrit dans `~/.config/facet/auth.json` avec le mode `600`.
`$XDG_CONFIG_HOME` déplace l’emplacement. Le fichier porte une entrée par URL
d’instance.

:::note[Refresh des tokens]
Les tokens d’accès ont une vie courte. La CLI ne rafraîchit une session
enregistrée que lorsqu’elle approche de son expiration ou après une réponse
`401`. Elle ne rafraîchit jamais par anticipation, car le serveur impose un
plancher entre deux refresh. Les refresh tokens tournés sont aussitôt
re-stockés.
:::

### 3. Construisez et déployez

Construisez votre app avec n’importe quel générateur de site statique. Puis
lancez :

```sh
pnpx @facetapp/cli deploy --note "first build"
```

La commande parcourt le dossier de build. Elle saute `node_modules`, `.git` et
`.DS_Store`. Elle téléverse une requête multipart et active la nouvelle
révision. Elle affiche la révision attribuée et l’URL de l’app ; le schéma et
le port suivent l’URL de l’instance.

Passez `--no-activate` pour téléverser une révision qui reste dormante :

```sh
pnpx @facetapp/cli deploy --no-activate
```

### 4. Vérifiez la session

```sh
pnpx @facetapp/cli whoami
```

La commande affiche l’instance, le compte derrière le token enregistré, le
rôle actif et la révision active de l’app.

### 5. Gérez les releases

```sh
pnpx @facetapp/cli releases
```

La liste montre les déploiements de l’app, de la révision la plus récente à

la plus ancienne. Le déploiement actif porte un `*`.

Ramenez un build défectueux en arrière par révision :

```sh
pnpx @facetapp/cli rollback 2
```

La commande pointe `active_deployment` vers le déploiement de révision `2`.
Une révision inconnue échoue avec la liste de celles qui existent.

Déconnectez-vous quand vous avez fini :

```sh
pnpx @facetapp/cli logout
```

La commande retire la session enregistrée de l’instance. Elle est idempotente.

### 6. Déployez depuis la CI

Mettez un token d’accès dans l’environnement de la CI :

```sh
export FACET_TOKEN="paste-an-access-token"
pnpx @facetapp/cli deploy --note "ci build 42"
```

Le token d’environnement gagne sur toute session enregistrée. La CLI ne le
rafraîchit jamais. À son expiration, l’exécution échoue avec l’invite de
reconnexion. Mettez un token neuf dans le secret CI avant la prochaine
exécution.

## Exemple

Ce `facet.config.json` configure deux cibles :

```json
{
  "app": "myapp",
  "outDir": "dist",
  "spa": true,
  "targets": {
    "staging": { "url": "https://staging.facet.example.tld" },
    "prod": { "url": "https://facet.example.tld" }
  },
  "defaultTarget": "staging"
}
```

| Champ | Requis | Signification |
| --- | --- | --- |
| `app` | oui | Le slug de l’app sur l’instance Facet, par exemple `myapp`. |
| `outDir` | oui | Le dossier de build à téléverser, relatif à la racine du projet. |
| `spa` | non | Indique si le déploiement se comporte comme une app monopage. Par défaut `true`. |
| `targets` | non | Des instances Facet nommées. Chacune porte une `url`. |
| `defaultTarget` | non | La cible employée quand aucun drapeau `--target` n’est passé. |

Choisissez une cible avec `--target` :

```sh
pnpx @facetapp/cli deploy --target prod --note "release 1.0"
```

Sans le drapeau, la CLI emploie `defaultTarget`. Sans les deux, la commande
échoue et liste les cibles disponibles.

## Dépannage

La CLI affiche un message par échec :

| Message | Cause et étape suivante |
| --- | --- |
| `No facet.config.json in <root>` | Pas de fichier de configuration. Lancez `init` ou placez-vous à la racine du projet. |
| `facet.config.json is not valid JSON` | Corrigez la syntaxe JSON. |
| `has no "app"/"outDir" value` | Renseignez le champ manquant dans `facet.config.json`. |
| `Unknown target "x"… Available targets: …` | `--target` ou `defaultTarget` ne nomme rien. Employez un nom listé. |
| `No stored session for <instance>` | Non connecté. Lancez `login`. |
| `Run "pnpx @facetapp/cli login" to sign in again.` | La session a expiré ou a été révoquée, et le refresh a échoué. Reconnectez-vous. |
| `No app with slug "x" on <instance>` | Le slug `app` de la configuration ne correspond à aucune app de l’instance. Créez-la ou corrigez le slug. |
| `The build folder "x" does not exist` | `outDir` pointe vers un dossier absent. Vérifiez la configuration. |
| `holds no files to deploy` | Le dossier de build est vide. Construisez d’abord. |
| `HTTP 422 from /api/app/…/deploy: …` | Le serveur a refusé le téléversement. Une app en brouillon ou désactivée est la cause habituelle ; un chemin de fichier refusé est l’autre. |
| `Cannot reach <instance>` | Échec réseau. Vérifiez l’URL et la connectivité. |

**Une app neuve répond sans fin `HTTP 422` au déploiement.**

Une app créée reste un brouillon jusqu’à ce qu’un opérateur l’active. Activez
l’app dans le tableau de bord, puis déployez de nouveau. Voir
[Enregistrer une app](/fr/build/apps/connect/register/).

**Une exécution CI échoue avec l’invite de reconnexion.**

`FACET_TOKEN` a expiré. La CLI ne rafraîchit jamais un token d’environnement.
Mettez un token d’accès neuf dans le secret CI.

## Voir aussi

- [Déployer votre frontend](/fr/build/apps/host/deploy/) — le modèle de
  déploiement derrière ces commandes.
- [Enregistrer une app](/fr/build/apps/connect/register/) — le statut de l’app, le
  brouillon et l’activation.
- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/build/apps/data/sdk/) — appelez
  l’API depuis le code de l’app.
- Le README de la CLI sur GitHub :
  [packages/cli/README.md](https://github.com/wearefacet/facet/blob/main/packages/cli/README.md).
- Le contrat du backend sur GitHub :
  [doc/packages/cli.md](https://github.com/wearefacet/facet/blob/main/doc/packages/cli.md).
