# Config

**Files covered:** `src/config.cr` (the `Config` core), `src/iam/config.cr`, `src/emails/config.cr`, `src/mutation/config.cr`, `src/dev/config.cr`, `src/webhook/config.cr`, `src/jobs/config.cr` (the concern-owned sections), `src/util/yaml_include.cr` (the `!env` tag)

`Facet::Config` loads runtime configuration from `config.{env}.yml`. The file is the single source of truth for boot and for every key the runtime-settings subsystem does not carry; for the hot keys (the assistant connection and the mail connector) it is the **bootstrap**: the effective value resolves document → file → default through `core.SystemSettings` — see [`system-settings.md`](system-settings.md). The file must stay present at boot: database and Redis addresses exist only in the file, and they must load before the database does.

The code is split across files:

- `src/config.cr` — the `Config` class core: the schema (`getter` per section), the singleton, `load` / `from_yaml_node`, `initialize` validation, the top-level keys, the shared `read_*` parsing helpers, and the loaders and records for the platform sections (`event`, `localization`, `domains`, `assistant`, `lua`, `hooks`, `mcp`, `sidecar`, `secrets`, `tombstone`, `cache`, `websocket`, `import_export`, `database`, `logs`) plus the `artifact` loader.
- `src/iam/config.cr` — the `iam:` section (`IAMConfig`, `JWTConfig`, `MFAConfig`, `TOTPConfig`, `AuthConfig`) and its loaders, plus the `Facet::IAM::Config` read facade.
- `src/emails/config.cr` — the `mail:` section (`MailConfig`, `SMTPConfig`), the SMTP loader, and the production mail-adapter gate.
- `src/mutation/config.cr` — the `mutations:` section (`MutationsConfig`).
- `src/dev/config.cr` — the `dev:` section (`DevConfig`, `DomainWatchConfig`).
- `src/webhook/config.cr` — the `webhook:` section (`WebhookConfig`).
- `src/jobs/config.cr` — the `jobs:` section (`JobsConfig`).

Every file reopens the same `class Facet::Config`, so the records keep their `Facet::Config::*` type paths and the `Config.instance.*` accessors (declared once in `src/config.cr`) do not change. Records whose types other subsystems own stay at their own paths (`Event::Config`, `Facet::Artifact::Config`, `Facet::Assistant::Config`, `Facet::Secrets::Config`).

Validation runs once, in `initialize`: the `domains.included` / `domains.excluded` mutual-exclusion check and the hard-required `artifact_grant_secret` check live there.

The file is parsed through `Util::YamlInclude.parse_string`, so any scalar tagged `!env NAME` expands to the value of the environment variable *NAME* at load time. This lets deployments inject secrets (passwords, tokens, API keys) without checking them into YAML.

---

## Loading

```crystal
# Production path — resolves config.#{APP_ENV}.yml (raises when the file is missing).
cfg = Facet::Config.instance

# Explicit path (used by specs and tooling).
cfg = Facet::Config.load(path)
```

| Method | Returns | Description |
|---|---|---|
| `.instance` | `Config` | Lazily loads and caches the singleton. |
| `.instance=(config)` | `Config` | Replaces the cached singleton (specs only). |
| `.reset!` | `Nil` | Drops the cached singleton; the next `.instance` reloads from disk. |
| `.load(path = nil)` | `Config` | Reads the YAML file, expands `!env` tags, builds a `Config`. Without `path`, resolves `config.#{APP_ENV}.yml` and raises when the file does not exist — there is no cross-environment fallback, so a misconfigured boot stops at startup instead of running with another environment's secrets and settings. |
| `.from_yaml_node(raw)` | `Config` | Builds a `Config` from an already-parsed `YAML::Any`. No `!env` expansion — it has no file context. Used by specs for fail-loud paths. |

Resolution order for the file path (the first match wins, fail loud):

1. **`FACET_CONFIG_FILE`** — an explicit path set in the environment. The operator's override: a container deploy points it at a mounted file (read-only mounts work, the image tree stays untouched) and non-container deployments get the same knob. A set-but-missing path raises with the path in the message — falling back to the default resolution would boot with the wrong file.
2. **`config.#{APP_ENV}.yml`** next to the binary — the default. Raises when the file does not exist.

`DATABASE_URL`, `APP_ENV`, and `JWT_SIGNING_KEY` (the ES256 signing PEM — see [`iam.md`](iam.md) → `Facet::IAM::JWT`) stay environment-only — the backend reads them outside YAML by design.

---

## The `!env` tag

```yaml
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET
```

Resolution rules:

- **Value shape.** The expanded value is always a string (env vars are strings). Numeric or boolean keys keep their plain YAML form; only tagged scalars are rewritten.
- **Fail loud.** A missing variable raises `Util::YamlInclude::IncludeError` at load, naming the variable and the config file. An empty variable name (`!env ""`) also raises. There is no silent-empty fallback — an unset variable must stop the process at startup, not surface later as a misconfigured value.
- **Config-only.** `!env` is rejected in bundle YAML. `YamlInclude.parse_file` — the reader for portable-domain bundle entries and doctype definition files — raises `IncludeError` when it meets an `!env` tag. Bundle YAML is untrusted authoring content: expanding env variables there would let an imported bundle exfiltrate secrets (e.g. a doctype definition carrying `!env ARTIFACT_GRANT_SECRET`, persisted into the database and served back to the importing user). The rejection is loud, not silent, so a bundle that relies on env expansion fails at import instead of storing the raw tag string.
- **Coverage.** `!env` works anywhere in the document: top-level keys, nested sections, and sequences. It is expanded by `Config.load` (file path) and by `YamlInclude.parse_string` (raw string). `Config.from_yaml_node` does not expand it.
- **Existing env fallbacks stay.** The artifact grant secret pair keeps its `read_str_or_env` behaviour (YAML value wins; the `ARTIFACT_GRANT_SECRET` env var is consulted only when the key is absent). `!env` is the explicit, per-key form for any config value.

The tag implementation lives in `src/util/yaml_include.cr` (`Facet::Util::YamlInclude`), alongside the `!read_file` tag used by fixture bundles (see [`shared/fixtures.md`](../shared/fixtures.md)).

## The `!env?` tag

`!env? NAME` is the optional tier. It expands to the variable's value when the variable is set. When the variable is unset, the key reads exactly like an explicit `null` in the file, and the consuming section applies its own default.

```yaml
assistant:
  api_endpoint: !env? FACET_AI_API_ENDPOINT
  api_key: !env? FACET_AI_API_KEY
  model: !env? FACET_AI_MODEL
```

Resolution rules:

- **Absence is a posture, not an error.** Use `!env?` where a missing variable means "feature off", not "broken boot". The AI Assistant is the model case: an installation without the `FACET_AI_*` variables runs without the assistant — the dock stays visible, conversation creation explains the posture, and the operator can enable the assistant at runtime from system settings. A missing variable never fails the load.
- **Set variables behave like `!env`.** The expansion is the same string. The `?` only changes the unset case.
- **An empty variable name still fails loud.** `!env? ""` raises, for the same reason `!env ""` does.
- **Config-only.** Same trust profile as `!env`: bundle parsing never receives the handler, so an `!env?` scalar in a bundle raises `IncludeError` as an unknown tag.
- **Consumer contract.** A section that reads `!env?` keys must treat null as its documented default. `Assistant::Config.from_yaml` does this for the three keys above.

`Config.load` passes both handlers (`EnvTag`, `EnvOptTag`), so one file can mix the two tiers.

---

## Sections

Each section has a dedicated loader. The platform sections load in `src/config.cr`; the concern-owned sections load in their own files:

| Section | Loader | Struct |
|---|---|---|
| `event` | `load_event` (required — Redis) | `Event::Config` |
| `iam` | `load_iam` / `load_jwt` / `load_mfa` / `load_auth` / `load_oidc` (`src/iam/config.cr`) | `IAMConfig`, `JWTConfig`, `MFAConfig`, `AuthConfig`, `OidcConfig` — `load_auth` validates `iam.auth.mode` at load (`hybrid` \| `oidc_only`, fail closed); `load_oidc` parses `iam.oidc.provision_roles` (non-empty strings, fail closed). OIDC providers are **not** config: they are `iam.OIDCProvider` documents — see [`oidc.md`](oidc.md) |
| `localization` | `load_localization` | `LocalizationConfig` — the instance defaults an account follows until it picks its own values: `default_timezone` (default `UTC`; a loadable IANA name is required at load) and `default_language` (default `en`; must be in `Settings::Keys::ALLOWED_LANGUAGES`). Both are hot keys resolved through `core.SystemSettings` (`localization.default_timezone`, `localization.default_language`) — see [`system-settings.md`](system-settings.md) |
| `artifact` | `load_artifact` (required — `artifact.storage`) | `Facet::Artifact::Config` (wires the Shrine object store — see [`artifact.md`](artifact.md)). The serving knobs (`grant_ttl_seconds`, `grant_ttl_media_seconds`, `prune_after_days`) are hot keys resolved through `core.SystemSettings` per mint / per prune run; `storage` is file-only — the adapter wires at boot |
| `domains` | `load_domains` | `DomainsConfig` |
| `mail` | `load_mail` / `load_smtp` (`src/emails/config.cr`) | `MailConfig`, `SMTPConfig` — production gate on the dev adapter, see below. The `mail.*` keys are hot keys: the effective values resolve through `core.SystemSettings` (`SystemSettings::MailView`) and a settings save rebuilds the adapter — see [`system-settings.md`](system-settings.md) |
| `assistant` | `load_assistant` | `Facet::Assistant::Config` — the connection keys (`api_endpoint`, `api_key`, `model`, `system_prompt`, sampling knobs) are hot keys resolved per turn start from `core.SystemSettings`; `turn_timeout_seconds` (default `900`) and `turn_sweep_cron` (default `"*/5 * * * *"`) drive the stale-turn sweep that marks orphaned `running` turns `interrupted` (see [`cron.md`](cron.md) → Wiring, and [`agent-conversations.md`](agent-conversations.md) for the turn statuses); `usage_retention_days` (default `0`, never) and `usage_prune_cron` (default `"30 4 * * *"`) schedule the usage-ledger prune (see [`workspace-assistant.md`](workspace-assistant.md) → Usage ledger) |
| `lua` | `load_lua` | `LuaConfig` |
| `hooks` | `load_hooks` | `HooksConfig` |
| `sidecar` | `load_sidecar` | `SidecarConfig` |
| `tombstone` | `load_tombstone` | `TombstoneConfig` — `content_retention_days` (default 30; `0` keeps every payload forever) is a hot key resolved through `core.SystemSettings` at the top of every `Cron::TombstoneContentPrune` pass; `prune_cron` schedules it (default `"15 4 * * *"`) |
| `mutations` | `load_mutations` (`src/mutation/config.cr`) | `MutationsConfig` — retention and coalescing policy for the `mutations` table: `retention_days` (default 180; `0` keeps history forever — compaction off, per-doctype overrides stop applying for that pass) is a hot key resolved through `core.SystemSettings` at the top of every `Cron::MutationCompaction` pass, `retention_overrides` (per qualified doctype, file-only), `compaction_cron` (default `"45 3 * * *"`), `coalesce_window_minutes` (default 3; `0` disables). `Config#retention_days_for(domain, doc_type)` (in `src/config.cr`) resolves the per-doctype window |
| `cache` | `load_cache` (optional — defaults when absent) | `CacheConfig` — `staleness_ttl_s` (default 300; `0` disables): the staleness bound for the invalidate-only process caches (doctype definitions, OAuth origins, app hosts, replication / hooks / webhook registries, currency registry). The Pub/Sub fanout is the fast invalidation path; the bound caps how long a cache may serve data when a fanout is lost (e.g. a mutation published while Redis was down). Consumed through `Util::CacheFreshness` — see [`replication.md`](replication.md) → `Event::Subscriber::DoctypeCache` → staleness bound. Keep the bound set in production: `0` turns a lost fanout into "stale until restart" — no writer republishes a no-op save (a re-applied value produces no mutation), so nothing would repair the cache. The spec suite pins `0` on purpose (examples truncate the tables the caches read) |
| `websocket` | `load_websocket` | `WebsocketConfig` |
| `jobs` | `load_jobs` (`src/jobs/config.cr`) | `JobsConfig` |
| `import_export` | `load_import_export` (optional — defaults when absent) | `ImportExportConfig` |
| `webhook` | `load_webhook` (`src/webhook/config.cr`, optional — defaults when absent) | `WebhookConfig` |
| `database` | `load_database` (optional — defaults when absent) | `DatabaseConfig` — carries `statement_timeout_ms`, applied as the PG session `statement_timeout` on every pooled connection of the server process, and the optional `cluster` route table (see below) (see [`workflow.md`](workflow.md) → Database quirks) |
| `logs` | `load_logs` (optional — defaults when absent) | `LogsConfig` — `format` (`text` \| `json`, default `text`) and `level` (default `info`), driving the explicit log setup `Facet::Logging.setup` (see [`logging.md`](logging.md)); both keys fail loud on an unknown value |
| `mcp` | `load_mcp` | `MCPConfig` |
| `dev` | `load_dev` (`src/dev/config.cr`, optional — `domain_watch: nil` when absent) | `DevConfig` / `DomainWatchConfig` / `DocumentsMode` — see [`dev-domain-watcher.md`](dev-domain-watcher.md) |

Top-level keys (`host`, `base_url`, `artifact_base_url`, `artifact_grant_secret`, `artifact_grant_secret_previous`, `snapshot_every`, `trusted_proxies`) are read directly in `from_yaml_node`. `artifact_base_url` and `artifact_grant_secret` are hard-required and fail loud at load. The `artifact:` section is likewise required — `artifact.storage` fails loud at load, and the entry is validated there (unknown types and incomplete S3 entries raise; see [`artifact.md`](artifact.md) → Configuration).

### Trusted proxies and the client IP

`trusted_proxies` (top-level list, default empty) names the addresses of the reverse proxies that face this server. [`util-client-ip.md`](util-client-ip.md) documents the resolver that reads it; this section records the config-side rule.

- An empty list ignores `X-Forwarded-For` on every request — any client can set that header to any value, so the server reads it only when the socket peer is on this list.
- A request whose socket peer is on the list may carry a trusted `X-Forwarded-For` chain. The resolver walks it right to left, skips the trusted hops, and returns the first untrusted hop; no header, or a chain with no untrusted hop, falls back to the peer host.
- Entries are bare hosts — no port, no brackets. Every entry can choose the client IP the server sees, so keep the list exact.

The resolver feeds the login throttle ([`iam.md`](iam.md) → `Facet::IAM::LoginThrottle`), the OAuth register/token rate limiters ([`oauth.md`](oauth.md) → Refresh floor and rate-limit scope), and the telemetry `http.client_ip` attribute ([`telemetry.md`](telemetry.md)). The result is always a bare host — the socket address port would give every connection a counter key of its own.

Currencies do not come from config — `core.Currency` documents (seeded, editable as documents) feed the registry through `Facet::Currency::Registry`. See [`util-money.md`](util-money.md).

### The `database.cluster` route table

The optional `database.cluster:` section builds the route table: one entry per physical database, each holding the resources (domain ids, `$`-prefixed subsystem tags, or `*`) it serves.

```yaml
database:
  statement_timeout_ms: 5000        # global — applies to every pool
  cluster:
    databases:
      main:                          # control plane + everything unrouted
        url: !env DATABASE_URL
        max_pool_size: 20
        replica:                     # optional — the read-only pool for this database
          url: !env DATABASE_REPLICA_URL
          max_pool_size: 30          # reads usually outnumber writes
        resources: ["*", "core", "iam", "$artifacts"]
      hr_crm:                        # two domains, one database
        url: "postgres://db2:5432/facet"
        resources: [hr, crm]
      bulk_pool:                     # pool isolation without a second database
        url: "postgres://db2:5432/facet"   # same URL as hr_crm — a second, smaller pool
        max_pool_size: 8
        resources: ["$bulk"]
```

Rules:

- Fields per entry: `url` (required, `!env` expands at load), optional sizing (`initial_pool_size`, `max_pool_size`, `checkout_timeout_s` — crystal-db reads them as URL query parameters), an optional `replica:` sub-entry (same fields), and `resources:` (required, non-empty).
- Validation fails the load: every entry needs a `url` and a non-empty `resources` list; exactly one entry carries `*`; a specific resource appears in one entry only; a `replica:` needs a `url`.
- **Routing is a function of the resource alone.** The resource picks the entry; the mode (`ro` / `rw`) picks the pool inside it — the `replica:` pool when defined, else an enforced pool at the entry's own URL. A mode-dependent database (an `ro` read of `iam` from a different database than the write) is not expressible.
- Every ro pool runs `SET default_transaction_read_only = on` on each connection — a write mislabelled as a read fails loud with a PG error.
- Entries that share a URL keep separate pools (pool isolation without a second host).
- **Back-compat:** an absent `cluster:` section gives one unnamed pool from `DATABASE_URL`, no separate ro pool, no enforcement — every ro request shares the primary pool.
- Pool sizing guidance: crystal-db defaults in v1 (`initial_pool_size` 1, no maximum). Tune from `facet_db_checkout_total{database, role}` once real traffic shows the checkout rate (see [`metrics.md`](metrics.md)). Escalation paths (a nested rw block inside a ro scope) hold two connections per fiber for their duration.

The test suite runs the cluster with a same-URL `replica:` — the read-only tripwire (see [`test-database.md`](test-database.md)).

The `iam` section lives in `src/iam/config.cr` and carries three validated sub-loaders. `load_mfa` rejects an `enforcement` value other than `preferred` or `always` at load. `load_auth` rejects an `auth.mode` value other than `hybrid` or `oidc_only` — fail closed like `enforcement`; the same mode is a runtime setting (`iam.auth.mode` on `core.SystemSettings`), the file value is the fallback tier. Providers are no longer configured here: identity providers are `iam.OIDCProvider` documents (see [`oidc.md`](oidc.md) → Provider documents). The `iam.oidc` section carries `provision_roles` — the config-file tier of the `iam.oidc.provision_roles` system setting (the instance-wide JIT-provisioning role baseline; see [`system-settings.md`](system-settings.md)). The `iam` section also carries `change_password_expiration` (token TTL for the password-change, reset, and invite-link flows) and `secure_cookies`.

The `mail` section lives in `src/emails/config.cr`.

### Mail adapter gate

The `mail` section defaults to `adapter: dev` — `Carbon::DevAdapter` prints every email to stdout. That default fails the config load in `APP_ENV=production`: password-reset, invite, and MFA links would never reach users. Production either sets `mail.adapter: smtp` with the `mail.smtp.*` keys, or accepts stdout delivery with `mail.allow_dev_adapter_in_production: true` (air-gapped installs). The raise names the exact YAML keys for both paths.

The same gate repeats at write time: a runtime save that switches the effective adapter to `dev` under `APP_ENV=production` is refused unless the file sets the hatch (`SystemSettings::WriteGate` — escape-hatch parity; the hatch itself stays file-only). See [`system-settings.md`](system-settings.md) → Write path and validation split.

Every environment that boots with the `dev` adapter emits one startup warning (log source `facet.config`, warn level) — once per process, not once per parse. The warning is emitted by the CLI boot after the log binding installs, never during the config load, so the line honours the configured `logs.format`. Specs re-arm it with `Config.reset_dev_adapter_warning!`.

---

## Singleton lifecycle

`Config.instance` caches the loaded config for the process lifetime. Specs that need bespoke values either build a `Config` directly, call `from_yaml_node` with an in-memory YAML string, or call `load(temp_path)` — the latter exercises the full `!env` expansion path without touching the checked-in config files.
