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
> quelle page en markdown brut sur `/apps/<page>.md` (à l’octet près,
> front-matter conservé). Séquence minimale : enregistrez une app
> (`POST /Api/app/App`) → connectez un utilisateur (`/OAuth/authorize` →
> `/OAuth/token`, ou une clé `fct_` propre à l’app) → appelez
> `/Api/<domain>/<Doctype>` avec `Authorization`. Commencez par
> [Comment fonctionnent les apps](/fr/apps/how-apps-work/).

## Plateforme

- [Comment fonctionnent les apps sur Facet](/fr/apps/how-apps-work/)
- [Démarrage rapide avec la CLI de dev](/fr/apps/quickstart-dev-cli/)
- [Enregistrer une app (publique, confidentielle ou headless)](/fr/apps/registering-app/)
- [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/apps/oauth-login/)
- [La liaison DPoP des tokens](/fr/apps/dpop/)
- [CORS et origines autorisées](/fr/apps/cors-origins/)
- [Comptes de service pour les apps backend](/fr/apps/service-accounts/)
- [Héberger votre frontend : déploiement, versions, retour arrière, domaines personnalisés](/fr/apps/hosting-deploy/)
- [Le SDK TypeScript (`@facetapp/sdk`)](/fr/apps/typescript-sdk/)

## API et agents

- [Travailler avec l’API REST (CRUD, filtres, agrégats, ETags)](/fr/apps/rest-api/)
- [Recherche](/fr/apps/search/)
- [Le temps réel avec WebSockets](/fr/apps/websockets/)
- [Téléverser et servir des fichiers](/fr/apps/files/)
- [Import et export en masse via l’API](/fr/apps/bulk-import-export/)
- [Conditionner votre UI au manifest](/fr/apps/permission-manifest/)
- [Intégrer l’assistant (`@facetapp/chat`)](/fr/apps/chat-embed/)
- [MCP : connecter des agents](/fr/apps/mcp-agents/)
- [Outils pour agents](/fr/apps/agent-tools/)
- [Construire des apps avec un agent de code IA](/fr/apps/ai-coding-agents/)

## Voir aussi

- [Apps, attributions et rôles](/fr/concepts/apps-grants-roles/) — le
  concept à la base du plafond d’attributions.
- [Référence](/fr/reference/) — les détails exploitables par la machine,
  dont la référence de l’API REST.
