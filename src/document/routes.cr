# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../event"
require "../http/helpers"
require "../http/list_request"
require "../rbac"
require "../rbac/write_enforcer"
require "../document/create"
require "../document/create_with_children"
require "../document/read"
require "../document/backrefs"
require "../document/update"
require "../document/delete"
require "../document/list"
require "../doctype"
require "../artifact/multipart"
require "../artifact/owners"

module Facet
  module Document
    # HTTP routes for document CRUD operations.
    #
    # Registered by `HTTP::Server.routes`.
    module Routes
      def self.register : Nil
        post "/Api/:domain/:doctype" do |env|
          domain = env.params.url["domain"]
          doc_type = env.params.url["doctype"]
          handle_create(env, domain, doc_type)
        end

        get "/Api/:domain/:doctype" do |env|
          handle_list(env)
        end

        query "/Api/:domain/:doctype" do |env|
          handle_query_list(env)
        end

        get "/Api/:domain/:doctype/:id" do |env|
          handle_read(env)
        end

        patch "/Api/:domain/:doctype/:id" do |env|
          handle_update(env)
        end

        delete "/Api/:domain/:doctype/:id" do |env|
          handle_delete(env)
        end

        # Document backlinks: GET|QUERY /Api/:domain/:doctype/:id/backrefs
        get "/Api/:domain/:doctype/:id/backrefs" do |env|
          handle_backrefs(env)
        end

        query "/Api/:domain/:doctype/:id/backrefs" do |env|
          handle_query_backrefs(env)
        end
      end

      # ── Handlers ────────────────────────────────────────────────────────

      # Rejects flat creates that must go through a parent-scoped route:
      # `member_of` children and sidecar doctypes. Returns the 422 error,
      # or nil when the flat create may proceed.
      #
      # `core.DocType` is exempt: `member_of: Domain` describes the
      # composition tree, not the create surface. There is no separate
      # doctype-create route — the flat `POST /Api/core/DocType` IS the
      # authoring API, and `Document::Create` routes it into
      # `Doctype::Create`.
      private def self.nested_create_guard(
        defn : Facet::Doctype::DoctypeDefinition,
        domain : String,
        doc_type : String,
      ) : Facet::ServiceError?
        return nil if {domain, doc_type} == {"core", "DocType"}
        if defn.member_of
          return Facet::ServiceError.new(422, "Document '#{doc_type}' belongs to '#{defn.member_of}'; create it through the parent's nested route")
        end
        if defn.sidecar
          return Facet::ServiceError.new(422, "Sidecar doctypes cannot be created through the flat route; use the nested route on the host document")
        end
        nil
      end

      private def self.handle_create(env, domain, doc_type)
        return unless HTTP::Helpers.require_csrf(env)

        auth_ctx = HTTP::Helpers.auth_context(env)

        # Multipart body: `$content` JSON + file parts. Uploads run inside
        # the mutation transaction so a failed create rolls back both the
        # document and the owner rows.
        if multipart_body = handle_multipart_create(env, domain, doc_type, auth_ctx)
          return multipart_body
        end

        body = HTTP::Helpers.require_body(env) || return
        return if reject_unsupported_media(env)
        parsed = parse_create_body(env, body) || return
        result = Database.with_transaction do |db|
          if parsed.as_h?.try(&.has_key?("$content"))
            Facet::Document::CreateWithChildren.call(db, domain, doc_type, body, HTTP::Helpers.auth_context(env))
          else
            doctype_id = "#{domain}.#{doc_type}"
            defn = Facet::Doctype::DefinitionStore.fetch(db, doctype_id)
            if defn && (guard = nested_create_guard(defn, domain, doc_type))
              next guard
            end
            Facet::Document::Create.call(db, domain, doc_type, body, HTTP::Helpers.auth_context(env))
          end
        end
        Event::Publisher.flush
        HTTP::Helpers.write_result(env, result, 201)
      end

      # Multipart intake of the flat create route. Uploads and the create
      # share one transaction. Returns the response body (the caller hands
      # it to Kemal — `write_result` does not print it), or nil when the
      # request was not multipart.
      private def self.handle_multipart_create(env, domain, doc_type, auth_ctx) : String?
        return nil unless multipart?(env)

        parsed = Facet::Artifact::Multipart.parse(env)
        if parsed.is_a?(Facet::ServiceError)
          return HTTP::Helpers.error_response(env, parsed.status, parsed.message)
        end

        result = begin
          Database.with_transaction do |db|
            doctype_id = "#{domain}.#{doc_type}"
            defn = Facet::Doctype::DefinitionStore.fetch!(db, doctype_id)
            if defn.is_a?(Facet::ServiceError)
              next defn
            end
            if guard = nested_create_guard(defn, domain, doc_type)
              next guard
            end

            # Mint the doc id up-front so the uploader can record owner rows
            # against it; `Document::Create` accepts the override.
            doc_id = Facet::Util::ScriptHelpers.ulid
            uploaded = Facet::Artifact::Multipart.upload_files(
              db, auth_ctx, parsed, defn, domain, doc_type, doc_id, auth_ctx.account_id,
            )
            Facet::Document::Create.call(db, domain, doc_type, uploaded.to_json, auth_ctx, doc_id: doc_id)
          end
        rescue ex : Facet::Artifact::Multipart::UploadFailed
          Facet::Artifact::Multipart.cleanup(parsed)
          return HTTP::Helpers.error_response(env, ex.error.status, ex.error.message)
        end
        Event::Publisher.flush
        Facet::Artifact::Multipart.cleanup(parsed)
        HTTP::Helpers.write_result(env, result, 201)
      end

      private def self.handle_list(env)
        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        defn = resolve_list_doctype(env, domain, doc_type) || return
        list_req = strict_list_request(env) || return
        return unless validate_list_select(env, defn, list_req.select)
        render_list(env, list_req)
      end

      # QUERY variant of the collection list: the parameters ride the body
      # only (see `Helpers.query_list_request`), the render is shared with
      # GET.
      private def self.handle_query_list(env)
        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        defn = resolve_list_doctype(env, domain, doc_type) || return
        list_req = strict_query_list_request(env) || return
        return unless validate_list_select(env, defn, list_req.select)
        render_list(env, list_req)
      end

      # ── Doctype pre-check and admitted-param shapes (B-366 / B-358) ──
      #
      # The flat collection routes resolve the doctype definition BEFORE
      # the strict parameter parse: an unknown `{domain}/{doctype}`
      # answers the same 404 the list service answers in-render, so the
      # list grammar's 422s never leak for a path that names no doctype.
      # The fetch rides the cached definition store, so the pre-check
      # costs one cache hit on the hot path.
      #
      # The same resolved definition validates the admitted `select`
      # parameter: `select` projects each row's `content` to the named
      # top-level keys, so a key outside the declared field set would
      # answer `{}` rows — a wrong shape, not an error. System identity
      # (`id`, timestamps, `display_name`) lives in `meta`, never in
      # `content`, so no system key is honoured and none is admitted.

      # ── Strict list admission (the B-169 remainder) ──────────────
      #
      # The collection list surfaces answer `422` for a parameter outside
      # the list grammar, naming it — a misspelled parameter must not
      # vanish into a `200`. The parse runs AFTER the doctype pre-check
      # (above), so an unknown doctype answers 404, never the grammar's
      # 422 (B-366). The GET shim parses through `ListRequest`
      # with `strict: true` (the same parse `Gates.get_list_request` runs
      # with the strict flag), and the QUERY shim reuses
      # `Gates.query_body_json` — the same body-only transport contract
      # (query-string `422`, `415` media-type gate, JSON-object gate) —
      # with the strict body parse. The audit-history and webhook-calls
      # lists hold the same contract: they parse through
      # `Gates.get_list_request` with `strict: true` and name `include` /
      # `status` as their admitted extras.
      private def self.strict_list_request(env) : Facet::HTTP::ListRequest?
        result = Facet::HTTP::ListRequest.from_request(env, strict: true)
        if result.is_a?(Facet::ServiceError)
          HTTP::Helpers.error_response(env, result.status, result.message)
          return nil
        end
        result
      end

      private def self.strict_query_list_request(env) : Facet::HTTP::ListRequest?
        parsed = HTTP::Helpers.query_body_json(env) || return nil
        result = Facet::HTTP::ListRequest.from_json(parsed, strict: true)
        if result.is_a?(Facet::ServiceError)
          HTTP::Helpers.error_response(env, result.status, result.message)
          return nil
        end
        result
      end

      # Resolves the doctype definition for the flat collection routes, or
      # nil after writing the 404 (B-366). Same answer the list service
      # gives in-render, same wording, reached before the strict parse.
      private def self.resolve_list_doctype(
        env,
        domain : String,
        doc_type : String,
      ) : Facet::Doctype::DoctypeDefinition?
        defn = Database.with_db(:read_only) { |db| HTTP::Helpers.fetch_doctype_defn(db, "#{domain}.#{doc_type}") }
        return defn if defn

        HTTP::Helpers.error_response(env, 404, "Unknown doctype: #{domain}.#{doc_type}")
        nil
      end

      # Validates the `select` keys against the doctype's declared fields
      # (B-358). Returns false after writing the 422 — it names the first
      # unknown key and the accepted set, the same shape the filter
      # grammar's `unknown_filter_field` 422 uses on the same surface.
      # Shared with the nested child list route, which validates `select`
      # against the child doctype's definition.
      def self.validate_list_select(
        env,
        defn : Facet::Doctype::DoctypeDefinition,
        sel : Array(String)?,
      ) : Bool
        return true if sel.nil?

        unknown = sel.reject { |key| defn.fields.has_key?(key) }
        return true if unknown.empty?

        accepted = defn.fields.keys.sort!
        HTTP::Helpers.error_response(
          env,
          422,
          "Unknown select key '#{unknown.first}' (accepted: #{accepted.join(", ")})",
        )
        false
      end

      private def self.render_list(env, list_req)
        HTTP::Helpers.accept_query(env)
        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        auth_ctx = HTTP::Helpers.auth_context(env)

        # ETag short-circuit
        version = Database.with_db(:read_only) { |db| Facet::Document::List.collection_version(db, domain, doc_type) }
        version_tag = version.try(&.to_rfc3339(fraction_digits: 6)) || "empty"
        request_digest = HTTP::Helpers.list_request_fingerprint(list_req)
        collection_tag = "#{HTTP::Helpers.role_fingerprint(auth_ctx)}:#{request_digest}:#{version_tag}"
        if HTTP::Helpers.not_modified?(env, collection_tag)
          return HTTP::Helpers.write_not_modified(env, collection_tag)
        end

        result = begin
          Database.with_db(:read_only) { |db| Facet::Document::List.call(db, domain, doc_type, filters: list_req.filters, sort: list_req.sort, page: list_req.page, items_per_page: list_req.items, auth_context: auth_ctx, aggregate: list_req.aggregate, field: list_req.field, named_scope: list_req.scope, include_deleted: list_req.include_deleted?) }
        rescue ex : PQ::PQError
          # Aggregate requests run uncapped (the global statement_timeout is
          # the cost guard), so a cancelled statement is an expected,
          # actionable outcome: 503 with a retry hint, not a 500. Plain
          # list/count requests keep failing loud — a timeout there is a
          # bug or an ops problem, not a caller error.
          raise ex unless list_req.aggregate && HTTP::Helpers.statement_timeout?(ex)
          return HTTP::Helpers.error_response(env, 503, "The request exceeded the server's statement timeout — narrow the filters and retry")
        end
        case result
        in Facet::Document::List::Result
          env.response.status_code = 200
          env.response.content_type = "application/json"
          HTTP::Helpers.set_etag_header(env, collection_tag)
          # `result.total` is already the real count from the page offset
          # (truncated at the cap by the service), so no offset is added
          # here. `more` comes from the service and is true only when
          # counting was truncated (B-297).
          count, _ = HTTP::Helpers.capped_count(result.total, 0)
          {data: HTTP::Helpers.projection_list(result.items, select_fields: list_req.select), meta: {count: count, more: result.more}}.to_json
        in Facet::Document::List::AggregateResult
          # Sum payload, not rows. `count` is the full contributing-row
          # count from the same statement and `more` is always false — the
          # sum honours the total, so there is no cap to compare against.
          env.response.status_code = 200
          env.response.content_type = "application/json"
          HTTP::Helpers.set_etag_header(env, collection_tag)
          {data: {value: result.value}, meta: {count: result.count, more: false}}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      private def self.handle_read(env)
        raw = env.request.body.try(&.gets_to_end)
        sel = if raw.nil? || raw.empty?
                query_req = HTTP::ListRequest.from_query(env.params.query)
                if query_req.is_a?(Facet::ServiceError)
                  return HTTP::Helpers.error_response(env, query_req.status, query_req.message)
                end
                query_req.select
              else
                body_req = HTTP::ListRequest.from_json(raw)
                if body_req.is_a?(Facet::ServiceError)
                  return HTTP::Helpers.error_response(env, body_req.status, body_req.message)
                end
                query_req = HTTP::ListRequest.from_query(env.params.query)
                if query_req.is_a?(Facet::ServiceError)
                  return HTTP::Helpers.error_response(env, query_req.status, query_req.message)
                end
                query_req.select || body_req.select
              end
        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        doc_id = HTTP::Helpers.canonical_doc_id(domain, doc_type, env.params.url["id"])
        result = Database.with_db(:read_only) { |db| Facet::Document::Read.call(db, domain, doc_type, doc_id, HTTP::Helpers.auth_context(env)) }
        case result
        in Facet::Document::Read::Result
          doc_tag = result.projection.state
          if HTTP::Helpers.not_modified?(env, doc_tag)
            env.response.headers["X-Document-Migrated"] = result.migrated.to_s
            return HTTP::Helpers.write_not_modified(env, doc_tag)
          end

          env.response.status_code = 200
          env.response.content_type = "application/json"
          env.response.headers["X-Document-Migrated"] = result.migrated.to_s
          HTTP::Helpers.set_etag_header(env, doc_tag)
          data = if sel
                   HTTP::Helpers.subset_json(result.projection.content, sel)
                 else
                   result.projection.content
                 end
          {
            data: data,
            meta: HTTP::Helpers.document_meta(result.projection),
          }.to_json
        in Facet::ServiceError
          env.response.headers["X-Document-Deleted"] = "true" if result.status == 410
          # Pass the error `meta` through (e.g. the tombstone `display_name` /
          # `deleted_at` on a 410) so the UI can render the surviving label.
          HTTP::Helpers.error_response(env, result.status, result.message, result.details, result.meta)
        end
      end

      private def self.handle_update(env)
        return unless HTTP::Helpers.require_csrf(env)

        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        doc_id = HTTP::Helpers.canonical_doc_id(domain, doc_type, env.params.url["id"])
        auth_ctx = HTTP::Helpers.auth_context(env)

        # Multipart update: `$content` JSON + file parts. Uploads run inside
        # the mutation transaction.
        if multipart?(env)
          parsed = Facet::Artifact::Multipart.parse(env)
          if parsed.is_a?(Facet::ServiceError)
            return HTTP::Helpers.error_response(env, parsed.status, parsed.message)
          end

          result = begin
            Database.with_transaction do |db|
              next Facet::ServiceError.new(404, "Not found") unless HTTP::Helpers.lock_with_chain(db, domain, doc_type, doc_id)
              doctype_id = "#{domain}.#{doc_type}"
              defn = Facet::Doctype::DefinitionStore.fetch!(db, doctype_id)
              if defn.is_a?(Facet::ServiceError)
                next defn
              end
              uploaded = Facet::Artifact::Multipart.upload_files(
                db, auth_ctx, parsed, defn, domain, doc_type, doc_id, auth_ctx.account_id,
              )
              Facet::Document::Update.call(db, domain, doc_type, doc_id, uploaded.to_json, auth_ctx)
            end
          rescue ex : Facet::Artifact::Multipart::UploadFailed
            Facet::Artifact::Multipart.cleanup(parsed)
            return HTTP::Helpers.error_response(env, ex.error.status, ex.error.message)
          end
          Event::Publisher.flush
          Facet::Artifact::Multipart.cleanup(parsed)
          return HTTP::Helpers.write_result(env, result)
        end

        body = HTTP::Helpers.require_body(env) || return
        return if reject_unsupported_media(env)
        result = Database.with_transaction do |db|
          next Facet::ServiceError.new(404, "Not found") unless HTTP::Helpers.lock_with_chain(db, domain, doc_type, doc_id)
          Facet::Document::Update.call(db, domain, doc_type, doc_id, body, auth_ctx)
        end
        Event::Publisher.flush
        HTTP::Helpers.write_result(env, result)
      end

      # Media-type answer shared by the flat create and update routes. It
      # mirrors the nested gate's wording and names the multipart intake
      # this route keeps for file uploads.
      MEDIA_TYPE_MESSAGE = "Unsupported media type — document routes accept application/json " \
                           "(multipart/form-data is accepted for file uploads)"

      # Flat-route media gate: a declared non-JSON Content-Type is a caller
      # error — 415, mirroring the nested gate's answer (B-113). A
      # multipart body never reaches here: the upload branch handles it
      # first, and a body with no Content-Type at all keeps the flat
      # routes' tolerance — the body itself must parse. Returns true when
      # the error was written.
      private def self.reject_unsupported_media(env) : Bool
        header = env.request.headers["Content-Type"]?
        return false if header.nil? || HTTP::Helpers.json_content_type?(header)
        HTTP::Helpers.error_response(env, 415, MEDIA_TYPE_MESSAGE)
        true
      end

      # Parses the flat create body once, before the transaction. A
      # malformed body answers 400 at the earliest parse point — never the
      # 5xx an unguarded parse raised. Returns nil after writing the error.
      private def self.parse_create_body(env, body : String) : JSON::Any?
        JSON.parse(body)
      rescue ex : JSON::ParseException
        HTTP::Helpers.error_response(env, 400, "Invalid JSON body: #{ex.message}")
        nil
      end

      # Returns true when the request body is `multipart/form-data` — the
      # signal that file parts are present and the body must be parsed as
      # multipart rather than JSON.
      private def self.multipart?(env) : Bool
        env.request.headers["Content-Type"]?.try(&.starts_with?("multipart/form-data")) || false
      end

      private def self.handle_delete(env)
        return unless HTTP::Helpers.require_csrf(env)

        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        doc_id = HTTP::Helpers.canonical_doc_id(domain, doc_type, env.params.url["id"])
        result = Database.with_transaction do |db|
          next Facet::ServiceError.new(404, "Not found") unless HTTP::Helpers.lock_with_chain(db, domain, doc_type, doc_id)
          Facet::Document::Delete.call(db, domain, doc_type, doc_id, HTTP::Helpers.auth_context(env))
        end
        Event::Publisher.flush
        HTTP::Helpers.write_result(env, result)
      end

      # ── Backrefs ─────────────────────────────────────────────────────

      private def self.handle_backrefs(env)
        list_req = HTTP::Helpers.get_list_request(env) || return
        render_backrefs(env, list_req)
      end

      private def self.handle_query_backrefs(env)
        list_req = HTTP::Helpers.query_list_request(env) || return
        render_backrefs(env, list_req)
      end

      # Only the `items` cap rides the list-request grammar (server max 1000,
      # default 100) — no filters or sort in v1: the query shape is fixed,
      # the target's URN needle. The target read gate is the authorization
      # (same rule as `/history`); referrer rows stay inside each doctype's
      # list visibility. No ETag: the result changes when any referrer
      # mutates, and a collection tag over the fan-out would cost more than
      # it saves.
      private def self.render_backrefs(env, list_req)
        HTTP::Helpers.accept_query(env)
        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        doc_id = HTTP::Helpers.canonical_doc_id(domain, doc_type, env.params.url["id"])
        result = Database.with_db(:read_only) do |db|
          Facet::Document::Backrefs.call(
            db, HTTP::Helpers.auth_context(env), domain, doc_type, doc_id,
            limit: list_req.items,
          )
        end
        case result
        in Facet::Document::Backrefs::Result
          env.response.status_code = 200
          data = result.items.map do |item|
            {"id" => item.id, "domain" => item.domain, "doc_type" => item.doc_type, "display_name" => item.display_name}
          end
          {data: data, meta: {target: result.target_urn, total: result.items.size, capped: result.capped}}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message, result.details, result.meta)
        end
      end
    end
  end
end
