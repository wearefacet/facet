---
title: Créer des apps
description: Créez des frontends et des intégrations sur Facet avec le SDK, l’API REST et MCP.
audience: [developer]
features: []
sidebar:
  order: 0
verified_at: a77c6171
---

Vous construisez une app sur Facet à la main ou avec un agent de code IA.
Enregistrez l’app, connectez les utilisateurs, puis appelez Facet via l’API
REST ou le SDK TypeScript. Les pages de cette section couvrent chaque étape,
et chacune porte du code à copier et à exécuter.

> **Pour les agents :** lisez d’abord `/llms.txt`, puis récupérez n’importe
> quelle page en markdown brut sur `/build/apps/<page>.md` (à l’octet près,
> front-matter conservé). Séquence minimale : enregistrez une app
> (`POST /Api/app/App`) → connectez un utilisateur (`/OAuth/authorize` →
> `/OAuth/token`, ou une clé `fct_` propre à l’app) → appelez
> `/Api/<domain>/<Doctype>` avec `Authorization`. Commencez par
> [Comment fonctionnent les apps](/fr/build/apps/how-apps-work/).

## Plateforme

- [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/)
- [Démarrage rapide avec la CLI de dev](/fr/build/apps/quickstart/)
- [Enregistrer une app (publique, confidentielle ou headless)](/fr/build/apps/connect/register/)
- [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/)
- [La liaison DPoP des tokens](/fr/build/apps/connect/dpop/)
- [CORS et origines autorisées](/fr/build/apps/connect/cors/)
- [Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/)
- [Héberger votre frontend : déploiement, versions, retour arrière, domaines personnalisés](/fr/build/apps/host/deploy/)
- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/build/apps/data/sdk/)

## API et agents

- [Travailler avec l’API REST (CRUD, filtres, agrégats, ETags)](/fr/build/apps/data/rest-api/)
- [Recherche](/fr/build/apps/data/search/)
- [Le temps réel avec WebSockets](/fr/build/apps/data/realtime/)
- [Téléverser et servir des fichiers](/fr/build/apps/data/files/)
- [Import et export en masse via l’API](/fr/build/apps/data/bulk-import-export/)
- [Conditionner votre UI au manifest](/fr/build/apps/connect/permission-manifest/)
- [Intégrer l’assistant (`@facetapp/chat`)](/fr/build/apps/host/embed-assistant/)
- [MCP : connecter des agents](/fr/build/apps/agents/mcp/)
- [Outils pour agents](/fr/build/apps/agents/agent-tools/)
- [Construire des apps avec un agent de code IA](/fr/build/apps/agents/coding-agents/)

## Voir aussi

- [Apps, attributions et rôles](/fr/build/apps/connect/what-an-app-can-do/) — le
  concept à la base du plafond d’attributions.
- [Référence](/fr/reference/) — les détails exploitables par la machine,
  dont la référence de l’API REST.
