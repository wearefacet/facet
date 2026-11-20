# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"

module Facet
  # ── `webhook:` section of `Facet::Config` ────────────────────────────
  #
  # The `webhook:` record and its YAML loader live here, next to the
  # webhook concern. `Facet::Config` (src/config.cr) declares the
  # `webhook` field, calls `load_webhook` when it parses the file, and
  # owns the cross-section check against `jobs.retention_days`.
  class Config
    # ── Webhook (outbound HTTP delivery) ─────────────────────────────────
    #
    # Per-kind retry + transport for the webhook dispatcher. The section is
    # optional in `config.{env}.yml`; the defaults apply when it is absent.
    #
    # NO signing-secret keys live here: the per-webhook `secret` field on
    # the `core.Webhook` projection is the whole signing key.
    #
    # - `timeout_s` — connect + read timeout for one outbound POST.
    # - `max_attempts` / `backoff_seconds` — retry policy stamped on each
    #   `webhook_delivery` row at enqueue time.
    # - `allow_insecure_urls` — when false (default), the dispatcher rejects
    #   non-`https` target URLs.
    # - `allowed_hosts` — target hosts the B-76 host gate passes even when
    #   they resolve private: exact hostnames (string-matched, no DNS), IP
    #   literals, or CIDRs (matched against every resolved address). Empty
    #   by default — a deployment that receives webhooks on its own private
    #   network opts in here. See `Webhook::TargetCheck`.
    # - `reconcile_cron` — schedule of `Cron::WebhookReconcile`, the
    #   at-least-once backstop for the enqueue hop. Defaults to hourly at
    #   minute 7 (`"7 */1 * * *"`), offset from the sidecar reconcile at
    #   minute 0.
    # - `reconcile_window_hours` — how far back the reconciler looks for
    #   mutations with a missing enqueue. Defaults to 24. **Must stay below
    #   `jobs.retention_days`** — terminal `webhook_delivery` rows are
    #   pruned after retention, and a wider window would re-enqueue
    #   delivered events whose job rows are gone. Validated at load.
    record WebhookConfig,
      timeout_s : Int32 = 10,
      max_attempts : Int32 = 5,
      backoff_seconds : Array(Int32) = [10, 60, 300, 1800, 7200],
      allow_insecure_urls : Bool = false,
      allowed_hosts : Array(String) = [] of String,
      reconcile_cron : String = "7 */1 * * *",
      reconcile_window_hours : Int32 = 24

    # Parses the webhook config from the YAML document. Returns the default
    # `WebhookConfig` when the `webhook:` section is absent — the section is
    # optional and the defaults match the documented retry policy.
    private def self.load_webhook(raw : YAML::Any) : WebhookConfig
      webhook_raw = raw["webhook"]?
      return WebhookConfig.new if webhook_raw.nil? || webhook_raw.raw.nil?

      WebhookConfig.new(
        timeout_s: read_int(webhook_raw["timeout_s"]?, 10),
        max_attempts: read_int(webhook_raw["max_attempts"]?, 5),
        reconcile_cron: read_str(webhook_raw["reconcile_cron"]?) || "7 */1 * * *",
        reconcile_window_hours: read_int(webhook_raw["reconcile_window_hours"]?, 24),
        backoff_seconds: webhook_raw["backoff_seconds"]?.try do |arr|
          arr.as_a.map(&.as_i)
        end || [10, 60, 300, 1800, 7200],
        allow_insecure_urls: read_bool(webhook_raw["allow_insecure_urls"]?, false),
        allowed_hosts: read_str_list(webhook_raw["allowed_hosts"]?),
      )
    end
  end
end
