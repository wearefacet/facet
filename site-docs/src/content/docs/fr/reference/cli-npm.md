---
title: CLI des apps Facet
description: Commandes et options de l'outil développeur @facetapp/cli.
audience: [developer]
type: reference
features: [APP-09]
verified_at: f1409cdc
---

> Généré depuis `packages/cli` par `make gen-docs-npm-cli`. Ne modifiez pas ce fichier à la main.

Le paquet npm `@facetapp/cli` déploie un dossier de build statique comme nouvelle révision d'une app Facet. Il liste et active les révisions, et gère la connexion à une instance Facet. Aucune installation n'est nécessaire : lancez les commandes via `pnpx @facetapp/cli`. Le paquet demande Node 20 ou plus récent. Les commandes lisent `facet.config.json` dans le répertoire courant ; `init` l'écrit.

## Commandes

| Commande | Options | Rôle |
| --- | --- | --- |
| `init` | `--yes`, `--app <slug>`, `--build <dir>`, `--server <url>` | Write a facet.config.json file for this project. |
| `setup-dev` | `--dir <path>`, `--hostname <name>`, `--port <n>`, `--watch <dir>`, `--no-watch`, `--no-start`, `--no-key`, `--force`, `--yes` | Scaffold, start, and seed a local dev instance, then fetch an API key. |
| `connect` | `--target <name>`, `--role <name>` | Sign in to a Facet instance and optionally store a project API key. |
| `apikey` | `--target <name>` | Print the stored API key for this project (for Authorization: Bearer). |
| `login` | `--target <name>` | Sign in to a Facet instance and store the session. |
| `logout` | `--target <name>` | Remove the stored session for a Facet instance. |
| `whoami` | `--target <name>` | Show the stored account, role, instance, and active revision. |
| `deploy` | `--target <name>`, `--note <text>`, `--no-activate` | Upload the build folder as a new deployment of the app. |
| `releases` | `--target <name>` | List the deployments of the app, newest first. |
| `rollback <revision>` | `--target <name>` | Set an older revision as the active deployment. |
| `help [command]` | — | display help for command |

## Sortie d'aide

Les blocs ci-dessous sont les textes d'aide capturés du paquet.

### `facet-cli`
```text
Usage: facet-cli [options] [command]

Command-line interface for Facet.

Options:
  -V, --version                  output the version number
  -h, --help                     display help for command

Commands:
  init [options]                 Write a facet.config.json file for this
                                 project.
  setup-dev [options]            Scaffold, start, and seed a local dev instance,
                                 then fetch an API key.
  connect [options]              Sign in to a Facet instance and optionally
                                 store a project API key.
  apikey [options]               Print the stored API key for this project (for
                                 Authorization: Bearer).
  login [options]                Sign in to a Facet instance and store the
                                 session.
  logout [options]               Remove the stored session for a Facet instance.
  whoami [options]               Show the stored account, role, instance, and
                                 active revision.
  deploy [options]               Upload the build folder as a new deployment of
                                 the app.
  releases [options]             List the deployments of the app, newest first.
  rollback [options] <revision>  Set an older revision as the active deployment.
  help [command]                 display help for command
```

### `facet-cli init`
```text
Usage: facet-cli init [options]

Write a facet.config.json file for this project.

Options:
  --yes           Create the app without asking for confirmation.
  --app <slug>    App slug to write to the config.
  --build <dir>   Build folder to upload (default: dist).
  --server <url>  Facet instance URL to add as the default target.
  -h, --help      display help for command
```

### `facet-cli setup-dev`
```text
Usage: facet-cli setup-dev [options]

Scaffold, start, and seed a local dev instance, then fetch an API key.

Options:
  --dir <path>       Folder to scaffold (default: current directory).
  --hostname <name>  Edge hostname (default: facet.localhost).
  --port <n>         Edge HTTPS port (default: 3443).
  --watch <dir>      Folder to watch for domain bundles (default: domains).
  --no-watch         Do not set up the domain watcher.
  --no-start         Write the stack files but do not start it.
  --no-key           Do not fetch an API key after the stack starts.
  --force            Overwrite an existing dev stack in the folder.
  --yes              Non-interactive: take every default.
  -h, --help         display help for command
```

### `facet-cli connect`
```text
Usage: facet-cli connect [options]

Sign in to a Facet instance and optionally store a project API key.

Options:
  --target <name>  Named target from facet.config.json to connect to.
  --role <name>    Role to pin the key to (id or name; default: your active
                   role).
  -h, --help       display help for command
```

### `facet-cli apikey`
```text
Usage: facet-cli apikey [options]

Print the stored API key for this project (for Authorization: Bearer).

Options:
  --target <name>  Named target from facet.config.json to read the key for.
  -h, --help       display help for command
```

### `facet-cli login`
```text
Usage: facet-cli login [options]

Sign in to a Facet instance and store the session.

Options:
  --target <name>  Named target from facet.config.json to sign in to.
  -h, --help       display help for command
```

### `facet-cli logout`
```text
Usage: facet-cli logout [options]

Remove the stored session for a Facet instance.

Options:
  --target <name>  Named target from facet.config.json to sign out of.
  -h, --help       display help for command
```

### `facet-cli whoami`
```text
Usage: facet-cli whoami [options]

Show the stored account, role, instance, and active revision.

Options:
  --target <name>  Named target from facet.config.json to ask.
  -h, --help       display help for command
```

### `facet-cli deploy`
```text
Usage: facet-cli deploy [options]

Upload the build folder as a new deployment of the app.

Options:
  --target <name>  Named target from facet.config.json to deploy to.
  --note <text>    Short note to attach to the new deployment.
  --no-activate    Keep the new deployment inactive after the upload.
  -h, --help       display help for command
```

### `facet-cli releases`
```text
Usage: facet-cli releases [options]

List the deployments of the app, newest first.

Options:
  --target <name>  Named target from facet.config.json to ask.
  -h, --help       display help for command
```

### `facet-cli rollback`
```text
Usage: facet-cli rollback [options] <revision>

Set an older revision as the active deployment.

Options:
  --target <name>  Named target from facet.config.json to ask.
  -h, --help       display help for command
```

## Voir aussi

- [Premiers pas avec le CLI dev](/fr/build/apps/quickstart/) — premier déploiement sans installation.
- [Héberger et déployer des apps](/fr/build/apps/host/deploy/) — ce qu'est un déploiement et comment fonctionne l'activation.
