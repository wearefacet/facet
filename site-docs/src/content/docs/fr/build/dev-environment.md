---
type: how-to
title: "Installer l’environnement de dev"
description: Lancez Facet depuis les sources — l’environnement de dev pour les domaines en fichiers, les apps et le produit lui-même.
audience: [developer]
features: [PLT-01, PLT-16, IAM-12, DOM-24]
sidebar:
  order: 2
verified_at: eee55a2
---

Trois types de travail exigent Facet lancé depuis les sources :

- **Les domaines en fichiers.** Le watcher de dev applique à la base qui
  tourne chaque enregistrement de fichier dans un dossier de domaine — le
  parcours [Le même domaine en fichiers](/fr/build/first-hour/first-domain-in-files/)
  le montre.
- **Les apps.** Une app hébergée est une base de code que vous développez à
  côté d’un backend réel — [Livrez votre première app](/fr/build/first-hour/first-app/)
  finit dans cette configuration.
- **Le produit lui-même.** Les specs backend, les composants frontend et la
  CLI tournent tous contre une pile locale.

Si vous voulez seulement essayer le produit, arrêtez-vous là : lancez la
pile de conteneurs en une commande — `facet-cli setup-dev`, décrit dans
[Exécuter Facet](/fr/build/first-hour/run-facet/) — ou suivez
[Déployer en production](/fr/admin/install/production/). Cette page est la
voie des sources, pour quand vous modifiez le backend, le frontend ou la
CLI elle-même.

:::tip
`facet-cli setup-dev` dresse une instance de dev en conteneurs sans cloner
le dépôt. Il crée aussi par défaut un dossier surveillé `domains/`.
Utilisez cette page quand vous devez modifier le code de Facet lui-même.
:::

## Prérequis

Installez d’abord ces outils. Le tableau dit à quoi chacun sert :

| Outil                       | Notes                                                                              |
| -------------------------- | ---------------------------------------------------------------------------------- |
| Crystal 1.21 ou plus récent | La chaîne d’outils en service est la 1.22. Le shard `agent-cr` demande 1.19 ou plus récent. |
| PostgreSQL 14 ou plus récent | Une instance pour l’app. La fonction `ulid()` demande PostgreSQL 14.               |
| Redis                      | Requis. Le bus d’événements, les sessions, les codes OAuth et les limites de débit l’utilisent. |
| Node.js 20+ et pnpm       | Frontend, paquet CLI, lanceur E2E. pnpm uniquement — les lockfiles sont des `pnpm-lock.yaml`. |
| Caddy                      | Le proxy de dev. `scripts/dev` l’attend dans le PATH.                                   |
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
scripts/import-fixtures   # facultatif : charge les domaines d’exemple sous data/fixtures/
./scripts/dev             # Caddy + backend + frontend sur https://facet.localhost:3443
```

`scripts/init` lance `facet db_reset seed:dev` : il supprime puis recrée la
base, applique toutes les migrations, et initialise le schéma de base avec
un administrateur de dev. `scripts/import-fixtures` importe les lots de
fixtures sous `data/fixtures/` — des domaines d’exemple CRM, RH, production
et identité. Vous pouvez le relancer sans risque : chaque import fusionne
avec ce qui existe déjà.

## Vérifier que tout fonctionne

Laissez à la pile environ une minute, puis lancez ces vérifications :

1. Ouvrez `https://facet.localhost:3443` et connectez-vous avec
   l’administrateur de dev créé par l’initialisation :
   `admin@example.tld` / `admin`. Ce compte ne sert qu’au développement,
   sur des données que vous pouvez effacer à tout moment — la plateforme
   le refuse en production.
2. Demandez au backend son état de santé :

   ```sh
   curl -sk https://facet.localhost:3443/Healthcheck
   ```

   ```json
   {"status":"ok","service":{"env":"dev",…},"database":{"status":"ok",…},"redis":{"status":"ok",…},…}
   ```

   Chaque sous-système de la réponse doit se lire `"ok"`.
3. Compilez les deux moitiés sans erreur :

   ```sh
   make check            # type-check du backend, sans binaire
   cd frontend && pnpm check   # svelte-check : types, syntaxe, accessibilité
   ```

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

`./scripts/dev` démarre tous les processus dans un seul terminal. Pour le
mode brut à deux ports, utilisez `./scripts/dev --no-caddy` (backend
`:3000`, frontend `:5173`). Les apps hébergées répondent sur leurs propres
hôtes sous `https://*.apps.localhost:3443`.

## Les commandes du quotidien

Backend (à la racine du dépôt) :

| Commande                            | But                                                            |
| ----------------------------------- | -------------------------------------------------------------- |
| `make check`                        | Le passage de compilation, sans binaire. Le signal le plus rapide sur les erreurs de types. |
| `make build` / `make build_release` | Le binaire serveur dans `build/`.                                       |
| `make run`                          | Backend seulement.                                                      |
| `make test`                         | La suite de specs complète. Démarre d’abord un PostgreSQL jetable sur le port 5433. |
| `bin/ameba`                         | Le linter Crystal.                                                      |

Frontend (dans `frontend/`) :

| Commande         | But                                               |
| ---------------- | -------------------------------------------------- |
| `pnpm check`     | `svelte-check` — types, syntaxe Svelte, accessibilité. |
| `pnpm lint`      | Prettier + ESLint.                                    |
| `pnpm test`      | Vitest : logique pure + fonctions play des stories Storybook.  |
| `pnpm storybook` | L’atelier de composants.                                  |

## Les domaines d’exemple

La configuration de dev surveille `site-docs/examples/brightwater`
(`dev.domain_watch` dans `config.dev.yml`, sondage à 500 millisecondes).
Enregistrez un fichier dans ce dossier et la base qui tourne change avec
lui — c’est le mécanisme que démontre
[Le même domaine en fichiers](/fr/build/first-hour/first-domain-in-files/).
Pour surveiller votre propre dossier à la place, pointez
`dev.domain_watch.path` vers lui. Le watcher refuse de démarrer en
production.

## Voir aussi

- [Le watcher de domaines de dev](/fr/build/model/in-files/domain-watcher/) —
  le contrat de surveillance : clés de config, modes, comportement en cas
  d’échec.
- [Déployer en production](/fr/admin/install/production/) — la pile de
  conteneurs, quand vous livrez.
- [Exécuter Facet](/fr/build/first-hour/run-facet/) — la voie conteneurs de
  la première heure.
- [Sécurité et gouvernance](/fr/discover/security/)
- [Prérequis système](/fr/admin/install/requirements/)
