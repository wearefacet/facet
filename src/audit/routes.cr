# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../event"
require "../http/helpers"
require "../http/list_request"
require "../rbac"
require "../doctype/definition_store"
require "./list"
require "./restore"
require "./rollback"

module Facet
  module Audit
    # HTTP routes for audit log access and rollback.
    #
    # Registered by `HTTP::Server.routes`.
    module Routes
      # Mutation ids are ULIDs. The route layer checks the shape before the
      # service runs, so a malformed id answers `422` with a clear message
      # and never reaches `Audit::Rollback` (whose lookup would answer a
      # bare not-found) or the document machinery behind a mis-routed path.
      MUTATION_ID_MESSAGE = "mutation_id must be a ULID"

      # Crockford base32, 26 characters — the canonical (uppercase) ULID
      # shape. Excludes I, L, O, U.
      ULID_SHAPE = /^[0-9A-HJKMNP-TV-Z]{26}$/

      # The query key the document-history GET reads beyond the list-request
      # grammar: `include` turns on the aggregate timeline
      # (`include=children`). The strict query admission admits it. The
      # global list and the child history read no keys beyond the grammar
      # and admit none.
      HISTORY_EXTRA_QUERY_KEYS = Set{"include"}

      # Returns `nil` when the value is a well-formed ULID; otherwise the
      # shared `422` error. All four audit write handlers (global rollback,
      # document rollback, child rollback, restore) run this check.
      private def self.mutation_id_error(value : String) : Facet::ServiceError?
        return nil if ULID_SHAPE.matches?(value)
        Facet::ServiceError.new(422, MUTATION_ID_MESSAGE)
      end

      def self.register : Nil
        # Global audit log: GET|QUERY /Api/Audit
        get "/Api/Audit" do |env|
          handle_global_list(env)
        end

        query "/Api/Audit" do |env|
          handle_query_global_list(env)
        end

        # Global rollback: POST /Api/Audit/:mutation_id/rollback
        post "/Api/Audit/:mutation_id/rollback" do |env|
          handle_global_rollback(env)
        end

        # Document history: GET|QUERY /Api/:domain/:doctype/:id/history
        get "/Api/:domain/:doctype/:id/history" do |env|
          handle_document_history(env)
        end

        query "/Api/:domain/:doctype/:id/history" do |env|
          handle_query_document_history(env)
        end

        # Document rollback: POST /Api/:domain/:doctype/:id/rollback
        post "/Api/:domain/:doctype/:id/rollback" do |env|
          handle_document_rollback(env)
        end

        # Document restore: POST /Api/:domain/:doctype/:id/restore (empty body)
        post "/Api/:domain/:doctype/:id/restore" do |env|
          handle_document_restore(env)
        end

        # Child document history: GET|QUERY /Api/:domain/:doctype/:id/:child/:child_id/history
        get "/Api/:domain/:doctype/:id/:child/:child_id/history" do |env|
          handle_child_history(env)
        end

        query "/Api/:domain/:doctype/:id/:child/:child_id/history" do |env|
          handle_query_child_history(env)
        end

        # Child document rollback: POST /Api/:domain/:doctype/:id/:child/:child_id/rollback
        post "/Api/:domain/:doctype/:id/:child/:child_id/rollback" do |env|
          handle_child_rollback(env)
        end
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.handle_global_list(env)
        list_req = HTTP::Helpers.get_list_request(env, strict: true) || return
        render_global_list(env, list_req)
      end

      private def self.handle_query_global_list(env)
        list_req = HTTP::Helpers.query_list_request(env) || return
        render_global_list(env, list_req)
      end

      private def self.render_global_list(env, list_req)
        HTTP::Helpers.accept_query(env)
        result = Database.with_db(:read_only) { |db| Facet::Audit::List.call(db, filters: list_req.filters, sort: list_req.sort, page: list_req.page, items_per_page: list_req.items, auth_context: HTTP::Helpers.auth_context(env)) }
        HTTP::Helpers.write_audit_list_result(env, result)
      end

      private def self.handle_global_rollback(env)
        return unless HTTP::Helpers.require_csrf(env)

        if err = mutation_id_error(env.params.url["mutation_id"])
          return HTTP::Helpers.error_response(env, err.status, err.message)
        end
        body = HTTP::Helpers.parse_body(env)
        scope = Rollback::Scope::Document
        if body && !body.empty?
          parsed = parse_object_body(env, body) || return
          scope = scope_from_json(env, parsed)
          return if scope.nil?
        end
        result = Database.with_transaction do |db|
          Facet::Audit::Rollback.call(db, env.params.url["mutation_id"], HTTP::Helpers.auth_context(env), scope: scope)
        end
        Event::Publisher.flush
        HTTP::Helpers.write_audit_rollback_result(env, result)
      end

      # Parses a rollback request body as a JSON object. A scalar or array
      # body answers `422` — the `#[]?` probes in the handlers would raise
      # on the wrapped value and surface as a `500`. Returns `nil` after
      # writing the error response.
      private def self.parse_object_body(env, raw : String) : JSON::Any?
        parsed = begin
          JSON.parse(raw)
        rescue
          HTTP::Helpers.error_response(env, 422, "Invalid JSON body")
          return nil
        end
        unless parsed.as_h?
          HTTP::Helpers.error_response(env, 422, "Invalid JSON body — the request body must be a JSON object")
          return nil
        end
        parsed
      end

      # Resolves the rollback `scope` (`"document"` | `"cluster"`) from a
      # parsed request body. Returns `Document` when the field is absent (the
      # default). Writes a `422` and returns `nil` for an unknown value or a
      # non-string value.
      private def self.scope_from_json(env, parsed : JSON::Any) : Rollback::Scope?
        raw_value = parsed["scope"]?
        case raw_value
        when Nil
          Rollback::Scope::Document
        when JSON::Any
          raw = raw_value.as_s?
          case raw
          when "document"
            Rollback::Scope::Document
          when "cluster"
            Rollback::Scope::Cluster
          else
            # A non-string value lands here too: the refusal stays a `422`
            # instead of surfacing as a `500` from a raising cast.
            HTTP::Helpers.error_response(env, 422, "scope must be 'document' or 'cluster'")
            nil
          end
        end
      end

      # Document history. `include=children` switches on the aggregate
      # timeline: parent rows plus readable child rows (the child RBAC
      # filter runs inside `Audit::List`). Any other `include` value is
      # ignored — the param is opt-in and `children` is its only value.
      #
      # The GET parse is strict (B-279): an unknown query key answers `422`
      # naming it; `include` is the one admitted extra key. Filters ride
      # the bracket form (`?filters[action__eq]=create`) or the QUERY body.
      # QUERY reads the flag from the body (`{"include": "children"}`) —
      # QUERY carries no query string.
      private def self.handle_document_history(env)
        list_req = HTTP::Helpers.get_list_request(env, strict: true, extra_query_keys: HISTORY_EXTRA_QUERY_KEYS) || return
        include_children = env.params.query["include"]? == "children"
        render_document_history(env, list_req, include_children)
      end

      private def self.handle_query_document_history(env)
        include_children = false
        list_req = HTTP::Helpers.query_list_request(env) do |body|
          include_children = body.try(&.["include"]?.try(&.as_s?)) == "children"
        end
        return if list_req.nil?
        render_document_history(env, list_req, include_children)
      end

      private def self.render_document_history(env, list_req, include_children)
        HTTP::Helpers.accept_query(env)
        result = Database.with_db(:read_only) do |db|
          Facet::Audit::List.call(
            db,
            domain: env.params.url["domain"],
            doc_type: env.params.url["doctype"],
            doc_id: env.params.url["id"],
            filters: list_req.filters,
            sort: list_req.sort,
            page: list_req.page,
            items_per_page: list_req.items,
            auth_context: HTTP::Helpers.auth_context(env),
            include_children: include_children,
          )
        end
        HTTP::Helpers.write_audit_list_result(env, result)
      end

      private def self.handle_document_rollback(env)
        return unless HTTP::Helpers.require_csrf(env)

        body = HTTP::Helpers.require_body(env) || return
        parsed = parse_object_body(env, body) || return
        mutation_id = parsed["mutation_id"]?.try(&.as_s?)
        if mutation_id.nil?
          return HTTP::Helpers.error_response(env, 422, "Body must include 'mutation_id' field")
        end
        if err = mutation_id_error(mutation_id)
          return HTTP::Helpers.error_response(env, err.status, err.message)
        end
        scope = scope_from_json(env, parsed)
        return if scope.nil?
        result = Database.with_transaction do |db|
          Facet::Audit::Rollback.call(db, mutation_id, HTTP::Helpers.auth_context(env), scope: scope,
            retention_scope: {domain: env.params.url["domain"], doc_type: env.params.url["doctype"]})
        end
        Event::Publisher.flush
        HTTP::Helpers.write_audit_rollback_result(env, result)
      end

      # Resolves the pre-delete mutation internally and delegates to
      # `Audit::Rollback.call` — the same machinery the manual two-step
      # rollback flow uses, wrapped into a single user action. Resolve and
      # rollback run inside one transaction so a concurrent restore (or a
      # delete racing the resolve) serializes on the row lock: the second
      # caller reads the now-live projection, finds no trailing `delete`, and
      # gets `409`. Empty body by design — the target is the URL document.
      private def self.handle_document_restore(env)
        return unless HTTP::Helpers.require_csrf(env)

        result = Database.with_transaction do |db|
          target = Facet::Audit::Restore.resolve_target(
            db,
            env.params.url["domain"],
            env.params.url["doctype"],
            env.params.url["id"],
          )
          next target if target.is_a?(Facet::ServiceError)
          # Defensive: the resolved target is a database-owned mutation id.
          # The route-layer ULID contract holds for it the same as for the
          # caller-supplied ids (the error renders as the shared 422 body).
          if err = mutation_id_error(target)
            next err
          end
          Facet::Audit::Rollback.call(db, target, HTTP::Helpers.auth_context(env),
            retention_scope: {domain: env.params.url["domain"], doc_type: env.params.url["doctype"]})
        end
        Event::Publisher.flush
        HTTP::Helpers.write_audit_rollback_result(env, result)
      end

      private def self.handle_child_history(env)
        list_req = HTTP::Helpers.get_list_request(env, strict: true) || return
        render_child_history(env, list_req)
      end

      private def self.handle_query_child_history(env)
        list_req = HTTP::Helpers.query_list_request(env) || return
        render_child_history(env, list_req)
      end

      private def self.render_child_history(env, list_req)
        HTTP::Helpers.accept_query(env)
        result = Database.with_db(:read_only) do |db|
          child_doctype = resolve_child_doctype(db, env)
          next child_doctype if child_doctype.is_a?(Facet::ServiceError)
          Facet::Audit::List.call(
            db,
            domain: env.params.url["domain"],
            doc_type: child_doctype,
            doc_id: env.params.url["child_id"],
            filters: list_req.filters,
            sort: list_req.sort,
            page: list_req.page,
            items_per_page: list_req.items,
            auth_context: HTTP::Helpers.auth_context(env),
          )
        end
        HTTP::Helpers.write_audit_list_result(env, result)
      end

      # Resolves the nested `:child` segment to the child doctype name the
      # history query filters on. The route serves the relationship-name
      # shape only: the segment must be a key of the parent definition's
      # `children` map — the same resolution the nested create path uses
      # (`Document::CreateWithChildren`). A child-doctype-name segment is
      # not a relationship name and misses the map, and so does an unknown
      # segment; both answer `404` naming the unresolvable segment instead
      # of a silent `200` with an empty page (B-197).
      private def self.resolve_child_doctype(db : DB::Connection, env) : String | Facet::ServiceError
        parent_id = "#{env.params.url["domain"]}.#{env.params.url["doctype"]}"
        segment = env.params.url["child"]

        defn = Facet::Doctype::DefinitionStore.fetch!(db, parent_id)
        return defn if defn.is_a?(Facet::ServiceError)

        child = defn.children[segment]?
        return Facet::ServiceError.new(404, "Unknown child '#{segment}'") if child.nil?

        child.doctype
      end

      private def self.handle_child_rollback(env)
        return unless HTTP::Helpers.require_csrf(env)

        body = HTTP::Helpers.require_body(env) || return
        parsed = parse_object_body(env, body) || return
        mutation_id = parsed["mutation_id"]?.try(&.as_s?)
        if mutation_id.nil?
          return HTTP::Helpers.error_response(env, 422, "Body must include 'mutation_id' field")
        end
        if err = mutation_id_error(mutation_id)
          return HTTP::Helpers.error_response(env, err.status, err.message)
        end
        result = Database.with_transaction do |db|
          Facet::Audit::Rollback.call(db, mutation_id, HTTP::Helpers.auth_context(env),
            retention_scope: {domain: env.params.url["domain"], doc_type: env.params.url["doctype"]})
        end
        Event::Publisher.flush
        HTTP::Helpers.write_audit_rollback_result(env, result)
      end
    end
  end
end
