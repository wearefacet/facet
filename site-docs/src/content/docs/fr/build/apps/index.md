---
type: overview
title: "Créer des apps"
description: Choisissez comment votre app se connecte — navigateur, service backend ou agent IA — et commencez par la bonne page.
audience: [developer]
features: []
sidebar:
  order: 0
verified_at: eee55a2
---

Votre équipe garde ses données dans Facet. Autre chose doit maintenant y
accéder : une app web pour l’entrepôt, une synchronisation nocturne, ou un
agent qui répond aux questions. Chacune se connecte à sa manière, et cette
différence décide des pages dont vous avez besoin. Choisissez la ligne qui
correspond à ce que vous construisez.

> **Pour les agents :** lisez d’abord `/llms.txt`, puis récupérez n’importe
> quelle page en markdown brut sur `/build/apps/<page>.md` (à l’octet près,
> front-matter conservé). Séquence minimale : enregistrez une app
> (`POST /Api/app/App`) → connectez un utilisateur (`/OAuth/authorize` →
> `/OAuth/token`, ou une clé `fct_` propre à l’app) → appelez
> `/Api/<domain>/<Doctype>` avec `Authorization`. Commencez par
> [Comment fonctionnent les apps](/fr/build/apps/how-apps-work/).

## Choisissez votre voie

| Vous construisez… | La connexion se fait avec | Pour commencer |
|---|---|---|
| Une app navigateur pour les utilisateurs — hébergée sur Facet ou sur votre propre hôte | OAuth 2.1 + PKCE, sous l’identité de l’utilisateur qui se connecte. L’utilisateur élit un rôle sur l’écran de consentement. Les tokens peuvent être liés avec DPoP. | [Démarrage rapide](/fr/build/apps/quickstart/), puis [Connecter les utilisateurs](/fr/build/apps/connect/user-login/) |
| Un service backend ou une intégration, sans personne au clavier | Un compte de service et une clé API propre à l’app (`fct_…`), sous un rôle que vous épinglez sur l’app | [Apps backend et comptes de service](/fr/build/apps/connect/backend-apps/) |
| Un agent IA | MCP, un endpoint par rôle, via un token d’app ou une clé API | [Connecter des agents via MCP](/fr/build/apps/agents/mcp/) |

Les trois voies obéissent à une règle commune. **Une app ne peut jamais
faire plus que ce que l’app et son utilisateur ont le droit de faire.**
Vous plafonnez l’app avec des attributions à l’enregistrement. Le rôle que
l’appelant endosse fait le reste. Le modèle derrière cette règle :
[Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/).

Un frontend statique qui n’a besoin que d’un hébergement saute entièrement
la connexion — déployez-le et laissez-le connecter les utilisateurs comme
n’importe quelle app navigateur. Voir
[Déployer votre app sur Facet](/fr/build/apps/host/deploy/).

## Toutes les pages de cette section

**Se connecter** — l’enregistrement et les chemins de connexion :

- [Enregistrer une app](/fr/build/apps/connect/register/)
- [Connecter les utilisateurs](/fr/build/apps/connect/user-login/)
- [Lier les tokens à votre app (DPoP)](/fr/build/apps/connect/dpop/)
- [Origines autorisées et CORS](/fr/build/apps/connect/cors/)
- [Apps backend et comptes de service](/fr/build/apps/connect/backend-apps/)
- [Afficher uniquement ce que l’utilisateur peut faire](/fr/build/apps/connect/permission-manifest/)
- [Apps, attributions et rôles](/fr/build/apps/connect/what-an-app-can-do/)

**Lire et écrire les données** — les surfaces qu’appelle une app connectée :

- [Utiliser l’API REST](/fr/build/apps/data/rest-api/)
- [Le SDK TypeScript](/fr/build/apps/data/sdk/)
- [Rechercher depuis une app](/fr/build/apps/data/search/)
- [Mises à jour en temps réel](/fr/build/apps/data/realtime/)
- [Téléverser et servir des fichiers](/fr/build/apps/data/files/)
- [Import et export en masse](/fr/build/apps/data/bulk-import-export/)

**Héberger et intégrer** :

- [Déployer votre app sur Facet](/fr/build/apps/host/deploy/)
- [Intégrer l’assistant dans votre app](/fr/build/apps/host/embed-assistant/)

**Agents IA** :

- [Construire des apps avec un agent de code](/fr/build/apps/agents/coding-agents/)
- [Connecter des agents via MCP](/fr/build/apps/agents/mcp/)
- [Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/)

## Voir aussi

- [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/) — le
  modèle sur lequel chaque page de ce groupe s’appuie.
- [Build](/fr/build/) — un niveau au-dessus : la modélisation des domaines et
  des règles d’accès.
- [Contrôler ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/) —
  la vue administrateur des mêmes attributions.
