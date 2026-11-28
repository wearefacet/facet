
## HTTP routes (src/**)

| Surface | Registered in |
|---|---|
| DELETE `/Api/:domain/:doctype/:id` | src/document/routes.cr |
| DELETE `/Api/Artifacts/:id` | src/artifact/routes.cr |
| DELETE `/Api/app/:id/api-key` | src/app/routes.cr |
| DELETE `/Api/core/artifacts/grants/:gid` | src/artifact/routes.cr |
| DELETE `/Api/iam/apps/:app_id/sessions` | src/iam/routes.cr |
| DELETE `/Api/iam/keys/:key_id` | src/iam/routes.cr |
| DELETE `/Api/iam/sessions/:session_id` | src/iam/routes.cr |
| DELETE `/Api/iam/sessions` | src/iam/routes.cr |
| DELETE `/Api/settings/:app/:key` | src/settings/routes.cr |
| GET `#{CREATE_ROUTE}/:id` | src/assistant/workspace/routes.cr |
| GET `#{PATH_PREFIX}/endpoints` | src/mcp/routes.cr |
| GET `/.well-known/oauth-authorization-server` | src/oauth/routes.cr |
| GET `/.well-known/oauth-protected-resource/*suffix` | src/mcp/routes.cr |
| GET `/.well-known/oauth-protected-resource` | src/mcp/routes.cr |
| GET `/A/:gid` | src/artifact/routes.cr |
| GET `/Api/:domain/:doctype/:id/:child/:child_id/history` | src/audit/routes.cr |
| GET `/Api/:domain/:doctype/:id/backrefs` | src/document/routes.cr |
| GET `/Api/:domain/:doctype/:id/history` | src/audit/routes.cr |
| GET `/Api/:domain/:doctype/:id` | src/document/routes.cr |
| GET `/Api/:domain/:doctype/import_export/:job_id/download` | src/import_export/routes.cr |
| GET `/Api/:domain/:doctype/import_export/:job_id` | src/import_export/routes.cr |
| GET `/Api/:domain/:doctype` | src/document/routes.cr |
| GET `/Api/:domain/search` | src/search/routes.cr |
| GET `/Api/Artifacts/:id/grants` | src/artifact/routes.cr |
| GET `/Api/Artifacts/:id/references` | src/artifact/routes.cr |
| GET `/Api/Artifacts` | src/artifact/routes.cr |
| GET `/Api/Audit` | src/audit/routes.cr |
| GET `/Api/Indexes` | src/index/routes.cr |
| GET `/Api/SystemSettings` | src/system_settings/routes.cr |
| GET `/Api/app/:id/api-key` | src/app/routes.cr |
| GET `/Api/assistant/conversations/:id/turns/latest` | src/assistant/routes.cr |
| GET `/Api/assistant/conversations/:id/turns` | src/assistant/routes.cr |
| GET `/Api/assistant/conversations/:id` | src/assistant/routes.cr |
| GET `/Api/assistant/conversations` | src/assistant/routes.cr |
| GET `/Api/assistant/usage` | src/assistant/routes.cr |
| GET `/Api/core/DocType/:id/check` | src/doctype/routes.cr |
| GET `/Api/core/DocType/:id/maintenance_jobs` | src/doctype/maintenance_routes.cr |
| GET `/Api/core/DocType/:id/maintenance_status` | src/doctype/maintenance_routes.cr |
| GET `/Api/core/Domain/:id/check` | src/domain/routes.cr |
| GET `/Api/core/Domain/import_export/:job_id/download` | src/domain/portable/routes.cr |
| GET `/Api/core/Domain/import_export/:job_id` | src/domain/portable/routes.cr |
| GET `/Api/core/Webhook/:id/calls/:call_id` | src/webhook/routes.cr |
| GET `/Api/core/Webhook/:id/calls` | src/webhook/routes.cr |
| GET `/Api/core/artifacts/:id/download` | src/artifact/routes.cr |
| GET `/Api/core/artifacts/:id` | src/artifact/routes.cr |
| GET `/Api/dev/check-report` | src/dev/check_report.cr |
| GET `/Api/iam/accounts/credential-states` | src/iam/routes.cr |
| GET `/Api/iam/apps` | src/iam/routes.cr |
| GET `/Api/iam/keys` | src/iam/routes.cr |
| GET `/Api/iam/me` | src/iam/routes.cr |
| GET `/Api/iam/oidc/providers` | src/iam/routes.cr |
| GET `/Api/iam/sessions` | src/iam/routes.cr |
| GET `/Api/notifications/unread_count` | src/notifications/routes.cr |
| GET `/Api/notifications` | src/notifications/routes.cr |
| GET `/Api/search` | src/search/routes.cr |
| GET `/Api/settings/:app/:key` | src/settings/routes.cr |
| GET `/Api/settings/:app` | src/settings/routes.cr |
| GET `/Api/settings` | src/settings/routes.cr |
| GET `/Edge/HostAsk` | src/app/host_ask.cr |
| GET `/Healthcheck/live` | src/http/healthcheck.cr |
| GET `/Healthcheck` | src/http/healthcheck.cr |
| GET `/OAuth/authorize` | src/oauth/routes.cr |
| GET `/OAuth/client-info` | src/oauth/routes.cr |
| GET `/auth/oidc/:provider/callback` | src/iam/oidc/routes.cr |
| GET `/auth/oidc/:provider` | src/iam/oidc/routes.cr |
| GET `/metrics` | src/http/metrics_route.cr |
| PATCH `/Api/:domain/:doctype/:id` | src/document/routes.cr |
| PATCH `/Api/assistant/conversations/:id` | src/assistant/routes.cr |
| POST `#{PATH_PREFIX}/:role_slug` | src/mcp/routes.cr |
| POST `/A/upload/:uid` | src/artifact/routes.cr |
| POST `/Api/:domain/:doctype/:id/:child/:child_id/rollback` | src/audit/routes.cr |
| POST `/Api/:domain/:doctype/:id/restore` | src/audit/routes.cr |
| POST `/Api/:domain/:doctype/:id/rollback` | src/audit/routes.cr |
| POST `/Api/:domain/:doctype/export_view` | src/import_export/routes.cr |
| POST `/Api/:domain/:doctype/export` | src/import_export/routes.cr |
| POST `/Api/:domain/:doctype/import` | src/import_export/routes.cr |
| POST `/Api/:domain/:doctype` | src/document/routes.cr |
| POST `/Api/Audit/:mutation_id/rollback` | src/audit/routes.cr |
| POST `/Api/SystemSettings/assistant/test` | src/system_settings/routes.cr |
| POST `/Api/SystemSettings/mail/test` | src/system_settings/routes.cr |
| POST `/Api/app/:id/api-key` | src/app/routes.cr |
| POST `/Api/app/:id/deploy` | src/app/deploy.cr |
| POST `/Api/assistant/cancel/:turn_token` | src/assistant/routes.cr |
| POST `/Api/assistant/conversations/:id/stream` | src/assistant/routes.cr |
| POST `/Api/assistant/conversations/:id/turns` | src/assistant/routes.cr |
| POST `/Api/assistant/conversations` | src/assistant/routes.cr |
| POST `/Api/core/DocType/:id/migrate_ahead` | src/doctype/maintenance_routes.cr |
| POST `/Api/core/DocType/:id/reproject` | src/doctype/maintenance_routes.cr |
| POST `/Api/core/Domain/:id/draft` | src/domain/routes.cr |
| POST `/Api/core/Domain/:id/drop` | src/domain/routes.cr |
| POST `/Api/core/Domain/:id/export` | src/domain/portable/routes.cr |
| POST `/Api/core/Domain/:id/preview-session` | src/domain/routes.cr |
| POST `/Api/core/Domain/:id/publish` | src/domain/routes.cr |
| POST `/Api/core/Domain/draft` | src/domain/routes.cr |
| POST `/Api/core/Domain/import` | src/domain/portable/routes.cr |
| POST `/Api/core/DomainGrant/:id/activate` | src/grants/routes.cr |
| POST `/Api/core/DomainGrant/:id/deactivate` | src/grants/routes.cr |
| POST `/Api/core/Webhook/:id/calls/:call_id/replay` | src/webhook/routes.cr |
| POST `/Api/core/Webhook/:id/test` | src/webhook/routes.cr |
| POST `/Api/core/artifacts/:id/grant` | src/artifact/routes.cr |
| POST `/Api/core/artifacts/:id/publish` | src/artifact/routes.cr |
| POST `/Api/core/artifacts` | src/artifact/routes.cr |
| POST `/Api/iam/accounts/:id/invite` | src/iam/routes.cr |
| POST `/Api/iam/accounts/:id/temporary-password` | src/iam/routes.cr |
| POST `/Api/iam/challenge` | src/iam/routes.cr |
| POST `/Api/iam/change-password` | src/iam/routes.cr |
| POST `/Api/iam/keys` | src/iam/routes.cr |
| POST `/Api/iam/login` | src/iam/routes.cr |
| POST `/Api/iam/logout` | src/iam/routes.cr |
| POST `/Api/iam/mfa/disable` | src/iam/routes.cr |
| POST `/Api/iam/mfa/enroll/verify` | src/iam/routes.cr |
| POST `/Api/iam/mfa/totp/setup` | src/iam/routes.cr |
| POST `/Api/iam/mfa/totp/verify` | src/iam/routes.cr |
| POST `/Api/iam/password-reset/confirm` | src/iam/routes.cr |
| POST `/Api/iam/password-reset/request` | src/iam/routes.cr |
| POST `/Api/iam/refresh` | src/iam/routes.cr |
| POST `/Api/notifications/:id/actions/:key` | src/notifications/routes.cr |
| POST `/Api/notifications/:id/read` | src/notifications/routes.cr |
| POST `/Api/notifications/read_all` | src/notifications/routes.cr |
| POST `/Api/secrets/stage` | src/http/secrets_routes.cr |
| POST `/OAuth/authorize` | src/oauth/routes.cr |
| POST `/OAuth/register` | src/oauth/routes.cr |
| POST `/OAuth/token` | src/oauth/routes.cr |
| PUT `/Api/core/DocType/:id` | src/doctype/routes.cr |
| PUT `/Api/settings/:app/:key` | src/settings/routes.cr |
| WS `/Ws` | src/websocket/route.cr |

## facet CLI commands (src/cli/commands.cr)

| Command | Description |
|---|---|
| `facet server` | Start the HTTP server (default; long-running, must be last in a chain) |
| `facet migrate` | Run database migrations |
| `facet migrate:down` | Revert applied migrations (run standalone to pass a target) |
| `facet db_reset` | Drop, recreate and migrate the database (asks to confirm; --yes skips) |
| `facet seed:core` | Seed core doctypes and the currency registry (idempotent, non-destructive) |
| `facet index:retry` | Retry failed index creations (run standalone to pass options) |
| `facet artifacts:prune` | Soft-delete (or --hard delete) artifacts with no live owner or recent reference |
| `facet artifacts:reconcile` | Delete orphaned objects from the artifact store (run standalone to pass options) |
| `facet artifacts:revoke` | Revoke every signed URL for an artifact (run standalone to pass the artifact id) |
| `facet accounts:list` | List accounts (id, email, display name, status, roles) |
| `facet accounts:create` | Create an account and print a one-time password (run standalone to pass email and options) |
| `facet roles:list` | List roles (id, name) |
| `facet roles:add` | Assign a role to an account (run standalone to pass account and role) |
| `facet auth:mode` | Pin the authentication mode on the SystemSettings document (run standalone: facet auth:mode {hybrid/oidc_only}) |
| `facet seed:dev` | Seed the dev admin (admin@example.tld / admin, refused when APP_ENV=production) |
| `facet seed:admin` | Create the first admin with a generated one-time password (run standalone to pass the email) |
| `facet domain:export` | Export a domain definition to a directory or .tar.gz (run standalone to pass options) |
| `facet domain:import` | Import a domain definition from a directory or .tar.gz (run standalone to pass options) |
| `facet doctype:reproject` | Re-project a doctype's search/links/display_name columns for every live document |
| `facet doctype:migrate-retry` | Re-run lazy migration for documents blocked by a meta.migration_error marker |
| `facet cron:list` | List the boot cron tasks (id, config key, schedule, next run) |

## @facetapp/cli commands (packages/cli/src/commands/)

| Command | Source |
|---|---|
| context | packages/cli/src/commands/context.ts |
| deploy | packages/cli/src/commands/deploy.ts |
| init | packages/cli/src/commands/init.ts |
| login | packages/cli/src/commands/login.ts |
| logout | packages/cli/src/commands/logout.ts |
| releases | packages/cli/src/commands/releases.ts |
| rollback | packages/cli/src/commands/rollback.ts |
| whoami | packages/cli/src/commands/whoami.ts |

## Cron tasks (src/cron/)

| Task | Source |
|---|---|
| artifact_grant_prune | src/cron/artifact_grant_prune.cr |
| assistant_turn_sweep | src/cron/assistant_turn_sweep.cr |
| assistant_usage_prune | src/cron/assistant_usage_prune.cr |
| event_lag_check | src/cron/event_lag_check.cr |
| lease | src/cron/lease.cr |
| list_cli | src/cron/list_cli.cr |
| mutation_compaction | src/cron/mutation_compaction.cr |
| parser | src/cron/parser.cr |
| pass | src/cron/pass.cr |
| scheduler | src/cron/scheduler.cr |
| secrets_prune | src/cron/secrets_prune.cr |
| sidecar_reconcile | src/cron/sidecar_reconcile.cr |
| tasks | src/cron/tasks.cr |
| tombstone_content_prune | src/cron/tombstone_content_prune.cr |
| webhook_reconcile | src/cron/webhook_reconcile.cr |

## Field types (src/doctype/field_types/)

| Type | Source |
|---|---|
| any_type | src/doctype/field_types/any_type.cr |
| array_type | src/doctype/field_types/array_type.cr |
| boolean_type | src/doctype/field_types/boolean_type.cr |
| color_type | src/doctype/field_types/color_type.cr |
| data_type | src/doctype/field_types/data_type.cr |
| date_type | src/doctype/field_types/date_type.cr |
| dateperiod_type | src/doctype/field_types/dateperiod_type.cr |
| datetime_type | src/doctype/field_types/datetime_type.cr |
| dictionary_type | src/doctype/field_types/dictionary_type.cr |
| duration_type | src/doctype/field_types/duration_type.cr |
| enum_type | src/doctype/field_types/enum_type.cr |
| file_type | src/doctype/field_types/file_type.cr |
| integer_type | src/doctype/field_types/integer_type.cr |
| long_text_type | src/doctype/field_types/long_text_type.cr |
| money_type | src/doctype/field_types/money_type.cr |
| object_type | src/doctype/field_types/object_type.cr |
| period_type | src/doctype/field_types/period_type.cr |
| phone_type | src/doctype/field_types/phone_type.cr |
| reference_type | src/doctype/field_types/reference_type.cr |
| secret_type | src/doctype/field_types/secret_type.cr |
| string_type | src/doctype/field_types/string_type.cr |
| url_type | src/doctype/field_types/url_type.cr |

## Agent tools (src/agent_tools/)

| Tool | Registered in |
|---|---|
| `aggregate_documents` | src/agent_tools/read.cr |
| `batch` | src/agent_tools/write.cr |
| `call_action` | src/agent_tools/write.cr |
| `create_document` | src/agent_tools/write.cr |
| `create_sidecar` | src/agent_tools/sidecar.cr |
| `delete_document` | src/agent_tools/write.cr |
| `get_artifact` | src/agent_tools/artifacts.cr |
| `get_backrefs` | src/agent_tools/history.cr |
| `get_document` | src/agent_tools/read.cr |
| `get_links` | src/agent_tools/history.cr |
| `get_schema` | src/agent_tools/discover.cr |
| `list_artifact_refs` | src/agent_tools/artifacts.cr |
| `list_doctypes` | src/agent_tools/discover.cr |
| `list_documents` | src/agent_tools/read.cr |
| `list_domains` | src/agent_tools/discover.cr |
| `list_mutations` | src/agent_tools/history.cr |
| `list_sidecars` | src/agent_tools/sidecar.cr |
| `ping` | src/agent_tools/registry.cr |
| `request_artifact_upload` | src/agent_tools/artifacts.cr |
| `resolve_refs` | src/agent_tools/read.cr |
| `search_documents` | src/agent_tools/read.cr |
| `update_document` | src/agent_tools/write.cr |
| `whoami` | src/agent_tools/discover.cr |

## System settings keys (src/system_settings/spec.cr)

| Key | Source |
|---|---|
| `artifact.grant_prune_days` | src/system_settings/spec.cr |
| `artifact.grant_ttl_media_seconds` | src/system_settings/spec.cr |
| `artifact.grant_ttl_seconds` | src/system_settings/spec.cr |
| `artifact.prune_after_days` | src/system_settings/spec.cr |
| `artifact.storage.type` | src/system_settings/spec.cr |
| `assistant.api_endpoint` | src/system_settings/spec.cr |
| `assistant.api_key` | src/system_settings/spec.cr |
| `assistant.auto_execute_tools` | src/system_settings/spec.cr |
| `assistant.max_history` | src/system_settings/spec.cr |
| `assistant.max_tokens` | src/system_settings/spec.cr |
| `assistant.model` | src/system_settings/spec.cr |
| `assistant.name` | src/system_settings/spec.cr |
| `assistant.system_prompt` | src/system_settings/spec.cr |
| `assistant.temperature` | src/system_settings/spec.cr |
| `iam.auth.mode` | src/system_settings/spec.cr |
| `iam.change_password_expiration` | src/system_settings/spec.cr |
| `iam.mfa.enforcement` | src/system_settings/spec.cr |
| `iam.mfa.type` | src/system_settings/spec.cr |
| `iam.oidc.provision_roles` | src/system_settings/spec.cr |
| `localization.default_language` | src/system_settings/spec.cr |
| `localization.default_timezone` | src/system_settings/spec.cr |
| `mail.adapter` | src/system_settings/spec.cr |
| `mail.from_address` | src/system_settings/spec.cr |
| `mail.from_name` | src/system_settings/spec.cr |
| `mail.smtp.host` | src/system_settings/spec.cr |
| `mail.smtp.password` | src/system_settings/spec.cr |
| `mail.smtp.port` | src/system_settings/spec.cr |
| `mail.smtp.use_tls` | src/system_settings/spec.cr |
| `mail.smtp.username` | src/system_settings/spec.cr |
| `mutations.retention_days` | src/system_settings/spec.cr |
| `tombstone.content_retention_days` | src/system_settings/spec.cr |

## Account settings keys (src/settings/keys.cr)

| Key | Source |
|---|---|
| `localization.default_language` | src/settings/keys.cr |
| `localization.default_timezone` | src/settings/keys.cr |

## Lua bindings (src/lua/sandbox.cr, string keys)

| Function | Source |
|---|---|
| `date.parts` | src/lua/sandbox.cr |

## Metric names (src/metrics.cr)

| Name | Source |
|---|---|
| `facet_consumer_consecutive_failures` | src/metrics.cr |
| `facet_consumer_restarts_total` | src/metrics.cr |
| `facet_cron_task_failures_total` | src/metrics.cr |
| `facet_cron_task_lease_skips_total` | src/metrics.cr |
| `facet_db_checkout_total` | src/metrics.cr |
| `facet_db_poisoned_discards_total` | src/metrics.cr |
| `facet_event_lag_max` | src/metrics.cr |
| `facet_event_loss_messages_dropped_total` | src/metrics.cr |
| `facet_event_loss_publish_events_dropped_total` | src/metrics.cr |
| `facet_event_loss_publish_flush_failures_total` | src/metrics.cr |
| `facet_events_published_total` | src/metrics.cr |
| `facet_fiber_loop_errors_total` | src/metrics.cr |
| `facet_fiber_restarts_total` | src/metrics.cr |
| `facet_http_requests_total` | src/metrics.cr |
| `facet_jobs_abandoned_total` | src/metrics.cr |
| `facet_jobs_claimed_total` | src/metrics.cr |
| `facet_jobs_enqueued_total` | src/metrics.cr |
| `facet_jobs_failed_total` | src/metrics.cr |
| `facet_jobs_succeeded_total` | src/metrics.cr |
| `facet_messages_processed_total` | src/metrics.cr |

## Frontend routes (frontend/src/routes/**/+page.svelte)

| Route | Source |
|---|---|
| `/+page.svelte` | frontend/src/routes/+page.svelte |
| `/Builder/[draftDomain]/[doctype]/[[tab]]` | frontend/src/routes/Builder/[draftDomain]/[doctype]/[[tab]]/+page.svelte |
| `/Builder/[draftDomain]/check` | frontend/src/routes/Builder/[draftDomain]/(editor)/check/+page.svelte |
| `/Builder/[draftDomain]/doctypes` | frontend/src/routes/Builder/[draftDomain]/(editor)/doctypes/+page.svelte |
| `/Builder/[draftDomain]/editors` | frontend/src/routes/Builder/[draftDomain]/(editor)/editors/+page.svelte |
| `/Builder/[draftDomain]/grants` | frontend/src/routes/Builder/[draftDomain]/(editor)/grants/+page.svelte |
| `/Builder/[draftDomain]/overview` | frontend/src/routes/Builder/[draftDomain]/(editor)/overview/+page.svelte |
| `/Builder/[draftDomain]/preview/[...path]` | frontend/src/routes/Builder/[draftDomain]/preview/[...path]/+page.svelte |
| `/Builder` | frontend/src/routes/Builder/+page.svelte |
| `/Configure/access/accounts` | frontend/src/routes/Configure/access/accounts/+page.svelte |
| `/Configure/access/assignments` | frontend/src/routes/Configure/access/assignments/+page.svelte |
| `/Configure/access/roles/[id]/details` | frontend/src/routes/Configure/access/roles/[id]/details/+page.svelte |
| `/Configure/access/roles/[id]/grants` | frontend/src/routes/Configure/access/roles/[id]/grants/+page.svelte |
| `/Configure/access/roles/[id]/members` | frontend/src/routes/Configure/access/roles/[id]/members/+page.svelte |
| `/Configure/access/roles/[id]` | frontend/src/routes/Configure/access/roles/[id]/+page.svelte |
| `/Configure/access/roles` | frontend/src/routes/Configure/access/roles/+page.svelte |
| `/Configure/access` | frontend/src/routes/Configure/access/+page.svelte |
| `/Configure/apps/[slug]/deploy` | frontend/src/routes/Configure/apps/[slug]/deploy/+page.svelte |
| `/Configure/apps/[slug]/grants` | frontend/src/routes/Configure/apps/[slug]/grants/+page.svelte |
| `/Configure/apps/[slug]/overview` | frontend/src/routes/Configure/apps/[slug]/overview/+page.svelte |
| `/Configure/apps/[slug]/settings` | frontend/src/routes/Configure/apps/[slug]/settings/+page.svelte |
| `/Configure/apps/[slug]` | frontend/src/routes/Configure/apps/[slug]/+page.svelte |
| `/Configure/apps/new/credentials` | frontend/src/routes/Configure/apps/new/credentials/+page.svelte |
| `/Configure/apps/new/permissions` | frontend/src/routes/Configure/apps/new/permissions/+page.svelte |
| `/Configure/apps/new/review` | frontend/src/routes/Configure/apps/new/review/+page.svelte |
| `/Configure/apps/new/setup` | frontend/src/routes/Configure/apps/new/setup/+page.svelte |
| `/Configure/apps/new` | frontend/src/routes/Configure/apps/new/+page.svelte |
| `/Configure/apps` | frontend/src/routes/Configure/apps/+page.svelte |
| `/Configure/audit` | frontend/src/routes/Configure/audit/+page.svelte |
| `/Configure/currencies` | frontend/src/routes/Configure/currencies/+page.svelte |
| `/Configure/domains/[slug]/doctypes/[dt]` | frontend/src/routes/Configure/domains/[slug]/doctypes/[dt]/+page.svelte |
| `/Configure/domains/[slug]/doctypes` | frontend/src/routes/Configure/domains/[slug]/(tabs)/doctypes/+page.svelte |
| `/Configure/domains/[slug]/editors` | frontend/src/routes/Configure/domains/[slug]/(tabs)/editors/+page.svelte |
| `/Configure/domains/[slug]/grants` | frontend/src/routes/Configure/domains/[slug]/(tabs)/grants/+page.svelte |
| `/Configure/domains/[slug]/overview` | frontend/src/routes/Configure/domains/[slug]/(tabs)/overview/+page.svelte |
| `/Configure/domains/[slug]` | frontend/src/routes/Configure/domains/[slug]/+page.svelte |
| `/Configure/domains` | frontend/src/routes/Configure/domains/+page.svelte |
| `/Configure/platform/artifacts` | frontend/src/routes/Configure/platform/artifacts/+page.svelte |
| `/Configure/platform/indexes` | frontend/src/routes/Configure/platform/indexes/+page.svelte |
| `/Configure/platform/maintenance` | frontend/src/routes/Configure/platform/maintenance/+page.svelte |
| `/Configure/platform/oidc` | frontend/src/routes/Configure/platform/oidc/+page.svelte |
| `/Configure/platform/settings` | frontend/src/routes/Configure/platform/settings/+page.svelte |
| `/Configure/platform` | frontend/src/routes/Configure/platform/+page.svelte |
| `/Configure` | frontend/src/routes/Configure/+page.svelte |
| `/Login` | frontend/src/routes/Login/+page.svelte |
| `/OAuthConsent` | frontend/src/routes/OAuthConsent/+page.svelte |
| `/ResetPassword` | frontend/src/routes/ResetPassword/+page.svelte |
| `/Settings/api-keys` | frontend/src/routes/Settings/api-keys/+page.svelte |
| `/Settings/webhooks` | frontend/src/routes/Settings/webhooks/+page.svelte |
| `/Settings` | frontend/src/routes/Settings/+page.svelte |
| `/[domain=notApi]/[doctype]/[id]/edit` | frontend/src/routes/[domain=notApi]/[doctype]/[id]/edit/+page.svelte |
| `/[domain=notApi]/[doctype]/[id]/history` | frontend/src/routes/[domain=notApi]/[doctype]/[id]/history/+page.svelte |
| `/[domain=notApi]/[doctype]/[id]` | frontend/src/routes/[domain=notApi]/[doctype]/[id]/+page.svelte |
| `/[domain=notApi]/[doctype]/new` | frontend/src/routes/[domain=notApi]/[doctype]/new/+page.svelte |
| `/[domain=notApi]/[doctype]` | frontend/src/routes/[domain=notApi]/[doctype]/+page.svelte |
| `/[domain=notApi]` | frontend/src/routes/[domain=notApi]/+page.svelte |

## UI label groups (frontend/messages/en.json)

| Group | Labels |
|---|---|
| `$schema` | 1 label |
| `admin_action_hint_aria` | 1 label |
| `admin_active_badge_title` | 1 label |
| `admin_active_badge` | 1 label |
| `admin_cascade_collapse` | 1 label |
| `admin_cascade_expand` | 1 label |
| `admin_cascade_title` | 1 label |
| `admin_collapse_all` | 1 label |
| `admin_collapse_button` | 1 label |
| `admin_collapse_domain_aria` | 1 label |
| `admin_collapse_subtree_title` | 1 label |
| `admin_confirm_delete_button` | 1 label |
| `admin_confirm_delete_message` | 1 label |
| `admin_confirm_delete_title` | 1 label |
| `admin_confirm_discard_delete` | 1 label |
| `admin_confirm_discard_leave` | 1 label |
| `admin_confirm_discard_message` | 1 label |
| `admin_confirm_discard_switch` | 1 label |
| `admin_confirm_discard_title` | 1 label |
| `admin_connectivity_budget_tokens` | 1 label |
| `admin_connectivity_budget_unlimited` | 1 label |
| `admin_connectivity_channel_off` | 1 label |
| `admin_connectivity_channel_on` | 1 label |
| `admin_connectivity_hint` | 1 label |
| `admin_create_role_button` | 1 label |
| `admin_credentials_title` | 1 label |
| `admin_custom_scopes_group` | 1 label |
| `admin_default_role_aria` | 1 label |
| `admin_default_tag` | 1 label |
| `admin_delete_disabled_title` | 1 label |
| `admin_delete_pick_title` | 1 label |
| `admin_delete_title` | 1 label |
| `admin_details_aria` | 1 label |
| `admin_details_link` | 1 label |
| `admin_discard_button` | 1 label |
| `admin_doctype_hint_aria` | 1 label |
| `admin_doctypes_count_title` | 1 label |
| `admin_domain_hint_aria` | 1 label |
| `admin_empty` | 1 label |
| `admin_expand_all` | 1 label |
| `admin_expand_button` | 1 label |
| `admin_expand_domain_aria` | 1 label |
| `admin_expand_subtree_title` | 1 label |
| `admin_generate_password` | 1 label |
| `admin_manage_members` | 1 label |
| `admin_member_plural` | 1 label |
| `admin_member_removing` | 1 label |
| `admin_member_singular` | 1 label |
| `admin_members_aria` | 1 label |
| `admin_new_role_desc_optional` | 1 label |
| `admin_new_role_desc_placeholder` | 1 label |
| `admin_new_role_helper` | 1 label |
| `admin_new_role_level_error` | 1 label |
| `admin_new_role_level_helper` | 1 label |
| `admin_new_role_level_label` | 1 label |
| `admin_new_role_level_placeholder` | 1 label |
| `admin_new_role_level_required` | 1 label |
| `admin_new_role_name_error` | 1 label |
| `admin_new_role_name_placeholder` | 1 label |
| `admin_new_role` | 1 label |
| `admin_no_doctypes` | 1 label |
| `admin_no_match` | 1 label |
| `admin_regenerate_password` | 1 label |
| `admin_resend_invite` | 1 label |
| `admin_reset_mfa_confirm_body` | 1 label |
| `admin_reset_mfa_confirm_title` | 1 label |
| `admin_reset_mfa` | 1 label |
| `admin_role_placeholder` | 1 label |
| `admin_scopes_count` | 1 label |
| `admin_search_aria` | 1 label |
| `admin_search_clear_aria` | 1 label |
| `admin_search_placeholder` | 1 label |
| `admin_send_invite` | 1 label |
| `admin_tags_empty` | 1 label |
| `admin_temp_pw_copy_aria` | 1 label |
| `admin_temp_pw_desc_email` | 1 label |
| `admin_temp_pw_desc` | 1 label |
| `admin_temp_pw_generated_title` | 1 label |
| `admin_temp_pw_regenerated_title` | 1 label |
| `admin_temp_pw_warning` | 1 label |
| `admin_tree_aria` | 1 label |
| `admin_wildcard_note` | 1 label |
| `apikeys_create_button` | 1 label |
| `apikeys_create_error` | 1 label |
| `apikeys_empty` | 1 label |
| `apikeys_expires_label` | 1 label |
| `apikeys_last_used_label` | 1 label |
| `apikeys_load_error` | 1 label |
| `apikeys_loading` | 1 label |
| `apikeys_manager_helper` | 1 label |
| `apikeys_manager_title` | 1 label |
| `apikeys_never_label` | 1 label |
| `apikeys_new_expires_error` | 1 label |
| `apikeys_new_expires_helper` | 1 label |
| `apikeys_new_helper` | 1 label |
| `apikeys_new_name_helper` | 1 label |
| `apikeys_new_name_placeholder` | 1 label |
| `apikeys_new_role_helper` | 1 label |
| `apikeys_new_role_placeholder` | 1 label |
| `apikeys_new_title` | 1 label |
| `apikeys_page_title` | 1 label |
| `apikeys_reveal_expiry` | 1 label |
| `apikeys_reveal_helper` | 1 label |
| `apikeys_reveal_title` | 1 label |
| `apikeys_revoke_aria` | 1 label |
| `apikeys_revoke_button` | 1 label |
| `apikeys_revoke_confirm_body` | 1 label |
| `apikeys_revoke_confirm_button` | 1 label |
| `apikeys_revoke_confirm_title` | 1 label |
| `apikeys_revoke_error` | 1 label |
| `apikeys_revoking_button` | 1 label |
| `apikeys_status_active` | 1 label |
| `apikeys_status_expired` | 1 label |
| `apikeys_status_revoked` | 1 label |
| `apikeys_subtitle` | 1 label |
| `apikeys_title` | 1 label |
| `apps_access_denied` | 1 label |
| `apps_acting_as_desc` | 1 label |
| `apps_acting_as` | 1 label |
| `apps_all_actions` | 1 label |
| `apps_all_doctypes` | 1 label |
| `apps_all_domains` | 1 label |
| `apps_app_disabled` | 1 label |
| `apps_app_label` | 1 label |
| `apps_authorize` | 1 label |
| `apps_blocked_title` | 1 label |
| `apps_body_app` | 1 label |
| `apps_body_request` | 1 label |
| `apps_checking` | 1 label |
| `apps_consent_sub` | 1 label |
| `apps_consent_title` | 1 label |
| `apps_error_sub` | 1 label |
| `apps_footer` | 1 label |
| `apps_grants_access_aria` | 1 label |
| `apps_grants_children_label` | 1 label |
| `apps_grants_core_required_label` | 1 label |
| `apps_grants_domains_aria` | 1 label |
| `apps_grants_empty_clear` | 1 label |
| `apps_grants_empty_domain` | 1 label |
| `apps_grants_empty_match` | 1 label |
| `apps_grants_empty` | 1 label |
| `apps_grants_filter_aria` | 1 label |
| `apps_grants_filter_placeholder` | 1 label |
| `apps_grants_level_full` | 1 label |
| `apps_grants_level_none` | 1 label |
| `apps_grants_level_read` | 1 label |
| `apps_grants_level_write` | 1 label |
| `apps_grants_named_label` | 1 label |
| `apps_grants_optional` | 1 label |
| `apps_grants_required` | 1 label |
| `apps_grants_sensitive_aria` | 1 label |
| `apps_grants_set_all_label` | 1 label |
| `apps_grants_summary_counts_pp` | 1 label |
| `apps_grants_summary_counts_ps` | 1 label |
| `apps_grants_summary_counts_sp` | 1 label |
| `apps_grants_summary_counts_ss` | 1 label |
| `apps_grants_summary_label` | 1 label |
| `apps_grants_summary_sensitive` | 1 label |
| `apps_grants_summary_tail` | 1 label |
| `apps_grants_tag_inherited` | 1 label |
| `apps_grants_tag_none_inherited` | 1 label |
| `apps_grants_tag_overridden` | 1 label |
| `apps_grants_title` | 1 label |
| `apps_grants_verb_delete` | 1 label |
| `apps_grants_verb_read` | 1 label |
| `apps_grants_verb_write` | 1 label |
| `apps_grants_wizard_helper` | 1 label |
| `apps_grants_wizard_title` | 1 label |
| `apps_invalid_request` | 1 label |
| `apps_loading_title` | 1 label |
| `apps_mcp_desc_role` | 1 label |
| `apps_mcp_desc` | 1 label |
| `apps_mcp_name` | 1 label |
| `apps_no_role_app` | 1 label |
| `apps_no_role_request` | 1 label |
| `apps_not_usable_body` | 1 label |
| `apps_not_usable_title` | 1 label |
| `apps_page_title` | 1 label |
| `apps_redirect_label` | 1 label |
| `apps_redirect_text` | 1 label |
| `apps_request_failed_status` | 1 label |
| `apps_request_failed` | 1 label |
| `apps_request_name` | 1 label |
| `apps_role_helper` | 1 label |
| `apps_role_legend` | 1 label |
| `apps_role_not_usable_body` | 1 label |
| `apps_try_again` | 1 label |
| `apps_unknown_client` | 1 label |
| `apps_verifying_sub` | 1 label |
| `assistant_agg_average` | 1 label |
| `assistant_agg_count` | 1 label |
| `assistant_agg_max` | 1 label |
| `assistant_agg_min` | 1 label |
| `assistant_agg_sum` | 1 label |
| `assistant_builder_empty_hint` | 1 label |
| `assistant_cancelled_note` | 1 label |
| `assistant_close_aria` | 1 label |
| `assistant_collapse_aria` | 1 label |
| `assistant_collapse` | 1 label |
| `assistant_conversation_create_failed` | 1 label |
| `assistant_conversation_excerpt` | 1 label |
| `assistant_conversation_fallback` | 1 label |
| `assistant_conversations_archive` | 1 label |
| `assistant_conversations_archived_empty` | 1 label |
| `assistant_conversations_empty` | 1 label |
| `assistant_conversations_end` | 1 label |
| `assistant_conversations_hide` | 1 label |
| `assistant_conversations_loading_more` | 1 label |
| `assistant_conversations_new` | 1 label |
| `assistant_conversations_rename_confirm` | 1 label |
| `assistant_conversations_rename_helper` | 1 label |
| `assistant_conversations_rename_label` | 1 label |
| `assistant_conversations_rename_title` | 1 label |
| `assistant_conversations_running` | 1 label |
| `assistant_conversations_show_archived` | 1 label |
| `assistant_conversations_show` | 1 label |
| `assistant_conversations_title` | 1 label |
| `assistant_conversations_unarchive` | 1 label |
| `assistant_copy_answer` | 1 label |
| `assistant_copy_thought` | 1 label |
| `assistant_dismiss` | 1 label |
| `assistant_doc_unavailable` | 1 label |
| `assistant_documents_error` | 1 label |
| `assistant_empty_hint` | 1 label |
| `assistant_error_line` | 1 label |
| `assistant_expand_aria` | 1 label |
| `assistant_expand` | 1 label |
| `assistant_input_placeholder` | 1 label |
| `assistant_input_queued` | 1 label |
| `assistant_input_thinking` | 1 label |
| `assistant_maximize_aria` | 1 label |
| `assistant_maximize` | 1 label |
| `assistant_mermaid_invalid` | 1 label |
| `assistant_mermaid_pending` | 1 label |
| `assistant_mermaid_rendering` | 1 label |
| `assistant_new_conversation` | 1 label |
| `assistant_not_configured` | 1 label |
| `assistant_preview_backdrop_aria` | 1 label |
| `assistant_preview_calendar` | 1 label |
| `assistant_preview_close_aria` | 1 label |
| `assistant_preview_collapse_aria` | 1 label |
| `assistant_preview_collapse` | 1 label |
| `assistant_preview_document` | 1 label |
| `assistant_preview_expand_aria` | 1 label |
| `assistant_preview_expand` | 1 label |
| `assistant_preview_failed` | 1 label |
| `assistant_preview_invalid` | 1 label |
| `assistant_preview_needs_discriminator` | 1 label |
| `assistant_preview_table` | 1 label |
| `assistant_preview_title` | 1 label |
| `assistant_rail_resize_aria` | 1 label |
| `assistant_resize_aria` | 1 label |
| `assistant_resize_height_aria` | 1 label |
| `assistant_resize_width_aria` | 1 label |
| `assistant_restore_aria` | 1 label |
| `assistant_restore` | 1 label |
| `assistant_send_aria` | 1 label |
| `assistant_send_title` | 1 label |
| `assistant_stats_aggregate` | 1 label |
| `assistant_stats_docs_plural` | 1 label |
| `assistant_stats_docs_singular` | 1 label |
| `assistant_stats_documents` | 1 label |
| `assistant_stats_matching` | 1 label |
| `assistant_stats_none` | 1 label |
| `assistant_still_generating` | 1 label |
| `assistant_stop_aria` | 1 label |
| `assistant_stop_title` | 1 label |
| `assistant_tag_schema` | 1 label |
| `assistant_tag_workspace` | 1 label |
| `assistant_thinking` | 1 label |
| `assistant_thought_label` | 1 label |
| `assistant_thread_empty` | 1 label |
| `assistant_title` | 1 label |
| `assistant_tool_error` | 1 label |
| `assistant_tool_ok` | 1 label |
| `assistant_tool_running` | 1 label |
| `assistant_turn_failed` | 1 label |
| `assistant_turns_load_failed` | 1 label |
| `assistant_usage_limit_reached` | 1 label |
| `assistant_usage_meter_estimated` | 1 label |
| `assistant_usage_meter` | 1 label |
| `assistant_window_controls_aria` | 1 label |
| `assistant_workspace_placeholder` | 1 label |
| `audit_action_column` | 1 label |
| `audit_action_snapshot` | 1 label |
| `audit_actor_column` | 1 label |
| `audit_block_newest` | 1 label |
| `audit_block_permission` | 1 label |
| `audit_block_snapshot` | 1 label |
| `audit_cause_on_label` | 1 label |
| `audit_change_patch_applied` | 1 label |
| `audit_change_redacted_helper` | 1 label |
| `audit_change_redacted` | 1 label |
| `audit_change_removed` | 1 label |
| `audit_channel_column` | 1 label |
| `audit_cluster_button_title` | 1 label |
| `audit_cluster_button` | 1 label |
| `audit_cluster_loading` | 1 label |
| `audit_cluster_title_plural` | 1 label |
| `audit_cluster_title_singular` | 1 label |
| `audit_confirm_cluster_button` | 1 label |
| `audit_confirm_cluster_desc_plural` | 1 label |
| `audit_confirm_cluster_desc_singular` | 1 label |
| `audit_confirm_cluster_title` | 1 label |
| `audit_confirm_delete_desc` | 1 label |
| `audit_confirm_rollback_button` | 1 label |
| `audit_confirm_single_title` | 1 label |
| `audit_confirm_update_desc` | 1 label |
| `audit_detail_actor_label` | 1 label |
| `audit_detail_key_sub` | 1 label |
| `audit_detail_missing_mutation` | 1 label |
| `audit_detail_target_label` | 1 label |
| `audit_detail_version_title` | 1 label |
| `audit_document_column` | 1 label |
| `audit_filter_actor_label` | 1 label |
| `audit_filter_all_option` | 1 label |
| `audit_filter_app_label` | 1 label |
| `audit_filter_channel_label` | 1 label |
| `audit_filter_doctype_label` | 1 label |
| `audit_filter_domain_label` | 1 label |
| `audit_filter_kind_label` | 1 label |
| `audit_filter_trace_label` | 1 label |
| `audit_filters_aria` | 1 label |
| `audit_forbidden` | 1 label |
| `audit_history_aria` | 1 label |
| `audit_history_count_plural` | 1 label |
| `audit_history_count_singular` | 1 label |
| `audit_history_empty` | 1 label |
| `audit_history_load_error` | 1 label |
| `audit_history_loading` | 1 label |
| `audit_history_refresh_aria` | 1 label |
| `audit_history_title` | 1 label |
| `audit_load_error` | 1 label |
| `audit_more_records` | 1 label |
| `audit_no_changes_recorded` | 1 label |
| `audit_page_count` | 1 label |
| `audit_page_header` | 1 label |
| `audit_page_subtitle` | 1 label |
| `audit_page_title` | 1 label |
| `audit_pager_next` | 1 label |
| `audit_pager_previous` | 1 label |
| `audit_remaining_count_plural` | 1 label |
| `audit_remaining_count_singular` | 1 label |
| `audit_restore_button` | 1 label |
| `audit_restore_hint` | 1 label |
| `audit_restore_title` | 1 label |
| `audit_revert_button` | 1 label |
| `audit_rollback_button` | 1 label |
| `audit_rollback_error` | 1 label |
| `audit_select_mutation_hint` | 1 label |
| `audit_summary_created` | 1 label |
| `audit_summary_deleted` | 1 label |
| `audit_summary_empty_doc` | 1 label |
| `audit_summary_fields_plural` | 1 label |
| `audit_summary_fields_singular` | 1 label |
| `audit_summary_no_changes` | 1 label |
| `audit_summary_patch_plural` | 1 label |
| `audit_summary_patch_singular` | 1 label |
| `audit_summary_redacted` | 1 label |
| `audit_summary_restored` | 1 label |
| `audit_summary_set` | 1 label |
| `audit_summary_snapshot` | 1 label |
| `audit_summary_unset` | 1 label |
| `audit_table_empty` | 1 label |
| `audit_via_sep` | 1 label |
| `audit_via` | 1 label |
| `audit_when_column` | 1 label |
| `auth_2fa_backup_button` | 1 label |
| `auth_2fa_sub` | 1 label |
| `auth_2fa_title` | 1 label |
| `auth_2fa_verify` | 1 label |
| `auth_back_signin` | 1 label |
| `auth_backup_back` | 1 label |
| `auth_backup_label` | 1 label |
| `auth_backup_placeholder` | 1 label |
| `auth_backup_sub` | 1 label |
| `auth_backup_title` | 1 label |
| `auth_challenge_expired` | 1 label |
| `auth_change_expired` | 1 label |
| `auth_change_incomplete` | 1 label |
| `auth_confirm_length_error` | 1 label |
| `auth_confirm_password_label` | 1 label |
| `auth_confirm_password_placeholder` | 1 label |
| `auth_confirm_set_button` | 1 label |
| `auth_confirm_sub` | 1 label |
| `auth_confirm_title` | 1 label |
| `auth_current_password_label` | 1 label |
| `auth_enroll_expired` | 1 label |
| `auth_forced_length_error` | 1 label |
| `auth_forced_save_button` | 1 label |
| `auth_forced_sub` | 1 label |
| `auth_forced_title` | 1 label |
| `auth_login_attempts_remaining.*` | 2 labels |
| `auth_login_button` | 1 label |
| `auth_login_email_label` | 1 label |
| `auth_login_email_placeholder` | 1 label |
| `auth_login_failed` | 1 label |
| `auth_login_forgot` | 1 label |
| `auth_login_identifier_label` | 1 label |
| `auth_login_identifier_placeholder` | 1 label |
| `auth_login_or` | 1 label |
| `auth_login_page_title` | 1 label |
| `auth_login_password_label` | 1 label |
| `auth_login_sso_only` | 1 label |
| `auth_login_sso_unavailable` | 1 label |
| `auth_login_sso` | 1 label |
| `auth_login_unrecognized` | 1 label |
| `auth_mfa_setup_failed` | 1 label |
| `auth_mfa_setup_unexpected` | 1 label |
| `auth_new_password_label` | 1 label |
| `auth_new_password_placeholder` | 1 label |
| `auth_no_role_page_title` | 1 label |
| `auth_no_role_refresh` | 1 label |
| `auth_no_role_sub` | 1 label |
| `auth_no_role_title` | 1 label |
| `auth_oidc_denied` | 1 label |
| `auth_otp_aria` | 1 label |
| `auth_otp_digit_aria` | 1 label |
| `auth_password_change_failed` | 1 label |
| `auth_password_mismatch` | 1 label |
| `auth_password_updated` | 1 label |
| `auth_reset_check_inbox` | 1 label |
| `auth_reset_failed` | 1 label |
| `auth_reset_fallback_identifier` | 1 label |
| `auth_reset_link_invalid` | 1 label |
| `auth_reset_link_validity` | 1 label |
| `auth_reset_page_title` | 1 label |
| `auth_reset_request_failed` | 1 label |
| `auth_reset_send_button` | 1 label |
| `auth_reset_sub` | 1 label |
| `auth_reset_success_sub` | 1 label |
| `auth_reset_title` | 1 label |
| `auth_session_lookup_failed` | 1 label |
| `auth_totp_backup_aria` | 1 label |
| `auth_totp_backup_empty` | 1 label |
| `auth_totp_backup_sub` | 1 label |
| `auth_totp_backup_warning` | 1 label |
| `auth_totp_copy_label` | 1 label |
| `auth_totp_digits` | 1 label |
| `auth_totp_done_button` | 1 label |
| `auth_totp_enabled_title` | 1 label |
| `auth_totp_enter_code` | 1 label |
| `auth_totp_qr_aria` | 1 label |
| `auth_totp_scan_sub` | 1 label |
| `auth_totp_secret_label` | 1 label |
| `auth_totp_setup_title` | 1 label |
| `auth_totp_skip_now` | 1 label |
| `auth_totp_verify_button` | 1 label |
| `auth_verify_failed` | 1 label |
| `auth_verify_unexpected` | 1 label |
| `builder_add_doctype` | 1 label |
| `builder_all_domains` | 1 label |
| `builder_back_domains_aria` | 1 label |
| `builder_badge_draft` | 1 label |
| `builder_create_domain_forbidden` | 1 label |
| `builder_discard_button` | 1 label |
| `builder_discard_title` | 1 label |
| `builder_doctypes_empty_add` | 1 label |
| `builder_doctypes_empty` | 1 label |
| `builder_draft_failed_status` | 1 label |
| `builder_draft_network_error` | 1 label |
| `builder_draft_pill_title` | 1 label |
| `builder_edit_domain_forbidden` | 1 label |
| `builder_edit_existing_hint` | 1 label |
| `builder_edit_existing` | 1 label |
| `builder_exit_builder` | 1 label |
| `builder_exit_config_hint` | 1 label |
| `builder_exit_label` | 1 label |
| `builder_exit_mode_hint` | 1 label |
| `builder_landing_empty_mid` | 1 label |
| `builder_landing_empty_pre` | 1 label |
| `builder_landing_hint` | 1 label |
| `builder_live_chip` | 1 label |
| `builder_mode_title` | 1 label |
| `builder_named_page_title` | 1 label |
| `builder_new_domain_hint` | 1 label |
| `builder_no_active_draft` | 1 label |
| `builder_page_title` | 1 label |
| `builder_preview_banner` | 1 label |
| `builder_preview_exit` | 1 label |
| `builder_preview_hint` | 1 label |
| `builder_preview_starting` | 1 label |
| `builder_publish_button` | 1 label |
| `builder_publish_title` | 1 label |
| `builder_publish_warnings_title` | 1 label |
| `builder_status_editing` | 1 label |
| `builder_status_live` | 1 label |
| `builder_status_no_draft` | 1 label |
| `builder_subtitle` | 1 label |
| `builder_tab_build` | 1 label |
| `builder_tab_check` | 1 label |
| `builder_tab_grants` | 1 label |
| `builder_tab_overview` | 1 label |
| `builder_tab_preview` | 1 label |
| `builder_title` | 1 label |
| `calendar_all_day` | 1 label |
| `calendar_day_items_aria` | 1 label |
| `calendar_discriminator_invalid` | 1 label |
| `calendar_items_count` | 1 label |
| `calendar_jump_to_date` | 1 label |
| `calendar_load_failed` | 1 label |
| `calendar_month` | 1 label |
| `calendar_next_year` | 1 label |
| `calendar_next` | 1 label |
| `calendar_previous_year` | 1 label |
| `calendar_previous` | 1 label |
| `calendar_today` | 1 label |
| `calendar_week_docs_aria` | 1 label |
| `calendar_week` | 1 label |
| `common_add` | 1 label |
| `common_administrator` | 1 label |
| `common_back_to_dashboard` | 1 label |
| `common_back` | 1 label |
| `common_cancel` | 1 label |
| `common_check_ready_title` | 1 label |
| `common_clear` | 1 label |
| `common_close` | 1 label |
| `common_confidence_aria` | 1 label |
| `common_confirm` | 1 label |
| `common_copied` | 1 label |
| `common_copy_clipboard_aria` | 1 label |
| `common_copy` | 1 label |
| `common_create_failed` | 1 label |
| `common_create` | 1 label |
| `common_created` | 1 label |
| `common_creating` | 1 label |
| `common_delete` | 1 label |
| `common_deleted` | 1 label |
| `common_deleting` | 1 label |
| `common_description` | 1 label |
| `common_doctypes_count` | 1 label |
| `common_done` | 1 label |
| `common_duration_aria` | 1 label |
| `common_duration_days` | 1 label |
| `common_duration_hours` | 1 label |
| `common_duration_minutes_short` | 1 label |
| `common_duration_minutes` | 1 label |
| `common_duration_seconds_short` | 1 label |
| `common_duration_seconds` | 1 label |
| `common_edit` | 1 label |
| `common_editor_collapse_aria` | 1 label |
| `common_editor_collapse` | 1 label |
| `common_editor_expand_aria` | 1 label |
| `common_editor_expand` | 1 label |
| `common_editor_expanded_aria` | 1 label |
| `common_error` | 1 label |
| `common_issues_check_title` | 1 label |
| `common_loading` | 1 label |
| `common_marker_set_badge` | 1 label |
| `common_name` | 1 label |
| `common_none` | 1 label |
| `common_options_empty` | 1 label |
| `common_remove` | 1 label |
| `common_retry` | 1 label |
| `common_role` | 1 label |
| `common_save_failed` | 1 label |
| `common_save` | 1 label |
| `common_saved` | 1 label |
| `common_saving` | 1 label |
| `common_secret_hint` | 1 label |
| `common_time_ago` | 1 label |
| `common_time_in` | 1 label |
| `common_time_just_now` | 1 label |
| `common_time_now` | 1 label |
| `common_time_yesterday_short` | 1 label |
| `common_type` | 1 label |
| `common_updated` | 1 label |
| `common_upload_failed` | 1 label |
| `common_uploading` | 1 label |
| `common_validity_day` | 1 label |
| `common_validity_days` | 1 label |
| `common_validity_hour` | 1 label |
| `common_validity_hours` | 1 label |
| `common_validity_minute` | 1 label |
| `common_validity_minutes` | 1 label |
| `common_validity_second` | 1 label |
| `common_validity_seconds` | 1 label |
| `configure_access_page_title` | 1 label |
| `configure_accounts_new_button` | 1 label |
| `configure_accounts_page_title` | 1 label |
| `configure_accounts_subtitle` | 1 label |
| `configure_accounts_title` | 1 label |
| `configure_apps_activate_title` | 1 label |
| `configure_apps_activate_toggle` | 1 label |
| `configure_apps_activate` | 1 label |
| `configure_apps_address_prefix` | 1 label |
| `configure_apps_allowed_origins_label` | 1 label |
| `configure_apps_apikey_title` | 1 label |
| `configure_apps_assistant_enable_label` | 1 label |
| `configure_apps_assistant_helper` | 1 label |
| `configure_apps_assistant_prompt_helper` | 1 label |
| `configure_apps_assistant_prompt_label` | 1 label |
| `configure_apps_assistant_prompt_placeholder` | 1 label |
| `configure_apps_assistant_title` | 1 label |
| `configure_apps_build_folder_sub` | 1 label |
| `configure_apps_build_folder` | 1 label |
| `configure_apps_cli_guide` | 1 label |
| `configure_apps_cli_note` | 1 label |
| `configure_apps_client_confidential` | 1 label |
| `configure_apps_client_helper` | 1 label |
| `configure_apps_client_id_helper` | 1 label |
| `configure_apps_client_id_label` | 1 label |
| `configure_apps_client_public` | 1 label |
| `configure_apps_client_type_label` | 1 label |
| `configure_apps_compatible_roles_title` | 1 label |
| `configure_apps_complete` | 1 label |
| `configure_apps_consent_empty` | 1 label |
| `configure_apps_consent_footer` | 1 label |
| `configure_apps_consent_intro` | 1 label |
| `configure_apps_consent_optional` | 1 label |
| `configure_apps_consent_sensitive` | 1 label |
| `configure_apps_consent_tier` | 1 label |
| `configure_apps_continue` | 1 label |
| `configure_apps_copy_client_id_aria` | 1 label |
| `configure_apps_copy_curl_aria` | 1 label |
| `configure_apps_copy_discovery_aria` | 1 label |
| `configure_apps_copy_signin_aria` | 1 label |
| `configure_apps_copy_snippet_aria` | 1 label |
| `configure_apps_credentials_page_title` | 1 label |
| `configure_apps_delete_button` | 1 label |
| `configure_apps_delete_confirm` | 1 label |
| `configure_apps_delete_label` | 1 label |
| `configure_apps_deploy_activate` | 1 label |
| `configure_apps_deploy_button` | 1 label |
| `configure_apps_deploy_note` | 1 label |
| `configure_apps_deploy_page_title` | 1 label |
| `configure_apps_deploy_short` | 1 label |
| `configure_apps_deployment_title` | 1 label |
| `configure_apps_desc_muted` | 1 label |
| `configure_apps_desc_placeholder` | 1 label |
| `configure_apps_detail_page_title` | 1 label |
| `configure_apps_disable_title` | 1 label |
| `configure_apps_disable` | 1 label |
| `configure_apps_discard_confirm` | 1 label |
| `configure_apps_discard_title` | 1 label |
| `configure_apps_discovery_label` | 1 label |
| `configure_apps_draft_banner` | 1 label |
| `configure_apps_draft_hint` | 1 label |
| `configure_apps_draft_missing_error` | 1 label |
| `configure_apps_empty_sub` | 1 label |
| `configure_apps_empty_title` | 1 label |
| `configure_apps_file_singular` | 1 label |
| `configure_apps_files_count` | 1 label |
| `configure_apps_first_call_label` | 1 label |
| `configure_apps_generate_key` | 1 label |
| `configure_apps_generating` | 1 label |
| `configure_apps_goto_app` | 1 label |
| `configure_apps_grants_count` | 1 label |
| `configure_apps_grants_page_title` | 1 label |
| `configure_apps_headless_helper` | 1 label |
| `configure_apps_headless_title` | 1 label |
| `configure_apps_history_title` | 1 label |
| `configure_apps_host_helper_no_asset` | 1 label |
| `configure_apps_host_helper` | 1 label |
| `configure_apps_host_label` | 1 label |
| `configure_apps_host_placeholder` | 1 label |
| `configure_apps_includes_sensitive` | 1 label |
| `configure_apps_issue_body` | 1 label |
| `configure_apps_keep_draft` | 1 label |
| `configure_apps_key_label` | 1 label |
| `configure_apps_key_needs_role` | 1 label |
| `configure_apps_lifecycle_title` | 1 label |
| `configure_apps_live_backend_sub` | 1 label |
| `configure_apps_live_public_sub` | 1 label |
| `configure_apps_live_title` | 1 label |
| `configure_apps_logo_missing_detail` | 1 label |
| `configure_apps_logo_missing` | 1 label |
| `configure_apps_loose_files_sub` | 1 label |
| `configure_apps_loose_files` | 1 label |
| `configure_apps_name_placeholder` | 1 label |
| `configure_apps_new_button` | 1 label |
| `configure_apps_no_asset_label` | 1 label |
| `configure_apps_no_deployment` | 1 label |
| `configure_apps_no_draft_error` | 1 label |
| `configure_apps_no_key` | 1 label |
| `configure_apps_no_launcher_label` | 1 label |
| `configure_apps_no_secret_body` | 1 label |
| `configure_apps_no_secret_title` | 1 label |
| `configure_apps_note_label` | 1 label |
| `configure_apps_open` | 1 label |
| `configure_apps_optional_tier` | 1 label |
| `configure_apps_origins_count` | 1 label |
| `configure_apps_origins_helper` | 1 label |
| `configure_apps_origins_title` | 1 label |
| `configure_apps_origins_wizard_helper` | 1 label |
| `configure_apps_overview_page_title` | 1 label |
| `configure_apps_owned_by` | 1 label |
| `configure_apps_owner_helper` | 1 label |
| `configure_apps_owner_label` | 1 label |
| `configure_apps_owner_placeholder` | 1 label |
| `configure_apps_page_title` | 1 label |
| `configure_apps_permissions_page_title` | 1 label |
| `configure_apps_pick_service_role` | 1 label |
| `configure_apps_preset_backend_desc` | 1 label |
| `configure_apps_preset_backend_name` | 1 label |
| `configure_apps_preset_backend_tag` | 1 label |
| `configure_apps_preset_web_desc` | 1 label |
| `configure_apps_preset_web_name` | 1 label |
| `configure_apps_preset_web_tag` | 1 label |
| `configure_apps_readonly_title` | 1 label |
| `configure_apps_redirect_helper` | 1 label |
| `configure_apps_redirect_ok` | 1 label |
| `configure_apps_redirect_uris_label` | 1 label |
| `configure_apps_redirect_warn` | 1 label |
| `configure_apps_redirect_wizard_helper` | 1 label |
| `configure_apps_reenable_title` | 1 label |
| `configure_apps_reenable` | 1 label |
| `configure_apps_regenerate_confirm` | 1 label |
| `configure_apps_regenerate` | 1 label |
| `configure_apps_registry_unreachable` | 1 label |
| `configure_apps_required_tier` | 1 label |
| `configure_apps_resume_link` | 1 label |
| `configure_apps_rev_title` | 1 label |
| `configure_apps_review_page_title` | 1 label |
| `configure_apps_review_sub` | 1 label |
| `configure_apps_review_title` | 1 label |
| `configure_apps_revoke_confirm` | 1 label |
| `configure_apps_role_ids_helper` | 1 label |
| `configure_apps_role_ids_label` | 1 label |
| `configure_apps_role_no_api_channel` | 1 label |
| `configure_apps_row_draft_grants` | 1 label |
| `configure_apps_row_grants` | 1 label |
| `configure_apps_save_grants` | 1 label |
| `configure_apps_served_at_label` | 1 label |
| `configure_apps_service_account_label` | 1 label |
| `configure_apps_service_identity_title` | 1 label |
| `configure_apps_service_role_helper` | 1 label |
| `configure_apps_service_role_label` | 1 label |
| `configure_apps_service_role_placeholder` | 1 label |
| `configure_apps_serving_title` | 1 label |
| `configure_apps_settings_page_title` | 1 label |
| `configure_apps_setup_page_title` | 1 label |
| `configure_apps_signin_label` | 1 label |
| `configure_apps_slug_helper` | 1 label |
| `configure_apps_slug_label` | 1 label |
| `configure_apps_slug_not_found` | 1 label |
| `configure_apps_slug_permanent` | 1 label |
| `configure_apps_slug_placeholder` | 1 label |
| `configure_apps_slug_required` | 1 label |
| `configure_apps_slug_taken` | 1 label |
| `configure_apps_snippet_label` | 1 label |
| `configure_apps_spa_toggle` | 1 label |
| `configure_apps_stored_button` | 1 label |
| `configure_apps_subtitle` | 1 label |
| `configure_apps_test_signin_note` | 1 label |
| `configure_apps_title` | 1 label |
| `configure_apps_uploading` | 1 label |
| `configure_apps_uris_count` | 1 label |
| `configure_apps_wizard_aria` | 1 label |
| `configure_apps_wizard_credentials` | 1 label |
| `configure_apps_wizard_permissions` | 1 label |
| `configure_apps_wizard_review` | 1 label |
| `configure_apps_wizard_setup` | 1 label |
| `configure_assignments_account_missing` | 1 label |
| `configure_assignments_account_placeholder` | 1 label |
| `configure_assignments_add_account_placeholder` | 1 label |
| `configure_assignments_add_role_placeholder` | 1 label |
| `configure_assignments_add_to_role` | 1 label |
| `configure_assignments_assign_role` | 1 label |
| `configure_assignments_by_account` | 1 label |
| `configure_assignments_by_role` | 1 label |
| `configure_assignments_default_role_aria` | 1 label |
| `configure_assignments_members_empty` | 1 label |
| `configure_assignments_members_loading` | 1 label |
| `configure_assignments_members_title` | 1 label |
| `configure_assignments_mode_aria` | 1 label |
| `configure_assignments_page_title` | 1 label |
| `configure_assignments_pick_account_hint` | 1 label |
| `configure_assignments_pick_role_hint` | 1 label |
| `configure_assignments_role_placeholder` | 1 label |
| `configure_assignments_roles_empty` | 1 label |
| `configure_assignments_roles_loading` | 1 label |
| `configure_assignments_roles_title` | 1 label |
| `configure_assignments_subtitle` | 1 label |
| `configure_assignments_title` | 1 label |
| `configure_color_label` | 1 label |
| `configure_confirm_placeholder` | 1 label |
| `configure_currencies_nav` | 1 label |
| `configure_currencies_new_button` | 1 label |
| `configure_currencies_page_title` | 1 label |
| `configure_currencies_subtitle` | 1 label |
| `configure_currencies_title` | 1 label |
| `configure_danger_zone_title` | 1 label |
| `configure_doctypes_access_opt` | 1 label |
| `configure_doctypes_access_title` | 1 label |
| `configure_doctypes_add_action_button` | 1 label |
| `configure_doctypes_add_arg_button` | 1 label |
| `configure_doctypes_add_child_button` | 1 label |
| `configure_doctypes_add_field_button` | 1 label |
| `configure_doctypes_add_subfield_button` | 1 label |
| `configure_doctypes_aggregate_root` | 1 label |
| `configure_doctypes_args_empty` | 1 label |
| `configure_doctypes_arguments_label` | 1 label |
| `configure_doctypes_array_constraints_title` | 1 label |
| `configure_doctypes_array_items_title` | 1 label |
| `configure_doctypes_array_note` | 1 label |
| `configure_doctypes_badge_collection` | 1 label |
| `configure_doctypes_badge_defined_aria` | 1 label |
| `configure_doctypes_badge_defined` | 1 label |
| `configure_doctypes_badge_fallback_aria` | 1 label |
| `configure_doctypes_badge_fallback` | 1 label |
| `configure_doctypes_badge_single` | 1 label |
| `configure_doctypes_cascade_note` | 1 label |
| `configure_doctypes_child_collection_label` | 1 label |
| `configure_doctypes_child_doctype_label` | 1 label |
| `configure_doctypes_child_doctype_placeholder` | 1 label |
| `configure_doctypes_compute_fn_label` | 1 label |
| `configure_doctypes_compute_note` | 1 label |
| `configure_doctypes_computed_title` | 1 label |
| `configure_doctypes_create_draft_button` | 1 label |
| `configure_doctypes_creating_draft_button` | 1 label |
| `configure_doctypes_currency_from_label` | 1 label |
| `configure_doctypes_danger_helper` | 1 label |
| `configure_doctypes_default_label` | 1 label |
| `configure_doctypes_default_title` | 1 label |
| `configure_doctypes_default_value_label` | 1 label |
| `configure_doctypes_delete_action_aria` | 1 label |
| `configure_doctypes_delete_arg_aria` | 1 label |
| `configure_doctypes_delete_button` | 1 label |
| `configure_doctypes_delete_child_aria` | 1 label |
| `configure_doctypes_delete_field_aria` | 1 label |
| `configure_doctypes_display_name_helper` | 1 label |
| `configure_doctypes_display_name_label` | 1 label |
| `configure_doctypes_domain_label` | 1 label |
| `configure_doctypes_enum_default_label` | 1 label |
| `configure_doctypes_enum_title` | 1 label |
| `configure_doctypes_exported_functions` | 1 label |
| `configure_doctypes_field_editor_empty` | 1 label |
| `configure_doctypes_filter_capabilities_title` | 1 label |
| `configure_doctypes_general_title` | 1 label |
| `configure_doctypes_icon_helper` | 1 label |
| `configure_doctypes_icon_label` | 1 label |
| `configure_doctypes_icon_placeholder` | 1 label |
| `configure_doctypes_inline_preview` | 1 label |
| `configure_doctypes_item_shape_label` | 1 label |
| `configure_doctypes_item_shape_opt` | 1 label |
| `configure_doctypes_item_type_label` | 1 label |
| `configure_doctypes_key_duplicate_error` | 1 label |
| `configure_doctypes_key_helper` | 1 label |
| `configure_doctypes_key_label` | 1 label |
| `configure_doctypes_legend_card` | 1 label |
| `configure_doctypes_legend_form` | 1 label |
| `configure_doctypes_legend_inline` | 1 label |
| `configure_doctypes_legend_quickview` | 1 label |
| `configure_doctypes_legend_view` | 1 label |
| `configure_doctypes_loading` | 1 label |
| `configure_doctypes_lua_helper` | 1 label |
| `configure_doctypes_max_items_label` | 1 label |
| `configure_doctypes_max_label` | 1 label |
| `configure_doctypes_migration_add` | 1 label |
| `configure_doctypes_migration_delete_aria` | 1 label |
| `configure_doctypes_migration_function_label` | 1 label |
| `configure_doctypes_migration_not_exported` | 1 label |
| `configure_doctypes_migration_version_label` | 1 label |
| `configure_doctypes_migrations_helper` | 1 label |
| `configure_doctypes_migrations_title` | 1 label |
| `configure_doctypes_min_items_label` | 1 label |
| `configure_doctypes_min_label` | 1 label |
| `configure_doctypes_mode_helper` | 1 label |
| `configure_doctypes_mode_label` | 1 label |
| `configure_doctypes_mode_reveal` | 1 label |
| `configure_doctypes_mode_token` | 1 label |
| `configure_doctypes_mode_verify` | 1 label |
| `configure_doctypes_money_title` | 1 label |
| `configure_doctypes_not_filterable_note` | 1 label |
| `configure_doctypes_number_title` | 1 label |
| `configure_doctypes_object_note` | 1 label |
| `configure_doctypes_object_title` | 1 label |
| `configure_doctypes_on_delete_label` | 1 label |
| `configure_doctypes_open_records` | 1 label |
| `configure_doctypes_published_note` | 1 label |
| `configure_doctypes_query_indexing_title` | 1 label |
| `configure_doctypes_quickview_preview_aria` | 1 label |
| `configure_doctypes_recompute_when_label` | 1 label |
| `configure_doctypes_reference_note` | 1 label |
| `configure_doctypes_reference_title` | 1 label |
| `configure_doctypes_remove_sub_aria` | 1 label |
| `configure_doctypes_required_label` | 1 label |
| `configure_doctypes_schema_label` | 1 label |
| `configure_doctypes_schema_version` | 1 label |
| `configure_doctypes_search_helper` | 1 label |
| `configure_doctypes_search_label` | 1 label |
| `configure_doctypes_secret_title` | 1 label |
| `configure_doctypes_stored_as_label` | 1 label |
| `configure_doctypes_stored_decimal_label` | 1 label |
| `configure_doctypes_stored_minor_label` | 1 label |
| `configure_doctypes_subfield_placeholder` | 1 label |
| `configure_doctypes_symbols_empty` | 1 label |
| `configure_doctypes_tab_actions` | 1 label |
| `configure_doctypes_tab_children` | 1 label |
| `configure_doctypes_tab_fields` | 1 label |
| `configure_doctypes_tab_general` | 1 label |
| `configure_doctypes_tab_logic` | 1 label |
| `configure_doctypes_tab_settings` | 1 label |
| `configure_doctypes_tab_views` | 1 label |
| `configure_doctypes_tags_chip_add_title` | 1 label |
| `configure_doctypes_tags_chip_remove_title` | 1 label |
| `configure_doctypes_tags_helper` | 1 label |
| `configure_doctypes_tags_label` | 1 label |
| `configure_doctypes_tags_placeholder` | 1 label |
| `configure_doctypes_target_doctype_label` | 1 label |
| `configure_doctypes_templates_reproject_hint` | 1 label |
| `configure_doctypes_templates_title` | 1 label |
| `configure_doctypes_title_label` | 1 label |
| `configure_doctypes_unique_helper` | 1 label |
| `configure_doctypes_unique_items_label` | 1 label |
| `configure_doctypes_unique_label` | 1 label |
| `configure_doctypes_value_add_placeholder` | 1 label |
| `configure_doctypes_view_kinds_aria` | 1 label |
| `configure_doctypes_views_display_button` | 1 label |
| `configure_doctypes_views_edit_button` | 1 label |
| `configure_doctypes_views_empty_hint_readonly` | 1 label |
| `configure_doctypes_views_empty_hint` | 1 label |
| `configure_doctypes_views_invalid_json` | 1 label |
| `configure_doctypes_views_json_label` | 1 label |
| `configure_doctypes_views_mode_aria` | 1 label |
| `configure_doctypes_views_save_error` | 1 label |
| `configure_doctypes_views_template_not_object` | 1 label |
| `configure_domains_add_context_set_button` | 1 label |
| `configure_domains_add_grant_button` | 1 label |
| `configure_domains_add_where_button` | 1 label |
| `configure_domains_bundle_choose` | 1 label |
| `configure_domains_bundle_failed` | 1 label |
| `configure_domains_bundle_import_another` | 1 label |
| `configure_domains_bundle_importing` | 1 label |
| `configure_domains_bundle_into_helper` | 1 label |
| `configure_domains_bundle_into_label` | 1 label |
| `configure_domains_bundle_into_placeholder` | 1 label |
| `configure_domains_bundle_invalid` | 1 label |
| `configure_domains_bundle_merge_helper` | 1 label |
| `configure_domains_bundle_merge_label` | 1 label |
| `configure_domains_bundle_pick_another` | 1 label |
| `configure_domains_bundle_report_line` | 1 label |
| `configure_domains_check_doctype_group` | 1 label |
| `configure_domains_check_domain_group` | 1 label |
| `configure_domains_check_helper` | 1 label |
| `configure_domains_check_loading` | 1 label |
| `configure_domains_check_notices_group` | 1 label |
| `configure_domains_check_notices_helper` | 1 label |
| `configure_domains_check_ok` | 1 label |
| `configure_domains_check_refresh` | 1 label |
| `configure_domains_check_refreshing` | 1 label |
| `configure_domains_check_title` | 1 label |
| `configure_domains_child_badge` | 1 label |
| `configure_domains_child_label` | 1 label |
| `configure_domains_children_label` | 1 label |
| `configure_domains_consumer_label` | 1 label |
| `configure_domains_context_sets_empty` | 1 label |
| `configure_domains_context_sets_helper` | 1 label |
| `configure_domains_context_sets_title` | 1 label |
| `configure_domains_danger_helper` | 1 label |
| `configure_domains_delete_button` | 1 label |
| `configure_domains_delete_dialog_desc` | 1 label |
| `configure_domains_delete_dialog_title` | 1 label |
| `configure_domains_description_placeholder` | 1 label |
| `configure_domains_detail_page_title` | 1 label |
| `configure_domains_discard_helper` | 1 label |
| `configure_domains_discard_title` | 1 label |
| `configure_domains_discarding_button` | 1 label |
| `configure_domains_display_name_label` | 1 label |
| `configure_domains_doctypes_count` | 1 label |
| `configure_domains_doctypes_empty` | 1 label |
| `configure_domains_doctypes_short` | 1 label |
| `configure_domains_draft_badge` | 1 label |
| `configure_domains_draft_confirm` | 1 label |
| `configure_domains_draft_source` | 1 label |
| `configure_domains_draft_tag` | 1 label |
| `configure_domains_drafts_empty` | 1 label |
| `configure_domains_drafts_title` | 1 label |
| `configure_domains_editors_add_button` | 1 label |
| `configure_domains_editors_add_placeholder` | 1 label |
| `configure_domains_editors_all_listed` | 1 label |
| `configure_domains_editors_empty` | 1 label |
| `configure_domains_editors_helper` | 1 label |
| `configure_domains_editors_loading` | 1 label |
| `configure_domains_editors_remove_aria` | 1 label |
| `configure_domains_editors_system_note` | 1 label |
| `configure_domains_editors_title` | 1 label |
| `configure_domains_empty` | 1 label |
| `configure_domains_everything_label` | 1 label |
| `configure_domains_explain_configure_text` | 1 label |
| `configure_domains_explain_configure_title` | 1 label |
| `configure_domains_explain_draft_text` | 1 label |
| `configure_domains_explain_draft_title` | 1 label |
| `configure_domains_export_item` | 1 label |
| `configure_domains_fields_empty` | 1 label |
| `configure_domains_fields_label` | 1 label |
| `configure_domains_filter_placeholder` | 1 label |
| `configure_domains_from_label` | 1 label |
| `configure_domains_grant_consumer` | 1 label |
| `configure_domains_grant_wildcard_error` | 1 label |
| `configure_domains_grants_empty` | 1 label |
| `configure_domains_grants_helper` | 1 label |
| `configure_domains_grants_title` | 1 label |
| `configure_domains_id_label` | 1 label |
| `configure_domains_import_button` | 1 label |
| `configure_domains_import_desc` | 1 label |
| `configure_domains_import_title` | 1 label |
| `configure_domains_in_progress_count` | 1 label |
| `configure_domains_issue_count_plural` | 1 label |
| `configure_domains_issue_count_singular` | 1 label |
| `configure_domains_just_now` | 1 label |
| `configure_domains_label_placeholder` | 1 label |
| `configure_domains_label` | 1 label |
| `configure_domains_last_edited` | 1 label |
| `configure_domains_layout_fallback` | 1 label |
| `configure_domains_list_subtitle` | 1 label |
| `configure_domains_list_title` | 1 label |
| `configure_domains_live_count` | 1 label |
| `configure_domains_loading` | 1 label |
| `configure_domains_network_delete_error` | 1 label |
| `configure_domains_network_discard_error` | 1 label |
| `configure_domains_new_button` | 1 label |
| `configure_domains_new_draft_item` | 1 label |
| `configure_domains_not_found` | 1 label |
| `configure_domains_open_editor` | 1 label |
| `configure_domains_page_title` | 1 label |
| `configure_domains_published_title` | 1 label |
| `configure_domains_remove_context_set_aria` | 1 label |
| `configure_domains_remove_grant_aria` | 1 label |
| `configure_domains_remove_where_aria` | 1 label |
| `configure_domains_review_changes` | 1 label |
| `configure_domains_root_badge` | 1 label |
| `configure_domains_select_field_label` | 1 label |
| `configure_domains_select_field_placeholder` | 1 label |
| `configure_domains_source_doctype_label` | 1 label |
| `configure_domains_tab_check` | 1 label |
| `configure_domains_tab_editors` | 1 label |
| `configure_domains_tab_grants` | 1 label |
| `configure_domains_tab_overview` | 1 label |
| `configure_domains_where_empty` | 1 label |
| `configure_domains_where_key_aria` | 1 label |
| `configure_domains_where_label` | 1 label |
| `configure_domains_where_value_aria` | 1 label |
| `configure_domains_where_value_placeholder` | 1 label |
| `configure_exit_aria` | 1 label |
| `configure_exit_button` | 1 label |
| `configure_exit_tag` | 1 label |
| `configure_exit_title` | 1 label |
| `configure_grants_activate` | 1 label |
| `configure_grants_add_button` | 1 label |
| `configure_grants_add_row_button` | 1 label |
| `configure_grants_consumer_label` | 1 label |
| `configure_grants_deactivate` | 1 label |
| `configure_grants_doctype_label` | 1 label |
| `configure_grants_for` | 1 label |
| `configure_grants_from` | 1 label |
| `configure_grants_held_empty` | 1 label |
| `configure_grants_held_helper` | 1 label |
| `configure_grants_held_title` | 1 label |
| `configure_grants_issued_empty` | 1 label |
| `configure_grants_issued_helper` | 1 label |
| `configure_grants_issued_title` | 1 label |
| `configure_grants_loading` | 1 label |
| `configure_grants_new_helper` | 1 label |
| `configure_grants_new_title` | 1 label |
| `configure_grants_no_tags` | 1 label |
| `configure_grants_remove_aria` | 1 label |
| `configure_grants_remove_row_aria` | 1 label |
| `configure_grants_resources_empty` | 1 label |
| `configure_grants_resources_helper` | 1 label |
| `configure_grants_resources_label` | 1 label |
| `configure_grants_row_doctype_error` | 1 label |
| `configure_grants_row_new` | 1 label |
| `configure_grants_row_tags_error` | 1 label |
| `configure_grants_state_active` | 1 label |
| `configure_grants_state_awaiting` | 1 label |
| `configure_grants_state_inactive` | 1 label |
| `configure_grants_tags_label` | 1 label |
| `configure_grants_tags_placeholder` | 1 label |
| `configure_identity_title` | 1 label |
| `configure_label_helper` | 1 label |
| `configure_label_label` | 1 label |
| `configure_listing_live` | 1 label |
| `configure_listing_mode_aria` | 1 label |
| `configure_more_actions_aria` | 1 label |
| `configure_oidc_col_domains` | 1 label |
| `configure_oidc_col_issuer` | 1 label |
| `configure_oidc_col_provider` | 1 label |
| `configure_oidc_col_state` | 1 label |
| `configure_oidc_create` | 1 label |
| `configure_oidc_delete_message` | 1 label |
| `configure_oidc_delete_title` | 1 label |
| `configure_oidc_edit_title` | 1 label |
| `configure_oidc_empty` | 1 label |
| `configure_oidc_enabled` | 1 label |
| `configure_oidc_field_auto_provision` | 1 label |
| `configure_oidc_field_client_id` | 1 label |
| `configure_oidc_field_domains_helper` | 1 label |
| `configure_oidc_field_domains` | 1 label |
| `configure_oidc_field_issuer` | 1 label |
| `configure_oidc_field_label` | 1 label |
| `configure_oidc_field_name_helper` | 1 label |
| `configure_oidc_field_name` | 1 label |
| `configure_oidc_field_role_helper` | 1 label |
| `configure_oidc_field_role` | 1 label |
| `configure_oidc_field_scopes_helper` | 1 label |
| `configure_oidc_field_scopes` | 1 label |
| `configure_oidc_field_secret_helper` | 1 label |
| `configure_oidc_field_secret` | 1 label |
| `configure_oidc_jit_badge` | 1 label |
| `configure_oidc_load_fallback` | 1 label |
| `configure_oidc_name_immutable` | 1 label |
| `configure_oidc_page_title` | 1 label |
| `configure_oidc_save_fallback` | 1 label |
| `configure_oidc_secret_set` | 1 label |
| `configure_oidc_secret_unset` | 1 label |
| `configure_oidc_subtitle` | 1 label |
| `configure_oidc_title` | 1 label |
| `configure_options_aria` | 1 label |
| `configure_page_title` | 1 label |
| `configure_plural_label_helper` | 1 label |
| `configure_plural_label_label` | 1 label |
| `configure_publish_button` | 1 label |
| `configure_publish_conflict_desc` | 1 label |
| `configure_publish_conflict_keep` | 1 label |
| `configure_publish_desc` | 1 label |
| `configure_publish_import_documents_all` | 1 label |
| `configure_publish_import_documents_desc` | 1 label |
| `configure_publish_import_documents_exists` | 1 label |
| `configure_publish_import_documents` | 1 label |
| `configure_publish_invalid_error` | 1 label |
| `configure_publish_loading` | 1 label |
| `configure_publish_name_helper` | 1 label |
| `configure_publish_name_label` | 1 label |
| `configure_publish_name_placeholder` | 1 label |
| `configure_publish_ok_note` | 1 label |
| `configure_publish_overwrite_button` | 1 label |
| `configure_publish_report_continue` | 1 label |
| `configure_publish_report_desc` | 1 label |
| `configure_publish_report_title` | 1 label |
| `configure_publish_ticket_dropped` | 1 label |
| `configure_publish_ticket_filed_active` | 1 label |
| `configure_publish_ticket_filed` | 1 label |
| `configure_publish_ticket_merged` | 1 label |
| `configure_publish_ticket_untagged` | 1 label |
| `configure_publish_title` | 1 label |
| `configure_publish_underscore_error` | 1 label |
| `configure_publish_warnings_note` | 1 label |
| `configure_publish_warnings_plural` | 1 label |
| `configure_publish_warnings_singular` | 1 label |
| `configure_publish_with_warning_singular` | 1 label |
| `configure_publish_with_warnings_plural` | 1 label |
| `configure_publishing_button` | 1 label |
| `configure_role_accounts_loading` | 1 label |
| `configure_role_assistant_label` | 1 label |
| `configure_role_assistant_toggle` | 1 label |
| `configure_role_back_button` | 1 label |
| `configure_role_budget_error` | 1 label |
| `configure_role_budget_helper` | 1 label |
| `configure_role_budget_label` | 1 label |
| `configure_role_budget_placeholder` | 1 label |
| `configure_role_budget_unlimited` | 1 label |
| `configure_role_channels_helper` | 1 label |
| `configure_role_desc_editable` | 1 label |
| `configure_role_details_page_title` | 1 label |
| `configure_role_details_subtitle` | 1 label |
| `configure_role_details_tab` | 1 label |
| `configure_role_grants_loading` | 1 label |
| `configure_role_grants_page_title` | 1 label |
| `configure_role_grants_subtitle` | 1 label |
| `configure_role_heading` | 1 label |
| `configure_role_loading` | 1 label |
| `configure_role_members_all_assigned` | 1 label |
| `configure_role_members_page_title` | 1 label |
| `configure_role_members_remove_aria` | 1 label |
| `configure_role_members_subtitle` | 1 label |
| `configure_role_members_tab` | 1 label |
| `configure_role_page_title` | 1 label |
| `configure_role_save_button` | 1 label |
| `configure_role_tags_helper` | 1 label |
| `configure_role_tags_label` | 1 label |
| `configure_role_tags_required` | 1 label |
| `configure_role_tags_union_error` | 1 label |
| `configure_roles_delete_missing` | 1 label |
| `configure_roles_loading` | 1 label |
| `configure_roles_no_registry` | 1 label |
| `configure_roles_page_title` | 1 label |
| `configure_roles_save_missing` | 1 label |
| `configure_roles_subtitle` | 1 label |
| `configure_roles_title` | 1 label |
| `configure_save_failed_reason` | 1 label |
| `configure_save_failed` | 1 label |
| `configure_section_access` | 1 label |
| `configure_section_apps` | 1 label |
| `configure_section_configure` | 1 label |
| `configure_section_platform` | 1 label |
| `configure_section_system` | 1 label |
| `configure_select_placeholder` | 1 label |
| `configure_subtitle` | 1 label |
| `dashboard_connected_as` | 1 label |
| `dashboard_domain_new_doctype` | 1 label |
| `dashboard_domain_page_title` | 1 label |
| `dashboard_domain_summary` | 1 label |
| `dashboard_edit_domain_empty` | 1 label |
| `dashboard_edit_domain_helper` | 1 label |
| `dashboard_edit_domain_title` | 1 label |
| `dashboard_empty_domains_body` | 1 label |
| `dashboard_empty_domains_import` | 1 label |
| `dashboard_empty_domains_new` | 1 label |
| `dashboard_empty_domains_title` | 1 label |
| `dashboard_hello_fallback` | 1 label |
| `dashboard_hello` | 1 label |
| `dashboard_new_doctype_button` | 1 label |
| `dashboard_new_doctype_helper` | 1 label |
| `dashboard_new_doctype_name_error` | 1 label |
| `dashboard_new_doctype_placeholder` | 1 label |
| `dashboard_new_doctype_title` | 1 label |
| `dashboard_new_domain_button` | 1 label |
| `dashboard_new_domain_helper` | 1 label |
| `dashboard_new_domain_id_helper` | 1 label |
| `dashboard_new_domain_id_label` | 1 label |
| `dashboard_new_domain_id_placeholder` | 1 label |
| `dashboard_new_domain_label_label` | 1 label |
| `dashboard_new_domain_label_placeholder` | 1 label |
| `dashboard_new_domain_title` | 1 label |
| `dashboard_no_domains_desc` | 1 label |
| `dashboard_no_domains_title` | 1 label |
| `dashboard_page_title` | 1 label |
| `dashboard_pinned_empty` | 1 label |
| `dashboard_pinned_title` | 1 label |
| `dashboard_quick_links_aria` | 1 label |
| `dashboard_recent_empty` | 1 label |
| `dashboard_recent_title` | 1 label |
| `dashboard_section_applications` | 1 label |
| `dashboard_section_domains` | 1 label |
| `dashboard_section_drafts` | 1 label |
| `dashboard_show_more` | 1 label |
| `dashboard_surface_aria` | 1 label |
| `doc_action_args_required` | 1 label |
| `doc_action_toast` | 1 label |
| `doc_actions` | 1 label |
| `doc_array_add` | 1 label |
| `doc_array_remove_title` | 1 label |
| `doc_attachment_attach_failed` | 1 label |
| `doc_attachment_attach` | 1 label |
| `doc_attachment_attaching` | 1 label |
| `doc_attachment_by` | 1 label |
| `doc_attachment_change` | 1 label |
| `doc_attachment_choose` | 1 label |
| `doc_attachment_delete_aria` | 1 label |
| `doc_attachment_delete_confirm` | 1 label |
| `doc_attachment_delete_failed` | 1 label |
| `doc_attachment_download_aria` | 1 label |
| `doc_attachment_name_aria` | 1 label |
| `doc_attachment_name_placeholder` | 1 label |
| `doc_attachment_preview_aria` | 1 label |
| `doc_attachment_rename_aria` | 1 label |
| `doc_attachment_rename_failed` | 1 label |
| `doc_attachments_empty` | 1 label |
| `doc_attachments_forbidden` | 1 label |
| `doc_attachments_load_failed` | 1 label |
| `doc_attachments_loading` | 1 label |
| `doc_back_to_document` | 1 label |
| `doc_backrefs_aria` | 1 label |
| `doc_backrefs_load_failed` | 1 label |
| `doc_backrefs_more` | 1 label |
| `doc_backrefs_title` | 1 label |
| `doc_banner_dismiss` | 1 label |
| `doc_capsule_deleted_message` | 1 label |
| `doc_capsule_deleted_note` | 1 label |
| `doc_capsule_load_failed_note` | 1 label |
| `doc_capsule_load_failed` | 1 label |
| `doc_color_hex_error` | 1 label |
| `doc_color_neutrals` | 1 label |
| `doc_color_paste_aria` | 1 label |
| `doc_color_pick_aria` | 1 label |
| `doc_color_picker_aria` | 1 label |
| `doc_color_value_aria` | 1 label |
| `doc_comment_add_failed` | 1 label |
| `doc_comment_button` | 1 label |
| `doc_comment_delete_aria` | 1 label |
| `doc_comment_delete_confirm` | 1 label |
| `doc_comment_delete_failed` | 1 label |
| `doc_comment_edit_aria` | 1 label |
| `doc_comment_placeholder` | 1 label |
| `doc_comment_posting` | 1 label |
| `doc_comment_replies_collapse` | 1 label |
| `doc_comment_replies_expand` | 1 label |
| `doc_comment_reply_aria` | 1 label |
| `doc_comment_reply_cancel_aria` | 1 label |
| `doc_comment_reply_failed` | 1 label |
| `doc_comment_reply_note` | 1 label |
| `doc_comment_reply_placeholder` | 1 label |
| `doc_comment_replying_note` | 1 label |
| `doc_comment_save_failed` | 1 label |
| `doc_comment_show_less` | 1 label |
| `doc_comment_show_more` | 1 label |
| `doc_comment_unknown_author` | 1 label |
| `doc_comments_empty` | 1 label |
| `doc_comments_forbidden` | 1 label |
| `doc_comments_load_failed` | 1 label |
| `doc_comments_loading` | 1 label |
| `doc_copy_capsule_aria` | 1 label |
| `doc_copy_capsule_title` | 1 label |
| `doc_copy_link_title` | 1 label |
| `doc_delete_confirm_referenced` | 1 label |
| `doc_delete_confirm` | 1 label |
| `doc_deleted_note_dated` | 1 label |
| `doc_deleted_note` | 1 label |
| `doc_document_missing` | 1 label |
| `doc_dt_aria` | 1 label |
| `doc_dt_calendar_aria` | 1 label |
| `doc_dt_date_aria` | 1 label |
| `doc_dt_next_month_aria` | 1 label |
| `doc_dt_not_set` | 1 label |
| `doc_dt_now` | 1 label |
| `doc_dt_open_calendar_aria` | 1 label |
| `doc_dt_prev_month_aria` | 1 label |
| `doc_dt_slots_aria` | 1 label |
| `doc_duration_clear_aria` | 1 label |
| `doc_duration_max` | 1 label |
| `doc_duration_none` | 1 label |
| `doc_edit_title` | 1 label |
| `doc_file_attach_aria` | 1 label |
| `doc_file_drop_hint` | 1 label |
| `doc_file_type_not_allowed` | 1 label |
| `doc_form_children_failed` | 1 label |
| `doc_form_parent_broken` | 1 label |
| `doc_form_parent_helper` | 1 label |
| `doc_form_parent_label` | 1 label |
| `doc_form_parent_missing` | 1 label |
| `doc_form_parent_required` | 1 label |
| `doc_form_schema_unavailable` | 1 label |
| `doc_form_select_placeholder` | 1 label |
| `doc_form_structured_invalid` | 1 label |
| `doc_history_page_title` | 1 label |
| `doc_history` | 1 label |
| `doc_input_auto_array` | 1 label |
| `doc_input_auto_computed` | 1 label |
| `doc_input_auto_dictionary` | 1 label |
| `doc_input_auto_object` | 1 label |
| `doc_input_auto_replicated` | 1 label |
| `doc_items_empty` | 1 label |
| `doc_list_add_placeholder` | 1 label |
| `doc_list_duplicate` | 1 label |
| `doc_list_remove_aria` | 1 label |
| `doc_md_collapse` | 1 label |
| `doc_md_editor_aria` | 1 label |
| `doc_md_expand` | 1 label |
| `doc_md_markdown` | 1 label |
| `doc_md_mode_aria` | 1 label |
| `doc_md_nothing` | 1 label |
| `doc_md_placeholder` | 1 label |
| `doc_md_preview` | 1 label |
| `doc_md_ref_all_domains` | 1 label |
| `doc_md_ref_filter_by_type` | 1 label |
| `doc_md_ref_more_in` | 1 label |
| `doc_md_ref_no_results` | 1 label |
| `doc_md_ref_no_types` | 1 label |
| `doc_md_ref_people` | 1 label |
| `doc_md_ref_recent` | 1 label |
| `doc_md_ref_restricted` | 1 label |
| `doc_md_ref_retry` | 1 label |
| `doc_md_ref_search_all` | 1 label |
| `doc_md_ref_slash_group` | 1 label |
| `doc_md_ref_slash_item` | 1 label |
| `doc_md_write` | 1 label |
| `doc_money_currency_aria` | 1 label |
| `doc_money_currency_placeholder` | 1 label |
| `doc_money_favorites` | 1 label |
| `doc_money_filter_placeholder` | 1 label |
| `doc_money_group_aria` | 1 label |
| `doc_money_inactive` | 1 label |
| `doc_money_invalid` | 1 label |
| `doc_money_no_match` | 1 label |
| `doc_new_button` | 1 label |
| `doc_new_title` | 1 label |
| `doc_open_link_title` | 1 label |
| `doc_page_title` | 1 label |
| `doc_peek_back_aria` | 1 label |
| `doc_peek_edit_aria` | 1 label |
| `doc_peek_loading` | 1 label |
| `doc_peek_open_aria` | 1 label |
| `doc_print_title` | 1 label |
| `doc_print` | 1 label |
| `doc_record_label` | 1 label |
| `doc_ref_add_placeholder` | 1 label |
| `doc_ref_clear_aria` | 1 label |
| `doc_ref_doctype_aria` | 1 label |
| `doc_ref_duplicate` | 1 label |
| `doc_ref_edit_aria` | 1 label |
| `doc_ref_filter_placeholder` | 1 label |
| `doc_ref_no_doctypes` | 1 label |
| `doc_ref_no_matches_id` | 1 label |
| `doc_ref_no_matches` | 1 label |
| `doc_ref_records` | 1 label |
| `doc_ref_results_aria` | 1 label |
| `doc_ref_search_hint_id` | 1 label |
| `doc_ref_search_hint_type` | 1 label |
| `doc_ref_search_hint` | 1 label |
| `doc_ref_search_placeholder` | 1 label |
| `doc_ref_select_type` | 1 label |
| `doc_relation_add_aria` | 1 label |
| `doc_relation_empty_hint` | 1 label |
| `doc_relation_load_failed` | 1 label |
| `doc_relation_remove_aria` | 1 label |
| `doc_relation_schema_unavailable` | 1 label |
| `doc_relation_source_invalid` | 1 label |
| `doc_secret_change` | 1 label |
| `doc_secret_copy_title` | 1 label |
| `doc_secret_enter` | 1 label |
| `doc_secret_generate_new` | 1 label |
| `doc_secret_generate` | 1 label |
| `doc_secret_generating` | 1 label |
| `doc_secret_once_helper` | 1 label |
| `doc_secret_set` | 1 label |
| `doc_secret_stage_failed` | 1 label |
| `doc_secret_staging` | 1 label |
| `doc_select_empty` | 1 label |
| `doc_share` | 1 label |
| `doc_sidecar_adding` | 1 label |
| `doc_sidecar_empty` | 1 label |
| `doc_sidecar_load_failed` | 1 label |
| `doc_structured_helper` | 1 label |
| `doc_structured_invalid_json` | 1 label |
| `doc_structured_mismatch` | 1 label |
| `doc_template_dotted_field` | 1 label |
| `doc_template_missing` | 1 label |
| `doc_template_no_field` | 1 label |
| `doc_version_title` | 1 label |
| `errors_404_title` | 1 label |
| `errors_500_title` | 1 label |
| `errors_api_key_create` | 1 label |
| `errors_api_key_revoke` | 1 label |
| `errors_api_keys_load` | 1 label |
| `errors_app_key_issue` | 1 label |
| `errors_app_key_revoke` | 1 label |
| `errors_app_key_status` | 1 label |
| `errors_deleted_title` | 1 label |
| `errors_doctype_not_found` | 1 label |
| `errors_doctype_not_registered` | 1 label |
| `errors_document_load_failed` | 1 label |
| `errors_domain_not_found` | 1 label |
| `errors_mcp_load` | 1 label |
| `errors_page_title` | 1 label |
| `errors_reference_load_failed` | 1 label |
| `errors_reference_no_access` | 1 label |
| `errors_session_load` | 1 label |
| `errors_session_revoke` | 1 label |
| `errors_sessions_load` | 1 label |
| `errors_sessions_revoke_all` | 1 label |
| `errors_settings_clear` | 1 label |
| `errors_settings_load` | 1 label |
| `errors_settings_save` | 1 label |
| `errors_streaming_unsupported` | 1 label |
| `errors_upload_failed` | 1 label |
| `errors_webhooks_calls_load` | 1 label |
| `errors_webhooks_replay` | 1 label |
| `errors_webhooks_test` | 1 label |
| `form_select_no_match` | 1 label |
| `grid_agg_avg` | 1 label |
| `grid_agg_count` | 1 label |
| `grid_agg_max` | 1 label |
| `grid_agg_min` | 1 label |
| `grid_agg_sum` | 1 label |
| `grid_coerce_boolean` | 1 label |
| `grid_coerce_bounds_between` | 1 label |
| `grid_coerce_bounds_max` | 1 label |
| `grid_coerce_bounds_min` | 1 label |
| `grid_coerce_color` | 1 label |
| `grid_coerce_date` | 1 label |
| `grid_coerce_datetime` | 1 label |
| `grid_coerce_duration` | 1 label |
| `grid_coerce_enum` | 1 label |
| `grid_coerce_integer` | 1 label |
| `grid_coerce_money` | 1 label |
| `grid_coerce_period` | 1 label |
| `grid_coerce_type` | 1 label |
| `grid_editor_aria` | 1 label |
| `grid_enum_filter` | 1 label |
| `grid_fx_read_only` | 1 label |
| `grid_new_row_fill` | 1 label |
| `grid_new_row_missing` | 1 label |
| `grid_new_row_prompt` | 1 label |
| `grid_paste_readonly` | 1 label |
| `grid_paste_unreadable` | 1 label |
| `grid_range_cells` | 1 label |
| `grid_redo_skipped` | 1 label |
| `grid_undo_skipped` | 1 label |
| `impex_choose_file` | 1 label |
| `impex_download` | 1 label |
| `impex_export_csv` | 1 label |
| `impex_export_failed` | 1 label |
| `impex_export_json` | 1 label |
| `impex_export_ready` | 1 label |
| `impex_export_start_failed` | 1 label |
| `impex_export_started` | 1 label |
| `impex_export_view_csv` | 1 label |
| `impex_export_view_ready` | 1 label |
| `impex_export` | 1 label |
| `impex_exporting_csv` | 1 label |
| `impex_exporting_json` | 1 label |
| `impex_exporting_view` | 1 label |
| `impex_file_read_failed` | 1 label |
| `impex_fix_row_hint` | 1 label |
| `impex_import_another` | 1 label |
| `impex_import_desc` | 1 label |
| `impex_import_failed` | 1 label |
| `impex_import_start_failed` | 1 label |
| `impex_import_title` | 1 label |
| `impex_import` | 1 label |
| `impex_importing` | 1 label |
| `impex_nothing_imported` | 1 label |
| `impex_pick_another` | 1 label |
| `impex_report_line` | 1 label |
| `impex_request_failed` | 1 label |
| `impex_row_count` | 1 label |
| `impex_row_error` | 1 label |
| `impex_row_field_error` | 1 label |
| `kanban_board_empty` | 1 label |
| `kanban_lane_empty` | 1 label |
| `kanban_lane_error` | 1 label |
| `kanban_show_more` | 1 label |
| `language_name_en` | 1 label |
| `language_name_fr` | 1 label |
| `list_editor_add_column_aria` | 1 label |
| `list_editor_available_aria` | 1 label |
| `list_editor_available` | 1 label |
| `list_editor_choose_surface` | 1 label |
| `list_editor_color_by_label` | 1 label |
| `list_editor_color_helper` | 1 label |
| `list_editor_columns_required` | 1 label |
| `list_editor_columns` | 1 label |
| `list_editor_coming_soon` | 1 label |
| `list_editor_create_view` | 1 label |
| `list_editor_date_capability` | 1 label |
| `list_editor_date_helper` | 1 label |
| `list_editor_date_label` | 1 label |
| `list_editor_date_placeholder` | 1 label |
| `list_editor_date_required` | 1 label |
| `list_editor_edit_title` | 1 label |
| `list_editor_end_date_capability` | 1 label |
| `list_editor_end_date_helper` | 1 label |
| `list_editor_end_date_label` | 1 label |
| `list_editor_end_date_placeholder` | 1 label |
| `list_editor_fields_exhausted` | 1 label |
| `list_editor_filters_helper` | 1 label |
| `list_editor_filters` | 1 label |
| `list_editor_general_edit_helper` | 1 label |
| `list_editor_general_sub` | 1 label |
| `list_editor_grid_allow_create_helper` | 1 label |
| `list_editor_grid_allow_create` | 1 label |
| `list_editor_grid_columns_editable_aria` | 1 label |
| `list_editor_grid_columns_editable_helper` | 1 label |
| `list_editor_grid_columns_editable` | 1 label |
| `list_editor_grid_frozen_helper` | 1 label |
| `list_editor_grid_frozen_marker` | 1 label |
| `list_editor_grid_frozen` | 1 label |
| `list_editor_grid_section_editable` | 1 label |
| `list_editor_grid_section_readonly` | 1 label |
| `list_editor_grid_sort_asc` | 1 label |
| `list_editor_grid_sort_default` | 1 label |
| `list_editor_grid_sort_desc` | 1 label |
| `list_editor_grid_sort_dir_aria` | 1 label |
| `list_editor_grid_sort_helper` | 1 label |
| `list_editor_grid_sort` | 1 label |
| `list_editor_grid_summary_aria` | 1 label |
| `list_editor_grid_summary_helper` | 1 label |
| `list_editor_grid_summary` | 1 label |
| `list_editor_grid_unknown_field` | 1 label |
| `list_editor_group_by_capability` | 1 label |
| `list_editor_group_by_helper` | 1 label |
| `list_editor_group_by_label` | 1 label |
| `list_editor_group_by_placeholder` | 1 label |
| `list_editor_group_by_required` | 1 label |
| `list_editor_inline_aria` | 1 label |
| `list_editor_inline_helper` | 1 label |
| `list_editor_inline_label` | 1 label |
| `list_editor_kanban_allow_move_helper` | 1 label |
| `list_editor_kanban_allow_move` | 1 label |
| `list_editor_kanban_desc` | 1 label |
| `list_editor_kanban_lanes_helper` | 1 label |
| `list_editor_kanban_mode_custom_desc` | 1 label |
| `list_editor_kanban_mode_custom` | 1 label |
| `list_editor_kanban_mode_values_desc` | 1 label |
| `list_editor_kanban_mode_values` | 1 label |
| `list_editor_kanban_mode` | 1 label |
| `list_editor_kanban_sort_asc` | 1 label |
| `list_editor_kanban_sort_default` | 1 label |
| `list_editor_kanban_sort_desc` | 1 label |
| `list_editor_kanban_sort_dir_aria` | 1 label |
| `list_editor_kanban_sort_helper` | 1 label |
| `list_editor_kanban_sort` | 1 label |
| `list_editor_label_aria` | 1 label |
| `list_editor_lane_add` | 1 label |
| `list_editor_lane_field` | 1 label |
| `list_editor_lane_filter_required` | 1 label |
| `list_editor_lane_label_duplicate` | 1 label |
| `list_editor_lane_label_required` | 1 label |
| `list_editor_lane_label` | 1 label |
| `list_editor_lane_operator` | 1 label |
| `list_editor_lane_remove_aria` | 1 label |
| `list_editor_lane_value` | 1 label |
| `list_editor_lane_visibility_aria` | 1 label |
| `list_editor_lanes_all_hidden` | 1 label |
| `list_editor_lanes_label` | 1 label |
| `list_editor_lanes_required` | 1 label |
| `list_editor_move_down_aria` | 1 label |
| `list_editor_move_up_aria` | 1 label |
| `list_editor_name_placeholder` | 1 label |
| `list_editor_name_required` | 1 label |
| `list_editor_new_title` | 1 label |
| `list_editor_next` | 1 label |
| `list_editor_no_columns` | 1 label |
| `list_editor_personal_edit_helper` | 1 label |
| `list_editor_personal_sub` | 1 label |
| `list_editor_personal_warn` | 1 label |
| `list_editor_remove_column_aria` | 1 label |
| `list_editor_save_changes` | 1 label |
| `list_editor_scope_aria` | 1 label |
| `list_editor_scope_general` | 1 label |
| `list_editor_scope_personal` | 1 label |
| `list_editor_scope` | 1 label |
| `list_editor_selected_aria` | 1 label |
| `list_editor_selected_count` | 1 label |
| `list_editor_soon` | 1 label |
| `list_editor_surface_calendar_desc` | 1 label |
| `list_editor_surface_calendar` | 1 label |
| `list_editor_surface_grid_desc` | 1 label |
| `list_editor_surface_grid` | 1 label |
| `list_editor_surface_kanban` | 1 label |
| `list_editor_surface_table_desc` | 1 label |
| `list_editor_surface_table` | 1 label |
| `list_editor_title_template_helper` | 1 label |
| `list_editor_title_template_label` | 1 label |
| `list_filter_add` | 1 label |
| `list_filter_false` | 1 label |
| `list_filter_from` | 1 label |
| `list_filter_max` | 1 label |
| `list_filter_min` | 1 label |
| `list_filter_pick_placeholder` | 1 label |
| `list_filter_remove_aria` | 1 label |
| `list_filter_to` | 1 label |
| `list_filter_true` | 1 label |
| `list_filter_value_aria` | 1 label |
| `list_filter_values_aria` | 1 label |
| `list_page_title` | 1 label |
| `list_restore_button` | 1 label |
| `list_restore_failed` | 1 label |
| `list_restore_not_deleted` | 1 label |
| `list_restore_permission_title` | 1 label |
| `list_restore_title` | 1 label |
| `list_search_placeholder` | 1 label |
| `list_tab_error_aria` | 1 label |
| `list_view_create` | 1 label |
| `list_view_delete_confirm_body` | 1 label |
| `list_view_delete_confirm_title` | 1 label |
| `list_view_delete` | 1 label |
| `list_view_edit` | 1 label |
| `list_view_pin` | 1 label |
| `list_view_starter_hint` | 1 label |
| `list_view_starter_no_create` | 1 label |
| `list_view_starter_title` | 1 label |
| `list_view_unpin` | 1 label |
| `list_views_loading` | 1 label |
| `mcp_copy_aria` | 1 label |
| `mcp_empty` | 1 label |
| `mcp_helper` | 1 label |
| `mcp_load_error` | 1 label |
| `mcp_title` | 1 label |
| `nav_action_taken` | 1 label |
| `nav_api_keys` | 1 label |
| `nav_assistant_close` | 1 label |
| `nav_assistant_open` | 1 label |
| `nav_assistant_toggle_aria` | 1 label |
| `nav_breadcrumb_aria` | 1 label |
| `nav_builder` | 1 label |
| `nav_close_notifications` | 1 label |
| `nav_configure_admin` | 1 label |
| `nav_configure` | 1 label |
| `nav_dashboard` | 1 label |
| `nav_domain_summary` | 1 label |
| `nav_download_notification_aria` | 1 label |
| `nav_draft_label` | 1 label |
| `nav_draft_unnamed` | 1 label |
| `nav_group_doctypes` | 1 label |
| `nav_group_pinned` | 1 label |
| `nav_load_more` | 1 label |
| `nav_logout` | 1 label |
| `nav_mark_all_read` | 1 label |
| `nav_my_settings` | 1 label |
| `nav_notifications_empty_helper` | 1 label |
| `nav_notifications_empty` | 1 label |
| `nav_notifications` | 1 label |
| `nav_open_notification_aria` | 1 label |
| `nav_pin_aria` | 1 label |
| `nav_pin` | 1 label |
| `nav_search_doctype_aria` | 1 label |
| `nav_search_doctype_placeholder` | 1 label |
| `nav_search_empty` | 1 label |
| `nav_search_inline_empty` | 1 label |
| `nav_search_placeholder` | 1 label |
| `nav_sidebar_collapse` | 1 label |
| `nav_sidebar_expand` | 1 label |
| `nav_switch_role` | 1 label |
| `nav_toggle_theme` | 1 label |
| `nav_tree_collapse` | 1 label |
| `nav_tree_expand` | 1 label |
| `nav_unpin_aria` | 1 label |
| `nav_unpin` | 1 label |
| `nav_unread_aria` | 1 label |
| `nav_webhooks` | 1 label |
| `palette_dialog_desc` | 1 label |
| `palette_dialog_title` | 1 label |
| `palette_empty_results` | 1 label |
| `palette_escalate` | 1 label |
| `palette_group_actions` | 1 label |
| `palette_group_navigate` | 1 label |
| `palette_group_recent` | 1 label |
| `palette_group_records` | 1 label |
| `palette_input_label` | 1 label |
| `palette_scope_all_domains` | 1 label |
| `period_end` | 1 label |
| `period_group_aria` | 1 label |
| `period_order_exclusive` | 1 label |
| `period_order_inclusive` | 1 label |
| `period_start` | 1 label |
| `platform_artifacts_col_created` | 1 label |
| `platform_artifacts_col_file` | 1 label |
| `platform_artifacts_col_grants` | 1 label |
| `platform_artifacts_col_mime` | 1 label |
| `platform_artifacts_col_owners` | 1 label |
| `platform_artifacts_col_references` | 1 label |
| `platform_artifacts_col_size` | 1 label |
| `platform_artifacts_col_uploaded_by` | 1 label |
| `platform_artifacts_deleted_badge` | 1 label |
| `platform_artifacts_detail_empty` | 1 label |
| `platform_artifacts_detail_load_error` | 1 label |
| `platform_artifacts_download_aria` | 1 label |
| `platform_artifacts_download` | 1 label |
| `platform_artifacts_filter_deleted_label` | 1 label |
| `platform_artifacts_filter_id_label` | 1 label |
| `platform_artifacts_filter_mime_label` | 1 label |
| `platform_artifacts_filter_name_label` | 1 label |
| `platform_artifacts_filter_state_all` | 1 label |
| `platform_artifacts_filter_state_deleted` | 1 label |
| `platform_artifacts_filter_state_live` | 1 label |
| `platform_artifacts_forbidden` | 1 label |
| `platform_artifacts_grants_col_created_by` | 1 label |
| `platform_artifacts_grants_col_created` | 1 label |
| `platform_artifacts_grants_col_expires` | 1 label |
| `platform_artifacts_grants_col_kind` | 1 label |
| `platform_artifacts_grants_empty` | 1 label |
| `platform_artifacts_grants_expired` | 1 label |
| `platform_artifacts_grants_kind_ephemeral` | 1 label |
| `platform_artifacts_grants_kind_permanent` | 1 label |
| `platform_artifacts_grants_never_expires` | 1 label |
| `platform_artifacts_grants_title` | 1 label |
| `platform_artifacts_id_label` | 1 label |
| `platform_artifacts_load_error` | 1 label |
| `platform_artifacts_more_grants` | 1 label |
| `platform_artifacts_more_records` | 1 label |
| `platform_artifacts_more_references` | 1 label |
| `platform_artifacts_nav` | 1 label |
| `platform_artifacts_page_count` | 1 label |
| `platform_artifacts_page_header` | 1 label |
| `platform_artifacts_page_subtitle` | 1 label |
| `platform_artifacts_page_title` | 1 label |
| `platform_artifacts_pager_next` | 1 label |
| `platform_artifacts_pager_previous` | 1 label |
| `platform_artifacts_purge_aria` | 1 label |
| `platform_artifacts_purge_busy` | 1 label |
| `platform_artifacts_purge_button` | 1 label |
| `platform_artifacts_purge_confirm_button` | 1 label |
| `platform_artifacts_purge_confirm_message` | 1 label |
| `platform_artifacts_purge_confirm_title` | 1 label |
| `platform_artifacts_purge_error` | 1 label |
| `platform_artifacts_purge_forbidden` | 1 label |
| `platform_artifacts_purge_reason_label` | 1 label |
| `platform_artifacts_purge_reason_placeholder` | 1 label |
| `platform_artifacts_references_col_doctype` | 1 label |
| `platform_artifacts_references_col_domain` | 1 label |
| `platform_artifacts_references_col_field` | 1 label |
| `platform_artifacts_references_col_last_seen` | 1 label |
| `platform_artifacts_references_col_resource` | 1 label |
| `platform_artifacts_references_empty` | 1 label |
| `platform_artifacts_references_title` | 1 label |
| `platform_artifacts_references_unresolved` | 1 label |
| `platform_artifacts_refresh_aria` | 1 label |
| `platform_artifacts_refresh` | 1 label |
| `platform_artifacts_revoke_aria` | 1 label |
| `platform_artifacts_revoke_button` | 1 label |
| `platform_artifacts_revoke_confirm_button` | 1 label |
| `platform_artifacts_revoke_confirm_message` | 1 label |
| `platform_artifacts_revoke_confirm_title` | 1 label |
| `platform_artifacts_revoke_error` | 1 label |
| `platform_artifacts_revoke_forbidden` | 1 label |
| `platform_artifacts_sha256_label` | 1 label |
| `platform_artifacts_table_empty` | 1 label |
| `platform_artifacts_total_count_plural` | 1 label |
| `platform_artifacts_total_count_singular` | 1 label |
| `platform_artifacts_uploaded_by_label` | 1 label |
| `platform_indexes_col_doctype` | 1 label |
| `platform_indexes_col_domain` | 1 label |
| `platform_indexes_col_error` | 1 label |
| `platform_indexes_col_field` | 1 label |
| `platform_indexes_col_index_name` | 1 label |
| `platform_indexes_col_status` | 1 label |
| `platform_indexes_col_type` | 1 label |
| `platform_indexes_col_updated` | 1 label |
| `platform_indexes_filter_all_option` | 1 label |
| `platform_indexes_filter_doctype_label` | 1 label |
| `platform_indexes_filter_domain_label` | 1 label |
| `platform_indexes_filter_field_label` | 1 label |
| `platform_indexes_filter_status_label` | 1 label |
| `platform_indexes_forbidden` | 1 label |
| `platform_indexes_load_error` | 1 label |
| `platform_indexes_more_records` | 1 label |
| `platform_indexes_nav` | 1 label |
| `platform_indexes_page_count` | 1 label |
| `platform_indexes_page_header` | 1 label |
| `platform_indexes_page_subtitle` | 1 label |
| `platform_indexes_page_title` | 1 label |
| `platform_indexes_pager_next` | 1 label |
| `platform_indexes_pager_previous` | 1 label |
| `platform_indexes_refresh_aria` | 1 label |
| `platform_indexes_refresh` | 1 label |
| `platform_indexes_status_active` | 1 label |
| `platform_indexes_status_dropped` | 1 label |
| `platform_indexes_status_error` | 1 label |
| `platform_indexes_status_pending` | 1 label |
| `platform_indexes_table_empty` | 1 label |
| `platform_indexes_total_count_plural` | 1 label |
| `platform_indexes_total_count_singular` | 1 label |
| `platform_maintenance_action_migrate_desc` | 1 label |
| `platform_maintenance_action_migrate` | 1 label |
| `platform_maintenance_action_reproject_desc` | 1 label |
| `platform_maintenance_action_reproject` | 1 label |
| `platform_maintenance_confirm_body` | 1 label |
| `platform_maintenance_confirm_run` | 1 label |
| `platform_maintenance_confirm_title` | 1 label |
| `platform_maintenance_doctype_label` | 1 label |
| `platform_maintenance_doctype_placeholder` | 1 label |
| `platform_maintenance_enqueue_failed` | 1 label |
| `platform_maintenance_forbidden` | 1 label |
| `platform_maintenance_job_failed` | 1 label |
| `platform_maintenance_job_pending` | 1 label |
| `platform_maintenance_job_running` | 1 label |
| `platform_maintenance_job_succeeded` | 1 label |
| `platform_maintenance_jobs_col_error` | 1 label |
| `platform_maintenance_jobs_col_kind` | 1 label |
| `platform_maintenance_jobs_col_started` | 1 label |
| `platform_maintenance_jobs_col_stats` | 1 label |
| `platform_maintenance_jobs_col_status` | 1 label |
| `platform_maintenance_jobs_col_updated` | 1 label |
| `platform_maintenance_jobs_empty` | 1 label |
| `platform_maintenance_jobs_header` | 1 label |
| `platform_maintenance_kind_migrate` | 1 label |
| `platform_maintenance_kind_reproject` | 1 label |
| `platform_maintenance_load_error` | 1 label |
| `platform_maintenance_nav` | 1 label |
| `platform_maintenance_page_count` | 1 label |
| `platform_maintenance_page_header` | 1 label |
| `platform_maintenance_page_subtitle` | 1 label |
| `platform_maintenance_page_title` | 1 label |
| `platform_maintenance_pager_next` | 1 label |
| `platform_maintenance_pager_previous` | 1 label |
| `platform_maintenance_refresh_aria` | 1 label |
| `platform_maintenance_refresh` | 1 label |
| `platform_maintenance_stats_batches` | 1 label |
| `platform_maintenance_stats_failed_ids` | 1 label |
| `platform_maintenance_stats_migrate` | 1 label |
| `platform_maintenance_stats_reproject` | 1 label |
| `platform_maintenance_stats_total` | 1 label |
| `platform_maintenance_status_ahead_count` | 1 label |
| `platform_maintenance_status_blocked_count` | 1 label |
| `platform_maintenance_status_current_version` | 1 label |
| `platform_maintenance_status_empty_hint` | 1 label |
| `sessions_bulk_button` | 1 label |
| `sessions_bulk_confirm_body` | 1 label |
| `sessions_bulk_confirm_button` | 1 label |
| `sessions_bulk_confirm_title` | 1 label |
| `sessions_bulk_done` | 1 label |
| `sessions_empty` | 1 label |
| `sessions_helper` | 1 label |
| `sessions_last_used_label` | 1 label |
| `sessions_no_ua` | 1 label |
| `sessions_revoke_aria` | 1 label |
| `sessions_revoke_button` | 1 label |
| `sessions_revoke_confirm_body` | 1 label |
| `sessions_revoke_confirm_button` | 1 label |
| `sessions_revoke_confirm_title` | 1 label |
| `sessions_revoking_button` | 1 label |
| `sessions_title` | 1 label |
| `settings_general_helper` | 1 label |
| `settings_general_title` | 1 label |
| `settings_language_helper` | 1 label |
| `settings_language_label` | 1 label |
| `settings_language_save_error` | 1 label |
| `settings_load_error` | 1 label |
| `settings_load_fallback` | 1 label |
| `settings_notifications_helper` | 1 label |
| `settings_notifications_inapp_helper` | 1 label |
| `settings_notifications_inapp_label` | 1 label |
| `settings_notifications_save_error` | 1 label |
| `settings_notifications_title` | 1 label |
| `settings_page_title` | 1 label |
| `settings_server_default` | 1 label |
| `settings_subtitle` | 1 label |
| `settings_timezone_auto_label` | 1 label |
| `settings_timezone_current_label` | 1 label |
| `settings_timezone_helper` | 1 label |
| `settings_timezone_label` | 1 label |
| `settings_timezone_offset_label` | 1 label |
| `settings_timezone_save_error` | 1 label |
| `settings_title` | 1 label |
| `settings_welcome_helper` | 1 label |
| `settings_welcome_show_helper` | 1 label |
| `settings_welcome_show_label` | 1 label |
| `settings_welcome_title` | 1 label |
| `shortcuts_close_aria` | 1 label |
| `shortcuts_desc` | 1 label |
| `shortcuts_doc_edit` | 1 label |
| `shortcuts_doc_save` | 1 label |
| `shortcuts_group_document` | 1 label |
| `shortcuts_group_general` | 1 label |
| `shortcuts_group_list` | 1 label |
| `shortcuts_list_clear` | 1 label |
| `shortcuts_list_new` | 1 label |
| `shortcuts_list_next` | 1 label |
| `shortcuts_list_open` | 1 label |
| `shortcuts_list_prev` | 1 label |
| `shortcuts_search_filter` | 1 label |
| `shortcuts_show_help` | 1 label |
| `shortcuts_title` | 1 label |
| `shortcuts_toggle_assistant` | 1 label |
| `shortcuts_toggle_sidebar` | 1 label |
| `system_settings_adapter_dev` | 1 label |
| `system_settings_adapter_smtp` | 1 label |
| `system_settings_artifact_adapter_filesystem` | 1 label |
| `system_settings_artifact_adapter_helper` | 1 label |
| `system_settings_artifact_adapter_s3` | 1 label |
| `system_settings_artifact_adapter` | 1 label |
| `system_settings_artifact_grant_prune_helper` | 1 label |
| `system_settings_artifact_grant_prune` | 1 label |
| `system_settings_artifact_grant_ttl_helper` | 1 label |
| `system_settings_artifact_grant_ttl_media_helper` | 1 label |
| `system_settings_artifact_grant_ttl_media` | 1 label |
| `system_settings_artifact_grant_ttl` | 1 label |
| `system_settings_artifact_prune_helper` | 1 label |
| `system_settings_artifact_prune` | 1 label |
| `system_settings_assistant_api_key_helper` | 1 label |
| `system_settings_assistant_api_key` | 1 label |
| `system_settings_assistant_auto_tools_helper` | 1 label |
| `system_settings_assistant_auto_tools` | 1 label |
| `system_settings_assistant_endpoint_helper` | 1 label |
| `system_settings_assistant_endpoint` | 1 label |
| `system_settings_assistant_max_history_helper` | 1 label |
| `system_settings_assistant_max_history` | 1 label |
| `system_settings_assistant_max_tokens_helper` | 1 label |
| `system_settings_assistant_max_tokens` | 1 label |
| `system_settings_assistant_model_helper` | 1 label |
| `system_settings_assistant_model` | 1 label |
| `system_settings_assistant_name_helper` | 1 label |
| `system_settings_assistant_name` | 1 label |
| `system_settings_assistant_prompt_helper` | 1 label |
| `system_settings_assistant_prompt` | 1 label |
| `system_settings_assistant_temperature_helper` | 1 label |
| `system_settings_assistant_temperature` | 1 label |
| `system_settings_assistant_test_failed` | 1 label |
| `system_settings_assistant_test_heading` | 1 label |
| `system_settings_assistant_test_note` | 1 label |
| `system_settings_assistant_test_ok` | 1 label |
| `system_settings_assistant_test_send` | 1 label |
| `system_settings_assistant_test_sending` | 1 label |
| `system_settings_assistant_test_sent` | 1 label |
| `system_settings_assistant_test_unsaved` | 1 label |
| `system_settings_auth_mode_helper` | 1 label |
| `system_settings_auth_mode_hybrid` | 1 label |
| `system_settings_auth_mode_oidc_only` | 1 label |
| `system_settings_auth_mode` | 1 label |
| `system_settings_credential_link_ttl_helper` | 1 label |
| `system_settings_credential_link_ttl` | 1 label |
| `system_settings_dirty_count` | 1 label |
| `system_settings_forbidden` | 1 label |
| `system_settings_group_artifacts_note` | 1 label |
| `system_settings_group_artifacts` | 1 label |
| `system_settings_group_assistant_note` | 1 label |
| `system_settings_group_assistant` | 1 label |
| `system_settings_group_localization_note` | 1 label |
| `system_settings_group_localization` | 1 label |
| `system_settings_group_mail_note` | 1 label |
| `system_settings_group_mail` | 1 label |
| `system_settings_group_retention_note` | 1 label |
| `system_settings_group_retention` | 1 label |
| `system_settings_group_security_note` | 1 label |
| `system_settings_group_security` | 1 label |
| `system_settings_keep_forever` | 1 label |
| `system_settings_load_error` | 1 label |
| `system_settings_localization_language_helper` | 1 label |
| `system_settings_localization_language` | 1 label |
| `system_settings_localization_timezone_auto` | 1 label |
| `system_settings_localization_timezone_helper` | 1 label |
| `system_settings_localization_timezone` | 1 label |
| `system_settings_mail_adapter_helper` | 1 label |
| `system_settings_mail_adapter` | 1 label |
| `system_settings_mail_from_address_helper` | 1 label |
| `system_settings_mail_from_address` | 1 label |
| `system_settings_mail_from_name_helper` | 1 label |
| `system_settings_mail_from_name` | 1 label |
| `system_settings_mail_smtp_heading_note` | 1 label |
| `system_settings_mail_smtp_heading` | 1 label |
| `system_settings_mail_smtp_host_helper` | 1 label |
| `system_settings_mail_smtp_host` | 1 label |
| `system_settings_mail_smtp_password_helper` | 1 label |
| `system_settings_mail_smtp_password` | 1 label |
| `system_settings_mail_smtp_port_helper` | 1 label |
| `system_settings_mail_smtp_port` | 1 label |
| `system_settings_mail_smtp_tls_helper` | 1 label |
| `system_settings_mail_smtp_tls` | 1 label |
| `system_settings_mail_smtp_username_helper` | 1 label |
| `system_settings_mail_smtp_username` | 1 label |
| `system_settings_mail_test_failed` | 1 label |
| `system_settings_mail_test_heading` | 1 label |
| `system_settings_mail_test_note` | 1 label |
| `system_settings_mail_test_recipient_helper` | 1 label |
| `system_settings_mail_test_recipient` | 1 label |
| `system_settings_mail_test_send` | 1 label |
| `system_settings_mail_test_sending` | 1 label |
| `system_settings_mail_test_sent` | 1 label |
| `system_settings_mail_test_unsaved` | 1 label |
| `system_settings_mfa_enforcement_always` | 1 label |
| `system_settings_mfa_enforcement_helper` | 1 label |
| `system_settings_mfa_enforcement_preferred` | 1 label |
| `system_settings_mfa_enforcement` | 1 label |
| `system_settings_mfa_type_helper` | 1 label |
| `system_settings_mfa_type_none` | 1 label |
| `system_settings_mfa_type_totp` | 1 label |
| `system_settings_mfa_type` | 1 label |
| `system_settings_nav_aria` | 1 label |
| `system_settings_nav` | 1 label |
| `system_settings_no_changes` | 1 label |
| `system_settings_override_badge` | 1 label |
| `system_settings_page_header` | 1 label |
| `system_settings_page_subtitle` | 1 label |
| `system_settings_page_title` | 1 label |
| `system_settings_provision_roles_add_helper` | 1 label |
| `system_settings_provision_roles_add` | 1 label |
| `system_settings_provision_roles_empty` | 1 label |
| `system_settings_provision_roles_helper` | 1 label |
| `system_settings_provision_roles_remove` | 1 label |
| `system_settings_provision_roles` | 1 label |
| `system_settings_reset_pending` | 1 label |
| `system_settings_reset_title` | 1 label |
| `system_settings_reset_to_file` | 1 label |
| `system_settings_retention_mutations_helper` | 1 label |
| `system_settings_retention_mutations` | 1 label |
| `system_settings_retention_tombstones_helper` | 1 label |
| `system_settings_retention_tombstones` | 1 label |
| `system_settings_save_error` | 1 label |
| `system_settings_saved` | 1 label |
| `system_settings_secret_set` | 1 label |
| `system_settings_secret_unset` | 1 label |
| `system_settings_security_oidc_link` | 1 label |
| `system_settings_undo` | 1 label |
| `table_bool_toggle_aria` | 1 label |
| `table_load_failed` | 1 label |
| `table_pager_aria` | 1 label |
| `table_pager_next_aria` | 1 label |
| `table_pager_page_aria` | 1 label |
| `table_pager_prev_aria` | 1 label |
| `table_range_open` | 1 label |
| `table_range_summary` | 1 label |
| `table_records_empty` | 1 label |
| `table_rows_label` | 1 label |
| `table_select_all_aria` | 1 label |
| `table_select_row_aria` | 1 label |
| `table_selected_count` | 1 label |
| `validation_inactive_currency` | 1 label |
| `validation_invalid_format` | 1 label |
| `validation_invalid_reference_format` | 1 label |
| `validation_invalid_type` | 1 label |
| `validation_out_of_range` | 1 label |
| `validation_read_only` | 1 label |
| `validation_reference_target_not_found` | 1 label |
| `validation_required` | 1 label |
| `validation_reserved` | 1 label |
| `validation_too_long` | 1 label |
| `validation_unique` | 1 label |
| `validation_unknown_field` | 1 label |
| `webhooks_all_events_helper` | 1 label |
| `webhooks_all_events_label` | 1 label |
| `webhooks_calls_button` | 1 label |
| `webhooks_calls_count` | 1 label |
| `webhooks_calls_empty` | 1 label |
| `webhooks_calls_error_label` | 1 label |
| `webhooks_calls_filter_all` | 1 label |
| `webhooks_calls_filter_aria` | 1 label |
| `webhooks_calls_load_error` | 1 label |
| `webhooks_calls_mutation_label` | 1 label |
| `webhooks_calls_newer` | 1 label |
| `webhooks_calls_older` | 1 label |
| `webhooks_calls_response_label` | 1 label |
| `webhooks_create_button` | 1 label |
| `webhooks_create_error` | 1 label |
| `webhooks_delete_button` | 1 label |
| `webhooks_delete_confirm_body` | 1 label |
| `webhooks_delete_confirm_title` | 1 label |
| `webhooks_delete_error` | 1 label |
| `webhooks_edit_button` | 1 label |
| `webhooks_edit_title` | 1 label |
| `webhooks_empty` | 1 label |
| `webhooks_enabled_label` | 1 label |
| `webhooks_events_all` | 1 label |
| `webhooks_events_label` | 1 label |
| `webhooks_events_none` | 1 label |
| `webhooks_events_placeholder` | 1 label |
| `webhooks_header_facet_error` | 1 label |
| `webhooks_header_key_error` | 1 label |
| `webhooks_header_key_label` | 1 label |
| `webhooks_header_value_label` | 1 label |
| `webhooks_headers_add` | 1 label |
| `webhooks_headers_helper` | 1 label |
| `webhooks_headers_label` | 1 label |
| `webhooks_headers_remove` | 1 label |
| `webhooks_label_placeholder` | 1 label |
| `webhooks_load_error` | 1 label |
| `webhooks_loading` | 1 label |
| `webhooks_manager_helper` | 1 label |
| `webhooks_manager_title` | 1 label |
| `webhooks_new_helper` | 1 label |
| `webhooks_new_title` | 1 label |
| `webhooks_page_title` | 1 label |
| `webhooks_replay_button` | 1 label |
| `webhooks_replay_error` | 1 label |
| `webhooks_replay_queued` | 1 label |
| `webhooks_replaying` | 1 label |
| `webhooks_secret_copy_aria` | 1 label |
| `webhooks_secret_label` | 1 label |
| `webhooks_source_helper` | 1 label |
| `webhooks_source_label` | 1 label |
| `webhooks_source_placeholder` | 1 label |
| `webhooks_status_disabled` | 1 label |
| `webhooks_status_enabled` | 1 label |
| `webhooks_subtitle` | 1 label |
| `webhooks_test_button` | 1 label |
| `webhooks_test_error` | 1 label |
| `webhooks_test_helper` | 1 label |
| `webhooks_test_rerun` | 1 label |
| `webhooks_test_response_label` | 1 label |
| `webhooks_test_running` | 1 label |
| `webhooks_test_signed_label` | 1 label |
| `webhooks_test_title` | 1 label |
| `webhooks_test_transport_label` | 1 label |
| `webhooks_title` | 1 label |
| `webhooks_update_error` | 1 label |
| `webhooks_url_helper` | 1 label |
| `webhooks_url_label` | 1 label |
| `welcome_access_art_aria` | 1 label |
| `welcome_access_art_auditor` | 1 label |
| `welcome_access_art_manager` | 1 label |
| `welcome_access_art_sales_rep` | 1 label |
| `welcome_access_body` | 1 label |
| `welcome_access_title` | 1 label |
| `welcome_audit_art_aria` | 1 label |
| `welcome_audit_body` | 1 label |
| `welcome_audit_title` | 1 label |
| `welcome_builder_art_aria` | 1 label |
| `welcome_builder_art_draft` | 1 label |
| `welcome_builder_art_published` | 1 label |
| `welcome_builder_body` | 1 label |
| `welcome_builder_title` | 1 label |
| `welcome_cta_create` | 1 label |
| `welcome_cta_import` | 1 label |
| `welcome_domains_art_aria` | 1 label |
| `welcome_domains_art_crm` | 1 label |
| `welcome_domains_art_hr` | 1 label |
| `welcome_domains_body` | 1 label |
| `welcome_domains_title` | 1 label |
| `welcome_done` | 1 label |
| `welcome_dont_show_again` | 1 label |
| `welcome_integrate_art_api_keys` | 1 label |
| `welcome_integrate_art_aria` | 1 label |
| `welcome_integrate_art_mcp` | 1 label |
| `welcome_integrate_art_oauth` | 1 label |
| `welcome_integrate_art_rest` | 1 label |
| `welcome_integrate_body` | 1 label |
| `welcome_integrate_title` | 1 label |
| `welcome_next` | 1 label |
| `welcome_pitch_art_aria` | 1 label |
| `welcome_pitch_body` | 1 label |
| `welcome_pitch_title` | 1 label |
| `welcome_save_error` | 1 label |
| `welcome_start_art_aria` | 1 label |
| `welcome_start_body` | 1 label |
| `welcome_start_title` | 1 label |

---

Extraction complete. Map each surface to its feature ID in
ledgers/surfaces.md; leave the new-page column to the content WPs.
