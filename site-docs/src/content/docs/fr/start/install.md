---
title: Installer pour le développement
description: Monter un environnement de développement Facet local, depuis les sources.
audience: [developer]
features: [PLT-01, PLT-16, IAM-12, DOM-24]
sidebar:
  order: 6
verified_at: 7a6cb462
---

Facet tourne depuis les sources sur Linux et macOS. Si vous voulez seulement
essayer le produit, prenez la pile Docker Compose — voir
[Déployer en production](/fr/operate/production/).

## Prérequis

Installez d’abord ces outils. Le tableau dit à quoi chacun sert :

| Outil                       | Notes                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------- |
| Crystal 1.21                | La chaîne d’outils du projet. Le shard `agent-cr` demande Crystal 1.19 ou plus récent. |
| PostgreSQL 14 ou plus récent | Une instance pour l’application. La fonction `ulid()` demande PostgreSQL 14.          |
| Redis                       | Obligatoire. Il sert le bus d’événements, les sessions, les codes OAuth et les limites de débit. |
| Node.js 20+ et pnpm         | Frontend, paquet CLI, lanceur E2E. pnpm uniquement — les lockfiles sont des `pnpm-lock.yaml`. |
| Caddy                       | Le proxy de développement. `scripts/dev` l’attend dans le PATH.                       |
| En-têtes Lua 5.4 ou 5.5     | Le shard `lua` lie la bibliothèque système (`liblua5.4-dev` sur Debian/Ubuntu).       |

## Récupérer le code

Clonez le dépôt :

```sh
git clone https://github.com/wearefacet/facet.git
cd facet
```

## Configurer

Deux fichiers portent la configuration :

- `config.dev.yml` — la configuration du backend (base de données, Redis,
  mail, artifacts).
- le `.env` à la racine — les adresses partagées, notamment `BACKEND_URL`.

## Amorcer

Lancez les trois scripts dans l’ordre :

```sh
scripts/init              # crée la base, applique les migrations, initialise les doctypes de base + un admin de dev
scripts/import-fixtures   # facultatif : charge les domaines d'exemple CRM / RH / production
./scripts/dev             # Caddy + backend + frontend sur https://facet.localhost:3443
```

`scripts/init` lance `facet db_reset seed:dev` : il supprime puis recrée la
base, applique toutes les migrations, et initialise le schéma de base avec un
administrateur de développement.

Ouvrez `https://facet.localhost:3443`, puis connectez-vous avec
l’administrateur créé par l’initialisation : `admin@example.tld` / `admin`.
Ce compte ne sert qu’au développement, sur des données que vous pouvez
effacer à tout moment — la plateforme le refuse en production.

## Ce qui tourne

Trois processus servent la pile :

<!-- d2
caddy: Caddy
frontend: "SvelteKit frontend"
backend: "Crystal backend"
postgres: PostgreSQL {class: store}
redis: Redis {class: store}

caddy -> frontend: https
caddy -> backend: https
frontend -> backend: API calls
backend -> postgres
backend -> redis
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/18dda779-light.svg" alt="SvelteKit frontend" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/18dda779-dark.svg" alt="SvelteKit frontend" loading="lazy" />
</div>

`./scripts/dev` démarre tous les processus dans un seul terminal. Pour le mode
brut à deux ports, utilisez `./scripts/dev --no-caddy` (backend `:3000`,
frontend `:5173`).

## Commandes du quotidien

Backend (à la racine du dépôt) :

| Commande                            | But                                                                      |
| ----------------------------------- | ------------------------------------------------------------------------ |
| `make check`                        | Le passage de compilation, sans binaire. Le signal le plus rapide sur les erreurs de types. |
| `make build` / `make build_release` | Le binaire serveur dans `build/`.                                         |
| `make run`                          | Backend seulement.                                                        |
| `make test`                         | La suite de specs complète. Démarre d’abord un PostgreSQL jetable sur le port 5433. |
| `bin/ameba`                         | Le linter Crystal.                                                        |

Frontend (dans `frontend/`) :

| Commande         | But                                                            |
| ---------------- | -------------------------------------------------------------- |
| `pnpm check`     | `svelte-check` — types, syntaxe Svelte, accessibilité.          |
| `pnpm lint`      | Prettier + ESLint.                                             |
| `pnpm test`      | Vitest : logique pure + fonctions play des stories Storybook.             |
| `pnpm storybook` | L’atelier de composants.                                       |

## Pour aller plus loin

- Lisez [Domaines, brouillons et éditeurs de domaines](/fr/build/domains-drafts-editors/) pour comprendre comment Facet organise les données.
- Lisez [Déployer en production](/fr/operate/production/) quand vous serez prêt à livrer.
