# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../src/mutation/client"

# Shared seeding helpers for the webhook specs (`handler_spec`,
# `manager_spec`, `routes_spec`, `doctype_spec`).

# Swaps the singleton config with one whose `webhook` section is replaced.
# Restores the original afterwards. Authoring-rule specs use it to flip
# `webhook.allow_insecure_urls` for one example (the dispatcher spec keeps
# a file-private copy).
#
# The wrapper PRESERVES the passed config's `allowed_hosts` and appends the
# `receiver.test` fixture host, so the B-76 host gate string-matches the
# fixture URL without DNS — the webhook specs never dial the transport (it
# is stubbed), and the suite must stay DNS-independent. Specs whose fixture
# URLs use another host (e.g. `receiver.example.com`) pass that host on the
# config they hand in. Gate-rule specs use `with_webhook_config_raw` to
# control the allowlist exactly.
def with_webhook_config(webhook : Facet::Config::WebhookConfig, &)
  with_webhook_config_raw(webhook.allowed_hosts + ["receiver.test"], webhook) do
    yield
  end
end

# The unwrapped form: `allowed_hosts` taken verbatim. Gate-rule specs use
# it to control the allowlist exactly.
def with_webhook_config_raw(allowed_hosts : Array(String), webhook : Facet::Config::WebhookConfig, &)
  original = Facet::Config.instance
  temp = Facet::Config.new(
    snapshot_every: original.snapshot_every,
    iam: original.iam,
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
    webhook: webhook.class.new(
      timeout_s: webhook.timeout_s,
      max_attempts: webhook.max_attempts,
      backoff_seconds: webhook.backoff_seconds,
      allow_insecure_urls: webhook.allow_insecure_urls,
      allowed_hosts: allowed_hosts,
      reconcile_cron: webhook.reconcile_cron,
      reconcile_window_hours: webhook.reconcile_window_hours,
    ),
    mcp: original.mcp,
    sidecar: original.sidecar,
    tombstone: original.tombstone,
    cache: original.cache,
  )
  Facet::Config.instance = temp
  result = yield
  result
ensure
  Facet::Config.instance = original if original
end

# Swaps `Webhook::TargetCheck`'s resolver for a canned mapping for the
# duration of the block, restoring the real resolver afterwards.
#
# Hosts named in `entries` resolve to the given addresses; every other
# host is unresolved. This is exactly the air-gapped shape — nothing
# resolves except what a hosts file pins — so resolution-dependent specs
# stay deterministic with no network at all (and skip the multi-second
# cold NXDOMAIN some resolvers impose on `.invalid` names).
#
# IP-literal URLs never reach the resolver (`TargetCheck.resolve_real`
# answers them from the literal text), so examples built on literals are
# unaffected by the swap.
def with_fake_resolver(entries : Hash(String, Array(String)) = {} of String => Array(String), &) : Nil
  previous = Facet::Webhook::TargetCheck.resolver
  Facet::Webhook::TargetCheck.resolver = ->(host : String) do
    ips = entries[host]? || [] of String
    ips.map { |ip| Socket::IPAddress.new(ip, 0) }
  end
  yield
ensure
  Facet::Webhook::TargetCheck.resolver = previous if previous
end

# The source doctype must be an aggregate root in a non-draft domain, with
# a real definition so `ReadEnforcer` has one to work with, plus one live
# source document row for the readability check to fetch.
def seed_webhook_source(db) : Nil
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: "sales.Invoice",
    content: %({"doctype": "Invoice", "domain": "sales", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"total": {"type": "integer"}}}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "sales", "Invoice", doc_id: "inv-1",
    content: %({"total": 100}),
    actioner_id: "system:test",
  )
end

# Creates a custom `iam.Roles` projection and returns its qualified row id
# (row ids are exactly the qualified string, e.g. `iam.Roles.viewer`). The
# connectivity list carries all four channels — these fixtures exercise
# webhook machinery, not the channel gate (the AuthCheck/AuthCheck specs
# build their own restricted roles where the gate is the subject).
def seed_role(db, name : String, permissions : Array) : String
  role_id = "iam.Roles.#{name}"
  content = {
    "name"         => name,
    "description"  => "Test role #{name}",
    "visible_tags" => ["default"],
    "connectivity" => ["mcp", "webhook", "api", "assistant"],
    "permissions"  => permissions,
  }.to_json
  Facet::Mutation::Client.create(
    db, "iam", "Roles", doc_id: role_id,
    content: content, actioner_id: "system",
  )
  role_id
end

# Persists a `core.Webhook` projection bound to the given account + role.
# The reference fields carry their fully qualified storage form, exactly as
# the authoring engine normalizes them.
def create_bound_webhook(db, doc_id : String, source_doctype : String, account_id : String?, role_id : String?, extra : String = "", secret : String = "secret-key-123456") : Nil
  account_ref = account_id ? %("iam.Account.#{account_id}") : "null"
  role_ref = role_id ? %("#{role_id}") : "null"
  Facet::Mutation::Client.create(
    db, "core", "Webhook", doc_id: doc_id,
    content: %({"label": "Relay", "url": "https://receiver.test/hook", "secret": "#{secret}", "source_doctype": "#{source_doctype}", "account_id": #{account_ref}, "role_id": #{role_ref}#{extra}}),
    actioner_id: "system:test",
  )
end
