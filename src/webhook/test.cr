# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "http/client"
require "pg"
require "../config"
require "../error"
require "../rbac"
require "../iam/helpers"
require "../util/script_helpers"
require "./dispatcher"

module Facet
  module Webhook
    # Synchronous test action for one webhook (decision 10): one inline
    # outbound POST with a synthetic test envelope, observed end to end.
    #
    # Unlike the delivery path nothing is enqueued — no `background_jobs`
    # row, no retry machinery. The operator wants one observed round trip,
    # so the receiver's status / body / transport error are returned as
    # data and the route answers 200 regardless of what the receiver did.
    # Only Facet-side failures surface as their own status: 404 when the
    # webhook does not exist, 422 when it is disabled or its transport
    # fields cannot support a signed request.
    #
    # The probe is logged as a call row (decision 8): `event = 'test'`,
    # `job_id` NULL, attempt 1. Only observed round trips are logged —
    # Facet-side rejections never reach the wire and write nothing.
    #
    # The envelope is signed with the webhook's `secret` exactly like a
    # real delivery — `Dispatcher.build_signed_request` is the shared code
    # path, so a receiver cannot tell the signature apart. The receiver
    # branches on `"event": "test"` in the body or the `X-Facet-Test:
    # true` header, which is overlaid after the shared merge (and so, like
    # every `X-Facet-*` header, cannot be overridden by custom headers).
    #
    # Never raises on transport errors — a timeout or refused connection
    # is returned as a `Result` with `http_status` nil and
    # `transport_error` set.
    module Test
      # The receiver's response body is capped at 4 KB — a receiver can
      # return megabytes and the operator only needs enough to identify
      # the failure. Shared convention with the dispatcher's call-log
      # capture.
      MAX_RESPONSE_BODY_BYTES = Dispatcher::MAX_RESPONSE_BODY_BYTES
      TRUNCATION_MARKER       = Dispatcher::TRUNCATION_MARKER

      # One observed round trip. `http_status` is nil on a transport error;
      # `signed_body` carries the exact JSON body that was signed and sent,
      # as the raw string (byte-identical to what went over the wire), so
      # the operator can verify a receiver-side signature failure offline.
      # `duration_ms` is the transport wall time of the POST.
      record Result,
        http_status : Int32?,
        response_body : String?,
        response_headers : Hash(String, String)?,
        transport_error : String?,
        duration_ms : Int64?,
        signed_body : String

      # Runs one inline test POST against the webhook's configured target.
      # Returns a `ServiceError` (404 / 422) for Facet-side rejections, or
      # a `Result` for whatever the receiver did. The auth context supplies
      # the `actioner_id` of the envelope — the caller who pressed the
      # button, not the webhook's bound account.
      def self.call(
        db : DB::Connection,
        webhook_id : String,
        auth_context : RBAC::AuthContext,
      ) : Result | Facet::ServiceError
        row = read_webhook_projection(db, webhook_id)
        return Facet::ServiceError.new(404, "Not Found") if row.nil?

        unless row[:enabled] == "true"
          return Facet::ServiceError.new(422, "Webhook is disabled")
        end

        url = row[:url]
        secret = row[:secret]
        if url.nil? || url.empty? || secret.nil? || secret.empty?
          return Facet::ServiceError.new(422, "url or secret missing — signing impossible")
        end

        # Same target gate the dispatcher applies at delivery time — the
        # test route must not become a way around it (scheme, B-77, and
        # host, B-76).
        if rejection = Dispatcher.target_rejection(url)
          return Facet::ServiceError.new(422, rejection)
        end

        # Same connectivity gate the dispatcher applies at enqueue — a
        # bound webhook whose role lost the `webhook` channel cannot probe
        # either (the test route must not become a way around it). An
        # unbound webhook carries no role to check; the delivery path
        # refuses those with `Unbound` regardless.
        if role_id = row[:role_id]
          role_content = IAM::Helpers.find_role_content(db, role_id)
          channels = role_content.try(&.["connectivity"]?.try(&.as_a?))
          webhook_ok = channels.try(&.any?(&.as_s?.try(&.==("webhook")))) == true
          unless webhook_ok
            return Facet::ServiceError.new(422,
              "The bound role's connectivity excludes the 'webhook' channel")
          end
        end

        payload = build_payload(webhook_id, url, secret, row[:headers], auth_context)
        body, headers = Dispatcher.build_signed_request(payload)
        headers["X-Facet-Test"] = "true"

        started = Time.instant
        begin
          response = post(URI.parse(url), body, headers)
        rescue ex : Exception
          duration = elapsed_ms(started)
          transport_error = ex.message || ex.class.name
          # A transport failure still logs a failed call row with the
          # error set — the probe happened, the receiver just never
          # answered.
          Dispatcher.record_test(db, webhook_id,
            http_status: nil,
            error: transport_error,
            response_body: nil,
            duration_ms: duration,
          )
          return Result.new(
            http_status: nil,
            response_body: nil,
            response_headers: nil,
            transport_error: transport_error,
            duration_ms: duration,
            signed_body: body,
          )
        end

        duration = elapsed_ms(started)
        response_body = truncate(response.body)

        # The probe is a call (decision 8): the outcome lands in the log
        # with the same status mapping as a delivery — 2xx succeeded,
        # everything else failed.
        Dispatcher.record_test(db, webhook_id,
          http_status: response.status.code,
          error: nil,
          response_body: response_body,
          duration_ms: duration,
        )

        Result.new(
          http_status: response.status.code,
          response_body: response_body,
          response_headers: header_map(response.headers),
          transport_error: nil,
          duration_ms: duration,
          signed_body: body,
        )
      end

      # ── Private ───────────────────────────────────────────────────────

      # The synthetic test envelope (decision 10). Signed and sent exactly
      # like a real delivery; only the `X-Facet-Test` header and the
      # `"event": "test"` field mark it as a probe.
      private def self.build_payload(
        webhook_id : String,
        url : String,
        secret : String,
        headers : JSON::Any?,
        auth_context : RBAC::AuthContext,
      ) : Payload
        Payload.new(
          webhook_id: webhook_id,
          delivery_id: "test-" + Util::ScriptHelpers.ulid,
          event: "test",
          domain: "core",
          doc_type: "Webhook",
          doc_id: webhook_id,
          mutation_id: nil,
          actioner_id: auth_context.principal.account_id,
          cause: Mutation::Cause.root(
            Mutation::CauseKind::WebhookTest,
            name: webhook_id,
            event: "test",
          ).resolve(Util::ScriptHelpers.ulid).to_json_any,
          content: JSON.parse({id: webhook_id, test: true}.to_json),
          emitted_at: Time.utc.to_rfc3339,
          url: url,
          secret: secret,
          headers: headers,
        )
      end

      # Reads the live `core.Webhook` projection row. A tombstoned or
      # absent row returns nil — the webhook was deleted (or never
      # existed).
      private def self.read_webhook_projection(db : DB::Connection, webhook_id : String)
        db.query_one?(
          <<-SQL,
            SELECT COALESCE(content->>'enabled', 'true') AS enabled,
                   content->>'url'                       AS url,
                   content->'headers'                    AS headers,
                   content->>'secret'                    AS secret,
                   content->>'role_id'                   AS role_id
            FROM projections
            WHERE domain = 'core' AND doc_type = 'Webhook' AND id = $1
              AND deleted_at IS NULL
          SQL
          webhook_id,
        ) do |rs|
          {
            enabled: rs.read(String),
            url:     rs.read(String?),
            headers: rs.read(JSON::Any?),
            secret:  rs.read(String?),
            role_id: rs.read(String?),
          }
        end
      end

      # One `HTTP::Client` per call, with connect + read timeouts from the
      # config. `protected` so the spec can stub the transport by reopening
      # the module — no real network in tests (the dispatcher achieves the
      # same with a subclass; a module has no subclass to reach for). The
      # body delegates to the shared `Webhook::Transport`.
      protected def self.post(uri : URI, body : String, headers : ::HTTP::Headers) : ::HTTP::Client::Response
        Transport.post(uri, body, headers)
      end

      private def self.truncate(body : String) : String
        Dispatcher.truncate_body(body)
      end

      # Wall time of one POST, in whole milliseconds.
      private def self.elapsed_ms(started : Time::Instant) : Int64
        Transport.elapsed_ms(started)
      end

      # Multi-value headers collapse to one comma-joined entry per name.
      private def self.header_map(headers : ::HTTP::Headers) : Hash(String, String)
        map = Hash(String, String).new
        headers.each do |name, values|
          map[name] = values.join(", ")
        end
        map
      end
    end
  end
end
