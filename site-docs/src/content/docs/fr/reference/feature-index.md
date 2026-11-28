---
title: Index des fonctionnalités
description: Chaque identifiant de fonctionnalité de l'inventaire, avec les pages qui le couvrent.
audience: [developer, operator]
type: reference
features: []
verified_at: f1409cdc
---

> Généré depuis `site-docs/inventory.yml` par `make gen-docs-feature-index`. Ne modifiez pas ce fichier à la main.

Cette page relie chaque identifiant de fonctionnalité de l'inventaire (138 fonctionnalités dans 10 domaines) aux pages de documentation qui le couvrent. Le contrôle de couverture du build demande à chaque identifiant d'apparaître sur au moins une page ou de figurer sur la liste d'exclusion de `site-docs/coverage-exclude.yml`. Un tiret signifie qu'aucune page ne cite encore l'identifiant.

## AI — assistants, agent tools, MCP

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| AI-01 | Workspace assistant | [L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/), [Interroger l’assistant](/fr/use/assistant/) |
| AI-02 | Domain-builder assistant | [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [Construire avec l’assistant](/fr/build/model/in-app/build-with-assistant/), [L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/) |
| AI-03 | Per-app assistant | [Intégrer l’assistant à votre app](/fr/build/apps/host/embed-assistant/), [L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/) |
| AI-04 | Agent tool catalogue | [Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/), [Connecter un agent IA](/fr/build/first-hour/connect-an-agent/), [Outils d’agent](/fr/reference/agent-tools/) |
| AI-05 | MCP resource server | [Connecter des agents par MCP](/fr/build/apps/agents/mcp/), [Connecter un agent IA](/fr/build/first-hour/connect-an-agent/), [L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/) |
| AI-06 | Skill corpus | [Ce que les agents peuvent faire](/fr/build/apps/agents/agent-tools/), [Bâtir des apps avec un agent de code](/fr/build/apps/agents/coding-agents/), [Construire avec l’assistant](/fr/build/model/in-app/build-with-assistant/), [Bâtir des domaines avec un agent](/fr/build/model/in-files/with-a-coding-agent/) |
| AI-07 | Usage ledger and limits | [Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/), [Gouverner l’assistant](/fr/admin/assistant/govern/), [Assistant et permissions](/fr/admin/under-the-hood/ai-and-permissions/), [L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/) |
| AI-08 | Assistant configuration | [Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/), [Gouverner l’assistant](/fr/admin/assistant/govern/), [Assistant et permissions](/fr/admin/under-the-hood/ai-and-permissions/), [L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/) |
| AI-09 | Stale-turn sweep | [Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/) |
| AI-10 | Conversation titles | [Interroger l’assistant](/fr/use/assistant/) |
| AI-11 | Reply-language directive | [Interroger l’assistant](/fr/use/assistant/) |

## APP — registered apps, OAuth, hosting, SDKs

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| APP-01 | App registry | [Enregistrer une app](/fr/build/apps/connect/register/), [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/), [Démarrage rapide](/fr/build/apps/quickstart/), [Livrez votre première app](/fr/build/first-hour/first-app/), [Apps : vite créées, librement remplacées](/fr/discover/how-it-works/apps/) |
| APP-02 | OAuth 2.1 authorization server | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/), [Démarrage rapide](/fr/build/apps/quickstart/), [Livrez votre première app](/fr/build/first-hour/first-app/) |
| APP-03 | DPoP proof binding | [Lier les tokens à votre app (DPoP)](/fr/build/apps/connect/dpop/) |
| APP-04 | Dynamic client registration | [Connecter des agents par MCP](/fr/build/apps/agents/mcp/), [Connecter un agent IA](/fr/build/first-hour/connect-an-agent/) |
| APP-05 | Consent screen | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/), [Livrez votre première app](/fr/build/first-hour/first-app/) |
| APP-06 | App hosting | [Exécuter avec des conteneurs](/fr/admin/install/containers/), [Passer en production](/fr/admin/install/production/), [Déployer votre app sur Facet](/fr/build/apps/host/deploy/), [Livrez votre première app](/fr/build/first-hour/first-app/), [Apps : vite créées, librement remplacées](/fr/discover/how-it-works/apps/) |
| APP-07 | App API keys and service accounts | [Apps backend et comptes de service](/fr/build/apps/connect/backend-apps/) |
| APP-08 | CORS for registered origins | [Origines autorisées et CORS](/fr/build/apps/connect/cors/) |
| APP-09 | Developer CLI | [Déployer votre app sur Facet](/fr/build/apps/host/deploy/), [Démarrage rapide](/fr/build/apps/quickstart/), [Livrez votre première app](/fr/build/first-hour/first-app/), [CLI des apps Facet](/fr/reference/cli-npm/) |
| APP-10 | TypeScript SDK | [Le SDK TypeScript](/fr/build/apps/data/sdk/), [Livrez votre première app](/fr/build/first-hour/first-app/) |
| APP-11 | Chat embed | [Intégrer l’assistant à votre app](/fr/build/apps/host/embed-assistant/) |
| APP-12 | Dashboard app launcher | [Le tableau de bord](/fr/use/first-day/dashboard/) |

## AUD — mutation log, audit, rollback

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| AUD-01 | Append-only mutation log | [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [Documents : enregistrements avec mémoire](/fr/discover/how-it-works/documents/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-02 | Audit reading | [Voir qui a fait quoi](/fr/admin/history/audit/), [Sécurité et gouvernance](/fr/discover/security/), [Historique et retour arrière](/fr/use/documents/history-undo/) |
| AUD-03 | Audit redaction | [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-04 | Rollback | [Revenir en arrière](/fr/admin/history/roll-back/), [Documents : enregistrements avec mémoire](/fr/discover/how-it-works/documents/), [Sécurité et gouvernance](/fr/discover/security/), [Historique et retour arrière](/fr/use/documents/history-undo/) |
| AUD-05 | Write-time coalescing | [Rétention : ce qui est gardé](/fr/admin/history/retention/), [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-06 | Retention compaction | [Rétention : ce qui est gardé](/fr/admin/history/retention/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-07 | Tombstone retention | [Rétention : ce qui est gardé](/fr/admin/history/retention/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-08 | Provenance and cause metadata | [Voir qui a fait quoi](/fr/admin/history/audit/), [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-09 | Cluster-scope rollback | [Sécurité et gouvernance](/fr/discover/security/) |

## AUT — events, hooks, webhooks, jobs, notifications, mail

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| AUT-01 | Event bus | [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/), [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) |
| AUT-02 | Domain event hooks | [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/) |
| AUT-03 | Outbound webhooks | [Envoyer des webhooks](/fr/build/model/automation/webhooks/), [Payloads des webhooks](/fr/reference/webhook-payloads/) |
| AUT-04 | Background jobs | [Performances et dimensionnement](/fr/admin/install/performance/), [Tâches de fond et cron](/fr/admin/keep-running/jobs-cron/) |
| AUT-05 | Cron scheduler and maintenance | [Tâches de fond et cron](/fr/admin/keep-running/jobs-cron/), [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) |
| AUT-06 | In-app notifications | [Notifications et mentions](/fr/build/model/automation/notifications/), [Notifications](/fr/use/notifications/) |
| AUT-07 | Outbound email | [Courriel sortant](/fr/admin/configure/email/) |
| AUT-08 | Lua scripting engine | [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/), [API Lua](/fr/reference/lua-api/) |
| AUT-09 | Aggregate child-change events | [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/) |
| AUT-10 | Cron task listing CLI | [Tâches de fond et cron](/fr/admin/keep-running/jobs-cron/) |

## DOC — document data plane

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| DOC-01 | Document CRUD | [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/), [Documents : enregistrements avec mémoire](/fr/discover/how-it-works/documents/) |
| DOC-02 | List and filter grammar | [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [Opérateurs de filtre](/fr/reference/filter-operators/) |
| DOC-03 | Aggregates | [Utiliser l’API REST](/fr/build/apps/data/rest-api/) |
| DOC-04 | ETag caching | [Utiliser l’API REST](/fr/build/apps/data/rest-api/) |
| DOC-05 | Links and backrefs | [Relier des documents entre eux](/fr/build/model/relations/references-links/) |
| DOC-06 | Cross-doctype search | [Rechercher depuis une app](/fr/build/apps/data/search/), [Recherche et palette de commandes](/fr/use/finding/search/) |
| DOC-07 | Atomic parent and children create | [Documents parents et enfants](/fr/build/model/relations/parent-child/) |
| DOC-08 | Document copy | [Le journal des mutations](/fr/admin/under-the-hood/change-log/) |
| DOC-09 | Write-only and secret fields | [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/), [Sécurité et gouvernance](/fr/discover/security/) |
| DOC-10 | Reference validation | [Relier des documents entre eux](/fr/build/model/relations/references-links/) |
| DOC-11 | Document import and export | [Import/export en masse via l’API](/fr/build/apps/data/bulk-import-export/), [Importer et exporter des données](/fr/use/documents/import-export/) |
| DOC-12 | Realtime updates | [Mises à jour en direct](/fr/build/apps/data/realtime/) |
| DOC-13 | Field defaults and normalization | [Choisir les types de champs](/fr/build/model/data/field-types/), [Types de champs](/fr/reference/field-types/), [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| DOC-14 | Child-list list grammar | [Utiliser l’API REST](/fr/build/apps/data/rest-api/) |
| DOC-15 | App tokens on WebSocket | [Mises à jour en direct](/fr/build/apps/data/realtime/) |

## DOM — domains, doctypes, schema authoring

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| DOM-01 | Domains | [L’isolation entre domaines](/fr/build/deeper/domain-isolation/), [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/), [Les domaines : là où vivent vos données](/fr/discover/how-it-works/domains/) |
| DOM-02 | Draft and publish lifecycle | [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [De la dev à la production](/fr/build/model/dev-to-production/), [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/), [Le fonctionnement des brouillons](/fr/build/model/in-app/how-drafts-work/), [Choisir sa façon de construire](/fr/build/model/), [Les domaines : là où vivent vos données](/fr/discover/how-it-works/domains/) |
| DOM-03 | Doctypes | [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/), [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [Concevoir un doctype](/fr/build/model/data/design-doctypes/), [Schéma de définition de doctype](/fr/reference/doctype-schema/) |
| DOM-04 | Field type system | [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [Choisir les types de champs](/fr/build/model/data/field-types/), [Types de champs](/fr/reference/field-types/) |
| DOM-05 | Composition (parent and children) | [Documents parents et enfants](/fr/build/model/relations/parent-child/) |
| DOM-06 | Sidecars | [Commentaires et pièces jointes](/fr/build/model/relations/comments-attachments/), [Documents : enregistrements avec mémoire](/fr/discover/how-it-works/documents/), [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/) |
| DOM-07 | Named actions | [Ajouter des actions à un doctype](/fr/build/model/behaviour/named-actions/) |
| DOM-08 | Lifecycle scripts | [Scripts et garde-fous](/fr/build/model/behaviour/scripts-and-guards/), [API Lua](/fr/reference/lua-api/) |
| DOM-09 | Computed fields | [Champs calculés](/fr/build/model/data/computed-fields/) |
| DOM-10 | Sequential identifiers | [Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/) |
| DOM-11 | Unique constraints | [Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/) |
| DOM-12 | Named scopes | [Les périmètres de lignes](/fr/admin/people/row-scopes/), [Les périmètres nommés](/fr/build/model/access/named-scopes/) |
| DOM-13 | Domain editors | [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/) |
| DOM-14 | Domain grants | [Réplication entre domaines](/fr/build/deeper/cross-domain-replication/), [L’isolation entre domaines](/fr/build/deeper/domain-isolation/), [Partager des données entre domaines](/fr/build/model/relations/across-domains/), [Les domaines : là où vivent vos données](/fr/discover/how-it-works/domains/) |
| DOM-15 | Portable domain bundles | [Le même domaine en fichiers](/fr/build/first-hour/first-domain-in-files/), [Déplacer des domaines avec des bundles](/fr/build/model/bundles/), [De la dev à la production](/fr/build/model/dev-to-production/), [La disposition des fichiers d’un domaine](/fr/build/model/in-files/domain-files/) |
| DOM-16 | Definition diagnostics | [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/), [Le fonctionnement des brouillons](/fr/build/model/in-app/how-drafts-work/) |
| DOM-17 | Lazy document migration | [Évolution du schéma à la demande](/fr/build/deeper/schema-evolution/), [Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/) |
| DOM-18 | Re-projection CLI | [Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/), [CLI facet](/fr/reference/cli-facet/) |
| DOM-19 | Dev domain watcher | [Le même domaine en fichiers](/fr/build/first-hour/first-domain-in-files/), [De la dev à la production](/fr/build/model/dev-to-production/), [Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/), [La disposition des fichiers d’un domaine](/fr/build/model/in-files/domain-files/), [Le watcher de domaines](/fr/build/model/in-files/domain-watcher/), [Bâtir des domaines avec un agent](/fr/build/model/in-files/with-a-coding-agent/), [Choisir sa façon de construire](/fr/build/model/) |
| DOM-20 | Domain schematic | [Votre domaine en schéma](/fr/build/model/views/schematic/) |
| DOM-21 | CollectionView | [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [Listes, kanban et calendriers](/fr/build/model/views/lists-boards-calendars/), [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| DOM-22 | DocumentView templates | [Concevoir les pages document](/fr/build/model/views/document-pages/), [Schéma du modèle DVT](/fr/reference/dvt-schema/), [Contexte des modèles Jinja2](/fr/reference/jinja2-context/) |
| DOM-23 | Jinja2 templating for derived columns | [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/), [Libellés et texte de recherche](/fr/build/model/views/names-and-search/), [Contexte des modèles Jinja2](/fr/reference/jinja2-context/) |
| DOM-24 | Core seeding | [Premier démarrage et amorçage](/fr/admin/install/bootstrap/), [Installer l’environnement de dev](/fr/build/dev-environment/), [Lancer Facet](/fr/build/first-hour/run-facet/) |
| DOM-25 | Cross-domain field replication | [Réplication entre domaines](/fr/build/deeper/cross-domain-replication/), [Partager des données entre domaines](/fr/build/model/relations/across-domains/) |
| DOM-26 | Doctype maintenance console | [Évolution du schéma à la demande](/fr/build/deeper/schema-evolution/) |
| DOM-27 | Eager document migration | [Évolution du schéma à la demande](/fr/build/deeper/schema-evolution/) |
| DOM-28 | Migration retry CLI | [Évolution du schéma à la demande](/fr/build/deeper/schema-evolution/) |
| DOM-29 | Collection view starter screen | [Listes, kanban et calendriers](/fr/build/model/views/lists-boards-calendars/) |
| DOM-30 | Collection view pinning | [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| DOM-31 | Draft from live domain | [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/) |
| DOM-32 | Kanban lane control | [Listes, kanban et calendriers](/fr/build/model/views/lists-boards-calendars/) |

## FE — workspace SPA surfaces

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| FE-01 | Auth screens | [Lancer Facet](/fr/build/first-hour/run-facet/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| FE-02 | Dashboard | [Le tableau de bord](/fr/use/first-day/dashboard/), [Visite de l’espace de travail](/fr/use/first-day/) |
| FE-03 | List surfaces | [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| FE-04 | Document show page | [Concevoir les pages document](/fr/build/model/views/document-pages/), [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/), [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| FE-05 | Document form | [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| FE-06 | History and rollback | [Historique et retour arrière](/fr/use/documents/history-undo/) |
| FE-07 | Command palette | [Recherche et palette de commandes](/fr/use/finding/search/), [Visite de l’espace de travail](/fr/use/first-day/) |
| FE-08 | Keyboard shortcuts | [Raccourcis clavier](/fr/use/finding/keyboard-shortcuts/), [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| FE-09 | Notifications UI | [Notifications](/fr/use/notifications/) |
| FE-10 | Builder | [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/), [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/) |
| FE-11 | Configure access | [Gérer les comptes](/fr/admin/people/accounts/), [Donner accès à votre équipe](/fr/build/first-hour/team-access/) |
| FE-12 | Configure apps | [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/), [Enregistrer une app](/fr/build/apps/connect/register/) |
| FE-13 | Configure domains | [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/) |
| FE-14 | Configure platform | [Paramètres système](/fr/admin/configure/system-settings/), [Le SSO avec OIDC](/fr/admin/people/sso/) |
| FE-15 | Configure currencies | [Devises](/fr/admin/configure/currencies/) |
| FE-16 | Configure audit | [Voir qui a fait quoi](/fr/admin/history/audit/) |
| FE-17 | Settings | [Vos réglages et clés API](/fr/use/account/) |
| FE-18 | Import and export UI | [Importer et exporter des données](/fr/use/documents/import-export/) |
| FE-19 | Welcome tour | [Lancer Facet](/fr/build/first-hour/run-facet/), [Visite de l’espace de travail](/fr/use/first-day/) |
| FE-20 | Internationalization | [Langues](/fr/admin/configure/languages/) |
| FE-21 | OAuth consent page | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/) |
| FE-22 | Assistant chat UI | [Interroger l’assistant](/fr/use/assistant/) |
| FE-23 | Grid view (dormant) | Exclu de la documentation utilisateur |
| FE-24 | Peek drawer | [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| FE-25 | Trash mode and restore | [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |

## IAM — identity and authentication

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| IAM-01 | Password login and sessions | [Sessions et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-02 | Refresh rotation and reuse detection | [Sessions et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-03 | MFA with TOTP and backup codes | [Imposer le MFA](/fr/admin/people/mfa/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-04 | Forced password change | [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-05 | Self-service password reset | [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-06 | Invites and temporary passwords | [Gérer les comptes](/fr/admin/people/accounts/), [Personnes et accès](/fr/admin/people/), [Donner accès à votre équipe](/fr/build/first-hour/team-access/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-07 | Account lifecycle | [Gérer les comptes](/fr/admin/people/accounts/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-08 | Inbound OIDC SSO | [Le SSO avec OIDC](/fr/admin/people/sso/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-09 | Static API keys | [Clés d’API](/fr/admin/apps-access/api-keys/), [Sécurité et gouvernance](/fr/discover/security/), [Vos réglages et clés API](/fr/use/account/) |
| IAM-10 | Login throttle and lockout | [Sessions et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-11 | Session management | [Sessions et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Vos réglages et clés API](/fr/use/account/) |
| IAM-12 | Bootstrap CLI | [Premier démarrage et amorçage](/fr/admin/install/bootstrap/), [Passer en production](/fr/admin/install/production/), [Installer l’environnement de dev](/fr/build/dev-environment/), [Lancer Facet](/fr/build/first-hour/run-facet/), [Sécurité et gouvernance](/fr/discover/security/), [CLI facet](/fr/reference/cli-facet/) |
| IAM-13 | Login event log | [Voir qui a fait quoi](/fr/admin/history/audit/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-14 | Caller identity endpoint | [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/), [Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-15 | Service accounts | [Sécurité et gouvernance](/fr/discover/security/) |

## PLT — platform, operations, observability

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| PLT-01 | YAML config | [Fichiers de configuration](/fr/admin/configure/configuration-files/), [Installer l’environnement de dev](/fr/build/dev-environment/), [Lancer Facet](/fr/build/first-hour/run-facet/), [Clés du fichier de configuration](/fr/reference/config-keys/) |
| PLT-02 | System settings | [Paramètres système](/fr/admin/configure/system-settings/), [Imposer le MFA](/fr/admin/people/mfa/), [Clés de réglage système](/fr/reference/system-settings-keys/) |
| PLT-03 | Secret store | [Sauvegarde et restauration](/fr/admin/keep-running/backup-restore/), [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/) |
| PLT-04 | Artifact store | [Stockage des fichiers](/fr/admin/configure/file-storage/), [Sauvegarde et restauration](/fr/admin/keep-running/backup-restore/), [Téléverser et servir des fichiers](/fr/build/apps/data/files/), [Fichiers dans les champs](/fr/build/model/data/files/) |
| PLT-05 | Managed indexes | [Performances et dimensionnement](/fr/admin/install/performance/), [Index](/fr/admin/keep-running/indexes/) |
| PLT-06 | Health probes | [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/), [Sondes et métriques](/fr/reference/health-metrics-names/) |
| PLT-07 | Metrics | [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/), [Sondes et métriques](/fr/reference/health-metrics-names/) |
| PLT-08 | OpenTelemetry tracing | [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/) |
| PLT-09 | Structured logging | [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/) |
| PLT-10 | Database topology | [Fichiers de configuration](/fr/admin/configure/configuration-files/), [Prérequis système](/fr/admin/install/requirements/) |
| PLT-11 | Migrations | [Passer en production](/fr/admin/install/production/), [Migrations de base de données](/fr/admin/keep-running/migrations/), [Mettre à niveau Facet](/fr/admin/keep-running/upgrades/), [CLI facet](/fr/reference/cli-facet/) |
| PLT-12 | OpenAPI specification | [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [API REST](/fr/reference/rest-api/) |
| PLT-13 | HTTP admission gates | [Performances et dimensionnement](/fr/admin/install/performance/), [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [Réponses d’erreur](/fr/reference/error-responses/) |
| PLT-14 | Currency registry and money math | [Devises](/fr/admin/configure/currencies/) |
| PLT-15 | Graceful shutdown | [Mettre à niveau Facet](/fr/admin/keep-running/upgrades/) |
| PLT-16 | Container images | [Exécuter avec des conteneurs](/fr/admin/install/containers/), [Passer en production](/fr/admin/install/production/), [Prérequis système](/fr/admin/install/requirements/), [Installer l’environnement de dev](/fr/build/dev-environment/), [Lancer Facet](/fr/build/first-hour/run-facet/) |
| PLT-17 | Account settings store | [Clés de réglage de compte](/fr/reference/account-settings-keys/), [Vos réglages et clés API](/fr/use/account/) |

## RBC — authorization and governance

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| RBC-01 | Roles | [Personnes et accès](/fr/admin/people/), [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/), [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/), [Donner accès à votre équipe](/fr/build/first-hour/team-access/), [Rôles : qui voit quoi et fait quoi](/fr/discover/how-it-works/roles/), [Sécurité et gouvernance](/fr/discover/security/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/) |
| RBC-02 | Role assignment and election | [Affecter les rôles et l’élection](/fr/admin/people/assign-roles/), [Donner accès à votre équipe](/fr/build/first-hour/team-access/), [Rôles : qui voit quoi et fait quoi](/fr/discover/how-it-works/roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-03 | Read enforcement | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Sécurité et gouvernance](/fr/discover/security/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/) |
| RBC-04 | Field visibility tags | [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/), [Donner accès à votre équipe](/fr/build/first-hour/team-access/), [Rôles : qui voit quoi et fait quoi](/fr/discover/how-it-works/roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-05 | Row scopes | [Les périmètres de lignes](/fr/admin/people/row-scopes/), [Donner accès à votre équipe](/fr/build/first-hour/team-access/), [Rôles : qui voit quoi et fait quoi](/fr/discover/how-it-works/roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-06 | Write enforcement | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Sécurité et gouvernance](/fr/discover/security/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/) |
| RBC-07 | Role authority guard | [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/), [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-08 | App grants | [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/), [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/), [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/), [Apps : vite créées, librement remplacées](/fr/discover/how-it-works/apps/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-09 | Metadata gate | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-10 | Auth contexts | [Assistant et permissions](/fr/admin/under-the-hood/ai-and-permissions/), [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-11 | Permission manifest | [Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-12 | Role connectivity channels | [Sécurité et gouvernance](/fr/discover/security/) |

## Voir aussi

- [Pour commencer](/fr/discover/)
- [Construire des domaines](/fr/build/)
- [Gouverner l'accès](/fr/admin/)
- [Construire des apps](/fr/build/apps/)
- [Opérer](/fr/admin/)
