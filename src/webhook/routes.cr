# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../config"
require "../database"
require "../http/helpers"
require "../http/list_request"
require "../jobs/manager"
require "../rbac"
require "../util/script_helpers"
require "./auth_check"
require "./calls"
require "./dispatcher"
require "./test"

module Facet
  module Webhook
    # HTTP routes for the call log and manual replay (decision 9).
    #
    # Registered by `HTTP::Server.routes` between the domain routes and the
    # REST catch-all. Reads against `webhook_calls` — one row per outbound
    # HTTP attempt; enqueueing goes through `Jobs::Manager`.
    #
    # Authorisation mirrors the platform convention (`doc/backend/rbac.md`
    # → Enforcement rules): the caller's `AuthContext` comes from
    # `Helpers.auth_context(env)`, list / show require `read core.Webhook`
    # and replay requires `update core.Webhook` on the webhook document. A
    # denial is a non-disclosing 404 — a not-found and a denied read are
    # indistinguishable.
    #
    # The replay route re-runs the **enqueue-time** RBAC check through
    # `Webhook::AuthCheck` — the exact code path `Webhook::Handler` uses.
    # It is never duplicated here: a drift would let replay deliver on a
    # binding the handler would have skipped.
    module Routes
      # The query key the call-log GET reads beyond the list-request
      # grammar: `status` filters by delivery status. `valid_status?`
      # checks the value before the parse. The strict query admission
      # admits the key.
      CALLS_EXTRA_QUERY_KEYS = Set{"status"}

      def self.register : Nil
        get "/Api/core/Webhook/:id/calls" do |env|
          handle_list(env)
        end

        query "/Api/core/Webhook/:id/calls" do |env|
          handle_query_list(env)
        end

        get "/Api/core/Webhook/:id/calls/:call_id" do |env|
          handle_show(env)
        end

        post "/Api/core/Webhook/:id/calls/:call_id/replay" do |env|
          handle_replay(env)
        end

        post "/Api/core/Webhook/:id/test" do |env|
          handle_test(env)
        end
      end

      # ── Handlers ────────────────────────────────────────────────────────

      # GET reads `status` from the query string. The list parse is strict
      # (B-279): an unknown query key answers `422` naming it; `status` is
      # the one admitted extra key, and `valid_status?` answers `422` for
      # an unknown value.
      private def self.handle_list(env)
        status = env.params.query["status"]?
        return unless valid_status?(env, status)
        list_req = HTTP::Helpers.get_list_request(env, strict: true, extra_query_keys: CALLS_EXTRA_QUERY_KEYS) || return
        render_list(env, list_req, status)
      end

      # QUERY variant: the parameters ride the body only, including the
      # `status` filter (body key `status` — QUERY carries no query string).
      private def self.handle_query_list(env)
        status : String? = nil
        list_req = HTTP::Helpers.query_list_request(env, extra_body_keys: CALLS_EXTRA_QUERY_KEYS) do |body|
          status = body.try(&.["status"]?.try(&.as_s?))
        end
        return if list_req.nil?
        return unless valid_status?(env, status)
        render_list(env, list_req, status)
      end

      private def self.render_list(env, list_req, status)
        HTTP::Helpers.accept_query(env)
        webhook_id = env.params.url["id"]

        result = Database.with_db(:read_only) do |db|
          next not_found unless read_authorized?(db, webhook_id, env)
          Calls.list(db, webhook_id, status, list_req.page, list_req.items)
        end

        if result.is_a?(Facet::ServiceError)
          return HTTP::Helpers.error_response(env, result.status, result.message)
        end
        calls, total = result
        count, _ = HTTP::Helpers.capped_count(total.to_i64, 0)
        # `count` is the real total from this page's offset, truncated at
        # the cap; `more` is true only when counting was truncated (B-297).
        more = total > HTTP::Helpers::COUNT_CAP

        HTTP::Helpers.write_json(env, 200, {
          data: calls.map { |c| JSON.parse(call_json(c)) },
          meta: {count: count, more: more},
        })
      end

      private def self.valid_status?(env, status : String?) : Bool
        return true if status.nil? || Calls::STATUSES.includes?(status)
        HTTP::Helpers.error_response(env, 422, "status must be one of: #{Calls::STATUSES.join(", ")}")
        false
      end

      private def self.handle_show(env)
        webhook_id = env.params.url["id"]
        call_id = env.params.url["call_id"]

        result = Database.with_db(:read_only) do |db|
          next not_found unless read_authorized?(db, webhook_id, env)
          Calls.find(db, webhook_id, call_id) || not_found
        end

        if result.is_a?(Facet::ServiceError)
          return HTTP::Helpers.error_response(env, result.status, result.message)
        end

        HTTP::Helpers.write_json(env, 200, call_json(result))
      end

      private def self.handle_replay(env)
        return unless HTTP::Helpers.require_csrf(env)

        webhook_id = env.params.url["id"]
        call_id = env.params.url["call_id"]

        prepared = Database.with_db do |db|
          next not_found unless RBAC::WriteEnforcer.authorize_update(
                                  db, "core", "Webhook", webhook_id, HTTP::Helpers.auth_context(env)
                                )

          call = Calls.find(db, webhook_id, call_id)
          next not_found if call.nil?

          # Test probes have no parent job to replay.
          job_id = call.job_id
          next Facet::ServiceError.new(422, "Replay rejected: test probes are not replayable") if job_id.nil?

          original = Facet::Jobs::Queries.find(db, job_id)
          next Facet::ServiceError.new(422, "Replay rejected: the original delivery payload is no longer retained") if original.nil?

          envelope = ReplayEnvelope.from_payload(original.payload)
          next Facet::ServiceError.new(422, "Original delivery payload is malformed") if envelope.nil?

          # Decision 9: replay re-runs the enqueue-time check against the
          # current bound identity and the original source document. Same
          # code path as `Webhook::Handler` — see `AuthCheck`. The event
          # name rides along so a job lifecycle delivery uses the same
          # doctype gate it was gated by at enqueue time.
          gate = AuthCheck.call(db, webhook_id, envelope.domain, envelope.doc_type, envelope.doc_id, envelope.event, envelope.content)
          unless gate.is_a?(AuthCheck::Pass)
            next Facet::ServiceError.new(422, "Replay rejected: #{AuthCheck.skip_label(gate)}")
          end

          {envelope, gate}
        end

        if prepared.is_a?(Facet::ServiceError)
          return HTTP::Helpers.error_response(env, prepared.status, prepared.message)
        end
        envelope, gate = prepared

        payload = Payload.new(
          webhook_id: webhook_id,
          delivery_id: Util::ScriptHelpers.ulid,
          event: envelope.event,
          domain: envelope.domain,
          doc_type: envelope.doc_type,
          doc_id: envelope.doc_id,
          mutation_id: envelope.mutation_id,
          actioner_id: envelope.actioner_id,
          cause: envelope.cause,
          content: envelope.content,
          emitted_at: envelope.emitted_at,
          # url / secret / headers re-read from the projection at replay
          # time (decision 9) — a URL fix or header change takes effect on
          # the next replay.
          url: gate.url,
          secret: gate.secret,
          headers: gate.headers,
        )

        mgr = Jobs::Manager.instance
        return HTTP::Helpers.error_response(env, 503, "Jobs subsystem unavailable") if mgr.nil?
        job_id = mgr.enqueue(
          Dispatcher::KIND,
          JSON.parse(payload.to_json),
          max_attempts: Config.instance.webhook.max_attempts,
          backoff: Config.instance.webhook.backoff_seconds,
        )

        HTTP::Helpers.write_json(env, 202, {call_id: call_id, job_id: job_id})
      end

      # The test action (decision 10): the audience that may edit the
      # webhook may test it. Unlike the log routes the denial is a plain
      # 403 — the caller is debugging a webhook they can already see, so
      # the non-disclosing-404 convention buys nothing here. A missing
      # webhook is still a 404, checked before the RBAC gate because the
      # enforcer cannot tell a denied read from an absent document.
      private def self.handle_test(env)
        return unless HTTP::Helpers.require_csrf(env)

        webhook_id = env.params.url["id"]

        result = Database.with_db do |db|
          next not_found unless webhook_exists?(db, webhook_id)
          next Facet::ServiceError.new(403, "Forbidden") unless RBAC::WriteEnforcer.authorize_update(
                                                                  db, "core", "Webhook", webhook_id, HTTP::Helpers.auth_context(env)
                                                                )
          Test.call(db, webhook_id, HTTP::Helpers.auth_context(env))
        end

        if result.is_a?(Facet::ServiceError)
          return HTTP::Helpers.error_response(env, result.status, result.message)
        end

        HTTP::Helpers.write_json(env, 200, {
          http_status:      result.http_status,
          response_body:    result.response_body,
          response_headers: result.response_headers,
          transport_error:  result.transport_error,
          duration_ms:      result.duration_ms,
          signed_body:      result.signed_body,
        })
      end

      # ── Private ───────────────────────────────────────────────────────

      private def self.read_authorized?(db : DB::Connection, webhook_id : String, env) : Bool
        RBAC::ReadEnforcer.authorized?(db, "core", "Webhook", webhook_id, HTTP::Helpers.auth_context(env))
      end

      # Non-disclosing denial — mirrors the RBAC convention: a not-found
      # and a denied read are indistinguishable.
      private def self.not_found : Facet::ServiceError
        Facet::ServiceError.new(404, "Not Found")
      end

      # True when a non-deleted `core.Webhook` projection owns the id.
      private def self.webhook_exists?(db : DB::Connection, webhook_id : String) : Bool
        !db.query_one?("SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Webhook' AND id = $1 AND deleted_at IS NULL", webhook_id, as: Int32).nil?
      end

      # Serializes one call row. The table never holds the signing
      # `secret` (plan decision 5) — nothing to strip.
      private def self.call_json(c : Calls::Call) : String
        {
          id:            c.id,
          webhook_id:    c.webhook_id,
          job_id:        c.job_id,
          event:         c.event,
          source_doc_id: c.source_doc_id,
          mutation_id:   c.mutation_id,
          attempt:       c.attempt,
          status:        c.status,
          http_status:   c.http_status,
          error:         c.error,
          response_body: c.response_body,
          duration_ms:   c.duration_ms,
          created_at:    c.created_at.to_rfc3339,
          updated_at:    c.updated_at.to_rfc3339,
        }.to_json
      end

      # The original envelope fields replayed verbatim (decision 9): the
      # receiver sees the original event with a fresh `delivery_id` and a
      # current signature.
      private record ReplayEnvelope,
        event : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        mutation_id : String?,
        actioner_id : String?,
        cause : JSON::Any?,
        content : JSON::Any,
        emitted_at : String do
        # Extracts the envelope from a stored job payload. Returns nil when
        # a required field is missing or has the wrong type — a corrupt row
        # is never replayed.
        def self.from_payload(payload : JSON::Any) : ReplayEnvelope?
          obj = payload.as_h?
          return nil if obj.nil?

          event = text(obj, "event")
          domain = text(obj, "domain")
          doc_type = text(obj, "doc_type")
          doc_id = text(obj, "doc_id")
          emitted_at = text(obj, "emitted_at")
          content = obj["content"]?
          return nil if event.nil? || domain.nil? || doc_type.nil? || doc_id.nil? ||
                        emitted_at.nil? || content.nil?

          ReplayEnvelope.new(
            event, domain, doc_type, doc_id,
            text(obj, "mutation_id"), text(obj, "actioner_id"), obj["cause"]?,
            content, emitted_at,
          )
        end

        private def self.text(obj : Hash(String, JSON::Any), key : String) : String?
          obj[key]?.try(&.as_s?)
        end
      end
    end
  end
end
