# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "http/client"
require "http/headers"
require "openssl/hmac"
require "../config"
require "../database"
require "../jobs/handler"
require "../jobs/job"
require "../util/script_helpers"
require "./transport"

module Facet
  module Webhook
    # The signed envelope plus the transport-only fields stamped at enqueue
    # time. `url` / `secret` / `headers` never reach the wire body — the
    # dispatcher strips them before signing and POSTing (decision 4).
    record Payload,
      webhook_id : String,
      delivery_id : String,
      event : String,
      domain : String,
      doc_type : String,
      doc_id : String,
      mutation_id : String?,
      actioner_id : String?,
      cause : JSON::Any?,
      content : JSON::Any,
      emitted_at : String,
      url : String,
      secret : String,
      headers : JSON::Any? do
      include JSON::Serializable

      # Returns the JSON body sent over the wire — the envelope WITHOUT the
      # transport-only `url` / `secret` / `headers` fields (decision 4).
      # Fields are emitted in the exact order decision 4 specifies, so the
      # receiver's parser sees a stable shape: JSON object key order is
      # observable, and the signature covers these raw bytes.
      def signed_body : String
        JSON.build do |json|
          json.object do
            json.field "webhook_id", webhook_id
            json.field "delivery_id", delivery_id
            json.field "event", event
            json.field "domain", domain
            json.field "doc_type", doc_type
            json.field "doc_id", doc_id
            json.field "mutation_id", mutation_id
            json.field "actioner_id", actioner_id
            json.field "cause", cause
            json.field "content", content
            json.field "emitted_at", emitted_at
          end
        end
      end
    end

    # Execute path for one `webhook_delivery` row: pure transport. Signs the
    # envelope body, merges the header set, issues the HTTP POST, and maps
    # every outcome to a `Jobs::Handler::Result`.
    #
    # The class is also the write side of the `webhook_calls` table
    # (`doc/backend/webhook.md`): one row per outbound HTTP attempt, created
    # `pending` when the worker starts an attempt and flipped to
    # `succeeded` / `failed` on the outcome. `background_jobs` stays the
    # retry scheduler; this table is the user-facing debug log. Envelope
    # identity (`event`, `source_doc_id`, `mutation_id`) is denormalized
    # onto the call row so the log is filterable without touching the job
    # payload. The full envelope and the signing `secret` stay only in the
    # `background_jobs` payload — the call row never holds the secret.
    #
    # All attempt hooks are idempotent: a missing or already-terminal row
    # makes the update a no-op.
    #
    # No RBAC and no projection reads live here (decision 8) — the enqueue
    # gate in `Webhook::Handler` already authorized the delivery, and the
    # whole `url` / `secret` / `headers` set plus the signed envelope ride
    # in the job payload. This file therefore requires nothing from `rbac/`,
    # `iam/`, or `document/`.
    #
    # Outcome mapping (decision 6): HTTP 2xx → `Succeeded`; any other status
    # (3xx included) and every transport error → `Failed`. Every code path
    # returns a `Result` — `execute` never raises.
    class Dispatcher < Facet::Jobs::Handler
      KIND = "webhook_delivery"

      DEFAULT_CONTENT_TYPE = "application/json"
      DEFAULT_USER_AGENT   = "Facet-Webhook/1.0"

      # Message written by the lease-loss sweep (decision 3): a call that
      # ends with no outcome is a failed call.
      LEASE_EXPIRED_MESSAGE = "worker lease expired"

      # The receiver's response body is capped at 4 KB — a receiver can
      # return megabytes and the log only needs enough to identify the
      # failure. The same cap convention as `Webhook::Test`.
      MAX_RESPONSE_BODY_BYTES = 4096
      TRUNCATION_MARKER       = "… [truncated]"

      # Media types whose body is captured as a debug snippet. Anything
      # not on the denylist is treated as text (including an absent
      # Content-Type), so JSON receivers are logged by default and only
      # unambiguously binary payloads are skipped.
      BINARY_MEDIA_TYPE_PREFIXES = %w[image/ audio/ video/ font/ application/octet-stream application/pdf application/zip application/gzip]

      def self.default_max_attempts : Int32
        Facet::Config.instance.webhook.max_attempts
      end

      def self.default_backoff : Array(Int32)
        Facet::Config.instance.webhook.backoff_seconds
      end

      def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
        payload = Payload.from_json(job.payload.to_json)

        # The B-76 target gate: scheme + host. A rejection is a transport
        # classification, not a crash — the row retries like any other
        # transport failure, and the message says why.
        if rejection = self.class.target_rejection(payload.url)
          return Result.new(status: Kind::Failed, error: rejection)
        end

        body, headers = self.class.build_signed_request(payload)
        started = Time.instant
        begin
          response = post(URI.parse(payload.url), body, headers)
        rescue ex : Exception
          # Transport errors keep `response_body` nil — there is no
          # response. The duration up to the failure is still measured.
          return Result.new(status: Kind::Failed, error: ex.message, duration_ms: elapsed_ms(started))
        end
        duration = elapsed_ms(started)
        snippet = self.class.response_snippet(response)

        if response.status.success?
          Result.new(status: Kind::Succeeded, http_status: response.status.code, response_body: snippet, duration_ms: duration)
        else
          Result.new(status: Kind::Failed, http_status: response.status.code, response_body: snippet, duration_ms: duration)
        end
      rescue ex : Exception
        Result.new(status: Kind::Failed, error: ex.message)
      end

      # ── Attempt hooks (the call-log write side) ─────────────────────

      # Inserts one `pending` row for the claimed attempt. Replaces any
      # lingering `pending` row for the same job (defence in depth; the
      # sweep should have flipped it). A payload without the mandatory
      # identity fields writes nothing — the log degrades, the job does
      # not.
      def attempt_started(db : DB::Connection, job : Facet::Jobs::Job, attempt : Int32) : Nil
        identity = EnvelopeIdentity.from_payload(job.payload)
        return if identity.nil?

        Database.with_transaction(db) do
          db.exec(
            "DELETE FROM webhook_calls WHERE job_id = $1 AND status = 'pending'",
            job.id,
          )
          db.exec(
            <<-SQL,
            INSERT INTO webhook_calls (id, webhook_id, job_id, event, source_doc_id, mutation_id, attempt, status)
            VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending')
          SQL
            Util::ScriptHelpers.ulid, identity.webhook_id, job.id, identity.event,
            identity.source_doc_id, identity.mutation_id, attempt,
          )
        end
      end

      # Flips the attempt's `pending` row to its terminal status with the
      # outcome fields captured by `execute`. The `status = 'pending'`
      # guard makes a replayed outcome write a no-op.
      def attempt_finished(db : DB::Connection, job_id : String, attempt : Int32, result : Facet::Jobs::Handler::Result) : Nil
        status = result.status == Facet::Jobs::Handler::Kind::Succeeded ? "succeeded" : "failed"
        duration_ms = Dispatcher.clamp_duration(result.duration_ms)

        db.exec(
          <<-SQL,
          UPDATE webhook_calls SET
            status        = $1,
            http_status   = $2,
            error         = $3,
            response_body = $4,
            duration_ms   = $5,
            updated_at    = now()
          WHERE job_id = $6 AND attempt = $7 AND status = 'pending'
        SQL
          status, result.http_status, result.error, result.response_body,
          duration_ms, job_id, attempt,
        )
      end

      # Marks the job's `pending` rows `failed` after a lease loss. Called
      # from the worker's lease sweep, in the same transaction.
      def attempt_abandoned(db : DB::Connection, job_id : String) : Nil
        db.exec(
          <<-SQL,
          UPDATE webhook_calls SET
            status     = 'failed',
            error      = $1,
            updated_at = now()
          WHERE job_id = $2 AND status = 'pending'
        SQL
          LEASE_EXPIRED_MESSAGE, job_id,
        )
      end

      # Deletes terminal rows older than the queue's retention horizon
      # (decision 9 — one `retention_days` source: `Jobs::Config`).
      # Returns the count deleted.
      def prune_expired(db : DB::Connection, retention_days : Int32) : Int32
        db.exec(
          <<-SQL,
          DELETE FROM webhook_calls
          WHERE status IN ('succeeded', 'failed')
            AND updated_at < now() - ($1::int * interval '1 day')
        SQL
          retention_days,
        ).rows_affected.to_i32
      end

      # Writes one completed probe row for `Webhook::Test` (decision 8):
      # `event = 'test'`, no parent job, attempt 1. A probe is a call; the
      # log should show it. Facet-side rejections (disabled webhook,
      # missing secret) never reach the wire and write nothing.
      def self.record_test(
        db : DB::Connection,
        webhook_id : String,
        *,
        http_status : Int32?,
        error : String?,
        response_body : String?,
        duration_ms : Int64?,
      ) : Nil
        status = http_status.try { |code| code >= 200 && code <= 299 } ? "succeeded" : "failed"
        db.exec(
          <<-SQL,
          INSERT INTO webhook_calls (id, webhook_id, job_id, event, attempt, status, http_status, error, response_body, duration_ms)
          VALUES ($1, $2, NULL, 'test', 1, $3, $4, $5, $6, $7)
        SQL
          Util::ScriptHelpers.ulid, webhook_id, status,
          http_status, error, response_body, clamp_duration(duration_ms),
        )
      end

      # Captures the response body as a text snippet for the call log:
      # binary media types are skipped, everything else is capped at
      # `MAX_RESPONSE_BODY_BYTES` with the truncation marker. Shared with
      # `Webhook::Test`.
      def self.response_snippet(response : ::HTTP::Client::Response) : String?
        return nil unless text_body?(response.headers)
        truncate_body(response.body)
      end

      # True when the body is worth capturing: an absent / empty
      # Content-Type is treated as text, denylisted media types are not.
      def self.text_body?(headers : ::HTTP::Headers) : Bool
        media_type = headers["Content-Type"]?.try do |value|
          value.split(';').first?.try(&.strip.downcase)
        end
        return true if media_type.nil? || media_type.empty?
        BINARY_MEDIA_TYPE_PREFIXES.none? { |prefix| media_type.starts_with?(prefix) }
      end

      # Caps a body at 4 KB, appending the truncation marker past the cap.
      def self.truncate_body(body : String) : String
        return body if body.bytesize <= MAX_RESPONSE_BODY_BYTES
        body.byte_slice(0, MAX_RESPONSE_BODY_BYTES) + TRUNCATION_MARKER
      end

      # Wall time of one POST, in whole milliseconds.
      private def elapsed_ms(started : Time::Instant) : Int64
        Transport.elapsed_ms(started)
      end

      # Signs the envelope and merges the header set (decision 4). Shared
      # with `Webhook::Test` (decision 10), which calls this directly instead
      # of going through the worker's dispatch table.
      #
      # Merge order: `Content-Type` + `User-Agent` defaults, then the custom
      # `headers` from the payload (a custom Content-Type / User-Agent wins),
      # then the `X-Facet-*` mandate — those always win. This is the runtime
      # guard behind the authoring-time ban on `X-Facet-` custom headers.
      # (Note: `::HTTP` — the project's own `Facet::HTTP` shadows stdlib
      # `HTTP` inside the `Facet` namespace.)
      def self.build_signed_request(payload : Payload) : {String, ::HTTP::Headers}
        body = payload.signed_body
        headers = ::HTTP::Headers{
          "Content-Type" => DEFAULT_CONTENT_TYPE,
          "User-Agent"   => DEFAULT_USER_AGENT,
        }

        if custom = payload.headers.try(&.as_h?)
          custom.each do |key, value|
            # The authoring-time validation admits string values only; skip
            # anything else so a corrupt payload cannot break the merge.
            next unless text = value.as_s?
            headers[key] = text
          end
        end

        signature = OpenSSL::HMAC.hexdigest(:sha256, payload.secret, body)
        headers["X-Facet-Signature"] = "sha256=" + signature
        headers["X-Facet-Event"] = payload.event
        headers["X-Facet-Delivery"] = payload.delivery_id
        headers["X-Facet-Webhook-Id"] = payload.webhook_id
        if mutation_id = payload.mutation_id
          headers["X-Facet-Mutation-Id"] = mutation_id
        end
        headers["X-Facet-Origin"] = "webhooks:#{payload.webhook_id}"

        {body, headers}
      end

      # The target gate: scheme (B-77) + host (B-76), owned by
      # `Webhook::TargetCheck`. A non-nil result is a transport
      # classification — the rejection flows through the normal `Failed`
      # path and the row retries. Shared with `Webhook::Test` (decision
      # 10), which answers 422 instead of retrying. Kept as a class method
      # so the spec stubs can intercept it like they intercept `post`.
      def self.target_rejection(url : String) : String?
        TargetCheck.check(url)
      end

      # One `HTTP::Client` per execute, with connect + read timeouts from
      # the config. `protected` so the spec drives the transport through a
      # subclass stub — no real network in tests. The body delegates to the
      # shared `Webhook::Transport`.
      protected def post(uri : URI, body : String, headers : ::HTTP::Headers) : ::HTTP::Client::Response
        Transport.post(uri, body, headers)
      end

      # The denormalized envelope identity of one job payload. Returns nil
      # when the mandatory `webhook_id` / `event` fields are missing or
      # empty — a corrupt payload is never logged, and never crashes the
      # worker.
      private record EnvelopeIdentity,
        webhook_id : String,
        event : String,
        source_doc_id : String?,
        mutation_id : String? do
        def self.from_payload(payload : JSON::Any) : EnvelopeIdentity?
          obj = payload.as_h?
          return nil if obj.nil?

          webhook_id = text(obj, "webhook_id")
          event = text(obj, "event")
          return nil if webhook_id.nil? || webhook_id.empty? || event.nil?

          EnvelopeIdentity.new(webhook_id, event, text(obj, "doc_id"), text(obj, "mutation_id"))
        end

        private def self.text(obj : Hash(String, JSON::Any), key : String) : String?
          obj[key]?.try(&.as_s?)
        end
      end

      # Caps a transport duration to the INT column's range. Shared by
      # the outcome write and the test-probe row.
      def self.clamp_duration(duration_ms : Int64?) : Int32?
        duration_ms.try { |d| Math.min(d, Int32::MAX.to_i64).to_i32 }
      end
    end
  end
end
