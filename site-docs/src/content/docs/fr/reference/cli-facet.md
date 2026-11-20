---
title: CLI facet
description: Chaque commande du CLI facet, avec son rôle et sa gestion des options.
audience: [developer, operator]
features: [PLT-11, IAM-12, DOM-18]
sidebar:
  order: 2
verified_at: 008dd880
---

> Généré depuis `src/cli/commands.cr` par `make gen-docs-cli`. Ne modifiez pas ce fichier à la main.

Cette page sert à trouver une commande `facet` et à vérifier comment elle gère ses options.

Un seul appel `facet` peut enchaîner plusieurs commandes : `facet db_reset --yes seed:dev`.
Une commande qui consomme ses propres options lit tous les jetons suivants comme ses options.
Une telle commande doit donc être la dernière de la chaîne.
Chaque autre commande ne prend que ses options préfixées d’un tiret, et la chaîne continue après elles.
`server` est la commande par défaut et démarre le serveur HTTP.

| Commande | Rôle | Options |
|---|---|---|
| `accounts:create` | Create an account and print a one-time password (run standalone to pass email and options) | consomme ses propres options |
| `accounts:list` | List accounts (id, email, display name, status, roles) | — |
| `artifacts:prune` | Soft-delete (or --hard delete) artifacts with no live owner or recent reference | consomme ses propres options |
| `artifacts:reconcile` | Delete orphaned objects from the artifact store (run standalone to pass options) | consomme ses propres options |
| `artifacts:revoke` | Revoke every signed URL for an artifact (run standalone to pass the artifact id) | consomme ses propres options |
| `auth:mode` | Pin the authentication mode on the SystemSettings document (run standalone: facet auth:mode {hybrid\|oidc_only}) | consomme ses propres options |
| `db_reset` | Drop, recreate and migrate the database (asks to confirm; --yes skips) | — |
| `doctype:migrate-retry` | Re-run lazy migration for documents blocked by a meta.migration_error marker | consomme ses propres options |
| `doctype:reproject` | Re-project a doctype's search/links/display_name columns for every live document | consomme ses propres options |
| `domain:export` | Export a domain definition to a directory or .tar.gz (run standalone to pass options) | consomme ses propres options |
| `domain:import` | Import a domain definition from a directory or .tar.gz (run standalone to pass options) | consomme ses propres options |
| `index:retry` | Retry failed index creations (run standalone to pass options) | consomme ses propres options |
| `migrate` | Run database migrations | — |
| `migrate:down` | Revert applied migrations (run standalone to pass a target) | consomme ses propres options |
| `roles:add` | Assign a role to an account (run standalone to pass account and role) | consomme ses propres options |
| `roles:list` | List roles (id, name) | — |
| `seed:admin` | Create the first admin with a generated one-time password (run standalone to pass the email) | consomme ses propres options |
| `seed:core` | Seed core doctypes and the currency registry (idempotent, non-destructive) | — |
| `seed:dev` | Seed the dev admin (admin@example.tld / admin, refused when APP_ENV=production) | — |
| `server` | Start the HTTP server (default; long-running, must be last in a chain) | — |

## Voir aussi

- [Amorçage et tâches CLI](/fr/operate/bootstrap-cli/)
- [Premiers pas avec le CLI dev](/fr/apps/quickstart-dev-cli/)
