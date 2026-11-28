---
type: reference
title: Limits
description: Every hard limit in Facet with its value, config key, and the code that enforces it.
audience: [admin, operator]
features: []
sidebar:
  order: 21
verified_at: eee55a2
---

An operator plans capacity or debugs a refusal and needs the exact cap and
where it comes from. This page lists every hard limit the engine enforces,
with its value, the config key or constant that carries it, and the source
path and line. Values shown are the defaults; a config file or a System
Settings pin can change the key-driven ones.

## Uploads, imports, and files

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| File artifact upload cap | 52,428,800 bytes (50 MiB); beyond answers `413` | `artifact.max_upload_bytes` | `src/artifact/config.cr:59,92`, `src/artifact/uploader.cr:770` |
| Document import row cap | 100,000 rows | `import_export.max_import_rows` | `src/config.cr:196-199,687` |
| Import reuse of the upload cap | same 50 MiB cap on the domain-import and document-import bodies | `artifact.max_upload_bytes` | `src/domain/portable/routes.cr:240`, `src/import_export/staging.cr:40-42` |
| Import enqueue wait | 30 s | `import_export.wait_timeout_s` | `src/config.cr:196-199` |
| Import enqueue poll | 500 ms | `import_export.wait_poll_ms` | `src/config.cr:196-199` |
| Artifact grant TTL (documents/images) | 3,600 s | `artifact.grant_ttl_seconds` | `src/artifact/config.cr:56-62` |
| Artifact grant TTL (media) | 21,600 s | `artifact.grant_ttl_media_seconds` | `src/artifact/config.cr:56-62` |
| Signed upload URL TTL | 300 s | `artifact.upload_grant_ttl_seconds` | `src/artifact/config.cr:56-62` |

## List and search grammar

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| List page size | default 100, max 1,000 | `MAX_ITEMS` | `src/http/list_request.cr:28-29,95` |
| Unknown list parameter | answered with `422` | — (strict admission) | `src/http/list_request.cr:476` |
| `__in` filter values | max 100 | `MAX_IN_VALUES` | `src/util/filter_set.cr:43`, `src/document/filter_compiler.cr:773` |
| Counted aggregate cap | 1,000 | `COUNT_CAP` | `src/http/responders.cr:604` |
| Artifact sub-list cap (grants, references) | 500 | `Artifact::Admin::SUB_LIST_CAP` | `src/artifact/admin.cr:84` |
| Search results per doctype | 5 | `MAX_PER_DOCTYPE` | `src/search/query.cr:20` |
| Search results overall | 25 | `MAX_TOTAL` | `src/search/query.cr:23` |
| Search composition depth | 8 | `MAX_DEPTH` | `src/search/query.cr:27` |
| `display_name` length | 255 characters | column cap | `src/document/display_name.cr:32` |
| `search` corpus length | 256 characters | column cap | `src/document/search.cr:33` |

## Retention and the change log

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| Mutation (history) retention | 180 days; `0` keeps forever | `mutations.retention_days` (runtime-pinnable) | `src/mutation/config.cr:37-40` |
| Per-doctype retention override | unset (file-only) | `mutations.retention_overrides` | `src/mutation/config.cr:55` |
| Compaction cron | `45 3 * * *` | `mutations.compaction_cron` | `src/mutation/config.cr:61` |
| Update coalescing window | 3 minutes; `0` disables | `mutations.coalesce_window_minutes` | `src/mutation/config.cr:84` |
| Tombstone content retention | 30 days; `0` keeps forever | `tombstone.content_retention_days` (runtime-pinnable) | `src/config.cr:258-260` |
| Tombstone prune cron | `15 4 * * *` | `tombstone.prune_cron` | `src/config.cr:258-260` |
| Periodic snapshot interval | every 10 mutations | `snapshot_every` | `src/config.cr:36` |
| Audit cluster rollback cap | 1,000 mutations | constant | `src/audit/rollback.cr:103` |

## Webhooks and delivery

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| Delivery timeout | 10 s per attempt | `webhook.timeout_s` | `src/webhook/config.cr:42` |
| Delivery attempts | 5, with backoff 10 / 60 / 300 / 1,800 / 7,200 s | `webhook.max_attempts`, `webhook.backoff_seconds` | `src/webhook/config.cr:43-48` |
| Allowed URL scheme | https only by default | `webhook.allow_insecure_urls` | `src/webhook/config.cr:42-48` |
| Allowed hosts | unset (any public host) | `webhook.allowed_hosts` | `src/webhook/config.cr:42-48` |
| Reconcile cron | `7 */1 * * *` | `webhook.reconcile_cron` | `src/webhook/config.cr:42-48` |
| Reconcile window | 24 hours — must stay below `jobs.retention_days`, validated at boot | `webhook.reconcile_window_hours` | `src/webhook/config.cr:42-48`, `src/config.cr:470-478` |

## Jobs, events, and cron

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| Job row retention | 30 days | `jobs.retention_days` | `src/jobs/config.cr:31-37` |
| Job lease TTL | 60 s | `jobs.lease_ttl_s` | `src/jobs/config.cr:31-37` |
| Long job lease TTL | 3,600 s | `jobs.long_lease_ttl_s` | `src/jobs/config.cr:31-37` |
| Job batch size | 32 | `jobs.batch` | `src/jobs/config.cr:31-37` |
| Event stream maxlen | 1,000,000 entries | `event.stream.maxlen` | `src/event/config.cr:35-38` |
| Event partitions | 16, max 32 | `event.stream.partitions` | `src/event/config.cr:35-38` |
| Event lag warn threshold | 100,000 entries | `event.stream.lag_warn_entries` | `src/event/config.cr:35-38` |

## Database and MCP

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| Statement timeout | unset (no timeout) by default | `database.statement_timeout_ms` | `src/config.cr:88-90`, `src/database.cr:154-167` |
| Statement timeout answer | `503` on aggregate paths | — | `src/http/responders.cr:107`, `src/http/rest_routes.cr:217-219` |
| MCP result rows | 200 (clamps agent `items`) | `mcp.max_result_rows` | `src/config.cr:218-222`, `src/agent_tools/history.cr:249` |
| MCP response bytes | 1,048,576 (post-serialization) | `mcp.max_response_bytes` | `src/config.cr:218-222`, `src/agent_tools/caps.cr:34` |
| MCP batch ops | 25 (raises `Capped`) | `mcp.max_batch_ops` | `src/config.cr:218-222`, `src/agent_tools/write.cr:359` |
| MCP concurrency per session | 4 | `mcp.max_concurrency_per_sid` | `src/config.cr:218-222` |
| MCP query duration | bounded by the shared statement timeout | `database.statement_timeout_ms` | `src/config.cr:213` |
| Cache staleness TTL | 300 s | `cache.staleness_ttl_s` | `src/config.cr:286` |
| WebSocket collection subscribers | 32 per doctype | `websocket.max_subscribers_per_doctype` | `src/config.cr:301` |
| WebSocket mailbox | 64 messages | constant | `src/websocket/connection.cr:76` |

## Lua sandbox

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| Instruction budget | 1,000,000 | engine default | `src/lua/engine.cr:82-84` |
| Memory budget | 32 MB | engine default | `src/lua/engine.cr:82-84` |
| Time budget | 0.5 s | engine default | `src/lua/engine.cr:82-84` |

The `lua:` config section loads (`src/config.cr:168-171,603-612`), but the
sandbox does not read it — `src/lua/sandbox.cr:33-35` always constructs the
engine with the defaults above. Raising the keys changes nothing until the
wiring lands. Logged as discrepancy #28.

## Assistant

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| Token budget window | rolling 30 days | `WINDOW_DAYS` | `src/assistant/limits.cr:27` |
| Token budget | max over enabling roles; unset = unlimited | role `assistant_token_budget` | `src/assistant/access.cr:81-100` |
| Usage ledger retention | 0 (never) by default; 31+ days is safe | `assistant.usage_retention_days` (runtime-pinnable) | `src/assistant/config.cr:63-71,89` |
| Turn timeout | 900 s | `assistant.turn_timeout_seconds` | `src/assistant/config.cr:86-87` |
| Cancel signal TTL | 15 s | `assistant.cancel_ttl_seconds` | `src/assistant/config.cr:86-87` |
| Conversation title cap | 120 characters | constant | `src/assistant/routes.cr:65` |
| Auto-title source cap | 60 characters | constant | `src/assistant/title.cr:16` |

## Identity and security

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| Password minimum length | 8 characters | constant | `src/iam/routes.cr:828` |
| Password lockout threshold | 10 failed attempts per account, 300 s window | `MAX_PWD_ATTEMPTS` | `src/iam/login.cr:40-51`, `src/iam/login_throttle.cr:94` |
| IP lockout threshold | 20 failed attempts per IP, 300 s window | `MAX_IP_ATTEMPTS` | `src/iam/login.cr:40-51`, `src/iam/login_throttle.cr:116` |
| MFA challenge issue cap | 5 challenges, 300 s window | `MAX_CHALLENGE_ISSUES` | `src/iam/login.cr:40-51`, `src/iam/login_throttle.cr:140` |
| Change-password throttle | 5 failures in 300 s | `MAX_CHANGE_PASSWORD_ATTEMPTS` | `src/iam/routes.cr` (login throttle), `src/iam/login_throttle.cr` |
| API key name length | 100 characters | constant | `src/iam/api_key.cr:49` |
| Access token TTL | 900 s | `iam.access_token_ttl` | `src/iam/config.cr:66-69` |
| Refresh token TTL | 1,209,600 s (14 days) | `iam.refresh_token_ttl` | `src/iam/config.cr:66-69` |
| Refresh token grace | 10 s | `iam.refresh_grace_seconds` | `src/iam/config.cr:66-69` |
| DPoP `iat` window | −10 s / +30 s | constants | `src/iam/config.cr:66-69` |
| Credential link TTL | 86,400 s (24 h) | `iam.change_password_expiration` (runtime-pinnable) | `src/iam/config.cr:62` |
| OAuth token rate limit | 30 requests per 300 s per (client, IP) | `DEFAULT_CAP` | `src/oauth/rate_limiter.cr:56-62` |
| Secret master key | ≥ 32 decoded bytes | `secrets.master_key` | `src/secrets/config.cr:35` |
| bcrypt cost | 12 | `secrets.bcrypt_cost` | `src/secrets/config.cr:44-48` |
| Secret staging TTL | 900 s | `secrets.staging_ttl` | `src/secrets/config.cr:44-48` |

## Indexes and identifiers

| Limit | Value | Config key / constant | Source |
| --- | --- | --- | --- |
| Index identifier length | 63 characters | constant | `src/index/naming.cr:15` |
| Index DDL retries | 3 | constant | `src/index/manager.cr:47` |
| Dev domain watch poll floor | 100 ms | `dev.domain_watch.poll_ms` | `src/dev/config.cr:66` |

## Runtime-pinnable keys

A subset of these limits is also a `core.SystemSettings` path, so an operator
pins it from the settings page without a redeploy: `mutations.retention_days`,
`tombstone.content_retention_days`, `artifact.grant_prune_days`,
`artifact.grant_ttl_seconds`, `artifact.grant_ttl_media_seconds`,
`artifact.prune_after_days`, the assistant knobs (`max_tokens`, `max_history`,
`temperature`), and `iam.change_password_expiration`. The full list lives in
`src/system_settings/spec.cr:108-190`. The config file stays the fallback
for every pinned key.

## Related

- [Configuration files](/admin/configure/configuration-files/) — every config section and key.
- [System settings](/admin/configure/system-settings/) — the runtime-pinnable keys.
- [Monitoring](/admin/keep-running/monitoring/) — the health probe and metrics these limits feed.
- [Retention](/admin/history/retention/) — the retention windows in context.
