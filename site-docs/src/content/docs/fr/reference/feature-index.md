---
title: Index des fonctionnalités
description: Chaque identifiant de fonctionnalité de l'inventaire, avec les pages qui le couvrent.
audience: [developer, operator]
features: []
verified_at: f1409cdc
---

> Généré depuis `site-docs/inventory.yml` par `make gen-docs-feature-index`. Ne modifiez pas ce fichier à la main.

Cette page relie chaque identifiant de fonctionnalité de l'inventaire (138 fonctionnalités dans 10 domaines) aux pages de documentation qui le couvrent. Le contrôle de couverture du build demande à chaque identifiant d'apparaître sur au moins une page ou de figurer sur la liste d'exclusion de `site-docs/coverage-exclude.yml`. Un tiret signifie qu'aucune page ne cite encore l'identifiant.

## AI — assistants, agent tools, MCP

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| AI-01 | Workspace assistant | [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/), [Utiliser l’assistant](/fr/use/assistant/) |
| AI-02 | Domain-builder assistant | [L’assistant de construction de domaines](/fr/build/model/in-app/build-with-assistant/) |
| AI-03 | Per-app assistant | [Intégrer l’assistant](/fr/build/apps/host/embed-assistant/) |
| AI-04 | Agent tool catalogue | [Outils pour agents](/fr/build/apps/agents/agent-tools/), [L’IA sous les droits de l’appelant](/fr/discover/how-it-works/assistant/), [Outils d’agent](/fr/reference/agent-tools/) |
| AI-05 | MCP resource server | [MCP : connecter des agents](/fr/build/apps/agents/mcp/) |
| AI-06 | Skill corpus | [Outils pour agents](/fr/build/apps/agents/agent-tools/), [Bâtir des apps avec un agent de code](/fr/build/apps/agents/coding-agents/), [L’assistant de construction de domaines](/fr/build/model/in-app/build-with-assistant/) |
| AI-07 | Usage ledger and limits | [Gouverner l’assistant](/fr/admin/assistant/govern/), [Configurer l’assistant](/fr/admin/assistant/connect-a-model/) |
| AI-08 | Assistant configuration | [Gouverner l’assistant](/fr/admin/assistant/govern/), [Configurer l’assistant](/fr/admin/assistant/connect-a-model/) |
| AI-09 | Stale-turn sweep | [Configurer l’assistant](/fr/admin/assistant/connect-a-model/) |

## APP — registered apps, OAuth, hosting, SDKs

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| APP-01 | App registry | [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/), [Enregistrer une app](/fr/build/apps/connect/register/) |
| APP-02 | OAuth 2.1 authorization server | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/) |
| APP-03 | DPoP proof binding | [Liaison DPoP des tokens](/fr/build/apps/connect/dpop/) |
| APP-04 | Dynamic client registration | [MCP : connecter des agents](/fr/build/apps/agents/mcp/) |
| APP-05 | Consent screen | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/) |
| APP-06 | App hosting | [Déployer votre frontend](/fr/build/apps/host/deploy/), [Déployer avec des conteneurs](/fr/admin/install/containers/), [Déployer en production](/fr/admin/install/production/) |
| APP-07 | App API keys and service accounts | [Comptes de service pour les apps backend](/fr/build/apps/connect/backend-apps/) |
| APP-08 | CORS for registered origins | [CORS et origines autorisées](/fr/build/apps/connect/cors/) |
| APP-09 | Developer CLI | [Déployer votre frontend](/fr/build/apps/host/deploy/), [Démarrage rapide avec la CLI dev](/fr/build/apps/quickstart/), [CLI des apps Facet](/fr/reference/cli-npm/) |
| APP-10 | TypeScript SDK | [Le SDK TypeScript (`@facetapp/sdk`)](/fr/build/apps/data/sdk/) |
| APP-11 | Chat embed | [Intégrer l’assistant](/fr/build/apps/host/embed-assistant/) |

## AUD — mutation log, audit, rollback

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| AUD-01 | Append-only mutation log | [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [Architecture en un coup d’œil](/fr/discover/how-it-works/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-02 | Audit reading | [Auditer l’activité](/fr/admin/history/audit/), [Sécurité et gouvernance](/fr/discover/security/), [Historique et retour arrière](/fr/use/documents/history-undo/) |
| AUD-03 | Audit redaction | [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-04 | Rollback | [Revenir en arrière](/fr/admin/history/roll-back/), [Sécurité et gouvernance](/fr/discover/security/), [Historique et retour arrière](/fr/use/documents/history-undo/) |
| AUD-05 | Write-time coalescing | [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [La rétention : quoi et combien de temps](/fr/admin/history/retention/), [Régler la rétention](/fr/admin/history/retention/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-06 | Retention compaction | [La rétention : quoi et combien de temps](/fr/admin/history/retention/), [Régler la rétention](/fr/admin/history/retention/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-07 | Tombstone retention | [La rétention : quoi et combien de temps](/fr/admin/history/retention/), [Régler la rétention](/fr/admin/history/retention/), [Sécurité et gouvernance](/fr/discover/security/) |
| AUD-08 | Provenance and cause metadata | [Le journal des mutations](/fr/admin/under-the-hood/change-log/), [Auditer l’activité](/fr/admin/history/audit/), [Sécurité et gouvernance](/fr/discover/security/) |

## AUT — events, hooks, webhooks, jobs, notifications, mail

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| AUT-01 | Event bus | [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/), [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/), [Architecture en un coup d’œil](/fr/discover/how-it-works/) |
| AUT-02 | Domain event hooks | [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/) |
| AUT-03 | Outbound webhooks | [Webhooks sortants](/fr/build/model/automation/webhooks/), [Payloads des webhooks](/fr/reference/webhook-payloads/) |
| AUT-04 | Background jobs | [Jobs en arrière-plan et cron](/fr/admin/keep-running/jobs-cron/) |
| AUT-05 | Cron scheduler and maintenance | [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/), [Jobs en arrière-plan et cron](/fr/admin/keep-running/jobs-cron/) |
| AUT-06 | In-app notifications | [Notifications et mentions](/fr/build/model/automation/notifications/), [Notifications](/fr/use/notifications/) |
| AUT-07 | Outbound email | [Envoi des mails](/fr/admin/configure/email/) |
| AUT-08 | Lua scripting engine | [Hooks d’événement et planifiés](/fr/build/model/automation/event-hooks/), [API Lua](/fr/reference/lua-api/) |

## DOC — document data plane

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| DOC-01 | Document CRUD | [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) |
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

## DOM — domains, doctypes, schema authoring

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| DOM-01 | Domains | [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/), [Domaines et isolement](/fr/discover/how-it-works/domains/) |
| DOM-02 | Draft and publish lifecycle | [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/), [Brouillon → publication](/fr/build/model/in-app/how-drafts-work/) |
| DOM-03 | Doctypes | [Concevoir des doctypes](/fr/build/model/data/design-doctypes/), [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/), [Schéma de définition de doctype](/fr/reference/doctype-schema/) |
| DOM-04 | Field type system | [Types de champs (guide)](/fr/build/model/data/field-types/), [Types de champs](/fr/reference/field-types/) |
| DOM-05 | Composition (parent and children) | [Composition parent/enfant](/fr/build/model/relations/parent-child/) |
| DOM-06 | Sidecars | [Sidecars (commentaires, pièces jointes)](/fr/build/model/relations/comments-attachments/), [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/) |
| DOM-07 | Named actions | [Actions nommées](/fr/build/model/behaviour/named-actions/) |
| DOM-08 | Lifecycle scripts | [Scripts de cycle de vie et garde-fous](/fr/build/model/behaviour/scripts-and-guards/), [API Lua](/fr/reference/lua-api/) |
| DOM-09 | Computed fields | [Champs calculés](/fr/build/model/data/computed-fields/) |
| DOM-10 | Sequential identifiers | [Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/) |
| DOM-11 | Unique constraints | [Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/) |
| DOM-12 | Named scopes | [Les périmètres nommés](/fr/build/model/access/named-scopes/), [Les périmètres de lignes](/fr/admin/people/row-scopes/) |
| DOM-13 | Domain editors | [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/) |
| DOM-14 | Domain grants | [Partager des données entre domaines](/fr/build/model/relations/across-domains/), [Réplication entre domaines](/fr/build/deeper/cross-domain-replication/), [Domaines et isolement](/fr/discover/how-it-works/domains/) |
| DOM-15 | Portable domain bundles | [Déplacer des domaines avec des bundles](/fr/build/model/bundles/) |
| DOM-16 | Definition diagnostics | [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/) |
| DOM-17 | Lazy document migration | [Faire évoluer un schéma](/fr/build/model/change-a-live-domain/), [Évolution du schéma](/fr/build/deeper/schema-evolution/) |
| DOM-18 | Re-projection CLI | [Faire évoluer un schéma](/fr/build/model/change-a-live-domain/), [CLI facet](/fr/reference/cli-facet/) |
| DOM-19 | Dev domain watcher | [Le watcher de domaines en dev](/fr/build/model/in-files/domain-watcher/) |
| DOM-20 | Domain schematic | [La vue schématique](/fr/build/model/views/schematic/) |
| DOM-21 | CollectionView | [Vues de collection](/fr/build/model/views/lists-boards-calendars/), [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| DOM-22 | DocumentView templates | [Modèles de vue](/fr/build/model/views/document-pages/), [Schéma du modèle DVT](/fr/reference/dvt-schema/), [Contexte des modèles Jinja2](/fr/reference/jinja2-context/) |
| DOM-23 | Jinja2 templating for derived columns | [Nom d’affichage et texte de recherche](/fr/build/model/views/names-and-search/), [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/), [Contexte des modèles Jinja2](/fr/reference/jinja2-context/) |
| DOM-24 | Core seeding | [Amorçage et tâches CLI](/fr/admin/install/bootstrap/), [Installer pour le développement](/fr/build/dev-environment/) |
| DOM-25 | Cross-domain field replication | [Partager des données entre domaines](/fr/build/model/relations/across-domains/), [Réplication entre domaines](/fr/build/deeper/cross-domain-replication/) |

## FE — workspace SPA surfaces

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| FE-01 | Auth screens | [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| FE-02 | Dashboard | [Le tableau de bord](/fr/use/first-day/dashboard/) |
| FE-03 | List surfaces | [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) |
| FE-04 | Document show page | [Modèles de vue](/fr/build/model/views/document-pages/), [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/), [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| FE-05 | Document form | [Consulter et modifier un document](/fr/use/documents/view-and-edit/) |
| FE-06 | History and rollback | [Historique et retour arrière](/fr/use/documents/history-undo/) |
| FE-07 | Command palette | [Recherche et palette de commandes](/fr/use/finding/search/) |
| FE-08 | Keyboard shortcuts | [Raccourcis clavier](/fr/use/finding/keyboard-shortcuts/) |
| FE-09 | Notifications UI | [Notifications](/fr/use/notifications/) |
| FE-10 | Builder | — |
| FE-11 | Configure access | [Gérer les comptes](/fr/admin/people/accounts/) |
| FE-12 | Configure apps | [Enregistrer une app](/fr/build/apps/connect/register/), [La portée des apps (attributions)](/fr/admin/apps-access/app-grants/) |
| FE-13 | Configure domains | [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/) |
| FE-14 | Configure platform | [Le SSO avec OIDC](/fr/admin/people/sso/), [Paramètres système](/fr/admin/configure/system-settings/) |
| FE-15 | Configure currencies | [Devises et montants](/fr/admin/configure/currencies/) |
| FE-16 | Configure audit | [Auditer l’activité](/fr/admin/history/audit/) |
| FE-17 | Settings | [Paramètres, sessions et clés API](/fr/use/account/) |
| FE-18 | Import and export UI | [Importer et exporter des données](/fr/use/documents/import-export/) |
| FE-19 | Welcome tour | — |
| FE-20 | Internationalization | [Localisation](/fr/admin/configure/languages/) |
| FE-21 | OAuth consent page | [Connexion utilisateur : OAuth 2.1 + PKCE](/fr/build/apps/connect/user-login/) |
| FE-22 | Assistant chat UI | [Utiliser l’assistant](/fr/use/assistant/) |

## IAM — identity and authentication

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| IAM-01 | Password login and sessions | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-02 | Refresh rotation and reuse detection | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-03 | MFA with TOTP and backup codes | [Imposer le MFA](/fr/admin/people/mfa/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-04 | Forced password change | [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-05 | Self-service password reset | [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-06 | Invites and temporary passwords | [Gérer les comptes](/fr/admin/people/accounts/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-07 | Account lifecycle | [Gérer les comptes](/fr/admin/people/accounts/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-08 | Inbound OIDC SSO | [Le SSO avec OIDC](/fr/admin/people/sso/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-09 | Static API keys | [Accès machine : clés d’API](/fr/admin/apps-access/api-keys/), [Sécurité et gouvernance](/fr/discover/security/), [Paramètres, sessions et clés API](/fr/use/account/) |
| IAM-10 | Login throttle and lockout | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) |
| IAM-11 | Session management | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/), [Sécurité et gouvernance](/fr/discover/security/), [Paramètres, sessions et clés API](/fr/use/account/) |
| IAM-12 | Bootstrap CLI | [Amorçage et tâches CLI](/fr/admin/install/bootstrap/), [Déployer en production](/fr/admin/install/production/), [CLI facet](/fr/reference/cli-facet/), [Installer pour le développement](/fr/build/dev-environment/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-13 | Login event log | [Auditer l’activité](/fr/admin/history/audit/), [Sécurité et gouvernance](/fr/discover/security/) |
| IAM-14 | Caller identity endpoint | [Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/), [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/), [Sécurité et gouvernance](/fr/discover/security/) |

## PLT — platform, operations, observability

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| PLT-01 | YAML config | [Fichiers de configuration](/fr/admin/configure/configuration-files/), [Clés du fichier de configuration](/fr/reference/config-keys/), [Installer pour le développement](/fr/build/dev-environment/) |
| PLT-02 | System settings | [Imposer le MFA](/fr/admin/people/mfa/), [Paramètres système](/fr/admin/configure/system-settings/), [Clés de réglage système](/fr/reference/system-settings-keys/) |
| PLT-03 | Secret store | [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/) |
| PLT-04 | Artifact store | [Téléverser et servir des fichiers](/fr/build/apps/data/files/), [Fichiers et artifacts dans les champs](/fr/build/model/data/files/), [Stockage de fichiers : local ou S3](/fr/admin/configure/file-storage/) |
| PLT-05 | Managed indexes | [Index gérés](/fr/admin/keep-running/indexes/) |
| PLT-06 | Health probes | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/), [Sondes et métriques](/fr/reference/health-metrics-names/) |
| PLT-07 | Metrics | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/), [Sondes et métriques](/fr/reference/health-metrics-names/) |
| PLT-08 | OpenTelemetry tracing | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/) |
| PLT-09 | Structured logging | [Health checks, métriques, tracing, logs](/fr/admin/keep-running/monitoring/) |
| PLT-10 | Database topology | [Prérequis système et topologie](/fr/admin/install/requirements/) |
| PLT-11 | Migrations | [Migrations de base de données](/fr/admin/keep-running/migrations/), [Déployer en production](/fr/admin/install/production/), [Mises à niveau et arrêt propre](/fr/admin/keep-running/upgrades/), [CLI facet](/fr/reference/cli-facet/) |
| PLT-12 | OpenAPI specification | [API REST](/fr/reference/rest-api/), [Facet est-il fait pour vous ?](/fr/discover/is-it-right-for-you/) |
| PLT-13 | HTTP admission gates | [Utiliser l’API REST](/fr/build/apps/data/rest-api/), [Réponses d’erreur](/fr/reference/error-responses/) |
| PLT-14 | Currency registry and money math | [Devises et montants](/fr/admin/configure/currencies/) |
| PLT-15 | Graceful shutdown | [Mises à niveau et arrêt propre](/fr/admin/keep-running/upgrades/) |
| PLT-16 | Container images | [Déployer avec des conteneurs](/fr/admin/install/containers/), [Déployer en production](/fr/admin/install/production/), [Prérequis système et topologie](/fr/admin/install/requirements/), [Installer pour le développement](/fr/build/dev-environment/) |
| PLT-17 | Account settings store | [Clés de réglage de compte](/fr/reference/account-settings-keys/), [Paramètres, sessions et clés API](/fr/use/account/) |

## RBC — authorization and governance

| ID | Fonctionnalité | Pages |
| --- | --- | --- |
| RBC-01 | Roles | [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/), [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-02 | Role assignment and election | [Affecter les rôles et l’élection](/fr/admin/people/assign-roles/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-03 | Read enforcement | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-04 | Field visibility tags | [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-05 | Row scopes | [Les périmètres de lignes](/fr/admin/people/row-scopes/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-06 | Write enforcement | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Syntaxe des lignes de permission](/fr/reference/permission-syntax/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-07 | Role authority guard | [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/), [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-08 | App grants | [Comment fonctionnent les apps sur Facet](/fr/build/apps/how-apps-work/), [Apps : attributions ∩ rôles](/fr/build/apps/connect/what-an-app-can-do/), [La portée des apps (attributions)](/fr/admin/apps-access/app-grants/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-09 | Metadata gate | [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-10 | Auth contexts | [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/), [Architecture en un coup d’œil](/fr/discover/how-it-works/), [Sécurité et gouvernance](/fr/discover/security/) |
| RBC-11 | Permission manifest | [Dimensionner l’UI avec le manifeste](/fr/build/apps/connect/permission-manifest/), [Sécurité et gouvernance](/fr/discover/security/) |

## Voir aussi

- [Pour commencer](/fr/discover/)
- [Construire des domaines](/fr/build/)
- [Gouverner l'accès](/fr/admin/)
- [Construire des apps](/fr/build/apps/)
- [Opérer](/fr/admin/)
