# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── IAM test helpers ─────────────────────────────────────────────────────────
#
# Helpers for creating test accounts and setting up IAM state in specs.
# These are top-level functions available in every spec.

require "../../src/mutation/client"
require "../../src/iam"
require "../../src/secrets"

# Ensures a bare `iam.Account` projection row exists with the given id,
# ensuring the `iam.Account` doctype definition when missing. Lighter than
# `create_test_account`: no roles, no auth secrets — for specs that only
# need the row to satisfy the authoring-time reference existence check.
def ensure_iam_account(db, account_id : String) : Nil
  exists = db.query_one?("SELECT 1 FROM projections WHERE domain='iam' AND doc_type='Account' AND id=$1 AND deleted_at IS NULL", account_id, as: Int32)
  return if exists

  Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
  result = Facet::Document::Create.call(
    db, "iam", "Account",
    %({"email": "#{account_id}@facet.test", "name": "#{account_id}", "roles": []}),
    Facet::RBAC::AuthContext.system,
    doc_id: account_id,
  )
  expect_create_success(result)
end

# Ensures the `iam.Roles` seed documents, with every doctype their
# permission scopes reference registered first (the seed documents validate
# their scopes against registered definitions — the same dependency order
# the seed runner guarantees). Use in specs that need the seeded role
# documents (including `iam.Roles.anonymous`); specs that only need
# admin/editor/viewer rows can use the lighter `seed_test_roles`.
def ensure_seed_roles_with_dependencies(db) : Nil
  %w[
    core.DocType core.Domain core.Comment core.Attachment
    core.DocumentView core.Currency core.DomainGrant core.Webhook
    core.SchematicLayout
  ].each do |dir|
    domain, doctype = dir.split(".", 2)
    Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
  end
  Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
end

# Creates a test Account document and its password slot in the secret store.
#
# Returns the document ID (ULID) of the created account.
def create_test_account(
  db,
  email = "test@example.com",
  display_name = "Test User",
  password = "test-password",
  roles = ["iam.Roles.admin", "iam.Roles.editor"],
  default_role = "iam.Roles.admin",
  status = "active",
  mfa_enabled = false,
)
  # Ensure seed roles exist (truncation wipes them)
  seed_test_roles(db)

  # AccountPatch-driven flows (MFA verify/disable, password change/reset)
  # run the document pipeline, which needs the doctype definition. The
  # per-example truncate wipes projections — re-create the iam.Account
  # definition when it is gone. Single-directory and idempotent: it must
  # not seed other doctypes' documents (the production iam.Roles seed
  # would overwrite the test roles).
  unless db.query_one?("SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'iam.Account' AND deleted_at IS NULL", as: Int32)
    Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
  end

  # Create the Account document
  content = {
    "email"        => email,
    "name"         => display_name,
    "status"       => status,
    "roles"        => roles,
    "default_role" => default_role,
    "mfa_enabled"  => mfa_enabled,
  }.to_json

  doc_id = Facet::Util::ScriptHelpers.ulid
  Facet::Mutation::Client.create(
    db,
    "iam",
    "Account",
    doc_id: doc_id,
    content: content,
    actioner_id: "system",
  )

  # Set the password slot
  Facet::Secrets.set(db, "iam.Account.#{doc_id}", "password", password,
    mode: "hash", set_by: "system")

  doc_id
end

# ── Reset-token helpers (DB-backed) ───────────────────────────────────
#
# Reset tokens live on the `reset` slot of the `secrets` store — the value
# column holds only the SHA-256 digest, so no raw token can be read back
# from the database. Specs that need a raw token mint it through the store
# (the exact call the request / invite flows make).

# Mints a reset token on the `reset` slot and returns the raw value.
def mint_reset_token(db, account_id, ttl = 3600.seconds) : String
  token = Random::Secure.hex(32)
  Facet::Secrets.set(db, "iam.Account.#{account_id}", "reset", token,
    mode: "token", set_by: "system", ttl: ttl)
  token
end

# True when the account holds a reset-slot row (any expiry state).
def reset_slot_exists?(db, account_id) : Bool
  !db.query_one?(
    "SELECT 1 FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'reset'",
    account_id, as: Int32
  ).nil?
end

# Forces a token row into the past so the TTL path can be exercised.
def expire_reset_token(db, account_id) : Nil
  db.exec(
    "UPDATE secrets SET expires_at = now() - interval '1 minute' WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'reset'",
    account_id
  )
end

# All LoginEvent names currently in the projections table.
def login_events(db) : Array(String)
  db.query_all(
    "SELECT content->>'event' FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
    as: String
  )
end

# Creates a service account — no password slot, `service_account: true`.
def create_service_account(db, email) : String
  seed_test_roles(db)
  unless db.query_one?("SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'iam.Account' AND deleted_at IS NULL", as: Int32)
    Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
  end

  doc_id = Facet::Util::ScriptHelpers.ulid
  content = {
    "email"           => email,
    "name"            => "Service Bot",
    "status"          => "active",
    "roles"           => ["iam.Roles.admin"],
    "default_role"    => "iam.Roles.admin",
    "service_account" => true,
  }.to_json
  Facet::Mutation::Client.create(db, "iam", "Account", doc_id: doc_id,
    content: content, actioner_id: "system")
  doc_id
end

# Seeds the default roles (admin, editor, viewer) that are wiped by per-test truncation.
#
# The editor role mirrors the production seed (`data/seeds/iam.Roles/documents.yml`):
# blanket CRUD except the definition surfaces and the provider registry, plus
# the domain-editor-scoped lines on `core.Domain` / `core.DocType` /
# `core.DocumentView`. KEEP THE TWO FILES IN STEP: when the seed's `except`
# carve-outs change (last change: `iam.OIDCProvider`), update
# `EDITOR_PERMISSIONS` here and the `viewer` permissions below to match. Note that the scoped lines only resolve when
# the seeded doctype definitions (which carry
# the `domain_editor` scopes) and the `core` domain document (which carries the
# `editor_*` context sets) are registered — run `restore_seeded_baseline(db)`
# first in specs that enforce them.
#
# Connectivity mirrors the production seed too: `admin` holds every channel,
# while `editor` and the other non-admin roles hold `api` + `assistant` only —
# no `webhook`, no `mcp` (F07-01: an outbound webhook is an egress path, so
# its authoring gate is the `webhook` channel). Specs that exercise webhook or
# MCP machinery seed their own role with `seed_role` / explicit content.
#
# Also seeds `iam.Roles.comment_author`: a role holding ONLY author-scoped
# grants on `core.Comment` (`read`/`update`/`delete` with the `$mine` scope).
# It must not carry a wildcard read — an unrestricted matching permission
# collapses `AuthContext#can?` to `All` and bypasses the scope entirely.
# Flat create is blocked for sidecar doctypes, so no `create` grant exists.
# The production role seed (`data/seeds/iam.Roles/`) is a separate concern.
private EDITOR_PERMISSIONS = [
  {action: "create", on: "*.*", except: ["core.DocType", "core.DocumentView", "core.DomainEditor", "core.SchematicLayout", "core.SystemSettings", "iam.OIDCProvider"]},
  {action: "update", on: "*.*", except: ["core.Domain", "core.DocType", "core.DocumentView", "core.DomainEditor", "core.SchematicLayout", "core.SystemSettings", "iam.OIDCProvider"]},
  {action: "delete", on: "*.*", except: ["core.Domain", "core.DocType", "core.DocumentView", "core.DomainEditor", "core.SchematicLayout", "core.SystemSettings", "iam.OIDCProvider"]},
  {action: "read", on: "*.*", except: ["core.SystemSettings", "iam.OIDCProvider"]},
  {action: "update", on: "core.Domain", scope: ["$domain_editor"]},
  {action: "delete", on: "core.Domain", scope: ["$domain_editor_draft"]},
  {action: "create", on: "core.DocType", scope: ["$domain_editor"]},
  {action: "update", on: "core.DocType", scope: ["$domain_editor"]},
  {action: "delete", on: "core.DocType", scope: ["$domain_editor"]},
  {action: "create", on: "core.DocumentView", scope: ["$domain_editor"]},
  {action: "update", on: "core.DocumentView", scope: ["$domain_editor"]},
  {action: "delete", on: "core.DocumentView", scope: ["$domain_editor"]},
  {action: "create", on: "core.SchematicLayout", scope: ["$domain_editor"]},
  {action: "update", on: "core.SchematicLayout", scope: ["$domain_editor"]},
]

def seed_test_roles(db)
  roles = [
    {id: "iam.Roles.admin", name: "admin", level: 100, description: "Full administrative access to all resources.", permissions: [{action: "*", on: "*.*"}, {action: "mfa_disable", on: "iam.Account"}]},
    {id: "iam.Roles.editor", name: "editor", level: 30, description: "Reads and edits documents in every domain; definition edits scoped to domains the account edits.", permissions: EDITOR_PERMISSIONS},
    {id: "iam.Roles.viewer", name: "viewer", level: 20, description: "Read-only access to all resources.", permissions: [{action: "read", on: "*.*", except: ["core.SystemSettings", "iam.OIDCProvider"]}]},
    {id: "iam.Roles.comment_author", name: "comment_author", level: 20, description: "Author-scoped access to core.Comment.", permissions: [{action: "read", on: "core.Comment", scope: ["$mine"]}, {action: "update", on: "core.Comment", scope: ["$mine"]}, {action: "delete", on: "core.Comment", scope: ["$mine"]}]},
    {id: "iam.Roles.attachment_owner", name: "attachment_owner", level: 20, description: "Uploader-scoped access to core.Attachment.", permissions: [{action: "read", on: "core.Attachment", scope: ["$mine"]}, {action: "update", on: "core.Attachment", scope: ["$mine"]}, {action: "delete", on: "core.Attachment", scope: ["$mine"]}]},
  ]

  roles.each do |role|
    # Skip if already seeded
    existing = db.query_one?(
      "SELECT 1 FROM projections WHERE id = $1 AND deleted_at IS NULL",
      role[:id],
      as: Int32
    )
    next if existing

    content = {
      "name"         => role[:name],
      "level"        => role[:level],
      "description"  => role[:description],
      "visible_tags" => role[:name] == "admin" ? ["*"] : ["default"],
      # Mirrors the production seed: admin holds every channel, the other
      # roles hold `api` + `assistant` only, and `anonymous` holds none.
      "connectivity" => case role[:name]
      when "admin"     then ["mcp", "webhook", "api", "assistant"]
      when "anonymous" then [] of String
      else                  ["api", "assistant"]
      end,
      "permissions" => role[:permissions],
    }.to_json

    Facet::Mutation::Client.create(
      db,
      "iam",
      "Roles",
      doc_id: role[:id],
      content: content,
      actioner_id: "system",
    )
  end
end

# Helper for refresh specs: creates a test account + Redis session, returns refresh token.
def create_session_and_refresh_token(db, roles = ["iam.Roles.admin", "iam.Roles.editor"], active_role = "iam.Roles.admin")
  account_id = create_test_account(db, roles: roles, default_role: active_role)

  # Create a session directly
  session_id, refresh_id = Facet::IAM::RedisSession.create(
    account_id: account_id,
    active_role: active_role,
  )

  refresh_token = "#{session_id}.#{refresh_id}"
  {account_id: account_id, session_id: session_id, refresh_token: refresh_token}
end

# Helper for challenge specs: enables MFA on a test account.
def create_mfa_account(db)
  account_id = create_test_account(db, mfa_enabled: true)
  doc_ref = "iam.Account.#{account_id}"

  # Seed the sealed `mfa` slot and the TOTP replay guard. Step 0 means any
  # positive step is accepted.
  secret = Facet::IAM::TOTP.generate_secret
  Facet::Secrets.set(db, doc_ref, "mfa", secret,
    mode: "sealed", set_by: "system", meta: {"mfa_type" => "totp"})
  Facet::IAM::AuthState.try_advance_totp_step(db, doc_ref, 0_i64)

  {account_id: account_id, secret: secret}
end

# ── RBAC projection fixtures ─────────────────────────────────────────────
#
# Canonical builders for the `iam.Role` / `iam.Account` rows that enforcer,
# artifact, and import/export specs seed directly (no password slot, no
# roles-seed pass). `permission_json` accepts the full scope grammar:
# nil (unrestricted), a single alias string, or an alias array (OR).

# Creates an `iam.Role` projection with the given permissions.
def create_role_projection(db, role_id, permissions = [] of JSON::Any, visible_tags = ["default"], level = 20)
  content = JSON::Any.new({
    "name"         => JSON::Any.new(role_id),
    "level"        => JSON::Any.new(level.to_i64),
    "permissions"  => JSON::Any.new(permissions),
    "visible_tags" => JSON::Any.new(visible_tags.map { |t| JSON::Any.new(t) }),
  })
  Facet::Mutation::Client.create(
    db, "iam", "Role",
    doc_id: role_id,
    content: content.to_json,
    actioner_id: "system",
  )
end

# Creates an `iam.Account` projection that holds the given role ids.
def create_account_projection(db, account_id, role_ids)
  content = JSON::Any.new({
    "roles" => JSON::Any.new(role_ids.map { |r| JSON::Any.new(r) }),
  })
  Facet::Mutation::Client.create(
    db, "iam", "Account",
    doc_id: account_id,
    content: content.to_json,
    actioner_id: "system",
  )
end

# Builds one permission in the canonical array-scope grammar. `scope` may
# be nil (unrestricted), a single alias string, or an Array(String) of
# aliases (OR semantics).
def permission_json(action : String, on : String, scope : String | Array(String)? = nil) : JSON::Any
  h = {"action" => JSON::Any.new(action), "on" => JSON::Any.new(on)}
  case scope
  when nil
    # omitted → unrestricted
  when String
    h["scope"] = JSON::Any.new(scope)
  when Array(String)
    h["scope"] = JSON::Any.new(scope.map { |s| JSON::Any.new(s) })
  end
  JSON::Any.new(h)
end

# ── HTTP login helpers ────────────────────────────────────────────────
#
# Canonical login for specs that drive the HTTP routes. Both defs call
# `call_api` / `assert_http_status` from `spec/support/http_helper.cr` —
# only spec files that require that file may call them (Crystal checks
# defs lazily, so specs that never call them are unaffected).

# Logs in via POST /Api/iam/login (JSON, no cookie) and returns the full
# parsed JSON body. Use this when a spec needs more fields than the token.
def login_response(email, password) : JSON::Any
  body = %({"email": #{email.to_json}, "password": #{password.to_json}, "cookie": false})
  headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
  resp = call_api(HTTP::Request.new("POST", "/Api/iam/login", headers: headers, body: body))
  assert_http_status(resp, 200)
  JSON.parse(resp.body)
end

# Builds a twin of `original` with only the `iam` section replaced. Every
# other field is propagated, so config values set for the test env survive
# the swap. Canonical helper for the `with_*` config wrappers in iam and
# oauth specs; read `Config` public fields from src/config.cr when a new
# one lands. The `cache` section must propagate too — the suite runs with
# `staleness_ttl_s: 0`, and a swap that defaulted it to 300 would let the
# process caches rebuild from the truncated projections mid-suite.
def config_with_iam(original, iam : Facet::Config::IAMConfig) : Facet::Config
  original.class.new(
    snapshot_every: original.snapshot_every,
    iam: iam,
    event: original.event,
    host: original.host,
    base_url: original.base_url,
    artifact_base_url: original.artifact_base_url,
    artifact_grant_secret: original.artifact_grant_secret,
    artifact_grant_secret_previous: original.artifact_grant_secret_previous,
    artifact: original.artifact,
    domains: original.domains,
    mail: original.mail,
    assistant: original.assistant,
    lua: original.lua,
    hooks: original.hooks,
    jobs: original.jobs,
    webhook: original.webhook,
    mcp: original.mcp,
    sidecar: original.sidecar,
    tombstone: original.tombstone,
    cache: original.cache,
    websocket: original.websocket,
    secrets: original.secrets,
    import_export: original.import_export,
    dev: original.dev,
    database: original.database,
  )
end

# Logs in via POST /Api/iam/login (JSON, no cookie) and returns the
# Bearer access token.
def login_token(email, password) : String
  login_response(email, password)["token"].as_s
end

# Pins the MFA enforcement mode on the SystemSettings document for the
# duration of the block — the policy tier the login gates read
# (`IAM::Policy`). The seed lands the null singleton; the pin writes the
# policy field.
def with_mfa_enforcement(mode : String, &)
  with_db do |db|
    ensure_settings_doc(db)
    pin_settings(db, %({"iam": {"mfa": {"enforcement": "#{mode}"}}}))
  end
  yield
ensure
  # The per-example truncation wipes the projection, but the process cache
  # may hold the pinned value — reset like the truncation-aware specs do.
  Facet::SystemSettings.reset_cache!
end
