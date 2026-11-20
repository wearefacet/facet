# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"
require "log"
require "./util/money"
require "./util/yaml_include"
require "./database/cluster_config"
require "./settings/keys"
require "./event/config"
require "./assistant/config"
require "./artifact/config"
require "./secrets/config"
require "./iam/config"
require "./emails/config"
require "./mutation/config"
require "./dev/config"
require "./webhook/config"
require "./jobs/config"

module Facet
  # Loads environment configuration from `config.#{APP_ENV}.yml`.
  #
  # The config file is the single source of truth for all runtime settings.
  # Environment variables override specific values at the edges (e.g. secrets)
  # but the structure is always driven by the YAML file.
  #
  # ## Golden rule
  #
  # Redis is a required dependency. The `event:` section must be present in
  # `config.{env}.yml` and contain a valid `url`. Without Redis, the system
  # cannot function — the event publisher will raise on flush.
  class Config
    # ── Schema ──────────────────────────────────────────────────────────

    getter snapshot_every : Int32
    getter iam : IAMConfig
    getter event : Event::Config
    getter host : String
    getter base_url : String
    getter artifact_base_url : String
    getter artifact_grant_secret : String
    getter artifact_grant_secret_previous : String?
    getter artifact : Facet::Artifact::Config
    getter domains : DomainsConfig
    getter mail : MailConfig
    getter assistant : Facet::Assistant::Config
    getter lua : LuaConfig
    getter hooks : HooksConfig
    getter jobs : JobsConfig
    getter webhook : WebhookConfig
    getter mcp : MCPConfig
    getter sidecar : SidecarConfig
    getter tombstone : TombstoneConfig
    getter mutations : MutationsConfig
    getter cache : CacheConfig
    getter websocket : WebsocketConfig
    getter secrets : Facet::Secrets::Config
    getter import_export : ImportExportConfig
    getter dev : DevConfig
    getter database : DatabaseConfig
    getter logs : LogsConfig
    getter localization : LocalizationConfig

    # Addresses of the reverse proxies that face this server (the optional
    # top-level `trusted_proxies:` list, default empty). The client-IP
    # resolver (`Util::ClientIp.resolve`) reads this list: a request whose
    # socket peer is on it may carry a trusted `X-Forwarded-For` chain,
    # and the resolver returns the first untrusted hop; every other
    # request keeps its socket host, and the header is ignored. An entry
    # can choose the client IP the server sees — keep the list exact.
    # Entries are bare hosts: no port, no brackets.
    getter trusted_proxies : Array(String)

    # ── Database Config ──────────────────────────────────────────────────

    # The optional `database:` section. `statement_timeout_ms` is applied as
    # the PostgreSQL session `statement_timeout` on every pooled connection
    # of the server process (see `Database.init`). `nil` — the section or
    # key absent — leaves the PG default (no timeout). CLI entry points
    # never pass it, so long-running migration DDL and reproject workers
    # cannot be cancelled.
    #
    # `cluster` holds the parsed `database.cluster:` section — the route
    # table grammar (see `Facet::Database::ClusterConfig`). `nil` — the
    # section absent — is the back-compat shape: one pool from DATABASE_URL,
    # no separate read-only pool, no read-only enforcement.
    record DatabaseConfig,
      statement_timeout_ms : Int32? = nil,
      cluster : Database::ClusterConfig? = nil

    # ── Logging Config ─────────────────────────────────────────────────

    # The optional `logs:` section. Drives the explicit log setup
    # (`Facet::Logging.setup`, called from `CLI.run`) — the app's own log
    # binding, replacing the env-driven one the shrine shard performs at
    # require time.
    #
    # - `format` — "text" (stdlib `Log::ShortFormat`, the historical
    #   output) or "json" (one JSON object per line).
    # - `level` — the minimum severity bound to every source
    #   (trace … fatal). Parsed case-insensitively.
    #
    # Both keys are validated at load — see `load_logs`.
    record LogsConfig,
      format : String = "text",
      level : String = "info"

    # ── Domain Config ──────────────────────────────────────────────────────

    # Controls which domains this server instance handles.
    #
    # - If `included` is non-empty, only those domains are active.
    # - If `excluded` is non-empty, all domains *except* those are active.
    # - If both are empty, all domains are active (default).
    # - `included` and `excluded` are **mutually exclusive** — if both are
    #   non-empty, a hard error is raised at config load time.
    #
    # When a domain is excluded, endpoints for that domain return 404
    # and WebSocket subscriptions to that domain are rejected.
    record DomainsConfig,
      included : Array(String) = [] of String,
      excluded : Array(String) = [] of String

    # Returns true if the given domain should be handled by this instance.
    def domain_enabled?(domain : String) : Bool
      if @domains.included.empty?
        # No inclusion list → all domains are enabled unless excluded
        !@domains.excluded.includes?(domain)
      else
        # Inclusion list is authoritative
        @domains.included.includes?(domain)
      end
    end

    # The public-facing base URL with a scheme, derived from `host`.
    #
    # `host` may carry a scheme (e.g. `https://localhost:3443` when a reverse
    # proxy terminates TLS in front of Kemal) or be scheme-less
    # (`localhost:3000`). This accessor normalizes both forms so callers never
    # have to inline the scheme check — use it whenever a fully-qualified
    # public URL is needed (outbound email links, signed-URL issuers, etc.).
    # When `host` is scheme-less the scheme defaults to `https`.
    def scheme_base_url : String
      return @host if @host.starts_with?("http://") || @host.starts_with?("https://")
      "https://#{@host}"
    end

    # ── Localization records ─────────────────────────────────────────
    #
    # The instance defaults an account falls back to when it has not set
    # its own timezone or language (`localization.default_timezone`,
    # `localization.default_language`). Both are hot keys: the effective
    # values resolve through `core.SystemSettings` (`SystemSettings::SPEC`),
    # and the account-settings service reads them as the server tier of
    # its default chain — see `doc/backend/settings.md`.
    record LocalizationConfig,
      default_timezone : String = "UTC",
      default_language : String = "en"

    # ── Lua sandbox limits ──────────────────────────────────────────────

    record LuaConfig,
      instruction_limit : Int32 = 10_000_000,
      memory_limit_mb : Int32 = 100,
      time_limit_s : Float64 = 5.0

    # ── Hooks (domain event/schedule hooks) ──────────────────────────────
    #
    # Tuning for `Hooks::Scheduler`. Returns the defaults when the `hooks:`
    # section is absent — the section is optional; only domains that declare
    # hook entries on `core.Domain.definition.content.hooks` consume it.
    record HooksConfig,
      scheduler_poll_interval_s : Float64 = 5.0,
      lease_ttl_s : Int32 = 600

    # ── Import/export (document CSV + JSON portability) ──────────────
    #
    # Tuning for the wait mode and the row-count guard of the
    # import/export enqueue routes. The section is optional in
    # `config.{env}.yml` — the defaults apply when it is absent.
    #
    # - `wait_poll_ms` — how often a `wait=true` request polls the job row.
    # - `wait_timeout_s` — how long a `wait=true` request waits before
    #   falling back to the `202` enqueue-mode body. The job keeps
    #   running; the wait never cancels it.
    # - `max_import_rows` — the row cap of one import file. The whole
    #   file applies as one transaction, so the cap bounds the write
    #   volume one API call can pin; an import above the cap fails in the
    #   job with the limit named, before any row is written.
    record ImportExportConfig,
      wait_poll_ms : Int32 = 500,
      wait_timeout_s : Int32 = 30,
      max_import_rows : Int32 = 100_000

    # ── MCP (Model Context Protocol) resource-server limits ─────────────
    #
    # Governance knobs for the `/Api/_mcp/:role_slug` surface. The section
    # is optional in `config.{env}.yml` — defaults keep the endpoint usable
    # without configuration.
    #
    # - `max_concurrency_per_sid` — cap on in-flight MCP dispatches per
    #   session id. A request over the cap waits for a slot rather than
    #   failing, bounding pool pressure from parallel agent traffic.
    # - `max_result_rows` / `max_response_bytes` — wired via
    #   `Tools::Read.items_arg` / `Tools::History.items_arg` and
    #   `Tools::Caps.apply_response_caps`. Query duration is bounded by the
    #   shared pool's `database.statement_timeout_ms` — MCP has no
    #   dedicated DB pool.
    # - `max_batch_ops` — the op-count cap of the `batch` tool's `ops`
    #   array (default 25). Over the cap the tool raises `Capped` before
    #   any transaction opens.
    record MCPConfig,
      max_concurrency_per_sid : Int32 = 4,
      max_result_rows : Int32 = 200,
      max_response_bytes : Int32 = 1_048_576,
      max_batch_ops : Int32 = 25

    # ── Sidecar (cross-doctype nested records) ──────────────────────────
    #
    # Tuning for the sidecar orphan-reconciliation cron task. The section
    # is optional in `config.{env}.yml` — the defaults keep the subsystem
    # usable without configuration.
    #
    # - `reconcile_cron` — the cron expression that schedules
    #   `Cron::SidecarReconcile`. Defaults to hourly (`"0 */1 * * *"`):
    #   minute 0 of every hour. The event-driven `SidecarSweep` subscriber
    #   handles the common path (host soft-delete tombstones the sidecars
    #   immediately); this cron is the backstop for orphans the sweep missed
    #   (a sweep delivery lost between Redis and the consumer, a host row
    #   hard-deleted by a maintenance script, etc.).
    record SidecarConfig,
      reconcile_cron : String = "0 */1 * * *"

    # ── Tombstone content retention ─────────────────────────────────────
    #
    # Tuning for the tombstone content prune cron task. The section is
    # optional in `config.{env}.yml` — the defaults keep the subsystem
    # usable without configuration.
    #
    # A delete tombstone keeps its `content`/`links`/`search` payload so
    # per-emit RBAC checks (e.g. WebSocket collection subscriptions) can
    # scope-evaluate `deleted` events. Clearing the payload is a storage
    # concern only, so the prune runs on a slow schedule.
    #
    # - `content_retention_days` — how many days a tombstone keeps its
    #   payload before `Cron::TombstoneContentPrune` clears
    #   `content`/`links`/`search`. Defaults to 30. `0` keeps every
    #   payload forever — the prune skips.
    # - `prune_cron` — the cron expression that schedules the prune task.
    #   Defaults to daily at 04:15 (`"15 4 * * *"`), offset from the
    #   sidecar reconcile runs at minute 0.
    record TombstoneConfig,
      content_retention_days : Int32 = 30,
      prune_cron : String = "15 4 * * *"

    # Returns the retention window in days for one doctype: the
    # `retention_overrides` entry for `domain.Doctype` when present,
    # otherwise `retention_days`.
    def retention_days_for(domain : String, doc_type : String) : Int32
      @mutations.retention_overrides["#{domain}.#{doc_type}"]? || @mutations.retention_days
    end

    # ── Process-cache staleness bound ──────────────────────────────────
    #
    # Safety net for the invalidate-only process caches (doctype
    # definitions, OAuth origins, app hosts, the replication / hooks /
    # webhook registries, the currency registry). The Redis Pub/Sub fanout
    # is the fast invalidation path; `staleness_ttl_s` caps how long a
    # cache may serve data when a fanout is lost — for example a mutation
    # published while Redis was down. Without the bound such a cache would
    # serve the old data until restart.
    #
    # - Defaults to 300 s: worst-case staleness of five minutes, at the
    #   cost of one cheap rebuild query per cache per window per instance.
    # - `0` disables the bound — the fanout is then the only invalidation.
    # - Negative values fail loud at load (`load_cache`).
    #
    # Consumed through `Util::CacheFreshness`.
    record CacheConfig,
      staleness_ttl_s : Int32 = 300

    # ── WebSocket (real-time bridge) ────────────────────────────────────
    #
    # Tuning for the WebSocket bridge. The section is optional in
    # `config.{env}.yml` — the defaults keep the subsystem usable without
    # configuration.
    #
    # - `collection.max_subscribers_per_doctype` — hard cap on collection
    #   subscribers per `{domain}.{doctype}` fanout channel. A `subscribe`
    #   frame that would push the channel past the cap is rejected with an
    #   error frame; the socket stays open and the client may retry. The
    #   cap bounds the per-emit RBAC cost of collection subscriptions
    #   (see `doc/backend/websocket.md`).
    record WebsocketCollectionConfig,
      max_subscribers_per_doctype : Int32 = 32

    record WebsocketConfig,
      collection : WebsocketCollectionConfig = WebsocketCollectionConfig.new

    def initialize(*, @snapshot_every : Int32 = 25,
                   @iam : IAMConfig = IAMConfig.new,
                   @event : Event::Config = Event::Config.new,
                   @host : String = "localhost:3000",
                   @base_url : String = "localhost:3000",
                   @artifact_base_url : String = "localhost:3001",
                   @artifact_grant_secret : String = "",
                   @artifact_grant_secret_previous : String? = nil,
                   @artifact : Facet::Artifact::Config = Facet::Artifact::Config.new,
                   @domains : DomainsConfig = DomainsConfig.new,
                   @mail : MailConfig = MailConfig.new,
                   @assistant : Facet::Assistant::Config = Facet::Assistant::Config.new,
                   @lua : LuaConfig = LuaConfig.new,
                   @hooks : HooksConfig = HooksConfig.new,
                   @mcp : MCPConfig = MCPConfig.new,
                   @sidecar : SidecarConfig = SidecarConfig.new,
                   @tombstone : TombstoneConfig = TombstoneConfig.new,
                   @mutations : MutationsConfig = MutationsConfig.new,
                   @cache : CacheConfig = CacheConfig.new,
                   @websocket : WebsocketConfig = WebsocketConfig.new,
                   @jobs : JobsConfig = JobsConfig.new,
                   @webhook : WebhookConfig = WebhookConfig.new,
                   @secrets : Facet::Secrets::Config = Facet::Secrets::Config.new,
                   @import_export : ImportExportConfig = ImportExportConfig.new,
                   @dev : DevConfig = DevConfig.new,
                   @database : DatabaseConfig = DatabaseConfig.new,
                   @logs : LogsConfig = LogsConfig.new,
                   @localization : LocalizationConfig = LocalizationConfig.new,
                   @trusted_proxies : Array(String) = [] of String,)
      if !@domains.included.empty? && !@domains.excluded.empty?
        raise "Domains config error: 'included' and 'excluded' are mutually exclusive. " \
              "Set only one of them, or leave both empty to serve all domains."
      end

      # Artifacts: the grant secret and the artifact origin are hard-required.
      # An empty secret would silently sign URLs with "", leaking bytes to
      # anyone who can guess an empty HMAC — fail loud at config load time.
      if @artifact_grant_secret.empty?
        raise "Missing required config key 'artifact_grant_secret'. " \
              "Set it in config.{env}.yml or via the ARTIFACT_GRANT_SECRET env var."
      end
    end

    # ── Singleton ───────────────────────────────────────────────────────

    @@instance : Config?

    def self.instance : Config
      @@instance ||= load
    end

    # Replaces the cached config singleton. Used by specs that need to
    # exercise config-driven tolerance windows (e.g. DPoP `iat` skew) with
    # bespoke values without rebuilding the YAML file. Production code
    # never calls this — `reset!` is the proper way to invalidate the cache.
    def self.instance=(config : Config) : Config
      @@instance = config
      config
    end

    # Reloads the config from disk (useful in tests).
    def self.reset! : Nil
      @@instance = nil
    end

    # Loads config from `config.#{APP_ENV}.yml`. The file must exist — a
    # missing environment file raises instead of falling back to another
    # environment's config (dev keys, insecure cookies, stdout mail).
    # Parsing goes through `Util::YamlInclude.parse_string` with the `!env`
    # handler so `!env NAME` scalars expand to environment variables at load
    # time (secrets stay out of the checked-in YAML). A missing variable
    # raises at load. The `!env?` handler is the optional tier: an unset
    # variable collapses the key to null and the consuming section applies
    # its own default (the AI Assistant's posture — absent vars mean the
    # assistant ships disabled, not a failed boot).
    def self.load(path : String? = nil) : Config
      path ||= resolve_config_path
      raw = Util::YamlInclude.parse_string(
        File.read(path),
        [Util::YamlTag::EnvTag.new, Util::YamlTag::EnvOptTag.new],
        source_file: path,
      )
      from_yaml_node(raw)
    end

    # Parses a YAML document into a `Config`. Separated from `load` so specs
    # can construct a `Config` from an in-memory YAML string (via
    # `YAML.parse`) and exercise the fail-loud paths without writing a
    # temporary file to disk.
    def self.from_yaml_node(raw : YAML::Any) : Config
      snapshot_every = raw["snapshot_every"]?.try(&.as_i) || 25
      iam_config = load_iam(raw)
      event_config = load_event(raw)
      host = raw["host"]?.try(&.as_s) || "localhost:3000"
      base_url = read_str(raw["base_url"]?) || host
      artifact_base_url = read_str(raw["artifact_base_url"]?) || raise(
        "Missing required config key 'artifact_base_url'. " \
        "Add an 'artifact_base_url:' entry to config.{env}.yml pointing at the " \
        "separate origin that serves artifact bytes (e.g. 'https://cdn.example.tld')."
      )
      artifact_grant_secret = read_str_or_env(raw["artifact_grant_secret"]?,
        "ARTIFACT_GRANT_SECRET") || ""
      artifact_grant_secret_previous = read_str_or_env(raw["artifact_grant_secret_previous"]?,
        "ARTIFACT_GRANT_SECRET_PREVIOUS")
      artifact_config = load_artifact(raw)

      domains_config = load_domains(raw)
      mail_config = load_mail(raw)
      validate_mail_adapter(mail_config)
      assistant_config = load_assistant(raw)
      lua_config = load_lua(raw)
      hooks_config = load_hooks(raw)
      mcp_config = load_mcp(raw)
      sidecar_config = load_sidecar(raw)
      tombstone_config = load_tombstone(raw)
      mutations_config = load_mutations(raw)
      cache_config = load_cache(raw)
      websocket_config = load_websocket(raw)
      jobs_config = load_jobs(raw)
      webhook_config = load_webhook(raw)
      secrets_config = load_secrets(raw)
      import_export_config = load_import_export(raw)
      dev_config = load_dev(raw)
      database_config = load_database(raw)
      logs_config = load_logs(raw)
      localization_config = load_localization(raw)
      trusted_proxies = load_trusted_proxies(raw)

      config = new(
        snapshot_every: snapshot_every,
        iam: iam_config,
        event: event_config,
        host: host,
        base_url: base_url,
        artifact_base_url: artifact_base_url,
        artifact_grant_secret: artifact_grant_secret,
        artifact_grant_secret_previous: artifact_grant_secret_previous,
        artifact: artifact_config,
        domains: domains_config,
        mail: mail_config,
        assistant: assistant_config,
        lua: lua_config,
        hooks: hooks_config,
        mcp: mcp_config,
        sidecar: sidecar_config,
        tombstone: tombstone_config,
        mutations: mutations_config,
        cache: cache_config,
        websocket: websocket_config,
        jobs: jobs_config,
        webhook: webhook_config,
        secrets: secrets_config,
        import_export: import_export_config,
        dev: dev_config,
        database: database_config,
        logs: logs_config,
        localization: localization_config,
        trusted_proxies: trusted_proxies,
      )

      # Cross-section constraint: the webhook reconcile window must stay
      # inside the jobs retention horizon. `background_jobs` rows are the
      # reconciler's dedupe authority — a window wider than retention
      # would re-enqueue delivered events whose rows are gone.
      retention_hours = jobs_config.retention_days * 24
      if webhook_config.reconcile_window_hours >= retention_hours
        raise ArgumentError.new(
          "webhook.reconcile_window_hours (#{webhook_config.reconcile_window_hours}) must stay below " \
          "jobs.retention_days (#{jobs_config.retention_days} days = #{retention_hours} hours): " \
          "terminal webhook_delivery rows are pruned after retention, and a wider reconcile window " \
          "would re-enqueue delivered events whose job rows are gone."
        )
      end

      config
    end

    # Resolves the config file path for the current environment. Fails loud
    # when `config.#{APP_ENV}.yml` does not exist — silently booting with
    # `config.dev.yml` would run prod with the dev master key, dev grant
    # secret, insecure cookies, and stdout mail.
    #
    # `FACET_CONFIG_FILE` wins when set: the explicit path an operator
    # points at a mounted file (container deploys, read-only mounts) or a
    # non-container boot that keeps configuration outside the binary tree.
    # A set-but-missing path fails loud with the path in the message —
    # falling back to the default resolution would boot with the wrong
    # file. Unset keeps the existing resolution.
    private def self.resolve_config_path : String
      if explicit = ENV["FACET_CONFIG_FILE"]?
        unless File.exists?(explicit)
          raise "FACET_CONFIG_FILE is set but the file does not exist: '#{explicit}'. " \
                "Mount or create the file, or unset FACET_CONFIG_FILE to use " \
                "'config.#{app_env}.yml' next to the binary."
        end
        return explicit
      end

      env = app_env
      path = File.join(__DIR__, "..", "config.#{env}.yml")

      unless File.exists?(path)
        raise "Missing config file for APP_ENV=#{env}: no such file '#{path}'. " \
              "Create 'config.#{env}.yml' (copy an existing config as a starting point) " \
              "or set APP_ENV to an environment that has a config file."
      end

      path
    end

    # Parses the event config from the YAML document.
    private def self.load_event(raw : YAML::Any) : Event::Config
      event_raw = raw["event"]?
      raise "Missing 'event' key in config — Redis is required. " \
            "Add an 'event:' section with at least a 'url' key." if event_raw.nil? || event_raw.raw.nil?

      Event::Config.from_yaml(event_raw)
    end

    # Parses the localization section. Both keys are validated at load —
    # fail closed like the mail adapter and the MFA enforcement: a timezone
    # the runtime cannot load and a language outside the allowlist would
    # otherwise surface as broken rendering for every account that follows
    # the server default.
    private def self.load_localization(raw : YAML::Any) : LocalizationConfig
      loc_raw = raw["localization"]?
      return LocalizationConfig.new if loc_raw.nil? || loc_raw.raw.nil?

      timezone = loc_raw["default_timezone"]?.try(&.as_s) || "UTC"
      begin
        Time::Location.load(timezone)
      rescue ex
        raise ArgumentError.new(
          "localization.default_timezone '#{timezone}' is not a loadable IANA timezone (#{ex.message})"
        )
      end

      language = loc_raw["default_language"]?.try(&.as_s) || "en"
      unless Facet::Settings::Keys::ALLOWED_LANGUAGES.includes?(language)
        raise ArgumentError.new(
          "localization.default_language '#{language}' is not in the allowed set " \
          "(#{Facet::Settings::Keys::ALLOWED_LANGUAGES.to_a.sort.join(", ")})"
        )
      end

      LocalizationConfig.new(default_timezone: timezone, default_language: language)
    end

    # Parses the top-level `trusted_proxies:` list. Returns an empty list
    # when the key is absent — every environment then keeps its socket
    # host and ignores `X-Forwarded-For` (see `Util::ClientIp.resolve`).
    # An entry that trims to nothing fails the load: a silent empty entry
    # would read as "trust nothing" and hide a proxy that was meant to be
    # listed.
    private def self.load_trusted_proxies(raw : YAML::Any) : Array(String)
      value = raw["trusted_proxies"]?
      return [] of String if value.nil? || value.raw.nil?

      entries = value.as_a
      list = entries.compact_map do |entry|
        text = entry.as_s?.to_s.strip
        text.empty? ? nil : text
      end
      raise ArgumentError.new("trusted_proxies entries must be non-empty strings") if list.size != entries.size
      list
    end

    # Parses the domains config from the YAML document. The mutual-exclusion
    # check for `included` and `excluded` lives in `initialize`, so direct
    # construction gets the same guard as a parsed file.
    private def self.load_domains(raw : YAML::Any) : DomainsConfig
      domains_raw = raw["domains"]?
      return DomainsConfig.new if domains_raw.nil? || domains_raw.raw.nil?

      included = domains_raw["included"]?.try do |arr|
        arr.as_a.map(&.as_s)
      end || [] of String

      excluded = domains_raw["excluded"]?.try do |arr|
        arr.as_a.map(&.as_s)
      end || [] of String

      DomainsConfig.new(included: included, excluded: excluded)
    end

    # Parses the assistant config from the YAML document. Returns the default
    # config when the `assistant:` section is absent — assistant features are
    # optional and must not break config loading for runs that don't use them.
    private def self.load_assistant(raw : YAML::Any) : Facet::Assistant::Config
      Facet::Assistant::Config.from_yaml(raw["assistant"]?)
    end

    # Parses the Lua sandbox config from the YAML document. Returns the default
    # config when the `lua:` section is absent.
    private def self.load_lua(raw : YAML::Any) : LuaConfig
      lua_raw = raw["lua"]?
      return LuaConfig.new if lua_raw.nil? || lua_raw.raw.nil?

      LuaConfig.new(
        instruction_limit: read_int(lua_raw["instruction_limit"]?, 10_000_000),
        memory_limit_mb: read_int(lua_raw["memory_limit_mb"]?, 100),
        time_limit_s: read_float(lua_raw["time_limit_s"]?, 5.0),
      )
    end

    # Parses the hooks scheduler config from the YAML document. Returns the
    # default config when the `hooks:` section is absent — the section is
    # optional and only consumed by `Hooks::Scheduler`.
    private def self.load_hooks(raw : YAML::Any) : HooksConfig
      hooks_raw = raw["hooks"]?
      return HooksConfig.new if hooks_raw.nil? || hooks_raw.raw.nil?

      HooksConfig.new(
        scheduler_poll_interval_s: read_float(hooks_raw["scheduler_poll_interval_s"]?, 5.0),
        lease_ttl_s: read_int(hooks_raw["lease_ttl_s"]?, 600),
      )
    end

    # Parses the MCP governance config from the YAML document. Returns the
    # default when the `mcp:` section is absent.
    private def self.load_mcp(raw : YAML::Any) : MCPConfig
      mcp_raw = raw["mcp"]?
      return MCPConfig.new if mcp_raw.nil? || mcp_raw.raw.nil?

      MCPConfig.new(
        max_concurrency_per_sid: read_int(mcp_raw["max_concurrency_per_sid"]?, 4),
        max_result_rows: read_int(mcp_raw["max_result_rows"]?, 200),
        max_response_bytes: read_int(mcp_raw["max_response_bytes"]?, 1_048_576),
        max_batch_ops: read_int(mcp_raw["max_batch_ops"]?, 25),
      )
    end

    # Parses the sidecar subsystem config from the YAML document. Returns the
    # default `SidecarConfig` when the `sidecar:` section is absent — the
    # section is optional; only the orphan-reconciliation cron task consumes
    # it. The default cron expression is validated lazily by `Cron::Parser`
    # when the reconciliation task is registered with the scheduler.
    private def self.load_sidecar(raw : YAML::Any) : SidecarConfig
      sidecar_raw = raw["sidecar"]?
      return SidecarConfig.new if sidecar_raw.nil? || sidecar_raw.raw.nil?

      SidecarConfig.new(
        reconcile_cron: read_str(sidecar_raw["reconcile_cron"]?) || "0 */1 * * *",
      )
    end

    # Parses the secrets store config from the YAML document and fails
    # closed on a missing or short `master_key` — a config file must never
    # load without real key material.
    private def self.load_secrets(raw : YAML::Any) : Facet::Secrets::Config
      Facet::Secrets::Config.from_yaml(raw["secrets"]?).tap(&.validate!)
    end

    # Parses the import/export wait-mode config from the YAML document.
    # Returns the default when the `import_export:` section is absent —
    # the section is optional; only the enqueue routes' wait loop consumes
    # it. `wait_timeout_s` must be positive: a zero window would make every
    # wait request a no-op poll, and a negative one is a config error.
    private def self.load_import_export(raw : YAML::Any) : ImportExportConfig
      ie_raw = raw["import_export"]?
      return ImportExportConfig.new if ie_raw.nil? || ie_raw.raw.nil?

      poll_ms = read_int(ie_raw["wait_poll_ms"]?, 500)
      if poll_ms <= 0
        raise ArgumentError.new(
          "import_export.wait_poll_ms must be a positive number of " \
          "milliseconds (got #{poll_ms})"
        )
      end

      timeout_s = read_int(ie_raw["wait_timeout_s"]?, 30)
      if timeout_s <= 0
        raise ArgumentError.new(
          "import_export.wait_timeout_s must be a positive number of " \
          "seconds (got #{timeout_s})"
        )
      end

      max_rows = read_int(ie_raw["max_import_rows"]?, 100_000)
      if max_rows <= 0
        raise ArgumentError.new(
          "import_export.max_import_rows must be a positive number of " \
          "rows (got #{max_rows})"
        )
      end

      ImportExportConfig.new(wait_poll_ms: poll_ms, wait_timeout_s: timeout_s, max_import_rows: max_rows)
    end

    # Parses the database session config from the YAML document. Returns
    # the default `DatabaseConfig` when the `database:` section is absent —
    # the section is optional; the server-process statement timeout and the
    # optional cluster route table consume it.
    private def self.load_database(raw : YAML::Any) : DatabaseConfig
      database_raw = raw["database"]?
      return DatabaseConfig.new if database_raw.nil? || database_raw.raw.nil?

      timeout = read_int_or_nil(database_raw["statement_timeout_ms"]?)
      if (ms = timeout) && ms.negative?
        raise ArgumentError.new(
          "database.statement_timeout_ms must be zero or a positive number of " \
          "milliseconds (got #{ms})"
        )
      end

      cluster = load_cluster(database_raw)
      DatabaseConfig.new(statement_timeout_ms: timeout, cluster: cluster)
    end

    # Parses the optional `database.cluster:` section into the route-table
    # grammar (see `Facet::Database::ClusterConfig`). Absent section —
    # `nil`, the back-compat single-pool shape.
    #
    # Validation fails the load:
    # - every entry needs a `url` and a non-empty `resources` list
    # - exactly one entry carries `*`
    # - a specific resource appears in one entry only
    # - a `replica:` sub-entry needs a `url`
    private def self.load_cluster(database_raw : YAML::Any) : Database::ClusterConfig?
      cluster_raw = database_raw["cluster"]?
      return nil if cluster_raw.nil? || cluster_raw.raw.nil?

      databases_raw = cluster_raw["databases"]?
      unless databases_map = databases_raw.try(&.as_h?)
        raise ArgumentError.new(
          "database.cluster.databases must be a mapping of database entry " \
          "names (e.g. `main: {url: ..., resources: [\"*\"]}`)"
        )
      end

      entries = [] of Database::ClusterDatabase
      seen_resources = {} of String => String
      star_entries = [] of String

      databases_map.each do |name_node, entry_raw|
        name = name_node.as_s?
        if name.nil? || name.empty?
          raise ArgumentError.new("database.cluster.databases keys must be non-empty names")
        end
        unless entry_map = entry_raw.as_h?
          raise ArgumentError.new("database.cluster.databases.#{name} must be a mapping")
        end

        url = entry_map["url"]?.try(&.as_s?)
        if url.nil? || url.empty?
          raise ArgumentError.new("database.cluster.databases.#{name}.url is required")
        end

        resources = parse_cluster_resources(entry_map, name)
        star_entries << name if resources.includes?("*")
        # A specific resource must appear in one entry only. An entry may
        # carry '*' alongside its explicit resources (the grammar example
        # does) — the '*' marker and the resource claims are independent.
        resources.reject("*").each do |res|
          if holder = seen_resources[res]?
            raise ArgumentError.new(
              "database.cluster: resource '#{res}' appears in both " \
              "'#{holder}' and '#{name}' — a resource appears in one entry only"
            )
          end
          seen_resources[res] = name
        end

        replica = load_cluster_replica(entry_map, name)

        entries << Database::ClusterDatabase.new(
          name: name,
          url: url,
          resources: resources,
          initial_pool_size: read_int_or_nil(entry_map["initial_pool_size"]?),
          max_pool_size: read_int_or_nil(entry_map["max_pool_size"]?),
          checkout_timeout_s: read_float_or_nil(entry_map["checkout_timeout_s"]?),
          replica: replica,
        )
      end

      unless star_entries.size == 1
        raise ArgumentError.new(
          "database.cluster: exactly one entry must carry the '*' resource " \
          "(got #{star_entries.size}: #{star_entries.join(", ")})"
        )
      end

      Database::ClusterConfig.new(databases: entries)
    end

    private def self.parse_cluster_resources(entry_map : Hash(YAML::Any, YAML::Any), name : String) : Array(String)
      resources_raw = entry_map["resources"]?
      unless list = resources_raw.try(&.as_a?)
        raise ArgumentError.new(
          "database.cluster.databases.#{name}.resources must be a list of " \
          "resource ids (domain ids, '$' tags, or '*')"
        )
      end

      list.map do |node|
        res = node.as_s?
        if res.nil? || res.empty?
          raise ArgumentError.new(
            "database.cluster.databases.#{name}.resources must hold " \
            "non-empty strings"
          )
        end
        if res.starts_with?("$") && res.size == 1
          raise ArgumentError.new(
            "database.cluster.databases.#{name}: '$' alone is not a resource — " \
            "subsystem tags carry a name (e.g. '$artifacts')"
          )
        end
        res
      end
    end

    private def self.load_cluster_replica(entry_map : Hash(YAML::Any, YAML::Any), name : String) : Database::ClusterReplica?
      replica_raw = entry_map["replica"]?
      return nil if replica_raw.nil? || replica_raw.raw.nil?

      unless replica_map = replica_raw.as_h?
        raise ArgumentError.new(
          "database.cluster.databases.#{name}.replica must be a mapping with " \
          "a url"
        )
      end

      url = replica_map["url"]?.try(&.as_s?)
      if url.nil? || url.empty?
        raise ArgumentError.new(
          "database.cluster.databases.#{name}.replica.url is required"
        )
      end

      Database::ClusterReplica.new(
        url: url,
        initial_pool_size: read_int_or_nil(replica_map["initial_pool_size"]?),
        max_pool_size: read_int_or_nil(replica_map["max_pool_size"]?),
        checkout_timeout_s: read_float_or_nil(replica_map["checkout_timeout_s"]?),
      )
    end

    # Parses the logging config from the YAML document. Returns the default
    # `LogsConfig` when the `logs:` section is absent — the section is
    # optional; only the explicit log setup (`Facet::Logging.setup`)
    # consumes it. Invalid values raise at load: a typo'd level or format
    # must stop the boot, not silently fall back to the defaults.
    private def self.load_logs(raw : YAML::Any) : LogsConfig
      logs_raw = raw["logs"]?
      return LogsConfig.new if logs_raw.nil? || logs_raw.raw.nil?

      format = read_str(logs_raw["format"]?) || "text"
      level = read_str(logs_raw["level"]?) || "info"

      unless format == "text" || format == "json"
        raise ArgumentError.new(
          "logs.format must be 'text' or 'json' (got '#{format}')"
        )
      end

      unless ::Log::Severity.parse?(level)
        raise ArgumentError.new(
          "logs.level must be one of trace, debug, info, notice, warn, " \
          "error, fatal (got '#{level}')"
        )
      end

      LogsConfig.new(format: format, level: level)
    end

    # Parses the tombstone retention config from the YAML document. Returns
    # the default `TombstoneConfig` when the `tombstone:` section is absent —
    # the section is optional; only the content prune cron task consumes it.
    # The default cron expression is validated lazily by `Cron::Parser` when
    # the prune task is registered with the scheduler.
    private def self.load_tombstone(raw : YAML::Any) : TombstoneConfig
      tombstone_raw = raw["tombstone"]?
      return TombstoneConfig.new if tombstone_raw.nil? || tombstone_raw.raw.nil?

      TombstoneConfig.new(
        content_retention_days: read_int(tombstone_raw["content_retention_days"]?, 30),
        prune_cron: read_str(tombstone_raw["prune_cron"]?) || "15 4 * * *",
      )
    end

    # Parses the process-cache staleness section of the config. The section
    # is optional; the defaults apply when it is absent. A negative bound
    # fails loud — a typo must stop the boot, not silently disable the
    # safety net (the fanout would then be the only invalidation).
    private def self.load_cache(raw : YAML::Any) : CacheConfig
      cache_raw = raw["cache"]?
      return CacheConfig.new if cache_raw.nil? || cache_raw.raw.nil?

      ttl = cache_raw["staleness_ttl_s"]?.try(&.as_i) || 300
      if ttl < 0
        raise ArgumentError.new(
          "cache.staleness_ttl_s must be 0 (disabled) or a positive number of seconds (got #{ttl})"
        )
      end

      CacheConfig.new(staleness_ttl_s: ttl)
    end

    # Parses the WebSocket bridge config from the YAML document. Returns the
    # default `WebsocketConfig` when the `websocket:` section is absent — the
    # section is optional; only the collection-subscription cap consumes it.
    private def self.load_websocket(raw : YAML::Any) : WebsocketConfig
      websocket_raw = raw["websocket"]?
      return WebsocketConfig.new if websocket_raw.nil? || websocket_raw.raw.nil?

      collection_raw = websocket_raw["collection"]?
      collection = WebsocketCollectionConfig.new
      if collection_raw && !collection_raw.raw.nil?
        collection = WebsocketCollectionConfig.new(
          max_subscribers_per_doctype: read_int(collection_raw["max_subscribers_per_doctype"]?, 32),
        )
      end

      WebsocketConfig.new(collection: collection)
    end

    # Parses the artifact subsystem config from the YAML document.
    # Delegates to `Artifact::Config.from_yaml`, which fails loud when the
    # `artifact:` section or its required `storage:` entry is absent or
    # malformed — a misconfigured storage must stop the boot, not surface
    # as a 500 on the first upload.
    private def self.load_artifact(raw : YAML::Any) : Facet::Artifact::Config
      Facet::Artifact::Config.from_yaml(raw["artifact"]?)
    end

    # Reads a Float64 from a YAML::Any?, with a default for missing/null.
    private def self.read_float(value : YAML::Any?, default : Float64) : Float64
      return default if value.nil? || value.raw.nil?
      value.as_f
    end

    # The environment this process boots in — the same resolution the
    # config file path uses (`config.#{env}.yml`). Public so the
    # system-settings write gate repeats the mail-adapter production gate
    # with the exact parity the loader enforces at boot.
    def self.app_env : String
      ENV["APP_ENV"]? || "dev"
    end

    # Reads a String from a YAML::Any?, treating both missing keys and
    # explicit YAML `null` values as nil.
    private def self.read_str(value : YAML::Any?) : String?
      return nil if value.nil? || value.raw.nil?
      value.as_s
    end

    # Reads a nullable String from a YAML::Any? or an ENV var, preferring
    # the YAML value when present. Used for the artifact grant secret pair
    # so production deployments can supply the secret via
    # `ARTIFACT_GRANT_SECRET` without checking it into YAML.
    private def self.read_str_or_env(value : YAML::Any?, env_key : String) : String?
      yaml_val = read_str(value)
      return yaml_val if yaml_val
      ENV[env_key]?
    end

    # Reads an Int32 from a YAML::Any?, with a default for missing/null.
    private def self.read_int(value : YAML::Any?, default : Int32) : Int32
      return default if value.nil? || value.raw.nil?
      value.as_i
    end

    # Reads a nullable Int32 from a YAML::Any?, treating both missing keys
    # and explicit YAML `null` values as nil.
    private def self.read_int_or_nil(value : YAML::Any?) : Int32?
      return nil if value.nil? || value.raw.nil?
      value.as_i
    end

    # Reads a nullable Float64 from a YAML::Any?, treating both missing keys
    # and explicit YAML `null` values as nil. Accepts integer scalars too —
    # YAML documents a timeout of `2` and `2.0` the same way.
    private def self.read_float_or_nil(value : YAML::Any?) : Float64?
      return nil if value.nil? || value.raw.nil?
      raw = value.raw
      raw.as?(Int64).try { |i| return i.to_f }
      value.as_f
    end

    # Reads a Bool from a YAML::Any?, with a default for missing/null.
    private def self.read_bool(value : YAML::Any?, default : Bool) : Bool
      return default if value.nil? || value.raw.nil?
      value.as_bool
    end

    # Reads a list of non-empty strings from a YAML::Any?, with an empty
    # list for missing/null. Entries are trimmed; an entry that trims to
    # nothing fails the config load — a silent empty entry would read as
    # "allowlisted" nothing or, worse, be mistaken for a deliberate
    # wildcard. Used by the webhook `allowed_hosts` list.
    private def self.read_str_list(value : YAML::Any?) : Array(String)
      return [] of String if value.nil? || value.raw.nil?
      raw_list = value.as_a
      list = raw_list.compact_map do |entry|
        text = entry.as_s?.to_s.strip
        text.empty? ? nil : text
      end
      raise ArgumentError.new("webhook.allowed_hosts entries must be non-empty strings") if list.size != raw_list.size
      list
    end
  end
end
