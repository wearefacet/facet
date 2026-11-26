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
| AI-01 | Workspace assistant | [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/), [Utiliser l’assistant](/fr/use/assistant/) |
| AI-02 | Domain-builder assistant | [L’assistant de construction de domaines](/fr/build/model/in-app/build-with-assistant/), [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/) |
| AI-03 | Per-app assistant | [Intégrer l’assistant](/fr/build/apps/host/embed-assistant/), [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/) |
| AI-04 | Agent tool catalogue | [Outils pour agents](/fr/build/apps/agents/agent-tools/), [Outils d’agent](/fr/reference/agent-tools/) |
| AI-05 | MCP resource server | [MCP : connecter des agents](/fr/build/apps/agents/mcp/), [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/) |
| AI-06 | Skill corpus | [Outils pour agents](/fr/build/apps/agents/agent-tools/), [Bâtir des apps avec un agent de code](/fr/build/apps/agents/coding-agents/), [L’assistant de construction de domaines](/fr/build/model/in-app/build-with-assistant/), [Build domains with a coding agent](/build/model/in-files/with-a-coding-agent/) |
| AI-07 | Usage ledger and limits | [Configurer l’assistant](/fr/admin/assistant/connect-a-model/), [Gouverner l’assistant](/fr/admin/assistant/govern/), [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/) |
| AI-08 | Assistant configuration | [Configurer l’assistant](/fr/admin/assistant/connect-a-model/), [Gouverner l’assistant](/fr/admin/assistant/govern/), [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/) |
| AI-09 | Stale-turn sweep | [Configurer l’assistant](/fr/admin/assistant/connect-a-model/) |
| AI-10 | Conversation titles | — |
| AI-11 | Reply-language directive | — |

## APP — registered apps, OAuth, hosting, SDKs

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| APP-01 | App registry | [Enregistrer une app](/fr/build/apps/connect/register/), [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/), [Démarrage rapide avec la CLI dev](/fr/build/apps/quickstart/), [Apps: built fast, replaced freely](/discover/how-it-works/apps/) |
| APP-02 | OAuth 2.1 authorization server | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/), [Démarrage rapide avec la CLI dev](/fr/build/apps/quickstart/) |
| APP-03 | DPoP proof binding | [Liaison DPoP des tokens](/fr/build/apps/connect/dpop/) |
| APP-04 | Dynamic client registration | [MCP : connecter des agents](/fr/build/apps/agents/mcp/) |
| APP-05 | Consent screen | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/) |
| APP-06 | App hosting | [Déployer avec des conteneurs](/fr/admin/install/containers/), [Déployer en production](/fr/admin/install/production/), [Déployer votre frontend](/fr/build/apps/host/deploy/), [Apps: built fast, replaced freely](/discover/how-it-works/apps/) |
| APP-07 | App API keys and service accounts | [Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/) |
| APP-08 | CORS for registered origins | [CORS et origines autorisées](/fr/build/apps/connect/cors/) |
| APP-09 | Developer CLI | [Déployer votre frontend](/fr/build/apps/host/deploy/), [Démarrage rapide avec la CLI dev](/fr/build/apps/quickstart/), [CLI des apps Facet](/fr/reference/cli-npm/) |
| APP-10 | TypeScript SDK | [Le SDK TypeScript (`@facetapp/sdk`)](/fr/build/apps/data/sdk/) |
| APP-11 | Chat embed | [Intégrer l’assistant](/fr/build/apps/host/embed-assistant/) |
| APP-12 | Dashboard app launcher | — |

## AUD — mutation log, audit, rollback

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| AUD-01 | Append-only mutation log | [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [Documents: records with a memory](/discover/how-it-works/documents/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-02 | Audit reading | [Auditer l’activité](/fr/admin/history/audit/), [Sécurité et gouvernance](/fr/discover/security/), [Historique et retour arrière](/fr/use/documents/history-undo/) |
| AUD-03 | Audit redaction | [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-04 | Rollback | [Revenir en arrière](/fr/admin/history/roll-back/), [Documents: records with a memory](/discover/how-it-works/documents/), [Sécurité et gouvernance](/fr/discover/security/), [Historique et retour arrière](/fr/use/documents/history-undo/) |
| AUD-05 | Write-time coalescing | [La rétention : quoi et combien de temps](/fr/admin/history/retention/), [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-06 | Retention compaction | [La rétention : quoi et combien de temps](/fr/admin/history/retention/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-07 | Tombstone retention | [La rétention : quoi et combien de temps](/fr/admin/history/retention/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-08 | Provenance and cause metadata | [Auditer l’activité](/fr/admin/history/audit/), [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-09 | Cluster-scope rollback | [Sécurité et gouvernance](/fr/discover/security/) |

## AUT — events, hooks, webhooks, jobs, notifications, mail

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| AUT-01 | Event bus | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/), [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) |
| AUT-02 | Domain event hooks | [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/) |
| AUT-03 | Outbound webhooks | [Webhooks sortants](/fr/build/model/automation/webhooks/), [Payloads des webhooks](/fr/reference/webhook-payloads/) |
| AUT-04 | Background jobs | [Jobs en arrière-plan et cron](/fr/admin/keep-running/jobs-cron/) |
| AUT-05 | Cron scheduler and maintenance | [Jobs en arrière-plan et cron](/fr/admin/keep-running/jobs-cron/), [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) |
| AUT-06 | In-app notifications | [Notifications et mentions](/fr/build/model/automation/notifications/), [Notifications](/fr/use/notifications/) |
| AUT-07 | Outbound email | [Envoi des mails](/fr/admin/configure/email/) |
| AUT-08 | Lua scripting engine | [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/), [API Lua](/fr/reference/lua-api/) |
| AUT-09 | Aggregate child-change events | — |
| AUT-10 | Cron task listing CLI | — |

## DOC — document data plane

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| DOC-01 | Document CRUD | [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/), [Documents: records with a memory](/discover/how-it-works/documents/) |
| DOC-02 | List and filter grammar | [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [Opérateurs de filtre](/fr/reference/filter-operators/), [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| DOC-03 | Aggregates | [Utiliser l’API REST](/fr/build/apps/data/rest-api/) |
| DOC-04 | ETag caching | [Utiliser l’API REST](/fr/build/apps/data/rest-api/) |
| DOC-05 | Links and backrefs | [Références et liens entrants](/fr/build/model/relations/references-links/) |
| DOC-06 | Cross-doctype search | [Recherche](/fr/build/apps/data/search/), [Recherche et palette de commandes](/fr/use/finding/search/) |
| DOC-07 | Atomic parent and children create | [Composition parent/enfant](/fr/build/model/relations/parent-child/) |
| DOC-08 | Document copy | [Le journal des mutations](/fr/admin/under-the-hood/change-log/) |
| DOC-09 | Write-only and secret fields | [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/), [Sécurité et gouvernance](/fr/discover/security/) |
| DOC-10 | Reference validation | [Références et liens entrants](/fr/build/model/relations/references-links/) |
| DOC-11 | Document import and export | [Import/export en masse via l’API](/fr/build/apps/data/bulk-import-export/), [Importer et exporter des données](/fr/use/documents/import-export/) |
| DOC-12 | Realtime updates | [Temps réel avec WebSockets](/fr/build/apps/data/realtime/) |
| DOC-13 | Field defaults and normalization | [Types de champs (guide)](/fr/build/model/data/field-types/), [Types de champs](/fr/reference/field-types/), [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| DOC-14 | Child-list list grammar | — |
| DOC-15 | App tokens on WebSocket | — |

## DOM — domains, doctypes, schema authoring

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| DOM-01 | Domains | [How domains stay isolated](/build/deeper/domain-isolation/), [Build your first domain](/build/first-hour/first-domain/), [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/), [Domaines et isolement](/fr/discover/how-it-works/domains/) |
| DOM-02 | Draft and publish lifecycle | [Build your first domain](/build/first-hour/first-domain/), [From dev to production](/build/model/dev-to-production/), [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/), [Brouillon → publication](/fr/build/model/in-app/how-drafts-work/), [Choose how you build](/build/model/), [Domaines et isolement](/fr/discover/how-it-works/domains/) |
| DOM-03 | Doctypes | [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/), [Build your first domain](/build/first-hour/first-domain/), [Concevoir des doctypes](/fr/build/model/data/design-doctypes/), [Schéma de définition de doctype](/fr/reference/doctype-schema/) |
| DOM-04 | Field type system | [Build your first domain](/build/first-hour/first-domain/), [Types de champs (guide)](/fr/build/model/data/field-types/), [Types de champs](/fr/reference/field-types/) |
| DOM-05 | Composition (parent and children) | [Composition parent/enfant](/fr/build/model/relations/parent-child/) |
| DOM-06 | Sidecars | [Sidecars (commentaires, pièces jointes)](/fr/build/model/relations/comments-attachments/), [Documents: records with a memory](/discover/how-it-works/documents/), [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/) |
| DOM-07 | Named actions | [Actions nommées](/fr/build/model/behaviour/named-actions/) |
| DOM-08 | Lifecycle scripts | [Scripts de cycle de vie et garde-fous](/fr/build/model/behaviour/scripts-and-guards/), [API Lua](/fr/reference/lua-api/) |
| DOM-09 | Computed fields | [Champs calculés](/fr/build/model/data/computed-fields/) |
| DOM-10 | Sequential identifiers | [Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/) |
| DOM-11 | Unique constraints | [Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/) |
| DOM-12 | Named scopes | [Les périmètres de lignes](/fr/admin/people/row-scopes/), [Les périmètres nommés](/fr/build/model/access/named-scopes/) |
| DOM-13 | Domain editors | [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/) |
| DOM-14 | Domain grants | [Réplication entre domaines](/fr/build/deeper/cross-domain-replication/), [How domains stay isolated](/build/deeper/domain-isolation/), [Partager des données entre domaines](/fr/build/model/relations/across-domains/), [Domaines et isolement](/fr/discover/how-it-works/domains/) |
| DOM-15 | Portable domain bundles | [The same domain in files](/build/first-hour/first-domain-in-files/), [Déplacer des domaines avec des bundles](/fr/build/model/bundles/), [From dev to production](/build/model/dev-to-production/), [The domain file layout](/build/model/in-files/domain-files/) |
| DOM-16 | Definition diagnostics | [Build your first domain](/build/first-hour/first-domain/), [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/), [Brouillon → publication](/fr/build/model/in-app/how-drafts-work/) |
| DOM-17 | Lazy document migration | [Évolution du schéma](/fr/build/deeper/schema-evolution/), [Faire évoluer un schéma](/fr/build/model/change-a-live-domain/) |
| DOM-18 | Re-projection CLI | [Faire évoluer un schéma](/fr/build/model/change-a-live-domain/), [CLI facet](/fr/reference/cli-facet/) |
| DOM-19 | Dev domain watcher | [The same domain in files](/build/first-hour/first-domain-in-files/), [From dev to production](/build/model/dev-to-production/), [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/), [The domain file layout](/build/model/in-files/domain-files/), [Le watcher de domaines en dev](/fr/build/model/in-files/domain-watcher/), [Build domains with a coding agent](/build/model/in-files/with-a-coding-agent/), [Choose how you build](/build/model/) |
| DOM-20 | Domain schematic | [La vue schématique](/fr/build/model/views/schematic/) |
| DOM-21 | CollectionView | [Build your first domain](/build/first-hour/first-domain/), [Vues de collection](/fr/build/model/views/lists-boards-calendars/), [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| DOM-22 | DocumentView templates | [Modèles de vue](/fr/build/model/views/document-pages/), [Schéma du modèle DVT](/fr/reference/dvt-schema/), [Contexte des modèles Jinja2](/fr/reference/jinja2-context/) |
| DOM-23 | Jinja2 templating for derived columns | [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/), [Nom d’affichage et texte de recherche](/fr/build/model/views/names-and-search/), [Contexte des modèles Jinja2](/fr/reference/jinja2-context/) |
| DOM-24 | Core seeding | [Amorçage et tâches CLI](/fr/admin/install/bootstrap/), [Installer pour le développement](/fr/build/dev-environment/), [Run Facet](/build/first-hour/run-facet/) |
| DOM-25 | Cross-domain field replication | [Réplication entre domaines](/fr/build/deeper/cross-domain-replication/), [Partager des données entre domaines](/fr/build/model/relations/across-domains/) |
| DOM-26 | Doctype maintenance console | — |
| DOM-27 | Eager document migration | — |
| DOM-28 | Migration retry CLI | — |
| DOM-29 | Collection view starter screen | — |
| DOM-30 | Collection view pinning | — |
| DOM-31 | Draft from live domain | — |
| DOM-32 | Kanban lane control | — |

## FE — workspace SPA surfaces

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| FE-01 | Auth screens | [Run Facet](/build/first-hour/run-facet/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| FE-02 | Dashboard | [Le tableau de bord](/fr/use/first-day/dashboard/) |
| FE-03 | List surfaces | [Build your first domain](/build/first-hour/first-domain/), [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| FE-04 | Document show page | [Modèles de vue](/fr/build/model/views/document-pages/), [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/), [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| FE-05 | Document form | [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| FE-06 | History and rollback | [Historique et retour arrière](/fr/use/documents/history-undo/) |
| FE-07 | Command palette | [Recherche et palette de commandes](/fr/use/finding/search/) |
| FE-08 | Keyboard shortcuts | [Raccourcis clavier](/fr/use/finding/keyboard-shortcuts/) |
| FE-09 | Notifications UI | [Notifications](/fr/use/notifications/) |
| FE-10 | Builder | [Build your first domain](/build/first-hour/first-domain/), [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/) |
| FE-11 | Configure access | [Gérer les comptes](/fr/admin/people/accounts/), [Give your team access](/build/first-hour/team-access/) |
| FE-12 | Configure apps | [La portée des apps (attributions)](/fr/admin/apps-access/app-grants/), [Enregistrer une app](/fr/build/apps/connect/register/) |
| FE-13 | Configure domains | [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/) |
| FE-14 | Configure platform | [Paramètres système](/fr/admin/configure/system-settings/), [Le SSO avec OIDC](/fr/admin/people/sso/) |
| FE-15 | Configure currencies | [Devises et montants](/fr/admin/configure/currencies/) |
| FE-16 | Configure audit | [Auditer l’activité](/fr/admin/history/audit/) |
| FE-17 | Settings | [Paramètres, sessions et clés API](/fr/use/account/) |
| FE-18 | Import and export UI | [Importer et exporter des données](/fr/use/documents/import-export/) |
| FE-19 | Welcome tour | [Run Facet](/build/first-hour/run-facet/) |
| FE-20 | Internationalization | [Localisation](/fr/admin/configure/languages/) |
| FE-21 | OAuth consent page | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/) |
| FE-22 | Assistant chat UI | [Utiliser l’assistant](/fr/use/assistant/) |
| FE-23 | Grid view (dormant) | Exclu de la documentation utilisateur |
| FE-24 | Peek drawer | — |
| FE-25 | Trash mode and restore | — |

## IAM — identity and authentication

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| IAM-01 | Password login and sessions | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-02 | Refresh rotation and reuse detection | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-03 | MFA with TOTP and backup codes | [Imposer le MFA](/fr/admin/people/mfa/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-04 | Forced password change | [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-05 | Self-service password reset | [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-06 | Invites and temporary passwords | [Gérer les comptes](/fr/admin/people/accounts/), [People and access](/admin/people/), [Give your team access](/build/first-hour/team-access/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-07 | Account lifecycle | [Gérer les comptes](/fr/admin/people/accounts/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-08 | Inbound OIDC SSO | [Le SSO avec OIDC](/fr/admin/people/sso/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-09 | Static API keys | [Accès machine : clés d’API](/fr/admin/apps-access/api-keys/), [Sécurité et gouvernance](/fr/discover/security/), [Paramètres, sessions et clés API](/fr/use/account/) |
| IAM-10 | Login throttle and lockout | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-11 | Session management | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Paramètres, sessions et clés API](/fr/use/account/) |
| IAM-12 | Bootstrap CLI | [Amorçage et tâches CLI](/fr/admin/install/bootstrap/), [Déployer en production](/fr/admin/install/production/), [Installer pour le développement](/fr/build/dev-environment/), [Run Facet](/build/first-hour/run-facet/), [Sécurité et gouvernance](/fr/discover/security/), [CLI facet](/fr/reference/cli-facet/) |
| IAM-13 | Login event log | [Auditer l’activité](/fr/admin/history/audit/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-14 | Caller identity endpoint | [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/), [Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-15 | Service accounts | [Sécurité et gouvernance](/fr/discover/security/) |

## PLT — platform, operations, observability

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| PLT-01 | YAML config | [Fichiers de configuration](/fr/admin/configure/configuration-files/), [Installer pour le développement](/fr/build/dev-environment/), [Run Facet](/build/first-hour/run-facet/), [Clés du fichier de configuration](/fr/reference/config-keys/) |
| PLT-02 | System settings | [Paramètres système](/fr/admin/configure/system-settings/), [Imposer le MFA](/fr/admin/people/mfa/), [Clés de réglage système](/fr/reference/system-settings-keys/) |
| PLT-03 | Secret store | [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/) |
| PLT-04 | Artifact store | [Stockage de fichiers : local ou S3](/fr/admin/configure/file-storage/), [Téléverser et servir des fichiers](/fr/build/apps/data/files/), [Fichiers et artifacts dans les champs](/fr/build/model/data/files/) |
| PLT-05 | Managed indexes | [Index gérés](/fr/admin/keep-running/indexes/) |
| PLT-06 | Health probes | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/), [Sondes et métriques](/fr/reference/health-metrics-names/) |
| PLT-07 | Metrics | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/), [Sondes et métriques](/fr/reference/health-metrics-names/) |
| PLT-08 | OpenTelemetry tracing | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/) |
| PLT-09 | Structured logging | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/) |
| PLT-10 | Database topology | [Prérequis système et topologie](/fr/admin/install/requirements/) |
| PLT-11 | Migrations | [Déployer en production](/fr/admin/install/production/), [Migrations de base de données](/fr/admin/keep-running/migrations/), [Mises à niveau et arrêt propre](/fr/admin/keep-running/upgrades/), [CLI facet](/fr/reference/cli-facet/) |
| PLT-12 | OpenAPI specification | [API REST](/fr/reference/rest-api/) |
| PLT-13 | HTTP admission gates | [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [Réponses d’erreur](/fr/reference/error-responses/) |
| PLT-14 | Currency registry and money math | [Devises et montants](/fr/admin/configure/currencies/) |
| PLT-15 | Graceful shutdown | [Mises à niveau et arrêt propre](/fr/admin/keep-running/upgrades/) |
| PLT-16 | Container images | [Déployer avec des conteneurs](/fr/admin/install/containers/), [Déployer en production](/fr/admin/install/production/), [Prérequis système et topologie](/fr/admin/install/requirements/), [Installer pour le développement](/fr/build/dev-environment/), [Run Facet](/build/first-hour/run-facet/) |
| PLT-17 | Account settings store | [Clés de réglage de compte](/fr/reference/account-settings-keys/), [Paramètres, sessions et clés API](/fr/use/account/) |

## RBC — authorization and governance

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| RBC-01 | Roles | [People and access](/admin/people/), [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/), [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/), [Give your team access](/build/first-hour/team-access/), [Roles: who sees and does what](/discover/how-it-works/roles/), [Sécurité et gouvernance](/fr/discover/security/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/) |
| RBC-02 | Role assignment and election | [Affecter les rôles et l’élection](/fr/admin/people/assign-roles/), [Give your team access](/build/first-hour/team-access/), [Roles: who sees and does what](/discover/how-it-works/roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-03 | Read enforcement | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Sécurité et gouvernance](/fr/discover/security/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/) |
| RBC-04 | Field visibility tags | [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/), [Give your team access](/build/first-hour/team-access/), [Roles: who sees and does what](/discover/how-it-works/roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-05 | Row scopes | [Les périmètres de lignes](/fr/admin/people/row-scopes/), [Give your team access](/build/first-hour/team-access/), [Roles: who sees and does what](/discover/how-it-works/roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-06 | Write enforcement | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Sécurité et gouvernance](/fr/discover/security/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/) |
| RBC-07 | Role authority guard | [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/), [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-08 | App grants | [La portée des apps (attributions)](/fr/admin/apps-access/app-grants/), [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/), [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/), [Apps: built fast, replaced freely](/discover/how-it-works/apps/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-09 | Metadata gate | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-10 | Auth contexts | [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-11 | Permission manifest | [Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-12 | Role connectivity channels | [Sécurité et gouvernance](/fr/discover/security/) |

## Voir aussi

- [Pour commencer](/fr/discover/)
- [Construire des domaines](/fr/build/)
- [Gouverner l'accès](/fr/admin/)
- [Construire des apps](/fr/build/apps/)
- [Opérer](/fr/admin/)
