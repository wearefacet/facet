# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
# Generates site-docs/src/content/docs/reference/config-keys.md from the YAML
# loaders: src/config.cr plus the per-section loaders it calls
# (src/iam/config.cr, src/emails/config.cr, src/event/config.cr,
# src/assistant/config.cr, src/artifact/config.cr, src/secrets/config.cr,
# src/mutation/config.cr, src/dev/config.cr, src/webhook/config.cr,
# src/jobs/config.cr).
# Run: make gen-docs-config-keys
#
# Mechanism: the loaders are plain code with no runtime registry, so the
# script declares one row per key (section, key, type, default, purpose) and
# then verifies the declared names against the loaders: it extracts every
# `["key"]` subscript read from the loader files and requires an exact
# two-way set match with the declared path segments. Adding, renaming, or
# removing a loader key therefore fails the generation. Type, default, and
# purpose are declared from the loader code and are not mechanically
# verified; `verified_at` stamps the commit they were checked against.
#
# Writes the English page and its French twin under
# site-docs/src/content/docs/fr/reference/. The French prose lives in
# scripts/gen_docs/fr_overlay/config-keys.json (see
# doc/site-docs-fr-style.md). Table cells (sections, keys, types, defaults,
# purposes) stay verbatim English; only the page prose, headings, and column
# headers translate.

require "yaml"
require "./fr_overlay"

REPO_ROOT  = File.expand_path("../..", __DIR__)
PAGE_PATHS = {
  "en" => File.join(REPO_ROOT, "site-docs/src/content/docs/reference/config-keys.md"),
  "fr" => File.join(REPO_ROOT, "site-docs/src/content/docs/fr/reference/config-keys.md"),
}

LOADER_FILES = [
  "src/config.cr",
  "src/iam/config.cr",
  "src/emails/config.cr",
  "src/event/config.cr",
  "src/assistant/config.cr",
  "src/artifact/config.cr",
  "src/secrets/config.cr",
  "src/mutation/config.cr",
  "src/dev/config.cr",
  "src/webhook/config.cr",
  "src/jobs/config.cr",
]

KEY_PATTERN = /\["([a-z_0-9]+)"\]/

record Row, section : String, key : String, type : String, default : String, purpose : String

ROWS = [
  # ── top-level keys ──────────────────────────────────────────────────────
  Row.new("", "host", "string", "\"localhost:3000\"", "Host and port the server binds to; may carry a scheme when a reverse proxy terminates TLS."),
  Row.new("", "base_url", "string", "defaults to host", "Public base URL used to build absolute links."),
  Row.new("", "artifact_base_url", "string", "required", "Origin that serves artifact bytes."),
  Row.new("", "artifact_grant_secret", "string", "required", "Signing key for artifact upload and download grants; may come from the ARTIFACT_GRANT_SECRET env var."),
  Row.new("", "artifact_grant_secret_previous", "string", "—", "Previous grant secret, still accepted during rotation; may come from the ARTIFACT_GRANT_SECRET_PREVIOUS env var."),
  Row.new("", "snapshot_every", "integer", "10", "Mutations between automatic projection snapshots."),
  Row.new("", "trusted_proxies", "string list", "[]", "Reverse-proxy addresses whose X-Forwarded-For chains the server trusts."),
  # ── domains ─────────────────────────────────────────────────────────────
  Row.new("domains", "included", "string list", "[]", "Serve only these domains when set."),
  Row.new("domains", "excluded", "string list", "[]", "Serve every domain except these when set. Mutually exclusive with included."),
  # ── event ───────────────────────────────────────────────────────────────
  Row.new("event", "url", "string", "required", "Redis connection URL for the event bus; the section itself is required."),
  Row.new("event", "partitions", "integer", "16", "Stream partitions (shards) per stream."),
  Row.new("event", "maxlen", "integer", "1000000", "Approximate stream length cap; older entries are trimmed."),
  Row.new("event", "lag_check_cron", "string", "\"*/10 * * * *\"", "Schedule of the consumer-lag check."),
  Row.new("event", "lag_warn_entries", "integer", "100000", "Consumer-group lag that logs a trim-loss warning."),
  Row.new("event.stream", "max_block_time", "number", "2.0", "Longest XREADGROUP block, in seconds."),
  Row.new("event.stream", "min_block_time", "number", "0.1", "Shortest XREADGROUP block, in seconds."),
  Row.new("event.stream", "block_time_delta", "number", "0.7", "Factor the block time adapts by."),
  Row.new("event.stream", "max_messages_count", "integer", "10", "Messages read per XREADGROUP call."),
  # ── iam ─────────────────────────────────────────────────────────────────
  Row.new("iam.jwt", "access_token_ttl", "integer", "900", "Access-token lifetime, in seconds."),
  Row.new("iam.jwt", "refresh_token_ttl", "integer", "1209600", "Refresh-token lifetime, in seconds."),
  Row.new("iam.jwt", "refresh_grace_window", "integer", "10", "Seconds in which a rotated refresh token still passes."),
  Row.new("iam.jwt", "dpop_iat_future_tolerance", "integer", "10", "Accepted DPoP proof iat skew into the future, in seconds."),
  Row.new("iam.jwt", "dpop_iat_past_tolerance", "integer", "30", "Accepted DPoP proof iat skew into the past, in seconds."),
  Row.new("iam.mfa.totp", "enabled", "boolean", "true", "Offer TOTP multi-factor login."),
  Row.new("iam.mfa.totp", "window", "integer", "1", "Accepted TOTP time steps around the current one."),
  Row.new("iam.mfa.totp", "issuer", "string", "\"Facet\"", "Issuer name in the otpauth URI."),
  Row.new("iam.mfa", "enforcement", "string", "\"preferred\"", "MFA enforcement: preferred asks, always blocks un-enrolled logins."),
  Row.new("iam.auth", "mode", "string", "\"hybrid\"", "Login modes: hybrid keeps passwords, oidc_only removes them."),
  Row.new("iam", "change_password_expiration", "integer", "86400", "Lifetime of credential links (reset, invite, first credential), in seconds."),
  Row.new("iam", "secure_cookies", "boolean", "true", "Set the Secure flag on auth cookies; disable only for plain-HTTP dev."),
  Row.new("iam.oidc", "provision_roles", "string[]", "[]", "Roles every OIDC-provisioned account receives when its provider sets no default_role; entries are iam.Roles references."),
  # ── mail ────────────────────────────────────────────────────────────────
  Row.new("mail", "adapter", "string", "\"dev\"", "Delivery adapter: dev prints to stdout, smtp delivers through the smtp sub-object; production refuses dev."),
  Row.new("mail", "from_address", "string", "\"no-reply@facet.local\"", "Sender address for outbound email."),
  Row.new("mail", "from_name", "string", "\"Facet\"", "Display name on the From header."),
  Row.new("mail", "allow_dev_adapter_in_production", "boolean", "false", "Escape hatch that lets the stdout adapter boot in production."),
  Row.new("mail.smtp", "host", "string", "\"localhost\"", "SMTP server hostname; required when the adapter is smtp."),
  Row.new("mail.smtp", "port", "integer", "587", "SMTP server port."),
  Row.new("mail.smtp", "username", "string", "—", "SMTP auth username; empty for open relays."),
  Row.new("mail.smtp", "password", "string", "—", "SMTP auth password."),
  Row.new("mail.smtp", "use_tls", "boolean", "true", "Upgrade the connection with STARTTLS."),
  # ── assistant ───────────────────────────────────────────────────────────
  Row.new("assistant", "name", "string", "\"Assistant\"", "Display name shown on every assistant surface."),
  Row.new("assistant", "api_endpoint", "string", "\"https://api.openai.com/v1\"", "OpenAI-compatible API endpoint."),
  Row.new("assistant", "api_key", "string", "—", "API key for the assistant provider."),
  Row.new("assistant", "model", "string", "\"gpt-4o\"", "Model identifier."),
  Row.new("assistant", "system_prompt", "string", "—", "Default persona prompt."),
  Row.new("assistant", "max_history", "integer", "—", "Conversation turns kept in history; empty means unlimited."),
  Row.new("assistant", "max_tokens", "integer", "—", "Completion token cap; empty means no cap."),
  Row.new("assistant", "temperature", "number", "—", "Sampling temperature, 0.0 to 2.0."),
  Row.new("assistant", "auto_execute_tools", "boolean", "true", "Run registered tools without a confirmation round-trip."),
  Row.new("assistant", "cancel_ttl_seconds", "integer", "15", "TTL of the Redis cancel key for a streaming turn."),
  Row.new("assistant", "turn_timeout_seconds", "integer", "900", "Seconds a running agent turn may stay un-flipped before the sweep marks it failed."),
  Row.new("assistant", "turn_sweep_cron", "string", "\"*/5 * * * *\"", "Schedule of the stale-turn sweep."),
  Row.new("assistant", "usage_retention_days", "integer", "0", "Days to keep the assistant usage ledger; 0 keeps it forever."),
  Row.new("assistant", "usage_prune_cron", "string", "\"30 4 * * *\"", "Schedule of the usage-ledger prune."),
  # ── lua ─────────────────────────────────────────────────────────────────
  Row.new("lua", "instruction_limit", "integer", "1000000", "Lua VM instruction budget per script run."),
  Row.new("lua", "memory_limit_mb", "integer", "32", "Lua VM memory cap, in MB."),
  Row.new("lua", "time_limit_s", "number", "0.5", "Lua VM wall-clock cap, in seconds."),
  # ── hooks ───────────────────────────────────────────────────────────────
  Row.new("hooks", "scheduler_poll_interval_s", "number", "5.0", "Seconds between hook scheduler polls."),
  Row.new("hooks", "lease_ttl_s", "integer", "600", "Hook scheduler lease lifetime, in seconds."),
  # ── mcp ─────────────────────────────────────────────────────────────────
  Row.new("mcp", "max_concurrency_per_sid", "integer", "4", "In-flight MCP dispatches allowed per session id."),
  Row.new("mcp", "max_result_rows", "integer", "200", "Row cap applied to tool queries."),
  Row.new("mcp", "max_response_bytes", "integer", "1048576", "Byte cap applied to serialized tool results."),
  Row.new("mcp", "max_batch_ops", "integer", "25", "Op cap of the batch tool's ops array."),
  # ── sidecar / tombstone / mutations / cache / websocket ─────────────────
  Row.new("sidecar", "reconcile_cron", "string", "\"0 */1 * * *\"", "Schedule of the sidecar orphan-reconciliation task."),
  Row.new("tombstone", "content_retention_days", "integer", "30", "Days a deleted document keeps its payload; 0 keeps it forever."),
  Row.new("tombstone", "prune_cron", "string", "\"15 4 * * *\"", "Schedule of the tombstone content prune."),
  Row.new("mutations", "retention_days", "integer", "180", "Days of mutation history before compaction folds them into a snapshot; 0 keeps history forever."),
  Row.new("mutations", "retention_overrides", "map", "{}", "Per-doctype retention window in days, keyed by domain.Doctype."),
  Row.new("mutations", "compaction_cron", "string", "\"45 3 * * *\"", "Schedule of the mutation compaction pass."),
  Row.new("mutations", "coalesce_window_minutes", "integer", "3", "Window in which same-actor, same-channel updates fold into one mutation; 0 disables."),
  Row.new("cache", "staleness_ttl_s", "integer", "300", "Seconds a process cache may serve data after a lost invalidation fanout; 0 disables the bound."),
  Row.new("websocket.collection", "max_subscribers_per_doctype", "integer", "32", "Cap on collection subscribers per doctype fanout channel."),
  # ── jobs ────────────────────────────────────────────────────────────────
  Row.new("jobs", "poll_interval_s", "number", "5.0", "Seconds the worker waits between claim passes."),
  Row.new("jobs", "lease_ttl_s", "integer", "60", "Seconds a claimed job stays running before the lease sweep requeues it."),
  Row.new("jobs", "long_lease_ttl_s", "integer", "3600", "Lease horizon for long job kinds such as import and export, in seconds."),
  Row.new("jobs", "batch", "integer", "32", "Rows claimed per pass."),
  Row.new("jobs", "sweep_interval_s", "number", "30.0", "Seconds between expired-lease sweeps."),
  Row.new("jobs", "retention_days", "integer", "30", "Days terminal job rows are kept."),
  Row.new("jobs", "enabled", "boolean", "true", "Start the background-job worker."),
  # ── webhook ─────────────────────────────────────────────────────────────
  Row.new("webhook", "timeout_s", "integer", "10", "Connect and read timeout for one outbound POST, in seconds."),
  Row.new("webhook", "max_attempts", "integer", "5", "Delivery attempts before a delivery ends failed."),
  Row.new("webhook", "backoff_seconds", "integer list", "[10, 60, 300, 1800, 7200]", "Retry delays, in seconds."),
  Row.new("webhook", "allow_insecure_urls", "boolean", "false", "Allow non-https webhook targets when true."),
  Row.new("webhook", "allowed_hosts", "string list", "[]", "Target hosts the private-network gate passes even when they resolve private."),
  Row.new("webhook", "reconcile_cron", "string", "\"7 */1 * * *\"", "Schedule of the webhook enqueue reconciler."),
  Row.new("webhook", "reconcile_window_hours", "integer", "24", "How far back the reconciler looks; must stay below jobs.retention_days."),
  # ── secrets ─────────────────────────────────────────────────────────────
  Row.new("secrets", "master_key", "string", "required", "Base64 AES-256 key for the secret store; production supplies it via !env SECRETS_MASTER_KEY."),
  Row.new("secrets", "bcrypt_cost", "integer", "12", "Cost parameter for hash-mode payloads."),
  Row.new("secrets", "staging_ttl_seconds", "integer", "900", "TTL of staged secret handles, in seconds."),
  Row.new("secrets", "prune_after_days", "integer", "30", "Days sealed rows are kept before the prune task deletes them."),
  Row.new("secrets", "prune_cron", "string", "\"45 4 * * *\"", "Schedule of the secret-store prune."),
  # ── import_export ───────────────────────────────────────────────────────────────
  Row.new("import_export", "wait_poll_ms", "integer", "500", "Poll interval of a wait=true import or export request, in milliseconds."),
  Row.new("import_export", "wait_timeout_s", "integer", "30", "Seconds a wait=true request waits before falling back to the enqueue response."),
  Row.new("import_export", "max_import_rows", "integer", "100000", "Row cap of one import file; the job refuses a larger file with the limit named, before any row is written."),
  # ── dev ─────────────────────────────────────────────────────────────────
  Row.new("dev.domain_watch", "path", "string", "required when domain_watch is set", "Watch root: a parent directory whose children are managed bundles."),
  Row.new("dev.domain_watch", "poll_ms", "integer", "500", "Poll interval, in milliseconds; minimum 100."),
  Row.new("dev.domain_watch", "documents", "string", "\"preserve\"", "Retention mode across sync cycles: preserve keeps app-created documents, discard reseeds from the bundle."),
  # ── database ────────────────────────────────────────────────────────────
  Row.new("database", "statement_timeout_ms", "integer", "—", "PostgreSQL statement_timeout on every pooled connection of the server process; absent leaves the PG default."),
  Row.new("database.cluster.databases", "<name>.url", "string", "required", "Connection URL of one physical database."),
  Row.new("database.cluster.databases", "<name>.resources", "string list", "required", "Resources the entry serves: domain ids, $-prefixed subsystem tags, or *."),
  Row.new("database.cluster.databases", "<name>.initial_pool_size", "integer", "—", "Initial pool size; absent leaves the driver default."),
  Row.new("database.cluster.databases", "<name>.max_pool_size", "integer", "—", "Maximum pool size; absent leaves the driver default."),
  Row.new("database.cluster.databases", "<name>.checkout_timeout_s", "number", "—", "Seconds a checkout waits for a free connection; absent leaves the driver default."),
  Row.new("database.cluster.databases", "<name>.replica.url", "string", "required when replica is set", "Read-only replica URL for the entry."),
  Row.new("database.cluster.databases", "<name>.replica.initial_pool_size", "integer", "—", "Initial replica pool size."),
  Row.new("database.cluster.databases", "<name>.replica.max_pool_size", "integer", "—", "Maximum replica pool size."),
  Row.new("database.cluster.databases", "<name>.replica.checkout_timeout_s", "number", "—", "Seconds a replica checkout waits."),
  # ── logs / localization ─────────────────────────────────────────────────
  Row.new("logs", "format", "string", "\"text\"", "Log output format: text or json."),
  Row.new("logs", "level", "string", "\"info\"", "Minimum severity bound to every source."),
  Row.new("localization", "default_timezone", "string", "\"auto\"", "Timezone accounts follow until they pick their own; auto follows each account's browser, any other value must be a loadable IANA name."),
  Row.new("localization", "default_language", "string", "\"en\"", "Language accounts follow until they pick their own; must be in the platform allowlist."),
  # ── artifact ────────────────────────────────────────────────────────────
  Row.new("artifact.storage", "type", "string", "\"filesystem\"", "Object storage backend: filesystem or s3; the storage entry itself is required."),
  Row.new("artifact.storage", "directory", "string", "\"tmp/uploads/dev\"", "Filesystem store directory."),
  Row.new("artifact.storage", "bucket", "string", "—", "S3 bucket; required for s3."),
  Row.new("artifact.storage", "region", "string", "—", "S3 region; required for s3."),
  Row.new("artifact.storage", "access_key_id", "string", "—", "S3 access key; may come from the S3_ACCESS_KEY_ID env var."),
  Row.new("artifact.storage", "secret_access_key", "string", "—", "S3 secret key; may come from the S3_SECRET_ACCESS_KEY env var."),
  Row.new("artifact.storage", "endpoint", "string", "—", "S3-compatible endpoint; may come from the S3_ENDPOINT env var."),
  Row.new("artifact.storage", "public", "boolean", "false", "Serve artifact bytes from a public origin when true."),
  Row.new("artifact", "prune_after_days", "integer", "30", "Days an unreferenced artifact stays eligible before the prune deletes it."),
  Row.new("artifact", "grant_ttl_seconds", "integer", "3600", "Signed download-link TTL for documents and images, in seconds."),
  Row.new("artifact", "grant_ttl_media_seconds", "integer", "21600", "Signed download-link TTL for audio and video, in seconds."),
  Row.new("artifact", "max_upload_bytes", "integer", "52428800", "Hard cap on one upload body, in bytes."),
  Row.new("artifact", "upload_grant_ttl_seconds", "integer", "300", "TTL of a signed upload URL, in seconds."),
  Row.new("artifact", "grant_prune_days", "integer", "7", "Days an expired ephemeral grant row stays before the prune deletes it; zero keeps every expired row forever."),
  Row.new("artifact", "grant_prune_cron", "string", "\"0 5 * * *\"", "Schedule of the expired-grant prune task."),
]

private def esc(text : String) : String
  text.gsub("|", "\\|")
end

# The dot path of a row, used for sorting and for the drift check.
private def row_path(row : Row) : String
  row.section.empty? ? row.key : "#{row.section}.#{row.key}"
end

# Every literal name a row declares: its key plus each section segment.
# A `<placeholder>` segment is a template, not a literal name.
private def declared_names : Set(String)
  names = Set(String).new
  ROWS.each do |row|
    row_path(row).split('.').each do |segment|
      next if segment.starts_with?("<")
      names << segment
    end
  end
  names
end

# Every `["key"]` subscript the loader files read.
private def extracted_names : Set(String)
  names = Set(String).new
  LOADER_FILES.each do |relative|
    text = File.read(File.join(REPO_ROOT, relative))
    text.scan(KEY_PATTERN).each { |match| names << match[1] }
  end
  raise "No key reads extracted from the loader files" if names.empty?
  names
end

private def generate : Nil
  extracted = extracted_names
  declared = declared_names
  missing = (extracted - declared).to_a.sort
  extra = (declared - extracted).to_a.sort
  unless missing.empty?
    raise "Loader keys the page does not declare: #{missing.join(", ")}"
  end
  unless extra.empty?
    raise "Declared names the loaders do not read: #{extra.join(", ")}"
  end

  rows = ROWS.sort_by { |row| {row.section, row.key} }.map do |row|
    "| #{row.section.empty? ? "(root)" : esc(row.section)} | `#{esc(row.key)}` | #{row.type} | #{esc(row.default)} | #{esc(row.purpose)} |"
  end

  # Front-matter and body reproduce the committed English page byte for byte:
  # the sidebar block and the pinned verified_at change only on re-verification.
  en_body = <<-MARKDOWN
  ---
  title: Config file keys
  description: Every config file key with its section, type, and default.
  audience: [operator]
  features: [PLT-01]
  sidebar:
    order: 15
  verified_at: 7af699f3
  ---

  > Generated from `src/config.cr` and the section loaders it calls by `make gen-docs-config-keys`. Do not edit this file by hand.

  Use this page to look up a config key: its section, type, and default.

  The YAML config file (`config.{env}.yml`) is the single source of truth for
  runtime configuration. `APP_ENV` picks the file; `FACET_CONFIG_FILE` names
  an explicit path. A `!env NAME` tag expands an environment variable
  anywhere in the file.

  The loaders read the keys below:

  - An absent key keeps its built-in default.
  - A required key fails the boot when missing.

  | Section | Key | Type | Default | Purpose |
  |---|---|---|---|---|
  #{rows.join("\n")}

  Some values can come from the environment instead of the file:

  - `DATABASE_URL` — the back-compat single connection pool, used when the
    `database.cluster` section is absent.
  - `ARTIFACT_GRANT_SECRET` and `ARTIFACT_GRANT_SECRET_PREVIOUS` — read when
    the matching YAML keys are absent.
  - `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_ENDPOINT` — read when the
    matching `artifact.storage` keys are absent.

    Several keys validate at load and fail the boot on a bad value. Examples:

  - `logs.level` and `logs.format`
  - `iam.mfa.enforcement` and `iam.auth.mode`
  - `webhook.reconcile_window_hours` against `jobs.retention_days`
  - the `secrets.master_key` length

  ## Related

  - [/operate/configuration-files/](/operate/configuration-files/)
  MARKDOWN

  ov = "config-keys"
  fr_body = <<-MARKDOWN
  ---
  title: Clés du fichier de configuration
  description: #{GenDocs::FrOverlay.fetch(ov, "description", "")}
  audience: [operator]
  features: [PLT-01]
  sidebar:
    order: 15
  verified_at: 7af699f3
  ---

  #{GenDocs::FrOverlay.fetch(ov, "generated_note", "")}

  #{GenDocs::FrOverlay.fetch(ov, "intro", "")}

  #{GenDocs::FrOverlay.fetch(ov, "file_intro", "")}

  #{GenDocs::FrOverlay.fetch(ov, "loaders_intro", "")}
  #{GenDocs::FrOverlay.fetch(ov, "rule_absent", "")}
  #{GenDocs::FrOverlay.fetch(ov, "rule_required", "")}

  | #{GenDocs::FrOverlay.fetch(ov, "col_section", "Section")} | #{GenDocs::FrOverlay.fetch(ov, "col_key", "Key")} | #{GenDocs::FrOverlay.fetch(ov, "col_type", "Type")} | #{GenDocs::FrOverlay.fetch(ov, "col_default", "Default")} | #{GenDocs::FrOverlay.fetch(ov, "col_purpose", "Purpose")} |
  |---|---|---|---|---|
  #{rows.join("\n")}

  #{GenDocs::FrOverlay.fetch(ov, "env_intro", "")}

  #{GenDocs::FrOverlay.fetch(ov, "env_database_url", "")}
  #{GenDocs::FrOverlay.fetch(ov, "env_grant_secret", "")}
  #{GenDocs::FrOverlay.fetch(ov, "env_s3", "")}

  #{GenDocs::FrOverlay.fetch(ov, "validation_intro", "")}

  #{GenDocs::FrOverlay.fetch(ov, "validation_logs", "")}
  #{GenDocs::FrOverlay.fetch(ov, "validation_iam", "")}
  #{GenDocs::FrOverlay.fetch(ov, "validation_webhook", "")}
  #{GenDocs::FrOverlay.fetch(ov, "validation_master_key", "")}

  ## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}

  #{GenDocs::FrOverlay.fetch(ov, "related_config_files", "")}
  MARKDOWN

  {"en" => en_body, "fr" => fr_body}.each do |locale, text|
    path = PAGE_PATHS[locale]
    Dir.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
  puts "wrote config-keys.md in en + fr (#{ROWS.size} keys)"
end

generate
