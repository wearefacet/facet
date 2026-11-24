# Project Structure

This document gives a high-level overview of the Facet project. Each concern is documented in its own file under `doc/`.

---

## Overview

Facet is a **governance layer** for mid-sized organizations: one governed place for the data of the organization. Business information is structured as documents — organized by **domain** and **doctype**, stored as JSONB in PostgreSQL. Roles decide who reads and writes, per doctype down to single fields and rows. Every mutation is recorded in an append-only event log, and any document can be audited and rolled back to a prior state.

**Backend stack:** Crystal + Kemal (HTTP) + PostgreSQL (PG) + Lua scripting + OpenTelemetry (tracing).
**Frontend stack:** SvelteKit (Svelte 5, runes) + TypeScript + Tailwind CSS + Bits UI + Storybook + Vitest (pure logic).
**Docs site stack:** Astro (Starlight) + TypeScript + Tailwind CSS + Svelte — public documentation in `site-docs/`.

**URL casing invariant:** a lowercase first path segment is a domain id (the document space); an uppercase first path segment is an application or infrastructure route (`/Api`, `/OAuth`, `/A`, `/Ws`, `/Healthcheck`, `/Edge`, plus the SPA's `/Configure`, `/Builder`, `/Settings`). `.well-known` paths are the one exception (a dot cannot start a domain). See [`backend/http-layer.md`](backend/http-layer.md) → The casing invariant.

---

## Directory Layout

```
facet/
├── AGENTS.md              # Engineering conventions & quirks
├── README.md              # Product overview + License section
├── CONTRIBUTING.md        # Onboarding map — environment, commands, subsystems → concern docs
├── LICENSE                # Business Source License 1.1 (BUSL-1.1) with the Facet Additional Use Grant
├── LICENSING.md           # Plain-language licensing FAQ (LICENSING.fr.md is the French version)
├── TRADEMARKS.md          # Facet name and logo usage rules
├── CLA.md                 # Contributor License Agreement (signed via CLA Assistant)
├── NOTICE                 # Copyright + third-party notice
├── THIRD_PARTY_LICENSES.md # Shard and npm dependency license audit
├── CHANGELOG.md           # Release notes
├── Makefile              # Backend build/test/run targets (wrap `crystal` invocations)
├── shard.yml              # Dependencies & metadata
├── shard.lock             # Dependency lockfile
├── .gitignore             # Ignores /lib/ and /tmp/
├── data/                  # Runtime data
│   ├── seeds/             # Seed directories — each {domain}.{Doctype}/ has definition.yml, optional script.lua, optional documents.yml (embedded into the binary at compile time)
│   │   ├── app.App/             # `app.App` — registered external app (Phase 1). `create` hook autogenerates client_id; update hook enforces slug immutability + the app-scoped guard; both hooks validate redirect_uris + the headless coherence rule; `deploy` named action; `documents.yml` seeds the `facet-cli` app (public OAuth client, headless).
│   │   ├── app.Deployment/      # `app.Deployment` — one uploaded build of an app; created only by the deploy route.
│   │   ├── core.Attachment/     # `core.Attachment` — sidecar doctype; one row per uploaded artifact (sidecar.md)
│   │   ├── core.CollectionView/
│   │   ├── core.Comment/         # `core.Comment` — sidecar doctype (target reference + author + body; Lua `create` hook forces the caller's author).
│   │   ├── core.Currency/       # core.Currency — one row per world currency; hydration source for the currency registry (util-money.md)
│   │   ├── core.DocType/
│   │   ├── core.DocumentView/
│   │   ├── core.Domain/
│   │   ├── core.DomainEditor/   # `core.DomainEditor` — scoped domain-admin membership record (domain-editors.md)
│   │   ├── core.DomainGrant/    # `core.DomainGrant` — cross-domain read-consent contract under the producer domain (domain-grants.md)
│   │   ├── core.SystemSettings/ # `core.SystemSettings` — runtime-settings singleton (one document, id `settings`)
│   │   ├── core.Webhook/        # `core.Webhook` — outbound HTTP webhook registration (webhook.md)
│   │   ├── iam.Account/
│   │   ├── iam.ArtifactEvent/   # `iam.ArtifactEvent` — artifact purge audit; snapshots the destroyed bytes, fail-closed (artifact.md)
│   │   ├── iam.LoginEvent/
│   │   ├── iam.OIDCProvider/    # `iam.OIDCProvider` — inbound OIDC provider config, one provider per document (oidc.md)
│   │   └── iam.Roles/
│   └── fixtures/          # Portable-domain bundles (`*.facet-domain/`) produced by `facet domain:export` — test/dev data for specs and Storybook
├── doc/                   # Documentation — stack docs (backend/, frontend/, shared/), package + plan notes (packages/, plans/), runbooks (ops/), + project-structure.md
├── site-docs/             # Public documentation website — Astro + Starlight + Tailwind, English + French; full tree in doc/site-docs.md
├── frontend/              # SvelteKit web application (Svelte 5 runes + Tailwind + Bits UI; full tree in doc/frontend/workflow.md)
│   ├── src/routes/            # Route subtrees — /, /Login (held-login + SSO), /ResetPassword, /oauth, /[domain], /Builder, /Configure, /Settings
│   │   └── Configure/access/  # Access admin — roles, assignments, accounts (+page.svelte); /Configure/currencies edits the core.Currency registry rows
│   ├── src/lib/components/
│   │   ├── primitives/        # Feature-free widgets (actions / data / content / forms / navigation / surfaces)
│   │   ├── features/          # Feature-owned UI, one subfolder per feature (configure/ holds the DoctypeEditor + DomainEditor families — see doc/frontend/configure-editors.md):
│   │   │   ├── auth/          # LoginScreen (SSO provider list), consent, MFA (challenge / enroll), forced change, password reset
│   │   │   ├── admin/         # RBAC (Can, RbacEditor, NewRoleDialog) + account admin (AccountCredentialActions, TemporaryPasswordPanel)
│   │   │   ├── search/        # CommandPalette — the top-bar search / Cmd+K surface (see doc/frontend/command-palette.md)
│   │   │   └── welcome/       # WelcomeTour — first-run tour modal for admins (flag core.show_welcome; see doc/frontend/settings.md → Welcome tour)
│   │   └── schematic/         # Domain schematic
│   └── src/lib/datasource/    # DataSource / DocumentRef abstraction (DocumentDataSource, MockDataSource, clientCache)
├── packages/              # npm packages (standalone — each has its own package.json + lockfile; no workspace file at the root)
│   ├── cli/               # @facetapp/cli — CLI for app developers (TypeScript ESM, commander; dev entry: `scripts/cli`, or `pnpm build` / `pnpm test` inside packages/cli)
│   ├── sdk/               # @facetapp/sdk — TypeScript SDK for Facet apps (HTTP handles, query builder, ETag cache, OAuth helper, WebSocket realtime, artifacts; `pnpm check` / `pnpm test` / `pnpm build` / `pnpm lint` inside packages/sdk; see doc/packages/sdk.md)
│   ├── chat/              # @facetapp/chat — embeddable assistant chat for Facet apps (Svelte 5 custom elements + `FacetAssistant` facade + HTTP/SSE driver + mock; see doc/packages/chat.md)
│   └── tmp/               # Scratch space for package-local experiments (git-ignored, not published)
├── e2e/                   # Dockerized browser E2E gate (own package.json; run via `e2e/run-suite.sh`) — see [`e2e/README.md`](../e2e/README.md)
│   ├── compose.yml        # One throwaway stack: pgvector/Redis/backend/frontend/Caddy + Playwright runner
│   ├── tests/             # Scenario files (`*.e2e.ts`, one per target doc) + `setup/` (admin login → storageState)
│   ├── stack/             # `config.e2e.yml.tmpl`, backend/runner entrypoints, Node runtime shims
│   ├── docker/            # Backend (multi-stage Crystal), frontend (vite preview), runner images
│   └── artifacts/         # Per-scenario traces, videos, HTML report (git-ignored)
├── db/
│   ├── migrations/        # SQL migration files (source of truth — embedded into the binary at compile time, applied in order)
│   └── lua/               # Lua scripts for Redis shard locking (embedded into the binary at compile time)
├── lib/                   # Shard dependencies (git submodules)
├── compose.test.yml       # Throwaway PostgreSQL for the spec suite — port 5433, tmpfs + fsync=off (test-database.md)
├── scripts/               # Dev + CI helper scripts
│   ├── dev                # Dev launcher — Caddy + backend (migrate + server) + frontend in one terminal
│   ├── facet              # Wrapper — rebuild + run the dev binary when sources changed (mtime-tracked)
│   ├── cli                # Wrapper — build @facetapp/cli when stale, then run it
│   ├── init               # One-shot bootstrap — `facet db_reset seed:dev`
│   ├── import-fixtures    # Import data/fixtures bundles into the dev database (--merge; re-runnable)
│   ├── callback_server.cr # HTTP callback server for the MCP OAuth test flow (test-mcp-flow.sh)
│   ├── test-mcp-flow.sh   # Manual end-to-end MCP OAuth flow test — curl + openssl + jq
│   ├── check-license-headers.sh # Fail when a first-party source file misses the SPDX header
│   ├── check-spec-defs.sh # Fail when two spec files define the same top-level def (make spec_defs_check)
│   ├── clean_test_db.cr   # Drop orphaned per-worker test databases from killed spec runs
│   └── loc.sh             # Count lines of code with cloc; deps + generated output excluded
├── bin/                   # Local tooling — vendored linter binary + generator entry points
│   ├── ameba              # Ameba linter binary (vendored)
│   ├── ameba.cr           # Ameba entry point — requires ameba/cli + project extensions
│   ├── lucky.gen.email.cr # Carbon email-generator entry point (shard scaffolding)
│   └── protoc-gen-crystal # protoc plugin for Crystal code generation (vendored binary)
├── src/                   # Application source code
│   ├── main.cr            # Process entrypoint — UTC pin, dotenv, CLI dispatch, server boot
│   ├── boot.cr            # Boot helpers for the server entry point
│   ├── shutdown.cr        # Graceful-shutdown coordination — signal traps, drain, teardown
│   ├── config.cr          # Loads the YAML config for the active environment (per-section loaders)
│   ├── database.cr        # Central database pools + route table + pin model + transaction helpers
│   ├── database/          # Cluster grammar records (`database.cluster` config shape) + wire-state guard (`wire_guard.cr` — discards desynced connections at release)
│   ├── fiber_state.cr     # Fiber-local pins (db_ro/db_rw), per-connection txn depths, request caches
│   ├── migrate.cr         # Migration runner (UP/DOWN per SQL file) + core seeding
│   ├── logging.cr         # Config-driven log setup (JSON or text)
│   ├── metrics.cr         # In-process metrics registry — Prometheus text on GET /metrics
│   ├── service.cr         # Process-wide service identity (service ids, env)
│   ├── error.cr           # Value-type error returned by service operations
│   ├── validation_error.cr # One structured validation error (field, code, message)
│   ├── fiber_state.cr     # Fiber-local request state (txn depth, auth context)
│   ├── cli/
│   │   └── commands.cr    # CLI command registry — names, help text, argument shapes
│   ├── event.cr           # Namespace root for the event system
│   ├── event/
│   │   ├── config.cr               # Event::Config — Redis URL, partitions, stream tuning
│   │   ├── consumer_health.cr      # Event::ConsumerHealth — consumer health for /Healthcheck
│   │   ├── in_process_manager.cr   # Event::InProcessManager — in-memory manager for tests
│   │   ├── loss.cr                 # Event::Loss — at-most-once loss counters (event_loss)
│   │   ├── manager.cr              # Event::Manager — subscriptions, publish, lifecycle
│   │   ├── message.cr              # Event::Message — JSON pack/unpack for one event
│   │   ├── publisher.cr            # Event::Publisher — fiber-local enqueue, flush after commit
│   │   ├── subscription_registry.cr # Event::SubscriptionRegistry — shared subscription record
│   │   └── subscriber/
│   │       ├── app_cache.cr             # AppCache — evicts OAuth origin + app-host caches
│   │       ├── base.cr                  # Subscriber::Base — shared start/stop/subscribe interface
│   │       ├── doctype_cache.cr         # DoctypeCache — doctype definition cache eviction
│   │       ├── fanout.cr                # Fanout — per-process pub/sub fanout driver
│   │       ├── oidc_provider_cache.cr   # OIDCProviderCache — provider cache eviction
│   │       ├── pattern_subscriber.cr    # PatternSubscriber — base for cache invalidation
│   │       ├── role_cache.cr            # RoleCache — RoleStore eviction + tools invalidation
│   │       ├── sidecar_sweep.cr         # SidecarSweep — orphan sweep on host deleted events
│   │       ├── stream.cr                # Stream — consumer-group reader over Redis Streams
│   │       └── system_settings_cache.cr # SystemSettingsCache — settings cache eviction
│   ├── doctype.cr         # Namespace root for doctype definitions
│   ├── doctype/
│   │   ├── action_definition.cr        # One scripted action in a definition
│   │   ├── check.cr                    # /check diagnostics for one doctype
│   │   ├── children_definition.cr      # One child relationship in the composition tree
│   │   ├── composition.cr              # Bundle-level composition check
│   │   ├── create.cr                   # Doctype creation service
│   │   ├── definition_store.cr         # Doctype definition cache interface
│   │   ├── definition_error.cr         # 422-channel error for wrong-shaped definitions
│   │   ├── derived_operators.cr        # Stamps derived per-field operators on content
│   │   ├── doctype_definition.cr       # Full schema (fields, refs, actions, scopes)
│   │   ├── enum_value.cr               # One value in an enum field definition
│   │   ├── field_definition.cr         # One field descriptor
│   │   ├── field_path.cr               # Shape-aware content-path resolution (FieldPath.levels)
│   │   ├── field_type.cr               # Base class for all field types
│   │   ├── field_types/
│   │   │   ├── any_type.cr             # Unbounded JSON values (schemaless)
│   │   │   ├── array_type.cr           # Array of typed elements
│   │   │   ├── boolean_type.cr         # Boolean values
│   │   │   ├── color_type.cr           # Color values
│   │   │   ├── data_type.cr            # Computed values (Lua-driven)
│   │   │   ├── date_type.cr            # Calendar dates
│   │   │   ├── dateperiod_type.cr      # Calendar-date range (start/end object)
│   │   │   ├── datetime_type.cr        # ISO-8601 datetimes
│   │   │   ├── dictionary_type.cr      # Key-value map with typed values
│   │   │   ├── duration_type.cr        # Duration as integer seconds
│   │   │   ├── enum_type.cr            # Closed set of string labels
│   │   │   ├── file_type.cr            # Binary attachments
│   │   │   ├── integer_type.cr         # 64-bit signed integers
│   │   │   ├── long_text_type.cr       # Long-form text values
│   │   │   ├── money_type.cr           # Money object {value, currency}
│   │   │   ├── object_type.cr          # JSONB sub-documents
│   │   │   ├── period_type.cr          # Datetime range (start/end object)
│   │   │   ├── phone_type.cr           # Phone number values
│   │   │   ├── reference_type.cr       # Reference to another document
│   │   │   ├── secret_type.cr          # Out-of-band secrets
│   │   │   ├── string_type.cr          # UTF-8 text values
│   │   │   └── url_type.cr             # URL values
│   │   ├── filter_capability.cr        # Field types where equality filters are valid
│   │   ├── identifier_definition.cr    # Sequential identifier generation config
│   │   ├── named_scope.cr              # Named server-side predicate over own fields
│   │   ├── operator.cr                 # Filter operator parse table
│   │   ├── replicate_config.cr         # Replicated-field configuration
│   │   ├── reproject.cr                # Re-projects derived columns for one doctype
│   │   ├── reproject_cli.cr            # facet doctypes:reproject CLI
│   │   ├── reproject_job.cr            # doctype_reproject background job handler
│   │   ├── ahead_migration.cr          # Eager migration of documents below the current schema version
│   │   ├── ahead_migration_job.cr      # doctype_migrate_ahead background job handler
│   │   ├── maintenance_routes.cr       # Maintenance HTTP surface (enqueue, status, jobs list)
│   │   ├── migration_retry.cr          # Clears meta.migration_error + re-runs lazy migration (B-301)
│   │   ├── migration_retry_cli.cr      # facet doctype:migrate-retry CLI
│   │   ├── routes.cr                   # Doctype management HTTP routes
│   │   ├── script_validator.cr         # Lua script vs action declaration validation
│   │   ├── seed.cr                     # Core doctype seeding (idempotent)
│   │   ├── sidecar_ref.cr              # One sidecars entry (doctype + reference column)
│   │   ├── structure.cr                # Structural diff between two definitions
│   │   ├── update.cr                   # Doctype update / schema version bump
│   │   ├── validation.cr               # Schema-level validation of a definition
│   │   ├── view_template_validator.cr  # DocumentView template tree validator
│   │   └── yaml_helper.cr              # YAML::Any → JSON::Any conversion
│   ├── document.cr        # Namespace root for document services
│   ├── document/
│   │   ├── action.cr                # Named action execution
│   │   ├── apply_defaults.cr        # Applies field defaults to a new document
│   │   ├── artifact_refs.cr         # Maintains artifact_references in the mutation txn
│   │   ├── backrefs.cr              # Backrefs — inverse links query, shared by MCP + HTTP
│   │   ├── coalesce.cr              # Write-time update coalescing + persist step
│   │   ├── collection_view_gate.cr  # Write-time CollectionView config gate (per surface)
│   │   ├── collection_version.cr    # Collection ETag validators (updated_at scopes)
│   │   ├── compute.cr               # Runs computed (data) fields
│   │   ├── copy.cr                  # Recursive document copy primitive
│   │   ├── create.cr                # Document creation service
│   │   ├── create_with_children.cr  # Atomic parent + children create
│   │   ├── delete.cr                # Soft delete service
│   │   ├── display_name.cr          # Computes display_name, stages the GUC
│   │   ├── file_mime_check.cr       # Checks file values against accept lists
│   │   ├── filter_compiler.cr       # Shared filter grammar compiler
│   │   ├── links.cr                 # Computes links array, stages the GUC
│   │   ├── list.cr                  # Document listing service
│   │   ├── list/
│   │   │   └── aggregate.cr         # Field aggregates for document lists
│   │   ├── lua_document_helpers.cr  # Lua document.* helpers (same domain)
│   │   ├── lua_notification_helpers.cr # Lua notification helpers
│   │   ├── migrate.cr               # Lazy migration engine
│   │   ├── money_currency_check.cr  # Money field currency lifecycle gate
│   │   ├── normalize.cr             # Field-type value normalization
│   │   ├── projection_gucs.cr       # Stages all mutation GUCs (set_all/clear_all)
│   │   ├── read.cr                  # Single-document read service
│   │   ├── reference_check.cr       # Reference existence + filter validation
│   │   ├── routes.cr                # Document CRUD HTTP routes
│   │   ├── row_access.cr            # Id canonicalization + row locking primitives
│   │   ├── script_context.cr        # Require root for the Lua script contexts
│   │   ├── script_context/
│   │   │   ├── action.cr            # ActionContext — named action scripts
│   │   │   ├── actor_table.cr       # ctx.actor surface of the base context
│   │   │   ├── base.cr              # Shared ctx table, script wrapper, errors
│   │   │   ├── create.cr            # CreateContext — create hook scripts
│   │   │   ├── delete.cr            # DeleteContext — delete hook scripts
│   │   │   ├── json_bridge.cr       # JSON ↔ Lua value converters
│   │   │   ├── migrate.cr           # MigrateContext — migration scripts
│   │   │   └── update.cr            # UpdateContext — update hook scripts
│   ├── search.cr                # Computes search corpus, stages the GUC
│   ├── sequence_id.cr           # Sequential identifiers from a template
│   ├── sidecar_handler.cr       # Nested sidecar route handlers
│   │   ├── snapshot_persist.cr      # Snapshot mutation write primitive
│   │   ├── strip_write_only.cr      # Removes write_only fields before persistence
│   │   ├── unique_constraint.cr     # Shared unique: true checker
│   │   ├── update.cr                # PATCH update service
│   │   ├── uri.cr                   # URN reference type (RFC 8141)
│   │   └── validation.cr            # Document validation against a definition
│   ├── mutation.cr        # Namespace root for the mutation client
│   ├── mutation/
│   │   ├── client.cr      # Mutation::Client — high-level mutation API
│   │   ├── config.cr      # mutations: config section
│   │   ├── json_diff.cr   # JSON diff, text patches, inversion, composition
│   │   └── provenance.cr  # Provenance + cause audit metadata
│   ├── oauth.cr           # Namespace root for the app authorization server
│   ├── oauth/
│   │   ├── authorize.cr      # Request validation, consent payload, code issue
│   │   ├── client_info.cr    # Public metadata for first-party CLI clients
│   │   ├── code_store.cr     # Redis single-use authorization codes (60s TTL)
│   │   ├── cors.cr           # CORS handler for registered origins
│   │   ├── discovery.cr      # well-known authorization-server metadata
│   │   ├── dpop.cr           # DPoP (RFC 9449) proof verification
│   │   ├── endpoint_error.cr # OAuth error type for the protocol endpoints
│   │   ├── origin_cache.cr   # allowed_origins → app_id process cache
│   │   ├── rate_limiter.cr   # Token endpoint + per-IP rate limiter
│   │   ├── redirect_uri.cr   # Redirect-URI validation + matching
│   │   ├── refresh.cr        # App access token refresh
│   │   ├── register.cr       # RFC 7591 dynamic client registration (MCP clients)
│   │   ├── replay_cache.cr   # DPoP jti replay cache (Redis)
│   │   ├── routes.cr         # App OAuth HTTP routes
│   │   └── token.cr          # PKCE verify, code consume, app JWT issue
│   ├── iam.cr             # Namespace root for identity and access management
│   ├── iam/
│   │   ├── account_cli.cr      # Account/role inspect + repair CLI
│   │   ├── account_patch.cr    # System-principal account field flips
│   │   ├── api_key.cr          # Static fct_ bearer keys
│   │   ├── app_launcher.cr     # Dashboard launcher for usable apps
│   │   ├── auth_mode_cli.cr    # facet auth:mode recovery command
│   │   ├── auth_state.cr       # TOTP replay guard (auth_state table)
│   │   ├── backup_codes.cr     # Single-use MFA backup codes (digest-only)
│   │   ├── challenge.cr        # MFA challenge verification
│   │   ├── config.cr           # IAM::Config — delegates to Facet::Config
│   │   ├── enroll.cr           # Enroll-at-login verify
│   │   ├── enroll_token.cr     # One-shot MFA enroll tokens (Redis)
│   │   ├── helpers.cr          # Account/role lookups, LoginEvent writer
│   │   ├── invite.cr           # Temporary password + invite services
│   │   ├── jwt.cr              # ES256 JWT sign/verify
│   │   ├── login.cr            # Password login pipeline
│   │   ├── login_throttle.cr   # Lockout flag + attempt counters (Redis)
│   │   ├── logout.cr           # Session teardown
│   │   ├── mfa.cr              # MFA enrollment, verification, disable
│   │   ├── password_reset.cr   # Reset request/confirm flow
│   │   ├── policy.cr           # Single read point for security settings
│   │   ├── pwd_change_token.cr # One-shot password-change tokens (Redis)
│   │   ├── redis.cr            # Per-call Redis client factory
│   │   ├── redis_session.cr    # Sessions, challenges, lockout in Redis
│   │   ├── refresh.cr          # Token rotation with reuse detection
│   │   ├── role_store.cr       # Process-local iam.Roles content cache
│   │   ├── routes.cr           # /Api/iam HTTP surface
│   │   ├── seed.cr             # IAM bootstrapping at seed time
│   │   ├── seed_cli.cr         # facet seed:admin bootstrap
│   │   ├── session_emit.cr     # Shared session-emit step for login paths
│   │   ├── token_emitter.cr    # Access + refresh token emission
│   │   ├── totp.cr             # RFC 6238 TOTP
│   │   └── oidc/
│   │       ├── discovery.cr      # OIDC::Discovery — issuer discovery + JWKS cache
│   │       ├── identity.cr       # Identity resolution, linking, JIT provisioning
│   │       ├── providers.cr      # Enabled-provider registry over documents
│   │       ├── provider_store.cr # Provider record + process-local cache
│   │       ├── routes.cr         # /auth/oidc/:provider(+ /callback) routes
│   │       ├── state.cr          # One-shot flow state (Redis, 300s TTL)
│   │       └── verify.cr         # id_token verification (RS256/ES256)
│   ├── audit.cr           # Namespace root for the audit system
│   ├── audit/
│   │   ├── list.cr        # Audit::List — queries the mutations table
│   │   ├── replay.cr      # Audit::Replay — shared history replay (rollback + compaction)
│   │   ├── restore.cr     # Audit::Restore — resolves the pre-delete restore target
│   │   ├── rollback.cr    # Audit::Rollback — replay + snapshot rollback
│   │   └── routes.cr      # Audit log + rollback HTTP routes
│   ├── search.cr          # Namespace root for the cross-doctype search
│   ├── search/
│   │   ├── query.cr       # Search::Query — contribution enumeration, statement builder, fan-out merge
│   │   └── routes.cr      # GET|QUERY /Api/:domain/search + /Api/search routes
│   ├── index.cr           # Namespace root for index management
│   ├── index/
│   │   ├── list.cr        # Index::List — read-only doctype_indexes listing (GET /Api/Indexes)
│   │   ├── manager.cr     # Index::Manager — sync engine, background DDL
│   │   ├── naming.cr      # Index::Naming — index names + access expressions
│   │   ├── planner.cr     # DesiredIndex records per doctype field set
│   │   ├── retry_cli.cr   # facet indexes:retry CLI
│   │   └── routes.cr      # Managed-index status route
│   ├── lua.cr             # Namespace root for the Lua engine
│   ├── lua/
│   │   ├── engine.cr      # Facet::Lua::Engine — Lua VM wrapper
│   │   └── sandbox.cr     # Shared sandbox setup for script surfaces
│   ├── http/              # Kemal HTTP layer — server, middleware, routes
│   │   ├── auth_handler.cr         # JWT extraction → RBAC::AuthContext
│   │   ├── caching.cr              # ETag validators (state + collection versions)
│   │   ├── domain_gate.cr          # 404 for excluded domains
│   │   ├── gates.cr                # Admission gates — body, QUERY, CSRF, params, token
│   │   ├── healthcheck.cr          # GET /Healthcheck probe
│   │   ├── helpers.cr              # Facade over Responders + Gates
│   │   ├── json_error_handler.cr   # Error rendering for the API surface
│   │   ├── list_request.cr         # List request parameter parsing
│   │   ├── metrics_handler.cr      # Request counter (first in the stack)
│   │   ├── metrics_route.cr        # GET /metrics scrape endpoint
│   │   ├── nested_path_resolver.cr # Nested child route resolver (*rest)
│   │   ├── responders.cr           # JSON response + error writers
│   │   ├── rest_routes.cr          # REST catch-all for nested paths
│   │   ├── secrets_routes.cr       # Out-of-band secret staging route
│   │   └── server.cr               # Kemal setup, middleware stack, route mount
│   ├── app/               # Registered-app subsystem (app.App + deployments)
│   │   ├── api_keys.cr          # App::ApiKeys — issue (rotate) / revoke, one active key
│   │   ├── deploy.cr            # POST /Api/app/:id/deploy — upload + optional activate
│   │   ├── hosting.cr           # Pre-router host dispatch, HostCache, static serving
│   │   ├── routes.cr            # App API key HTTP surface
│   │   └── service_accounts.cr  # Service-account provisioning for backend apps
│   ├── artifact/          # Artifact store — uploads, grants, serving
│   │   ├── access.cr      # Provenance-based read check
│   │   ├── admin.cr       # Operator listing (GET /Api/Artifacts)
│   │   ├── config.cr      # Prune / TTL / size-cap knobs
│   │   ├── grants.cr      # Signed capability URLs — mint / verify / revoke
│   │   ├── multipart.cr   # Multipart intake for file-typed fields
│   │   ├── owners.cr      # Owner-row append flows (copy, replication)
│   │   ├── prune.cr       # Prune eligibility + soft/hard delete + CLI
│   │   ├── purge.cr       # Operator force delete + hard prune CLI
│   │   ├── reconcile.cr   # Object-store orphan sweep + CLI
│   │   ├── revoke.cr      # Signed-URL revoke CLI
│   │   ├── routes.cr      # Artifact API + serve routes + upload-capability route
│   │   ├── serve.cr       # Byte serving for downloads
│   │   ├── upload_grants.cr # One-time signed upload capability (Redis, agent surfaces)
│   │   ├── store.cr       # artifacts + artifact_owners SQL
│   │   └── uploader.cr    # Byte put/open by storage (filesystem via shrine, S3 via awscr), MIME sniffing
│   ├── currency.cr        # Facet::Currency::Registry — hydration from core.Currency, ensure_fresh, mark_stale
│   ├── replication.cr     # Namespace root for cross-domain field replication
│   ├── replication/
│   │   ├── binding.cr      # Replication::Binding — one replication edge
│   │   ├── handler.cr      # Source-event propagation to replica fields
│   │   ├── manager.cr      # Replication coordinator
│   │   ├── manager_base.cr # Shared lifecycle scaffold for the managers
│   │   ├── queries.cr      # Read-side SQL helpers
│   │   ├── registry.cr     # Edges keyed by source doctype
│   │   ├── sync_pull.cr    # Write-time initial value pull
│   │   └── validator.cr    # Diagnostics validator
│   ├── domain.cr          # Namespace root for domain-level operations
│   ├── domain/
│   │   ├── check.cr             # Aggregate draft diagnostics
│   │   ├── copy.cr              # Reusable structure-copy primitive
│   │   ├── draft.cr             # Draft domain creation
│   │   ├── drop.cr              # Live domain delete with audit record
│   │   ├── editors.cr           # Domain-editor membership primitives
│   │   ├── publish.cr           # Draft → live publish
│   │   ├── publish_gate.cr      # Shared publish version gate
│   │   ├── routes.cr            # Draft lifecycle HTTP routes
│   │   ├── scratch.cr           # Fail-closed draft teardown
│   │   ├── view_reconciler.cr   # Converges view rows to a desired set
│   │   ├── portable.cr          # Require root for the portable-domain concern
│   │   └── portable/            # Portable-domain bundle import/export
│   │       ├── archive.cr            # Require root for the bundle archive
│   │       ├── archive/
│   │       │   ├── bundle.cr         # Bundle model + format constants
│   │       │   ├── reader.cr         # Directory/tar/zip readers
│   │       │   ├── writer.cr         # Directory/tar/zip writers + YAML emitter
│   │       │   └── yaml_encode.cr    # YAML → JSON for bundle entries
│   │       ├── cli.cr                # facet domain:export / domain:import CLI
│   │       ├── export.cr             # Builds a Bundle from a live domain
│   │       ├── export_job.cr         # domain_export background handler
│   │       ├── externalize.cr        # !read_file sidecar policy
│   │       ├── import.cr             # Applies a Bundle (transactional, gated)
│   │       ├── import/
│   │       │   ├── canonical_json.cr # Canonical JSON helpers
│   │       │   └── rewrite.cr        # Bundle content rewrite helpers
│   │       ├── import_job.cr         # domain_import background handler
│   │       └── routes.cr             # Enqueue / status / download routes
│   ├── hooks.cr           # Namespace root for domain hooks
│   ├── hooks/
│   │   ├── definition.cr  # Hooks::Definition — one hook on core.Domain.content.hooks
│   │   ├── executor.cr    # Hooks::Executor — sandboxed run of one hook fire
│   │   ├── handler.cr     # Hooks::Handler — event-hook source-event dispatch
│   │   ├── manager.cr     # Hooks::Manager — coordinator, dedicated Event::Manager
│   │   ├── registry.cr    # Hooks::Registry — event bindings by source selector
│   │   ├── scheduler.cr   # Hooks::Scheduler — cron dispatch under a Redis lease
│   │   └── validator.cr   # Authoring-time hook validator
│   ├── import_export/     # Document CSV/JSON import + export
│   │   ├── artifacts.cr       # Bytes-only artifact writer
│   │   ├── caller_context.cr  # Caller identity → execution AuthContext
│   │   ├── csv_serializer.cr  # CSV cell codec
│   │   ├── export.cr          # Rows in, file out (keyset, one snapshot)
│   │   ├── export_job.cr      # document_export background handler
│   │   ├── import.cr          # File rows in, documents out (one txn)
│   │   ├── import_job.cr      # document_import background handler
│   │   ├── job_outcome.cr     # Shared handler outcome plumbing
│   │   ├── job_queue.cr       # Enqueue via jobs manager or direct insert
│   │   ├── routes.cr          # Export/import enqueue / status / download
│   │   └── staging.cr         # Capped-body import staging
│   ├── rbac.cr            # Namespace root for role-based access control
│   ├── rbac/
│   │   ├── account_loader.cr   # Loads account role IDs
│   │   ├── active_role.cr      # Active role per request
│   │   ├── app_scope.cr        # Parsed app.App grant set
│   │   ├── auth_context.cr     # Per-request authorization context
│   │   ├── can_result.cr       # can? result type
│   │   ├── context_resolver.cr # Request-time context-set resolution
│   │   ├── context_set.cr      # Named domain-owned context set
│   │   ├── enforcer_support.cr # Shared enforcer internals
│   │   ├── error.cr            # RBAC error types
│   │   ├── grant.cr            # One app.App grant entry
│   │   ├── grant_resolver.cr   # Grant/permission intersection engine
│   │   ├── permission.cr       # One permission line in a role
│   │   ├── preview_enforcer.cr # Preview-capability principal branch
│   │   ├── principal.cr        # Caller principal
│   │   ├── read_enforcer.cr    # Read authorization (single + list)
│   │   ├── scope_context.cr    # Actioner attributes for scope evaluation
│   │   ├── scope_expander.cr   # Scope alias resolution + evaluation
│   │   ├── scope_matcher.cr    # Shared predicate matching
│   │   ├── scope_predicate.cr  # Parsed where-clause entry
│   │   ├── scope_value.cr      # $self qualification doctype
│   │   ├── validator.cr        # Authoring-time RBAC validator
│   │   └── write_enforcer.cr   # Write authorization (create/update/delete/action)
│   ├── settings.cr        # Namespace root for account preferences
│   ├── settings/
│   │   ├── keys.cr        # Settings::Keys — preference key registry + validation
│   │   ├── routes.cr      # Settings::Routes — /Api/settings HTTP routes
│   │   └── service.cr     # Settings::Service — account_settings read/write
│   ├── skill_files.cr     # Facet::SkillFiles — skill .md corpus loader (front-matter)
│   ├── system_settings.cr # Namespace root for runtime platform configuration
│   ├── system_settings/
│   │   ├── routes.cr      # GET /Api/SystemSettings (values + pinned)
│   │   ├── service.cr     # Invalidate-only cache + read API
│   │   ├── spec.cr        # One registry entry per config path
│   │   ├── views.cr       # MailView / AssistantView consumer views
│   │   └── write_gate.cr  # Write-time semantic gate
│   ├── notifications.cr   # Namespace root for the in-app notification store
│   ├── notifications/
│   │   ├── invoke_action.cr # Dispatches a descriptor via Document::Action
│   │   ├── list.cr          # Paginated list + unread count
│   │   ├── mark_read.cr     # Mark one / all read
│   │   ├── queue.cr         # Deferred producer queue + drain
│   │   ├── routes.cr        # /Api/notifications routes
│   │   └── send.cr          # Single write path — validate, insert, event
│   ├── secrets.cr         # Namespace root for the secret store
│   ├── secrets/
│   │   ├── adoption.cr    # Stage handles → markers walker
│   │   ├── codec.cr       # Hash / sealed / token payload codec
│   │   ├── config.cr      # Master key, bcrypt cost, TTL knobs
│   │   ├── staging.cr     # Stage-handle table + raw-token generation
│   │   └── store.cr       # set / verify / reveal / consume / prune
│   ├── telemetry.cr       # OpenTelemetry configuration + init
│   ├── telemetry/
│   │   ├── db_integration.cr # crystal-db query instrumentation
│   │   ├── middleware.cr     # HTTP server tracing middleware
│   │   └── span_patch.cr     # Serializes span status to protobuf
│   ├── templating.cr      # Namespace root for the template engine
│   ├── templating/
│   │   ├── context.cr     # Template variable bindings per mutation
│   │   └── engine.cr      # Crinja compile cache + render
│   ├── websocket.cr       # Namespace root for the WebSocket bridge
│   ├── websocket/
│   │   ├── connection.cr            # Per-socket frame handling
│   │   ├── manager.cr               # Subscription tracking + fanout dispatch
│   │   ├── route.cr                 # Kemal /Ws handler
│   │   └── subscription_resolver.cr # Path resolution + RBAC
│   ├── cron.cr            # Namespace root for cron (parser + scheduler)
│   ├── cron/
│   │   ├── artifact_grant_prune.cr    # Deletes expired ephemeral grant rows past the retention window
│   │   ├── assistant_turn_sweep.cr    # Marks stale running turns as error
│   │   ├── assistant_usage_prune.cr   # Deletes aged assistant_usage rows
│   │   ├── event_lag_check.cr         # Consumer lag probe + /Healthcheck gauge
│   │   ├── list_cli.cr                # facet cron:list — prints the boot task table
│   │   ├── mutation_compaction.cr     # Retention compaction to one snapshot row
│   │   ├── parser.cr                  # Cron::Parser — cron expression parser
│   │   ├── pass.cr                    # Shared runner for one scheduled pass
│   │   ├── scheduler.cr               # Single-loop scheduler + per-task fibers
│   │   ├── secrets_prune.cr           # Deletes expired secret/token/staging rows
│   │   ├── sidecar_reconcile.cr       # Sidecar orphan reconciliation backstop
│   │   ├── tasks.cr                   # Boot cron task table (id, config key, schedule, callback)
│   │   ├── tombstone_content_prune.cr # Clears tombstone payloads after retention
│   │   └── webhook_reconcile.cr       # Webhook enqueue repair from mutations log
│   ├── jobs.cr            # Namespace root for the background-jobs queue
│   ├── jobs/
│   │   ├── config.cr      # jobs: config section
│   │   ├── handler.cr     # Jobs::Handler — handler contract (Result, attempt hooks)
│   │   ├── job.cr         # Jobs::Job — claimed job row
│   │   ├── manager.cr     # Jobs::Manager — singleton coordinator, register_handler
│   │   ├── queries.cr     # background_jobs SQL — insert / claim / finish / sweep / prune
│   │   └── worker.cr      # Jobs::Worker — poll loop + lease sweep + prune ticks
│   ├── util/              # Shared helpers — SQL, text, time, YAML, Lua
│   │   ├── bind_scalar.cr          # JSON value → DB::Any binding coercion
│   │   ├── cache_freshness.cr      # Staleness bound for invalidate-only caches
│   │   ├── client_ip.cr            # Client-IP resolution behind trusted proxies
│   │   ├── color.cr                # Color parsing + normalization
│   │   ├── crypto.cr               # Constant-time comparisons for tokens
│   │   ├── diacritic_fold.cr       # Accent folding for trigram search
│   │   ├── fiber_supervisor.cr     # Fiber restart with exponential backoff
│   │   ├── filter_clauses.cr       # Type-aware SQL clause builders
│   │   ├── filter_set.cr           # Composable SQL filter-set builder
│   │   ├── identifier.cr           # JSONB field identifier validation
│   │   ├── like_escape.cr          # LIKE/ILIKE pattern escaping
│   │   ├── mime_matcher.cr         # MIME accept-pattern matcher
│   │   ├── money.cr                # Currency struct + registry lookups
│   │   ├── money_filter_value.cr   # Money filter value parser
│   │   ├── past_tense_inflector.cr # Past-tense inflection for event names
│   │   ├── pg_error.cr             # PostgreSQL error read helpers
│   │   ├── projections.cr          # Shared projections-table queries
│   │   ├── qualified_ref.cr        # Qualified identifier splitting
│   │   ├── redirect_uri.cr         # Redirect-URI shape rule + loopback host predicate
│   │   ├── retry.cr                # Exponential-backoff retry
│   │   ├── script_helpers.cr       # util.* / date.* / math.clamp Lua globals
│   │   ├── sequence.cr             # Sequential identifier generation
│   │   ├── sidecars.cr             # Shared sidecar tombstone routine
│   │   ├── sql_ops.cr              # Operator suffix → SQL operator map
│   │   ├── string_util.cr          # Codepoint-aware truncation
│   │   ├── time_helper.cr          # Time / timezone helpers
│   │   ├── yaml_include.cr         # YAML parse entry with tag handlers
│   │   ├── yaml_json.cr            # Generic YAML → JSON conversion
│   │   └── yaml_tag.cr             # Tag-handler framework (jail rules)
│   ├── emails/            # Outbound email (Carbon)
│   │   ├── base_email.cr             # Carbon base class + adapter wiring
│   │   ├── config.cr                 # mail: config section
│   │   ├── email_adapter_registry.cr # Adapter name → Carbon adapter
│   │   ├── invite_email.cr           # Account invite email
│   │   ├── password_reset_email.cr   # Reset-link email
│   │   └── templates/                # ECR templates per email class
│   ├── mcp.cr             # Model Context Protocol resource server
│   ├── mcp/
│   │   ├── dispatch.cr            # Bearer verify + AuthContext for MCP
│   │   ├── protected_resource.cr  # RFC 9728 Protected Resource Metadata
│   │   ├── routes.cr              # MCP HTTP surface
│   │   └── skills.cr              # read_skill — corpus tool (surface-filtered)
│   ├── webhook.cr         # Namespace root for webhooks
│   ├── webhook/
│   │   ├── auth_check.cr  # Webhook::AuthCheck — enqueue-time authorization gate
│   │   ├── calls.cr       # Webhook::Calls — webhook_calls read side
│   │   ├── config.cr      # webhook: config section
│   │   ├── dispatcher.cr  # Webhook::Dispatcher — webhook_delivery job handler
│   │   ├── handler.cr     # Webhook::Handler — source-event enqueue handler
│   │   ├── manager.cr     # Webhook::Manager — registry + dedicated Event::Manager
│   │   ├── registry.cr    # Webhook::Registry — bindings by source doctype
│   │   ├── routes.cr      # Call log + replay + test routes
│   │   ├── test.cr        # Inline synchronous test POST
│   │   └── transport.cr   # Shared delivery transport
│   ├── agent_tools.cr     # Shared agent tool catalogue (MCP + assistants)
│   ├── agent_tools/
│   │   ├── caps.cr        # Response-cap enforcement
│   │   ├── discover.cr    # Schema discovery tools
│   │   ├── errors.cr      # Tool error taxonomy
│   │   ├── history.cr     # Mutation log + back-reference tools
│   │   ├── read.cr        # Document query tools
│   │   ├── registry.cr    # Tool records, visibility, dispatch
│   │   ├── skills.cr      # Shared skill corpus — surface-filtered read_skill source
│   │   ├── skills/        # Skill .md corpus (front-matter `surfaces` allow-list)
│   │   └── write.cr       # Document mutation tools
│   ├── assistant.cr       # Namespace root for the AI assistant
│   ├── assistant/
│   │   ├── access.cr        # Workspace availability gate
│   │   ├── config.cr        # LLM endpoint, model, prompt config
│   │   ├── conversation.cr  # agent_conversations storage
│   │   ├── custom_prompt.cr # Operator custom instructions
│   │   ├── limits.cr        # Token-budget seam
│   │   ├── resume.cr        # Rebuilds an Agent from stored rows
│   │   ├── routes.cr        # Conversation storage routes
│   │   ├── tools.cr         # Shared tool-result envelope
│   │   ├── turn.cr          # agent_turns storage
│   │   ├── usage.cr         # Per-account token ledger
│   │   ├── stream/
│   │   │   ├── cancel_bus.cr         # Redis pub/sub cancel fan-out
│   │   │   ├── session.cr            # One-turn SSE streaming orchestrator
│   │   │   └── tool_trace_handler.cr # tool_call SSE trace events
│   │   ├── domain_builder.cr             # Domain-builder assistant surface
│   │   ├── domain_builder/               # Domain-builder assistant surface
│   │   │   ├── auth.cr            # System-tier identity for tool mutations
│   │   │   ├── context.cr         # Conversation context typed view
│   │   │   ├── routes.cr          # Domain-builder conversation route
│   │   │   ├── skills.cr          # Skill corpus pin
│   │   │   ├── skills/            # 16 skill .md files
│   │   │   ├── system_prompt.cr   # System prompt builder
│   │   │   ├── system_prompt.md   # Static prompt body
│   │   │   ├── tools.cr           # Registers the domain-builder tools
│   │   │   └── tools/
│   │   │       ├── read_tools.cr  # Read-only tool callbacks
│   │   │       ├── ui_tools.cr    # Frontend-executed UI tools
│   │   │       └── write_tools.cr # Draft-scoped write tool callbacks
│   │   ├── workspace.cr                  # Workspace assistant surface
│   │   ├── workspace/                    # Workspace assistant surface
│   │   │   ├── context.cr         # Conversation kind + owner
│   │   │   ├── registrar.cr       # Document + UI tool registration
│   │   │   ├── routes.cr          # Workspace conversation route
│   │   │   ├── skills.cr          # Skill corpus pin
│   │   │   ├── skills/            # 4 skill .md files
│   │   │   ├── system_prompt.cr   # System prompt builder
│   │   │   └── system_prompt.md   # Static prompt body
│   │   └── app/                           # Per-app assistant surface (embedded via @facetapp/chat)
│   │       ├── context.cr         # `app` conversation kind + server-side context
│   │       ├── gate.cr            # Per-app availability gate (flag + access + app-scoped caller)
│   │       ├── registrar.cr       # Registry tools minus ping; no skills, no UI tools
│   │       ├── routes.cr          # Dedicated create route
│   │       ├── system_prompt.cr   # System prompt builder
│   │       └── system_prompt.md   # Static prompt body
│   └── dev/               # Development-mode helpers
│       ├── config.cr      # dev: config section
│       └── domain_watcher.cr # Injects folder-authored domains at runtime
├── spec/                  # Specs mirror the src/ layout
│   ├── config_spec.cr             # Facet::Config — YAML config loading
│   ├── database_spec.cr           # Facet::Database — pools + transaction helpers
│   ├── database_pin_spec.cr       # Pin-reuse contract (pg_backend_pid assertions)
│   ├── database_cluster_spec.cr   # Route resolution + read-only enforcement + back-compat
│   ├── doc_citations_spec.cr      # Doc lint — migration citations resolve to real db/migrations files
│   ├── embedded_sources_spec.cr   # Compile-time embedded sources (migrations, seeds, Lua)
│   ├── fixtures_spec.cr           # data/fixtures bundle validation
│   ├── logging_spec.cr            # Facet::Logging — setup + formatters
│   ├── metrics_spec.cr            # Facet::Metrics — registry + Prometheus text
│   ├── service_spec.cr            # Facet::Service — process identity
│   ├── shutdown_spec.cr           # Facet::Shutdown — SIGTERM drain + teardown order
│   ├── spec_helper.cr             # Loads .env.test, runs db_reset before suite; loads spec/support helpers
│   ├── agent_tools/
│   │   ├── actions_spec.cr        # AgentTools::CallAction
│   │   ├── discover_spec.cr       # AgentTools::Discover
│   │   ├── history_spec.cr        # AgentTools::History
│   │   ├── read_spec.cr           # AgentTools::Read
│   │   ├── artifacts_spec.cr      # AgentTools::Artifacts — upload/download capabilities
│   │   ├── tools_spec.cr          # AgentTools catalogue — definitions + role-filtered visibility
│   │   └── write_spec.cr          # AgentTools::Write
│   ├── app/
│   │   ├── api_keys_spec.cr       # App::ApiKeys — app-owned API keys
│   │   ├── cli_app_spec.cr        # facet-cli seed: seed round-trip via the document pipeline, grant ∩ role resolution, redirect-URI + headless hooks, app-scoped grant guard
│   │   ├── deployment_spec.cr     # Deploy route: multipart atomicity, revision monotonicity, activate/rollback, `deploy` named-action gate
│   │   └── registration_spec.cr   # app.App registration (Phase 1): create, grants round-trip, disable, RBAC; host field rules
│   ├── artifact/
│   │   ├── access_spec.cr         # Facet::Artifact::Access — provenance-based read ACL
│   │   ├── admin_spec.cr          # Facet::Artifact::Admin — operator listing + revoke
│   │   ├── grants_spec.cr         # Facet::Artifact::Grants — signed capability URLs (mint / verify / revoke)
│   │   ├── multipart_spec.cr      # Multipart intake
│   │   ├── owners_spec.cr         # Facet::Artifact::Owners — owner-row append flows
│   │   ├── prune_spec.cr          # Facet::Artifact::Prune — eligibility + soft/hard delete + CLI
│   │   ├── purge_spec.cr          # Facet::Artifact::Purge — destroy + iam.ArtifactEvent audit
│   │   ├── reconcile_spec.cr      # Facet::Artifact::Reconcile — object-store reconcile + CLI
│   │   ├── revoke_spec.cr         # Facet::Artifact::RevokeCLI — `revoke *.*` action
│   │   ├── routes_spec.cr         # Artifact API + serve route HTTP surface
│   │   ├── schema_config_spec.cr  # Schema (migration 0003_artifacts.sql) + Facet::Artifact::Config
│   │   ├── upload_grants_spec.cr  # Artifact::UploadGrants — capability mint/consume + route
│   │   └── uploader_spec.cr       # Facet::Artifact::Uploader — dedup, MIME sniff, size cap
│   ├── assistant/
│   │   ├── access_spec.cr                 # Facet::Assistant::Access — workspace availability gate
│   │   ├── custom_prompt_spec.cr          # Facet::Assistant::CustomPrompt — operator custom instructions
│   │   ├── domain_builder/
│   │   │   ├── context_spec.cr            # DomainBuilder conversation context
│   │   │   ├── skills_spec.cr             # DomainBuilder skill corpus pin
│   │   │   ├── system_prompt_spec.cr      # DomainBuilder::SystemPrompt
│   │   │   └── tools_spec.cr              # DomainBuilder tool registrar
│   │   ├── limits_spec.cr                 # Facet::Assistant::Limits — token-budget seam
│   │   ├── routes_spec.cr                 # Assistant conversation storage routes
│   │   ├── storage_spec.cr                # Facet::Assistant::Conversation — conversation storage
│   │   ├── stream/
│   │   │   ├── cancel_bus_spec.cr         # Facet::Assistant::Stream::CancelBus — Redis pub/sub cancel fan-out
│   │   │   └── session_spec.cr            # Facet::Assistant::Stream::Session — one-turn SSE orchestrator
│   │   ├── usage_spec.cr                  # Facet::Assistant::Usage — per-account token ledger
│   │   └── workspace/
│   │       ├── context_spec.cr            # Workspace conversation kind + owner
│   │       ├── registrar_spec.cr          # Workspace::Registrar — document + UI tool registration
│   │       ├── routes_spec.cr             # Workspace assistant routes
│   │       ├── skills_spec.cr             # Workspace skill corpus pin
│   │       ├── system_prompt_spec.cr      # Workspace::SystemPrompt
│   │       └── tools_spec.cr              # Facet::Assistant::Tools.schema_parameters
│   │   └── app/
│   │       ├── context_spec.cr            # App conversation kind + server-side context
│   │       ├── gate_spec.cr               # App::Gate — flag + access + app-scoped caller
│   │       ├── registrar_spec.cr          # App::Registrar — registry minus ping
│   │       ├── routes_spec.cr             # App assistant create + read surfaces + per-message gate
│   │       └── system_prompt_spec.cr      # App::SystemPrompt
│   ├── audit/
│   │   ├── aggregate_history_spec.cr  # Aggregate history (include=children)
│   │   ├── audit_spec.cr              # Facet::Audit — list + events
│   │   └── restore_spec.cr            # Facet::Audit::Restore + rollback
│   ├── cron/
│   │   ├── artifact_grant_prune_spec.cr    # Cron::ArtifactGrantPrune — window resolution, kind filter, keep-forever, idempotency
│   │   ├── assistant_usage_prune_spec.cr   # Cron::AssistantUsagePrune
│   │   ├── event_lag_check_spec.cr         # Cron::EventLagCheck — threshold warn, vanished key, no groups
│   │   ├── list_cli_spec.cr                # Cron::ListCLI — table render, invalid-expression failure
│   │   ├── mutation_compaction_spec.cr     # Cron::MutationCompaction — cut resolution, tombstone clamp, idempotency, rollback/restore
│   │   ├── parser_spec.cr                  # Cron::Parser — next/last, aliases, seconds field, malformed input
│   │   ├── scheduler_spec.cr               # Cron::Scheduler — register/unregister, fire, fault isolation, idempotence
│   │   ├── sidecar_reconcile_spec.cr       # Cron::SidecarReconcile — hard/soft orphan, live-host no-op, dotted-id split contract
│   │   ├── tasks_spec.cr                   # Cron::Tasks — boot table ids, schedule keys, parseable expressions
│   │   ├── tombstone_content_prune_spec.cr # Cron::TombstoneContentPrune — retention window, batched payload clear
│   │   └── webhook_reconcile_spec.cr       # Cron::WebhookReconcile — repair, dedupe per status, reentrancy, event-name map
│   ├── currency_spec.cr            # Currency::Registry — hydration + lookup
│   ├── dev/
│   │   └── domain_watcher_spec.cr  # Dev::DomainWatcher — folder-authored domains at runtime
│   ├── doctype/
│   │   ├── action_definition_spec.cr           # ActionDefinition — one scripted action
│   │   ├── check_spec.cr                       # Doctype::Check — /check diagnostics
│   │   ├── collection_view_default_spec.cr     # Default CollectionView seed
│   │   ├── composition_spec.cr                 # Composition — bundle-level composition check
│   │   ├── doctype_definition_spec.cr          # DoctypeDefinition — fields, refs, actions, scopes
│   │   ├── doctype_update_spec.cr              # Definition update flow
│   │   ├── doctype_validation_service_spec.cr  # Validation service
│   │   ├── field_types/
│   │   │   ├── any_type_spec.cr                # AnyType — unbounded JSON values
│   │   │   ├── array_type_spec.cr              # ArrayType — typed elements
│   │   │   ├── boolean_type_spec.cr            # BooleanType
│   │   │   ├── color_type_spec.cr              # ColorType
│   │   │   ├── data_type_spec.cr               # DataType — computed (Lua-driven)
│   │   │   ├── date_type_spec.cr               # DateType — calendar dates
│   │   │   ├── dateperiod_type_spec.cr         # DatePeriodType — date range
│   │   │   ├── datetime_type_spec.cr           # DatetimeType — UTC RFC-3339 normalization
│   │   │   ├── dictionary_type_spec.cr         # DictionaryType
│   │   │   ├── duration_type_spec.cr           # DurationType
│   │   │   ├── enum_type_spec.cr               # EnumType
│   │   │   ├── file_type_spec.cr               # FileType
│   │   │   ├── integer_type_spec.cr            # IntegerType
│   │   │   ├── long_text_type_spec.cr          # LongTextType
│   │   │   ├── money_type_spec.cr              # MoneyType
│   │   │   ├── object_type_spec.cr             # ObjectType
│   │   │   ├── period_type_spec.cr             # PeriodType
│   │   │   ├── phone_type_spec.cr              # PhoneType
│   │   │   ├── reference_type_spec.cr          # ReferenceType
│   │   │   ├── string_type_spec.cr             # StringType
│   │   │   └── url_type_spec.cr                # UrlType
│   │   ├── migration_definition_spec.cr        # Migration fields on the definition
│   │   ├── migration_validation_spec.cr        # Migration validation
│   │   ├── process_definition_cache_spec.cr    # Doctype::ProcessDefinitionCache
│   │   ├── replicate_config_spec.cr            # ReplicateConfig — replication binding
│   │   ├── reproject_spec.cr                   # Reproject — re-run projections after schema change
│   │   ├── ahead_migration_spec.cr             # AheadMigration — eager migration run contract
│   │   ├── maintenance_job_spec.cr             # ReprojectJob / AheadMigrationJob handlers
│   │   ├── maintenance_routes_spec.cr          # Maintenance HTTP surface
│   │   ├── migration_retry_spec.cr             # MigrationRetry — clear a sticky meta.migration_error marker
│   │   ├── script_validator_spec.cr            # ScriptValidator
│   │   ├── secret_type_spec.cr                 # SecretType — stage + adopt
│   │   ├── seeded_views_spec.cr                # Seeded document views
│   │   ├── seed_validity_spec.cr               # Seed validity checks
│   │   ├── structure_spec.cr                   # Structure — doctype structure rules
│   │   ├── view_template_validator_spec.cr     # ViewTemplateValidator — document view templates
│   │   └── yaml_helper_spec.cr                 # YamlHelper
│   ├── document/
│   │   ├── action_spec.cr                    # Document::Action — named actions
│   │   ├── artifact_refs_spec.cr             # Document::ArtifactRefs — artifact reference scan
│   │   ├── coalesce_spec.cr                  # Document::Coalesce — write-time coalescing: merge conditions, idx gap, composed diff, rollback to a merged row
│   │   ├── collection_view_gate_spec.cr      # Document::CollectionViewGate — per-surface config rules, replace-on-write
│   │   ├── compute_spec.cr                   # Compute — computed field evaluation
│   │   ├── copy_spec.cr                      # Document::Copy
│   │   ├── create_spec.cr                    # Document::Create
│   │   ├── create_with_children_spec.cr      # Document::CreateWithChildren
│   │   ├── create_with_script_spec.cr        # Script integration on create
│   │   ├── delete_spec.cr                    # Document::Delete — tombstones
│   │   ├── display_name_resolver_spec.cr     # DisplayName::DatabaseReferenceResolver
│   │   ├── display_name_spec.cr              # Document::DisplayName
│   │   ├── document_migrate_spec.cr          # Migrate — lazy schema migration on read
│   │   ├── file_mime_check_spec.cr           # Document::FileMimeCheck
│   │   ├── filter_compiler_spec.cr           # Document::FilterCompiler
│   │   ├── links_spec.cr                     # Document::Links — back-reference extraction
│   │   ├── list_filter_types_spec.cr         # Document::List — typed scalar filters
│   │   ├── list_spec.cr                      # Document::List — listing + pagination
│   │   ├── lua_notification_helpers_spec.cr  # Lua notification.send helper
│   │   ├── money_currency_check_spec.cr      # Document::MoneyCurrencyCheck — inactive_currency rule
│   │   ├── read_spec.cr                      # Document::Read
│   │   ├── reference_check_spec.cr           # Document::ReferenceCheck
│   │   ├── script_context_spec.cr            # ScriptContext
│   │   ├── script_document_helpers_spec.cr   # Lua document.* helpers
│   │   ├── search_spec.cr                    # Document::Search
│   │   ├── strip_write_only_spec.cr          # Document::StripWriteOnly
│   │   ├── update_spec.cr                    # Document::Update
│   │   ├── uri_spec.cr                       # Document::DocURI
│   │   └── validation_spec.cr                # Validation pipeline
│   ├── domain/
│   │   ├── check_spec.cr                 # Domain::Check — aggregate /check diagnostics
│   │   ├── domain_editor_rbac_spec.cr    # Domain-editor RBAC enforcement matrix
│   │   ├── domain_editors_spec.cr        # core.DomainEditor doctype
│   │   ├── draft_domains_spec.cr         # Draft / Scratch / Copy / Publish — create, publish, scratch drop, isolation
│   │   ├── portable/
│   │   │   ├── archive_spec.cr           # Portable::Archive — directory/.zip/.tar.gz read+write, format_version rejection
│   │   │   ├── http_jobs_spec.cr         # domain_export / domain_import jobs — packaging, gates, failures
│   │   │   ├── http_routes_spec.cr       # Portable::Routes — export/import HTTP: gates, staging, status/download
│   │   │   ├── import_export_spec.cr     # Portable end-to-end — fresh, merge, version gate, idempotence
│   │   │   └── import_force_spec.cr      # Portable::Import $force
│   │   ├── preview_end_to_end_spec.cr    # Preview mode end-to-end
│   │   └── preview_session_spec.cr       # POST /Api/core/Domain/:id/preview-session
│   ├── emails/
│   │   └── email_adapter_registry_spec.cr  # EmailAdapterRegistry
│   ├── event/
│   │   ├── aggregate_events_spec.cr           # Aggregate child_changed events
│   │   ├── config_spec.cr                     # Event::Config
│   │   ├── consumer_health_spec.cr            # Event::ConsumerHealth — reports, degraded?, snapshot shape
│   │   ├── in_process_manager_spec.cr         # Event::InProcessManager
│   │   ├── loss_spec.cr                       # Event::Loss — flush-failure and dispatch-drop counters
│   │   ├── manager_spec.cr                    # Event::Manager — publish + subscriptions
│   │   ├── message_spec.cr                    # Event::Message — pack/unpack
│   │   └── subscriber/
│   │       ├── doctype_cache_spec.cr          # DoctypeCache — definition cache eviction
│   │       ├── fanout_spec.cr                 # Fanout — per-process pub/sub fanout
│   │       ├── sidecar_sweep_spec.cr          # SidecarSweep — tombstone on host delete, idempotency, malformed-event skip
│   │       ├── stream_spec.cr                 # Stream — consumer-group reader
│   │       └── system_settings_cache_spec.cr  # SystemSettingsCache — settings cache eviction
│   ├── hooks/
│   │   ├── authoring_gate_spec.cr  # Hook authoring gate — 422 on invalid hooks
│   │   ├── executor_spec.cr        # Executor — ctx table, document.* domain pinning, error model
│   │   ├── handler_spec.cr         # Handler — event dispatch, reentrancy skip, failure logging
│   │   ├── manager_spec.cr         # Manager — lifecycle + subscription wiring
│   │   ├── registry_spec.cr        # Registry — build / stale / rebuild, draft isolation
│   │   ├── scheduler_spec.cr       # Scheduler — fire buckets, lease semantics, once-per-cluster
│   │   └── validator_spec.cr       # Validator — ids, compile, exports, cron restrictiveness
│   ├── http/
│   │   ├── anonymous_auth_spec.cr            # Anonymous role fallback
│   │   ├── app_hosting_spec.cr               # Host dispatch: facet-host fall-through, exact match, SPA fallback, headers, 404s, cache rebuild
│   │   ├── assistant_domain_builder_spec.cr  # Domain-builder conversation routes
│   │   ├── audit_history_spec.cr             # Audit history HTTP response shape
│   │   ├── audit_routes_spec.cr              # Document restore HTTP endpoint
│   │   ├── auth_handler_aud_spec.cr          # Empty placeholder
│   │   ├── children_integration_spec.cr      # Children parent_id linkage
│   │   ├── doctype_check_spec.cr             # GET /Api/core/DocType/:id/check
│   │   ├── domain_check_spec.cr              # GET /Api/core/Domain/:id/check
│   │   ├── domain_draft_http_spec.cr         # POST /Api/core/Domain/:id/draft
│   │   ├── domain_drop_http_spec.cr          # POST /Api/core/Domain/:id/drop + generic-DELETE refusal
│   │   ├── domain_gate_spec.cr               # HTTP::DomainGate
│   │   ├── etag_spec.cr                      # ETag — single-document reads
│   │   ├── healthcheck_spec.cr               # GET /Healthcheck
│   │   ├── helpers_spec.cr                   # HTTP::Helpers
│   │   ├── http_debug_harness_spec.cr        # Spec HTTP debug harness
│   │   ├── json_error_handler_spec.cr        # HTTP::JsonErrorHandler
│   │   ├── list_aggregate_spec.cr            # HTTP aggregate=count
│   │   ├── list_aggregates_spec.cr           # HTTP field aggregates (sum / avg / min / max)
│   │   ├── list_request_spec.cr              # HTTP::ListRequest parsing
│   │   ├── nested_path_resolver_spec.cr      # HTTP::NestedPathResolver — nested path resolution
│   │   ├── query_method_spec.cr              # HTTP QUERY method — document collection list
│   │   ├── rest_etag_spec.cr                 # ETag — nested child single reads
│   │   ├── secrets_routes_spec.cr            # HTTP::SecretsRoutes — stage + adopt
│   │   ├── server_spec.cr                    # HTTP server endpoints
│   │   ├── sidecar_attachment_spec.cr        # Attachment sidecar (core.Attachment)
│   │   ├── sidecar_integration_spec.cr       # Sidecar nested routes
│   │   └── well_known_discovery_spec.cr      # well-known discovery is unauthenticated
│   ├── iam/
│   │   ├── account_cli_spec.cr        # IAM::AccountCLI
│   │   ├── account_roles_spec.cr      # iam.Account roles dedup
│   │   ├── account_script_spec.cr     # iam.Account lifecycle script
│   │   ├── api_key_spec.cr            # IAM::ApiKey — pair liveness + self-service routes
│   │   ├── app_launcher_spec.cr       # IAM::AppLauncher
│   │   ├── auth_state_spec.cr         # IAM::AuthState — credential-states admin read
│   │   ├── challenge_spec.cr          # IAM::Challenge
│   │   ├── iam_integration_spec.cr    # IAM HTTP integration
│   │   ├── invite_routes_spec.cr      # Credential-bootstrap routes (invite + temporary password)
│   │   ├── invite_spec.cr             # IAM::Invite
│   │   ├── jwt_spec.cr                # IAM::JWT
│   │   ├── login_spec.cr              # IAM::Login — password pipeline
│   │   ├── login_throttle_spec.cr     # IAM::LoginThrottle — lockout after failed logins
│   │   ├── logout_spec.cr             # IAM::Logout
│   │   ├── mfa_enroll_spec.cr         # IAM::Enroll — TOTP enrollment
│   │   ├── mfa_spec.cr                # IAM::MFA — preferred / always enforcement
│   │   ├── oidc_spec.cr               # Inbound OIDC — providers, discovery, verify, identity, login routes
│   │   ├── password_reset_spec.cr     # IAM::PasswordReset — reset slot link tokens
│   │   ├── redis_session_spec.cr      # IAM::RedisSession
│   │   ├── refresh_spec.cr            # IAM::Refresh — token refresh
│   │   ├── role_store_spec.cr         # RoleStore::ProcessCache
│   │   ├── seed_spec.cr               # IAM::Seed
│   │   ├── sessions_routes_spec.cr    # /Api/iam/sessions* routes
│   │   ├── token_emitter_spec.cr      # IAM::TokenEmitter
│   │   └── totp_spec.cr               # IAM::TOTP
│   ├── import_export/
│   │   ├── caller_context_spec.cr  # ImportExport::CallerContext
│   │   ├── csv_serializer_spec.cr  # CSV cell codec — round trip per cell convention, money grammar, decode rules, quoting
│   │   ├── export_job_spec.cr      # Document::ExportJob — artifact result, execution-time RBAC recompile, events, notification
│   │   ├── export_routes_spec.cr   # Export routes — enqueue validation, requester-scoped status/download, wait mode
│   │   ├── export_spec.cr          # Document::Export — RBAC scoping, masking, both formats, batching
│   │   ├── import_job_spec.cr      # Document::ImportJob — end-to-end report, manifest idempotence, import_failed
│   │   ├── import_routes_spec.cr   # Import routes — synchronous fast-fail with row numbers, 413 cap, wait-mode shapes
│   │   └── import_spec.cr          # Document::Import — upsert matrix, first-failure rollback, Lua hooks
│   ├── index/
│   │   ├── list_spec.cr            # Index::List — status listing
│   │   ├── manager_spec.cr         # Index::Manager — create / drop / rebuild
│   │   ├── naming_spec.cr          # Index::Naming
│   │   ├── planner_spec.cr         # Index::Planner — desired partial indexes from doctype fields
│   │   └── retry_cli_spec.cr       # Index::RetryCLI
│   ├── integration/
│   │   ├── collection_view_spec.cr     # core.CollectionView end-to-end
│   │   ├── crm_doctype_spec.cr         # CRM integration
│   │   ├── document_view_spec.cr       # core.DocumentView end-to-end
│   │   ├── hr_doctype_spec.cr          # HR / Identity integration
│   │   └── journey/
│   │       └── auth_flow_spec.cr       # Full authentication journey
│   ├── jobs/
│   │   ├── handler_spec.cr  # Handler contract + defaults
│   │   ├── manager_spec.cr  # Manager — lifecycle + enqueue-only mode
│   │   ├── queries_spec.cr  # Queries — insert / claim (SKIP LOCKED, disjoint claims, backoff clamp) / sweep / prune
│   │   └── worker_spec.cr   # Worker — retry, max-attempts, no-handler, lease sweep, disjoint claims
│   ├── lua/
│   │   └── engine_spec.cr  # Lua::Engine
│   ├── mcp/
│   │   ├── dispatch_spec.cr             # MCP::Dispatch — JSON-RPC chain + per-sid cap
│   │   ├── mcp_endpoints_spec.cr        # GET /Api/_mcp/endpoints
│   │   ├── mutation_attribution_spec.cr # MCP mutation attribution
│   │   ├── oauth_mcp_branch_spec.cr     # OAuth MCP branch
│   │   ├── protected_resource_spec.cr   # MCP::ProtectedResource — RFC 9728 PRM
│   │   ├── skills_spec.cr               # read_skill — tools/list append + surface filter end to end
│   │   ├── tools_call_spec.cr           # tools/call JSON-RPC envelope
│   │   └── url_role_pinning_spec.cr     # URL role pinning
│   ├── migrate/
│   │   ├── db_reset_spec.cr  # Facet::Migrate.db_reset
│   │   └── down_spec.cr      # Facet::Migrate.down — revert through DOWN sections
│   ├── mutation/
│   │   ├── client_spec.cr               # Mutation::Client — write pipeline
│   │   ├── json_diff_compose_spec.cr    # JsonDiff — composition: case table, patch∘patch, property test
│   │   ├── json_diff_patch_spec.cr      # JsonDiff — text patches: thresholds, hunk context, apply sad paths, invert
│   │   ├── json_diff_spec.cr            # JsonDiff — set/unset paths, nested objects
│   │   ├── meta_attribution_spec.cr     # Mutation::Client meta attribution
│   │   ├── mutations_spec.cr            # Mutations → Projections trigger flow
│   │   ├── parent_linkage_spec.cr       # mutations.parent_doc_id stamping
│   │   └── provenance_spec.cr           # Mutation::Provenance
│   ├── mutations/                        # Integration specs for the mutation→projection trigger
│   │   ├── links_spec.cr             # Projection links column
│   │   └── longtext_patch_spec.cr    # Mutation longtext patch
│   ├── notifications/
│   │   ├── invoke_action_spec.cr  # Notification::InvokeAction — RBAC at execute time, one-shot 409
│   │   ├── list_spec.cr           # Notification::List — ordering, pagination, unread count
│   │   ├── mark_read_spec.cr      # Notification::MarkRead — idempotent mark-one, mark-all
│   │   ├── queue_spec.cr          # Notification::Queue — enqueue validation, FIFO drain
│   │   ├── routes_spec.cr         # Notifications HTTP routes
│   │   └── send_spec.cr           # Notification::Send — validation, reserved keys, ULID id
│   ├── oauth/
│   │   ├── app_audit_spec.cr                     # Phase 6 — app audit + observability
│   │   ├── auth_handler_app_token_spec.cr        # AuthHandler `typ: "app"` — active/draft/disabled app, Layer-1 enforcement
│   │   ├── auth_handler_preview_token_spec.cr    # AuthHandler `typ: "preview"` acceptance
│   │   ├── authorize_spec.cr                     # OAuth::Authorize — parse_params, load_app, build_consent, issue_code
│   │   ├── client_info_spec.cr                   # Client-info endpoint
│   │   ├── code_store_spec.cr                    # OAuth::CodeStore — single-use, TTL, atomic consume
│   │   ├── cors_spec.cr                          # OAuth::Cors — origin echoing, unregistered origin blocking
│   │   ├── dpop_flow_spec.cr                     # DPoP flow (Phase 7)
│   │   ├── dpop_jose_interop_spec.cr             # JOSE ES256 interop
│   │   ├── dpop_spec.cr                          # OAuth::DPoP
│   │   ├── iss_parameter_spec.cr                 # RFC 9207 issuer identification
│   │   ├── login_redirect_spec.cr                # Unauthenticated authorize → login redirect
│   │   ├── oauth_flow_spec.cr                    # Full HTTP flow — authorize → consent → role election → token
│   │   ├── oauth_refresh_flow_spec.cr            # Refresh + revocation flow (Phase 5)
│   │   ├── rate_limiter_spec.cr                  # OAuth::RateLimiter
│   │   ├── redirect_uri_spec.cr                  # OAuth::RedirectUri — match + admission rules
│   │   ├── refresh_spec.cr                       # OAuth::Refresh
│   │   ├── register_spec.cr                      # RFC 7591 dynamic client registration endpoint
│   │   ├── replay_cache_spec.cr                  # OAuth::ReplayCache
│   │   └── token_spec.cr                         # OAuth::Token — happy path, replay, PKCE, fail-closed
│   ├── rbac/
│   │   ├── account_loader_spec.cr                    # AccountLoader
│   │   ├── account_ou_hook_spec.cr                   # iam.Account organizational_unit normalization (Lua hook)
│   │   ├── active_role_spec.cr                       # ActiveRole
│   │   ├── app_enforcement_spec.cr                   # AuthContext app-grant enforcement (Phase 3) — service layer + WebSocket
│   │   ├── auth_context_spec.cr                      # AuthContext
│   │   ├── can_result_spec.cr                        # CanResult
│   │   ├── context_resolver_spec.cr                  # ContextResolver
│   │   ├── context_set_spec.cr                       # ContextSet
│   │   ├── doc_id_scope_spec.cr                      # ScopePredicateSql $doc_id field expression
│   │   ├── grant_resolver_spec.cr                    # GrantResolver (Phase 2) — resolve, write expansion, wildcards
│   │   ├── permission_except_spec.cr                 # Permission except carve-out
│   │   ├── permission_spec.cr                        # Permission
│   │   ├── preview_enforcer_spec.cr                  # PreviewEnforcer
│   │   ├── principal_spec.cr                         # Principal
│   │   ├── read_enforcer_spec.cr                     # ReadEnforcer
│   │   ├── parent_id_scope_spec.cr                   # $parent_id row gate + list parity
│   │   ├── scope_context_spec.cr                     # ScopeContext
│   │   ├── scope_predicate_spec.cr                   # ScopePredicateParser
│   │   ├── scope_predicate_sql_semantics_spec.cr     # ScopePredicateSql semantics
│   │   ├── scope_value_spec.cr                       # ScopeValue
│   │   ├── sidecar_grant_spec.cr                     # Sidecar cross-domain nested grant
│   │   ├── validator_spec.cr                         # Validator — authoring-time checks
│   │   └── write_enforcer_spec.cr                    # WriteEnforcer
│   ├── replication/
│   │   ├── handler_spec.cr                # Replication::Handler — async apply
│   │   ├── reentrancy_spec.cr             # Handler reentrancy guard
│   │   ├── registry_auto_refresh_spec.cr  # Registry auto-refresh on doctype mutations
│   │   ├── registry_spec.cr               # Registry — build + lazy rebuild on staleness
│   │   ├── sync_pull_spec.cr              # SyncPull
│   │   └── validator_spec.cr              # Validator — /check-driven
│   ├── secrets/
│   │   ├── adoption_spec.cr  # Secrets::Adoption — stage → adopt
│   │   ├── codec_spec.cr     # Secrets::Codec
│   │   └── store_spec.cr     # Facet::Secrets slot API
│   ├── settings/
│   │   ├── keys_spec.cr     # Settings::Keys — key registry
│   │   ├── routes_spec.cr   # Settings HTTP integration
│   │   └── service_spec.cr  # Settings::Service
│   ├── support/                             # Shared helpers — one helper used by 2+ spec files
│   │   ├── agent_tools_helper.cr          # AgentTools spec context builders
│   │   ├── app_helper.cr                  # app.App seed restore (re-creates app.App + meta rows after TRUNCATE); `seed_facet_cli_app` seeds the facet-cli app document
│   │   ├── cache_freshness_helper.cr      # with_cache_ttl — cache TTL override
│   │   ├── db_helper.cr                   # DB helpers (with_db, with_temp_doctype, etc.)
│   │   ├── doctype_helper.cr              # Doctype helpers (load, build, persist; shared domain/doctype/person fixtures)
│   │   ├── event_helper.cr                # In-process event manager accessor
│   │   ├── fixture_helper.cr              # Seed definition loader (seed_path, load_seed_definition)
│   │   ├── http_debug.cr                  # Spec HTTP debug harness
│   │   ├── http_helper.cr                 # HTTPTest — HTTP request helpers
│   │   ├── http_helpers.cr                # bearer_headers / with_xrw header helpers
│   │   ├── iam_helper.cr                  # IAM test accounts (ensure_iam_account, create_test_account)
│   │   ├── io_helper.cr                   # silence_stdout
│   │   ├── log_capture.cr                 # SpecLogCapture — log assertions
│   │   ├── money_helper.cr                # money / money_json JSON builders
│   │   ├── oauth_helper.cr                # Shared OAuth spec builders (create_test_app/role, oauth_grant/action/perm, s256_challenge, make_authorize_params, sign_app_token)
│   │   ├── oidc_helper.cr                 # OidcIdpStub — local test identity provider
│   │   ├── rbac_helper.cr                 # RBAC fixtures (crm.Project scopes, test docs, perm/role builders) + enforcer diagnostics (expect_rbac_authorized / expect_rbac_denied)
│   │   ├── redis_helper.cr                # with_redis / with_event_redis clients
│   │   ├── redis_proxy.cr                 # RedisProxy — byte-transparent TCP proxy for Redis-outage specs (start/pause/resume)
│   │   ├── result_helper.cr               # Result unwrapping helpers
│   │   ├── stub_event_manager.cr          # StubEventManager — Event::Manager test double
│   │   ├── system_settings_helper.cr      # ensure_settings_doc / pin_settings
│   │   ├── wait_helper.cr                 # wait_for / assert_eventually polling
│   │   ├── webhook_helper.cr              # Webhook seed fixtures (source doctype, roles)
│   │   └── workspace_test_helpers.cr      # Workspace assistant test doubles
│   ├── system_settings/
│   │   ├── assistant_hot_spec.cr  # Assistant hot settings
│   │   ├── fanout_spec.cr         # Save fans out + marks the cache stale
│   │   ├── http_spec.cr           # SystemSettings HTTP surface
│   │   ├── mail_hot_spec.cr       # Mail hot settings
│   │   ├── registry_spec.cr       # SystemSettings registry
│   │   ├── resolution_spec.cr     # Document → file → default resolution
│   │   ├── views_spec.cr          # SystemSettings::MailView
│   │   └── write_gate_spec.cr     # SystemSettings::WriteGate
│   ├── telemetry/
│   │   └── db_integration_spec.cr  # Telemetry DB integration
│   ├── templating/
│   │   └── engine_spec.cr  # Templating::Engine — display_name + search rendering
│   ├── util/
│   │   ├── cache_freshness_spec.cr      # Util::CacheFreshness
│   │   ├── client_ip_spec.cr            # Util::ClientIp — trusted-proxy client-IP resolution
│   │   ├── color_spec.cr                # Util::Color — CSS parsing + normalization
│   │   ├── diacritic_fold_spec.cr       # Util::DiacriticFold
│   │   ├── fiber_supervisor_spec.cr     # Util::FiberSupervisor
│   │   ├── filter_set_spec.cr           # Util::FilterSet — SQL filter builder
│   │   ├── mime_matcher_spec.cr         # Util::MimeMatcher
│   │   ├── money_filter_value_spec.cr   # Util::MoneyFilterValue
│   │   ├── money_spec.cr                # Util::Currency + Util::Money
│   │   ├── past_tense_inflector_spec.cr # Util::PastTenseInflector
│   │   ├── retry_spec.cr                # Util::Retry
│   │   ├── script_helpers_spec.cr       # Util::ScriptHelpers — ulid helper
│   │   ├── sequence_spec.cr             # Util::Sequence
│   │   ├── string_util_spec.cr          # Util::StringUtil
│   │   ├── time_helper_spec.cr          # Util::TimeHelper — UTC conversion
│   │   └── yaml_include_spec.cr         # Util::YamlInclude
│   ├── webhook/
│   │   ├── call_log_spec.cr       # Dispatcher call-log write side — pending → terminal, lease-loss, prune
│   │   ├── calls_spec.cr          # Webhook::Calls — pagination, status filter, scoped find
│   │   ├── dispatcher_spec.cr     # Webhook::Dispatcher — signature, header merge, outcome mapping
│   │   ├── doctype_spec.cr        # core.Webhook authoring rules — secret/binding stamps, PATCH rejection
│   │   ├── handler_spec.cr        # Webhook::Handler — enqueue path, filters, per-binding RBAC
│   │   ├── job_lifecycle_spec.cr  # Webhook job lifecycle events (import/export)
│   │   ├── manager_spec.cr        # Webhook::Manager — lifecycle + registration
│   │   ├── registry_spec.cr       # Registry — build / stale / rebuild, exclusion filters
│   │   ├── routes_spec.cr         # Call log + replay routes
│   │   └── test_spec.cr           # Test action end to end
│   └── websocket/
│       ├── child_changed_dispatch_spec.cr    # Aggregate child_changed frame dispatch
│       ├── collection_subscription_spec.cr   # Collection channel — two-segment path, cap, per-emit RBAC
│       ├── connection_spec.cr                # Websocket::Connection
│       ├── manager_spec.cr                   # Websocket::Manager — fake Fanout + fake Connection
│       ├── route_spec.cr                     # Websocket::Route
│       └── subscription_resolver_spec.cr     # SubscriptionResolver — path resolution + RBAC
```

Per-spec helper rules: a helper shared by more than one spec file lives once in `spec/support/`; a helper owned by one file is `private def`. `scripts/check-spec-defs.sh` (`make spec_defs_check`) fails a second public definition — see `doc/backend/workflow.md` → Testing.

---

## Concern Docs

| File                                                                   | Stack    | Covers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------------------------------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`backend/workflow.md`](backend/workflow.md)                           | Backend  | Backend working rules — Crystal conventions, lint + type-check + spec commands, spec patterns, debugging tracepoints, and per-concern quirks (database, doctype system, HTTP layer, Lua engine, index management, RBAC)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| [`backend/event.md`](backend/event.md)                                 | Backend  | Event system — Redis Streams, consumer groups, shard locking, fiber supervision + error backoff, the consumer-health registry, the at-most-once delivery contract (loss counters, consumer-lag check, reconciler pointer, group start id), `maxlen` sizing rule                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| [`ops/build-a-domain.md`](ops/build-a-domain.md)                       | Ops      | Task-oriented walkthrough — author a domain over the API: the draft loop (create → register doctypes → iterate with `/check` → publish) and the direct live-domain path, with the status codes to expect |
| [`ops/first-deployment.md`](ops/first-deployment.md)                   | Ops      | First-deployment bootstrap runbook — `db_reset`, `facet seed:admin` (one-time password, `must_change_pw`), first login + forced password change, verification steps; the `seed:dev` production refusal                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| [`ops/container-images.md`](ops/container-images.md)                   | Ops      | Container release path — the two image contracts, the config/env contract, the entrypoint chain, the release stack with the Caddy edge (On-Demand TLS ask), the smoke gate, the GHCR publish pipeline |
| [`backend/cli.md`](backend/cli.md)                                     | Backend  | Entrypoint, dotenv loading, subcommands                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| [`backend/cron.md`](backend/cron.md)                                   | Backend  | Cron concern — `Cron::Parser` (wrapper over `cron_parser` shard) and `Cron::Scheduler` (single-loop fiber, per-task fibers, signal channel, injectable clock)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/shutdown.md`](backend/shutdown.md)                           | Backend  | Graceful shutdown — `Facet::Shutdown` signal traps (SIGTERM/SIGINT/SIGHUP), HTTP drain, WebSocket close frames, ordered `at_exit` subsystem teardown with the DB pool last, synchronous shard-lock release on stream stop, shutdown log sequence + probe spec                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/migrations.md`](backend/migrations.md)                       | Backend  | Migration runner (`Migrate.run`, `Migrate.down` / `migrate:down`, `Migrate.db_reset`), rollback semantics, release discipline                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/doctype-system.md`](backend/doctype-system.md)               | Backend  | Field types, operators, schemas, validation, `/check` diagnostics, seed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| [`backend/collection-view.md`](backend/collection-view.md)             | Backend  | `core.CollectionView` — saved listing surfaces (table/kanban/grid) as children of `core.DocType`; general vs personal views, `$mine`+`$general` OR-joined read scopes, Lua `owner_id` coercion/immutability                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| [`backend/http-layer.md`](backend/http-layer.md)                       | Backend  | Routes, `ListRequest` parsing                                                                                                                                  |
| [`backend/openapi.md`](backend/openapi.md)                             | Backend  | OpenAPI surface — `GET /Api/openapi.json`, the declarative v1 slice (document CRUD, audit, IAM accounts), the auth gate, the CI drift check                     |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/search.md`](backend/search.md)                               | Backend  | Cross-doctype search — the `GET|QUERY /Api/:domain/search` and `/Api/search` routes, the per-doctype RBAC branch composition, the child → root resolution join, and the per-database fan-out merge; the `search` template as the searchability flag                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/mutation.md`](backend/mutation.md)                           | Backend  | Mutations table, projections table, JsonDiff, trigger flow, `Mutation::Client`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [`backend/links.md`](backend/links.md)                                 | Backend  | Document-to-document back-references (`projections.links`) — URN extraction from `reference` + `longtext` fields, `harness.mutation_links` GUC, partial GIN containment index                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/templating.md`](backend/templating.md)                       | Backend  | Jinja2 template rendering (`Templating::Engine` / `Templating::Context`) for the `display_name` label and `search` corpus — binding rules, reference and money resolution, validation, quirks                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/document.md`](backend/document.md)                           | Backend  | `Document::Create`, `Document::Action`, `Document::Copy`, `Document::ScriptContext`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| [`backend/import-export.md`](backend/import-export.md)                 | Backend  | Document import/export, both sides live — routes (`POST .../export`, `POST .../import`, status, download, wait mode), the `document_export` / `document_import` jobs (`max_attempts: 1`, long lease, execution-time RBAC recompile), one-transaction all-or-nothing upsert by manifest id, ownerless result + staging artifacts, completion events + notification, and the CSV cell codec (`ImportExport::CsvSerializer`) with its decode contract                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/artifact.md`](backend/artifact.md)                           | Backend  | Artifact subsystem — schema (`db/migrations/0003_artifacts.sql`), invariants (`artifacts` table is content-facts-only; `artifact_owners` rows are append-only), transversal-by-design + its prune consequence, the dedup timing oracle, upload + multipart intake, access control, signed grants, owner-append lifecycle, the operator admin surface (`GET /Api/Artifacts` + grants/references listings + the `revoke *.*` action), and `Facet::Artifact::Config` / `Facet::Config` artifact keys                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| [`backend/lua-engine.md`](backend/lua-engine.md)                       | Backend  | `Lua::Engine` wrapper, `ScriptContext`, `ScriptValidator`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| [`backend/specs.md`](backend/specs.md)                                 | Backend  | Test layout and spec coverage                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/test-database.md`](backend/test-database.md)                 | Backend  | Throwaway PostgreSQL for the spec suite — `compose.test.yml` (port 5433, tmpfs + `fsync=off`), `make test_db_up` / `make test_db_down`, why the suite must not run against the dev instance (`DROP DATABASE` checkpoint stalls)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| [`backend/schema-migration.md`](backend/schema-migration.md)           | Backend  | Schema migration — version gaps, migration functions, lazy migration on read and list, error marker recovery                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| [`backend/filter-set.md`](backend/filter-set.md)                       | Backend  | `Util::FilterSet` + `Util::FilterClauses` — composable SQL filter builder and the type-aware clause builders; the `match` / `starts_with` escape contract                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| [`backend/index-management.md`](backend/index-management.md)           | Backend  | `doctype_indexes` table, `Index::Manager`, automatic partial indexes on `projections`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| [`backend/rbac.md`](backend/rbac.md)                                   | Backend  | Role-based access control — permissions (alias-only `scope` over named scopes), context sets (domain-owned dynamic value sets), named scopes (doctype-owned static predicates with operator-suffix `where` grammar and the `$organizational_unit` token), scope predicates (`ScopePredicate`, `ScopeContext`), read/write enforcers, authoring-time validator                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/app-system.md`](backend/app-system.md)                       | Backend  | `app.App` registered external app doctype — Phase 1 registration schema (grants shape, `create` hook for autogenerated `client_id`, RBAC, seeding) + Phase 2 grant resolution engine (`Grant`, `AppScope`, `EffectiveScope`, `GrantResolver`): pure grant ∩ role intersection with pass-through scope aliases + Phase 3 Layer-1 enforcement (`AuthContext#app_grant` + `app_grant_permits?` pre-check in `ReadEnforcer` / `WriteEnforcer`, fail-closed) + Phase 4 OAuth contract (token carries elected role, consent always shown, Transport re-resolves grant from live `app.App` on every request; see oauth.md) + Phase 6 audit & observability (`AuthContext#app_id`, `mutations.app`, `Audit::List` app filter, `iam.LoginEvent.app` + `consent_granted` / `app_refresh` / `refresh_failed` / `layer1_denied` events, OpenTelemetry `app` / `role` / `sid` span attributes) + backend apps (service account + app-owned API key) + the per-app assistant (`assistant_enabled` / `assistant_prompt` fields, the `app` conversation kind, `App::Gate`) + deployment serving (`app.Deployment` doctype, `deploy` named-action gate on the deploy route, `no_asset` refusal, host dispatch + `HostCache`) + the `facet-cli` seed (first-party CLI app: public OAuth client, loopback redirect patterns, `no_launcher`/`no_asset` headless flags, app-scoped grant guard) + the `redirect_uris` match rule (`OAuth::RedirectUri`) |
| [`backend/oauth.md`](backend/oauth.md)                                 | Backend  | OAuth app authorization server (Phase 4) — `/OAuth/...` endpoints, PKCE-protected authorization code flow, single-use Redis code store, app JWT (`typ: "app"`) claims, `AuthHandler` branching on `typ: "app"`, CORS by registered origin match, `OriginCache` + `Event::Subscriber::AppCache`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/agent-tools.md`](backend/agent-tools.md)                     | Backend  | Shared agent tool catalogue (`AgentTools`) — one definition per tool (name, schema, handler) served to MCP clients and mounted by assistant registrars; role-filtered visibility, row/byte caps, tool-error taxonomy, fanout invalidation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| [`backend/mcp.md`](backend/mcp.md)                                     | Backend  | MCP resource server — `/Api/_mcp/:role_slug` (URL-pinned role), RFC 9728 PRM discovery, OAuth 2.1 resource-server validation (`aud` exact match), dispatch chain + per-`sid` concurrency cap, role-filtered tool registry with fanout invalidation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/config.md`](backend/config.md)                               | Backend  | `Facet::Config` — YAML config loading (`config.{env}.yml`), the `!env` tag for env-injected secrets, per-section loaders, singleton lifecycle                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/logging.md`](backend/logging.md)                             | Backend  | Logging — explicit config-driven setup (`logs:` section, `Facet::Logging.setup` from `CLI.run`), JSON/text formatters, the shrine require-time side effect it replaces, credential hygiene rule                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| [`backend/metrics.md`](backend/metrics.md)                             | Backend  | Metrics — in-process registry on `GET /metrics` (Prometheus text 0.0.4): catalog, counter hooks, scrape-time gauges, cardinality policy, scrape topology                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| [`backend/jobs.md`](backend/jobs.md)                                   | Backend  | Background jobs — PostgreSQL-only queue (`background_jobs` table, migration `0008_jobs.sql`), `Jobs::Handler` contract with attempt-lifecycle hooks, `Queries` (SKIP LOCKED claim), `Worker` poll loop, `Manager` singleton (enqueue-only mode), `jobs:` config                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| [`backend/settings.md`](backend/settings.md)                           | Backend  | Account Settings — per-account, per-application preference store (`account_settings` table), key registry, validation, self-service HTTP routes under `/Api/settings`, `/Api/iam/me` integration                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| [`backend/system-settings.md`](backend/system-settings.md)             | Backend  | System Settings — runtime platform configuration as the `core.SystemSettings` singleton document (seed bundle + Lua singleton guard + editor/viewer RBAC carve-outs): `SPEC` registry keyed by config paths, document → file → default resolution, the invalidate-only process cache + `SystemSettingsCache` subscriber, the write-time validation split (shape / Lua / `WriteGate`), `GET /Api/SystemSettings` (`values` + `pinned`), and the two hot consumers (assistant per-turn view, mail adapter rebuild)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| [`backend/secrets.md`](backend/secrets.md)                             | Backend  | Secret store — durable secrets keyed by document + slot (`secrets` + `secret_staging` tables, migration `0011_secrets.sql`), closed mode enum (`hash` / `sealed` / `token`), self-describing payloads, `Facet::Secrets` slot API, doctype `secret` field type with the stage route and adoption flow (markers, forge guard), reserved IAM slots (`password` / `mfa` / `reset`), `Cron::SecretsPrune`, the `secrets:` config section                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| [`backend/notifications.md`](backend/notifications.md)                 | Backend  | Notifications — per-account in-app store (`notifications` table, not event-sourced), `Send` / `List` / `MarkRead` / `InvokeAction`, the `notification.send` Lua producer, the `notified` Redis event (source-doc stream + per-account fanout, webhook opt-in), self-service HTTP routes under `/Api/notifications`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/replication.md`](backend/replication.md)                     | Backend  | Cross-domain field replication — `Binding`, `Registry`, `SyncPull`, async `Handler`, `Validator` (now `/check`-driven), reentrancy guard, `Manager` singleton refresh wiring                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| [`backend/domain-grants.md`](backend/domain-grants.md)                 | Backend  | Domain grants — cross-domain read consent as `core.DomainGrant` documents under the producer domain (`Grants::DEFAULT_TAG`, `Grants::Validator` authoring gate, stale-flag `Grants::Registry`, the four gates G1–G4, activate/deactivate routes, `Grants::PublishTickets` filing at publish with the D6/D11 acceptance rules, `grant_tickets` publish report) |
| [`backend/sidecar.md`](backend/sidecar.md)                             | Backend  | Sidecar doctypes — cross-domain nested records (`sidecar` flag + `sidecars` map, flat-create block, nested flat-or-grant routes, `SidecarSweep` event subscriber + `Cron::SidecarReconcile` backstop)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| [`backend/webhook.md`](backend/webhook.md)                             | Backend  | Webhooks — outbound signed delivery on source-doctype mutations (`core.Webhook` doctype, `Registry`, enqueue-time `AuthCheck` six-step gate, `webhook_delivery` jobs + `Dispatcher` transport and call-log hooks, `webhook_calls` call log (`Calls` read side), call-log / replay / test routes, the `Cron::WebhookReconcile` enqueue-hop backstop (window, dedupe, reentrancy, new-binding bound, duplicate tolerance), `WebhookConfig`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| [`backend/hooks.md`](backend/hooks.md)                                 | Backend  | Domain hooks — domain-owned Lua automation on `core.Domain.hooks`: `event` hooks fired by source mutations, `schedule` hooks fired on cron with a Redis once-per-cluster lease; authoring-time `Hooks::Validator` (`Document::Update` gate + `Domain::Check`), stale-flag / lazy-rebuild `Registry`, sandboxed `Executor` (`ctx.event` / `ctx.scheduled_at`, domain-scoped `document.*`, reentrant writes), `cg:hooks:` consumer groups, portable-bundle carry-through (`hooks/{i}-{hook_id}.lua`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/draft-domains.md`](backend/draft-domains.md)                 | Backend  | Draft domains — throwaway `_`-prefixed domains for doctype iteration; copy-and-drop publish, draft-mode schema mutation, replication isolation, `Domain::Check` aggregate `/check` diagnostics; `Domain::Drop` — delete a domain (draft or live) with audit record and system-domain guards                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| [`backend/domain-editors.md`](backend/domain-editors.md)               | Backend  | Domain editors — scoped domain administration for the `editor` role: `core.DomainEditor` doctype + guard hook, `editor_domains`/`editor_doctypes`/`editor_draft_domains` context sets on the `core` domain document, `$domain_editor`/`$domain_editor_draft` named scopes, the `except`-carved role shape, `Domain::Editors` membership helpers (member?/grant/transfer/authorize_doctype_create?), auto-editorship on every domain-creation path, publish overwrite guard + editor carry-over, teardown cleanup                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| [`backend/portable-domains.md`](backend/portable-domains.md)           | Backend  | Portable-domain bundle — export/import of a domain definition (`core.Domain`, doctypes, document views, general collection views); opt-in `--with-documents` captures every user-doctype document in the source domain (`core.*` never captured as documents); `Archive` directory/`.zip`/`.tar.gz` format, `Export` / `Import` service layer, `domain:export` / `domain:import` CLI, HTTP routes + `domain_export` / `domain_import` jobs (RBAC on `core.Domain`, definition-only over HTTP, zip artifacts); version gate + atomicity on merge, `--into` rewrite of document ids and reference tokens, cross-domain reference integrity never enforced                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| [`backend/dev-domain-watcher.md`](backend/dev-domain-watcher.md)       | Backend  | Dev domain watcher — folder-authored doctypes: `dev.domain_watch` config, watch-root scan, per-child fingerprint + debounce, teardown-per-documents-mode + fresh `Portable::Import` sync cycle, removed-doctype data tombstone, structure warnings, `Domain::Check` summary + `Doctype::Reproject`, check-report endpoint (`GET /Api/dev/check-report`), dev-only lifecycle                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| [`backend/iam.md`](backend/iam.md)                                     | Backend  | IAM — authentication (password login pipeline with `pending` bootstrap accounts), credential bootstrap (operator temporary-password + invite-link routes, `reset` slot link tokens, convergence rule), TOTP MFA with `preferred` / `always` enforcement and enroll-at-login, sessions, JWT, token refresh; static API keys (`fct_…` bearer keys with pair liveness, `/Api/iam/keys` self-service routes, `mutations.api_key` provenance); service-account login gate; credential-states admin read                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/oidc.md`](backend/oidc.md)                                   | Backend  | Inbound OIDC — federated login at `/auth/oidc/…` (hand-rolled client: discovery + JWKS cache, id_token verification with pinned {RS256, ES256}, PKCE S256, one-shot Redis state), identity resolution (link → verified-email match → JIT provisioning) over the `federated_identities` field on `iam.Account`, `GET /Api/iam/oidc/providers`, anti-enumeration + audit events                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/util-money.md`](backend/util-money.md)                       | Backend  | `Util::Currency`, `Util::Money`, `Util::MoneyFilterValue` — currency registry (`Facet::Currency::Registry`, hydrated from `core.Currency` documents), money struct (`{value,currency}`), write-path lifecycle rule (`inactive_currency`), filter value grammar, doctype integration                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| [`backend/util-client-ip.md`](backend/util-client-ip.md)               | Backend  | `Util::ClientIp` — client-IP resolution for the throttle, rate-limit, and telemetry inputs: socket host without the port, `X-Forwarded-For` walked right to left only behind a configured `trusted_proxies` entry, nil when the request has no IP peer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| [`backend/util-color.md`](backend/util-color.md)                       | Backend  | `Util::Color` — CSS color parsing and normalization                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| [`backend/util-crypto.md`](backend/util-crypto.md)                     | Backend  | `Util::Crypto` — constant-time string comparison for secret tokens                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/util-projections.md`](backend/util-projections.md)           | Backend  | `Util::Projections` — shared projection lookups (row existence, draft-domain flag)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`backend/util-sequence.md`](backend/util-sequence.md)                 | Backend  | `Util::Sequence` — Sequential identifier generation from templates with digit groups and time variables, overflow fallback, doctype integration                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| [`backend/audit.md`](backend/audit.md)                                 | Backend  | Audit system — `Audit::List`, `Audit::Restore`, `Audit::Rollback`, HTTP routes (history / rollback / restore)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/telemetry.md`](backend/telemetry.md)                         | Backend  | Telemetry — OpenTelemetry config, instrumentation spans, environment variables                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [`backend/websocket.md`](backend/websocket.md)                         | Backend  | WebSocket real-time bridge — /Ws endpoint, RBAC-gated subscriptions (per-document + two-segment collection channels with per-emit RBAC and a config-bounded subscriber cap), fanout dispatch                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| [`backend/assistant.md`](backend/assistant.md)                         | Backend  | AI Assistant — LLM agent loop, config, shared tool envelope, conversation kinds (generic, `domain-builder`, `workspace`, `app`), domain builder assistant (draft-domain schema architect)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| [`backend/workspace-assistant.md`](backend/workspace-assistant.md)     | Backend  | Workspace assistant — main-application chat surface: `connectivity ∋ assistant` role gate, owner-scoped workspace kind, registry-delegated toolset + `navigate` / `show_documents` UI tools, per-message access re-check, usage ledger + limits seam, `/Api/iam/me` availability payload                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| [`backend/domain-builder-skills.md`](backend/domain-builder-skills.md) | Backend  | Domain-builder assistant skill files — LLM guidance for authoring doctype definitions, document views, and fixtures; the skill inventory \+ fixture reference                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`backend/agent-conversations.md`](backend/agent-conversations.md)     | Backend  | Agent conversations — persistent storage (`agent_conversations`, `agent_turns`, `assistant_usage`), per-turn message replay, KV cache preservation, SSE streaming + Redis Pub/Sub cancel bus + usage-ledger writer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`frontend/workflow.md`](frontend/workflow.md)                         | Frontend | SvelteKit web UI — toolchain, scripts, testing strategy, i18n, DataSource layer, document view template engine                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [`frontend/document-view.md`](frontend/document-view.md)               | Frontend | Document-view renderer — the header (title, status, chips, reference-label subtitle via `referenceLabel.ts`) and the relation table (column normalization, hydrated reference Capsules with click-through)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [`frontend/configure-editors.md`](frontend/configure-editors.md)       | Frontend | Builder schema editors — `DoctypeEditor` / `DomainEditor` component families (grants tab: issued + held `core.DomainGrant` documents), the shared working-copy contract, `domainSecurity.ts` / `domainGrants.ts` / `keys.ts` / `iconPicker` modules, and the shared `DangerZone` primitive                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| [`frontend/sidecar-panel.md`](frontend/sidecar-panel.md)               | Frontend | Sidecar panel — right-side rail on the document show page (`SidecarPanel` / `SidecarDvtSurface` / `CommentSurface`), the general surface registry, `DocumentRef.sidecars(segment)` DataSource accessor                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| [`frontend/backlinks.md`](frontend/backlinks.md)                       | Frontend | Backlinks panel — the show page's "Referenced by" section and the delete-confirmation referrer warning over `DocumentRef.backrefs()` (the HTTP `/backrefs` endpoint's `{ data, meta: { target, total, capped } }` stub rows)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| [`frontend/schematic.md`](frontend/schematic.md)                       | Frontend | Schematic component — reusable boxes-and-arrows renderer, doctype domain schematic, drag-to-move                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| [`frontend/bits-ui.md`](frontend/bits-ui.md)                           | Frontend | Bits UI integration — API rules, CSS targeting, component patterns, pitfalls                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| [`frontend/command-palette.md`](frontend/command-palette.md)           | Frontend | Command palette — the top-bar search trigger's target: one `Cmd/Ctrl+K` surface with four result groups (navigate, recent, records, actions), the record-search adapter to the backend search endpoint, and both shell mounts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`frontend/chat.md`](frontend/chat.md)                                 | Frontend | Chat components — markdown bubbles, tool-call bar, composer, thread; the reusable `ChatPanel` core, the shared `AssistantWindow` floating window with both mounts (`FloatingAssistant` builder, `WorkspaceAssistant` main application), and the workspace document/stats renderers with replay                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [`frontend/notifications.md`](frontend/notifications.md)               | Frontend | Notification centre — `notifications.svelte.ts` store (`/Api/notifications` + `/notifications` WebSocket self-subscription, unread badge, mark-read, action dispatch) and the `NotificationPanel` surface; the `NotificationPanelHost` fixed-position mount owns open/navigation wiring                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| [`frontend/markdown-editor.md`](frontend/markdown-editor.md)           | Frontend | Markdown editor — `Display/Markdown` (preview / WYSIWYG / source), `Display/Milkdown` wrapper around `@milkdown/crepe`, shared CodeMirror source setup, longtext DVT integration                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| [`frontend/settings.md`](frontend/settings.md)                         | Frontend | Settings surfaces — personal preferences page (timezone, language, notification mockup; store wired to `/Api/settings/core`), the API keys screen at `/Settings/api-keys` (create, one-time reveal, revoke via `/Api/iam/keys`), and the webhooks screen at `/Settings/webhooks` (list/create/edit/pause/delete over `core.Webhook` through the DataSource layer with an own-account filter, test action, and the per-webhook call log with replay via the bespoke routes — `src/lib/webhooks/webhooks.ts`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| [`../../e2e/README.md`](../../e2e/README.md)                           | E2E      | Dockerized pre-release gate — one throwaway compose stack (`pgvector`/Redis/backend/frontend/Caddy) per scenario file, setup-project storageState, Node runtime shims for Caddy's wildcard cert + `vite preview` SSR scheme, artifacts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| [`documentation.md`](documentation.md)                                 | Docs site | Documentation workflow — how pages get written, verified and shipped: claims checked against code or a running instance, action-first style rules (examples, tips, cautions), build + render gates, page front-matter contract
| [`site-docs.md`](site-docs.md)                                                         | Docs site | Public documentation website (`site-docs/`) — Astro + Starlight structure, English-first i18n with fallback routes, build-time D2 diagram rendering, Tailwind setup, `llms.txt` output, `npm run build` as the validation gate |
| [`site-docs-fr-style.md`](site-docs-fr-style.md)                       | Docs site | French translation rules for the docs site — meaning-first translation, terminology tables (what stays English), typography, calque blacklist, page mechanics for `fr/` pages |
| [`frontend/audit.md`](frontend/audit.md)                               | Frontend | Audit pages — global audit log at `/Configure/audit` (`GlobalAuditTable` filter bar, table, `more`-driven pagination; `AuditDetail` change inspector, rollback with confirm dialog; `AuditSource` adapter for `GET /Api/Audit` and global rollback; fail-honest `403` handling, capped-count behaviour) and the document history page at `/{domain}/{doctype}/{id}/history` (`History` timeline + detail pane, `via <cause>` provenance badge, shareable `?mutation=<ulid>` selection with a bounded deep-link page walk)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| [`frontend/platform.md`](frontend/platform.md)                         | Frontend | PLATFORM section (`/Configure/platform/*`, admin-only via wildcard read) — index status page at `/Configure/platform/indexes`: `IndexesTable` (status badges, filters, `more`-driven pagination, refresh), `IndexesSource` adapter for `GET /Api/Indexes`; artifact management page at `/Configure/platform/artifacts`: `ArtifactsExplorer` (master–detail listing + grants table with `revoke *.*`-gated revocation + referenced-by table), `ArtifactsSource` adapter for `GET /Api/Artifacts`; system settings page at `/Configure/platform/settings`: `SystemSettingsForm` (sticky chapter rail — Assistant / Mail / Artifacts / Retention — with scroll-spy and icons, pin badges + reset-to-file, read-only storage-adapter row, secret stage/adopt), `SystemSettingsSource` adapter for `GET /Api/SystemSettings` + the sparse document PATCH + `POST /Api/secrets/stage`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`frontend/calendar.md`](frontend/calendar.md)                         | Frontend | Calendar view — month/week grid, discriminator kinds, window filter, native-range overlap, fixture date shifting                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| [`frontend/kanban.md`](frontend/kanban.md)                             | Frontend | Kanban view — lane model (`KanbanLane`, values vs custom; enum or boolean group-by), one `list()` per lane, card rendering through the `card` DVT with identity fallback, `laneWriteTarget` drag-and-drop groundwork, view-editor lane form                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| [`frontend/grid.md`](frontend/grid.md)                                 | Frontend | Grid view — spreadsheet-style listing surface (`Grid.svelte`: frozen columns, range selection, keyboard navigation, TSV copy, Σ row, per-type cell editors, write queue with undo), the `config.grid` shape and column semantics (the `editable` opt-out, `summary` aggregates, the `fieldTypes.ts` capability sets), and the view editor's grid form                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [`frontend/templating.md`](frontend/templating.md)                     | Frontend | Jinja2-subset renderer for client-side templates (`renderTemplate`) — renders the calendar view's `title_template` with the backend `Templating` conventions (`{{ field }}`, `content.` root, blank misses, money formatting, verbatim unsupported syntax)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| [`frontend/filter-bar.md`](frontend/filter-bar.md)                     | Frontend | Reusable schema-aware filter bar — search + add-filter menu + per-filter chips, shared by the table toolbar and the calendar view configuration                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| [`frontend/list-view.md`](frontend/list-view.md)                       | Frontend | Listing surface — `ListView` (saved-view tabs over `core.CollectionView`, surface dispatch, deep links) and the `Table` (rows, sort, filter toolbar, pagination), plus the per-view localStorage persistence of the manual sort, filters, and rows-per-page (`collectionView/viewState.ts`) |
| [`frontend/datetime-picker.md`](frontend/datetime-picker.md)           | Frontend | DatetimePicker primitive — segmented timezone-aware datetime entry (`YYYY-MM-DD HH:MM`), UTC RFC-3339 value contract, `granularity: 'date'` calendar-date mode, `zonedTime.ts` conversion module, Now/Clear actions, stories as component tests                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| [`frontend/period-picker.md`](frontend/period-picker.md)               | Frontend | PeriodPicker primitive — Start/End range entry for `period` (UTC bounds) and `dateperiod` (calendar-date bounds) fields, pair commit rule, order hint; the `input-period` / `input-dateperiod` / `input-date` DVT nodes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| [`frontend/shortcuts.md`](frontend/shortcuts.md)                       | Frontend | Keyboard shortcuts — `$lib/shortcuts.svelte.ts` registry + dispatcher (global vs route scope, platform `Mod`, typing-target and dialog guards), the `?` cheat-sheet `ShortcutsDialog`, and the wired surfaces (assistant toggle, sidebar, list navigation and search focus, `C` new, `E` edit, `Mod+S` save)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| [`frontend/access-assignments.md`](frontend/access-assignments.md)     | Frontend | Assignment page — two-mode editor (by role / by account) at `/Configure/access/assignments`; subject pickers use async search so large account/role tables do not load at once; writes `iam.Account.roles` (+ `default_role`) via `PATCH /Api/iam/Account/:id`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [`frontend/access-accounts.md`](frontend/access-accounts.md)           | Frontend | Accounts admin page at `/Configure/access/accounts` — standard tab-less `ListView` (`showTabs={false}`) with the shared filter toolbar (search over `email` + `name`), trash mode, and QuickView peek; create/edit via the standard document form routes; credential actions (invite, temporary password with reveal-once panel, MFA reset with confirm) live on the account show page via `AccountCredentialActions`, gated on `provision_credentials` / `mfa_disable`; the plan §4.6 create rule (human → `pending`) is enforced by the seeded `iam.Account` Lua create hook                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| [`frontend/access-roles.md`](frontend/access-roles.md)                 | Frontend | Roles admin surface at `/Configure/access/roles` — the roles list with the shared `RbacEditor` grants tree (writes only `permissions`), the role detail tabs (Details / Members / Grants), the read-only role powers strip (connectivity channels + assistant token budget mirrored above the grants tree; the Details tab is the single write surface), and the browser-only default for dialog-created roles |
| [`frontend/app-configure.md`](frontend/app-configure.md)               | Frontend | Apps configuration surface — `/Configure/apps` list with preset cards, creation wizard (setup → permissions → review → credentials), detail page with three tabs, plain-language permissions picker shared by the wizard and the grants tab |
| [`packages/cli.md`](packages/cli.md)                                   | Packages | `@facetapp/cli` — CLI for app developers: command layer, config/auth/api/deploy/login modules, OAuth + PKCE sign-in, deploy contract with the backend, testing layout                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| [`packages/sdk.md`](packages/sdk.md)                                   | Packages | `@facetapp/sdk` — TypeScript SDK for Facet apps: the HTTP core and error contract, the query builder, the client handle tree (documents, children, sidecars, history, backrefs), the ETag cache, the browser OAuth helper with single-flight refresh, the WebSocket realtime handle (handshake per transport, reconnect, close-code signals), and the artifact upload/grant/download surface, with the backend contract for each                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`packages/chat.md`](packages/chat.md)                                 | Packages | `@facetapp/chat` — embeddable assistant chat for Facet apps: the `FacetAssistant` facade and the two custom-element mounts (`<facet-assistant>` inline, `<facet-assistant-window>` floating), the app-scoped chat core, the HTTP/SSE driver + mock, shadow-DOM theming, and the backend `app` kind contract                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| [`packages/release.md`](packages/release.md)                           | Packages | npm package release — tag-driven publish workflow (`cli-v*` tags), gates + build + smoke + publish steps, trusted publishing (OIDC), one-time npm setup, failure handling                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| [`shared/fixtures.md`](shared/fixtures.md)                             | Shared   | Shared fixture system — `data/fixtures/` format, frontend/backend usage                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |

See [`AGENTS.md`](../AGENTS.md) for the main loop, coding conventions, and project quirks.
