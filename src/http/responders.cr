# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../util/pg_error"
require "../validation_error"
require "../error"
require "../mutation/client"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../document/presenter"
require "./caching"
require "../document/create"
require "../document/create_with_children"
require "../document/action"
require "../document/update"
require "../document/read"
require "../document/delete"
require "../doctype/update"
require "../audit/list"
require "../audit/rollback"

module Facet
  module HTTP
    # JSON response and error writing for the route handlers. Owns the
    # response body builders, the error writers, and the PG error checks
    # the error handler uses to pick a status.
    module Responders
      extend self

      # Logger for request-error traces. Separate from Kemal's request log
      # (which only records status + method + path + elapsed) so operators
      # can see *why* a request failed without inspecting response bodies.
      HTTP_LOG = ::Log.for("facet.http")

      # SQLSTATE of a statement the server cancelled (`query_canceled`, PG
      # class 57 — operator intervention). `statement_timeout` raises this
      # when a statement runs past the session's configured budget.
      STATEMENT_TIMEOUT_SQLSTATE = "57014"

      # SQLSTATE of a unique-constraint violation (`unique_violation`).
      UNIQUE_VIOLATION_SQLSTATE = "23505"

      # The unique index that orders the mutation log per document — see
      # `db/migrations/0001_document_store.sql`. A 23505 on this index is
      # the concurrent-write race the index exists to catch.
      MUTATION_IDX_INDEX = "idx_mutations_doc_id_idx"

      # Name prefix of every managed per-doctype index — see
      # `Index::Naming::PREFIX`. The `unique_btree` members of that family
      # enforce `unique: true` field constraints at the database level.
      MANAGED_INDEX_PREFIX = "idx_env_"

      # True when the exception is the concurrent-write race on the mutation
      # log: the insert trigger assigns `idx = MAX(idx)+1` per document, and
      # the unique index `idx_mutations_doc_id_idx` is the guard when two
      # writers read the same `MAX(idx)` before either commits. Update and
      # delete writers take the projection row lock first, so in practice the
      # race is the create path with a client-supplied doc id. Surfaces as
      # HTTP 409 with a retry hint (see `JsonErrorHandler`) — there is no
      # server-side retry; a fresh write reads the committed `MAX(idx)` and
      # takes the next free slot. SQLSTATE and constraint name are read via
      # the shared `Util::PgError` extractor.
      def mutation_write_conflict?(ex : Exception) : Bool
        return false unless ex.is_a?(PQ::PQError)
        Util::PgError.sqlstate(ex) == UNIQUE_VIOLATION_SQLSTATE &&
          Util::PgError.constraint_name(ex) == MUTATION_IDX_INDEX
      end

      # True when the exception is a `unique: true` field constraint
      # enforced by a managed unique index on `projections` (an
      # `idx_env_*` `unique_btree` member from `Index::Planner`). The
      # Crystal pre-check (`Document::UniqueConstraint`) answers the
      # common case with a clean 422; this classifier catches the race
      # the pre-check cannot see — a competing write that committed
      # between the check and the mutation insert. Surfaces as HTTP 422
      # (see `JsonErrorHandler`), the same status the pre-check answers.
      def projection_unique_conflict?(ex : Exception) : Bool
        return false unless ex.is_a?(PQ::PQError)
        return false unless Util::PgError.sqlstate(ex) == UNIQUE_VIOLATION_SQLSTATE
        name = Util::PgError.constraint_name(ex)
        !name.nil? && name.starts_with?(MANAGED_INDEX_PREFIX)
      end

      # Builds the 422 validation error for a lost unique-index race.
      # The index name hashes the (domain, doctype, field, type) tuple, so
      # the field name is not recoverable from it; the server's `Detail:`
      # line names the conflicting key and value instead
      # (`Key (content->>'email')=(a@b.c) already exists.`). The detail is
      # stable server output quoted verbatim — no SQL, no backtrace — so
      # carrying it in the response is safe. When the detail is absent the
      # message stays generic.
      def projection_unique_conflict_error(ex : PQ::PQError) : Facet::ValidationError
        message = if detail = Util::PgError.detail(ex)
                    "Value conflicts with a unique field constraint — #{detail}"
                  else
                    "Value conflicts with a unique field constraint"
                  end
        Facet::ValidationError.new(message: message, code: "unique")
      end

      # True when the exception is a PG cancellation the caller can act on:
      # the statement exceeded the session's `statement_timeout` and should
      # surface as HTTP 503 (retry with a narrower filter) rather than a
      # generic 500. SQLSTATE 57014 = `query_canceled` (PG class 57 —
      # operator intervention), read via the shared `Util::PgError` extractor.
      def statement_timeout?(ex : Exception) : Bool
        return false unless ex.is_a?(PQ::PQError)
        Util::PgError.sqlstate(ex) == STATEMENT_TIMEOUT_SQLSTATE
      end

      # ── Dependency-unavailable classification ───────────────────────────

      # The dependencies a request path can find down, keyed by the name the
      # 503 body carries. The healthcheck reports the same names.
      DEPENDENCIES = {"redis" => "redis", "postgresql" => "postgresql"}

      # The dependency an exception says is down, or nil — the `503`
      # classification. Only connection-level exception classes match, so a
      # programming error never maps to a dependency status:
      #
      # - `Socket::ConnectError` — a refused connection (the Redis client
      #   dials a `TCPSocket`, so an unreachable Redis surfaces here).
      # - `Socket::Addrinfo::Error` — an unresolved host (a `redis://` URL
      #   whose host does not resolve).
      # - `DB::ConnectionRefused` — the PostgreSQL pool cannot reach its
      #   server.
      #
      # `Redis::Error` is deliberately NOT matched: it is the base class of
      # every Redis protocol and command error, so a malformed command would
      # masquerade as an outage. The Redis paths here (sessions, login
      # throttle, codes) build their commands from constants, so a
      # connection-level failure is the only realistic failure they raise.
      #
      # The two socket classes are not Redis-specific, but the only outbound
      # socket dials on a request path are Redis (the event publisher is
      # fail-silent and the mailer is out of band), so naming `redis` is the
      # correct attribution for them.
      def dependency_unavailable?(ex : Exception) : String?
        case ex
        when ::Socket::ConnectError, ::Socket::Addrinfo::Error
          DEPENDENCIES["redis"]
        when ::DB::ConnectionRefused
          DEPENDENCIES["postgresql"]
        end
      end

      # ── JSON error responses ──────────────────────────────────────────────

      # Stamps `Cache-Control: no-store` on an error response. 404 and 410
      # are cacheable by default (RFC 9111 — no explicit header needed for a
      # browser to store them), so without this a cached tombstone would
      # keep reporting "deleted" after the document is restored or the
      # database is re-seeded under the same id. Headers must be
      # set before the body is printed — Kemal commits them on first write.
      def no_store(env) : Nil
        env.response.headers["Cache-Control"] = "no-store"
      end

      # Builds a JSON error string with an optional `details` array and
      # optional flat `meta` key/values merged into the body (e.g. the
      # tombstone fields on a `410`).
      def json_error(
        status : Int32,
        message : String,
        details : Array(ValidationError)? = nil,
        meta : Hash(String, String)? = nil,
      ) : String
        if meta && !meta.empty?
          JSON.build do |json|
            json.object do
              json.field("error", message)
              if details && !details.empty?
                json.field("details") { details.to_json(json) }
              end
              meta.each { |key, value| json.field(key, value) }
            end
          end
        elsif details && !details.empty?
          {error: message, details: details}.to_json
        else
          {error: message}.to_json
        end
      end

      # Writes a JSON error response directly to the env.
      def write_json_error(env, status : Int32, message : String, details : Array(ValidationError)? = nil) : Nil
        env.response.status_code = status
        env.response.print(json_error(status, message, details))
        log_request_error(env, status, message, details)
      end

      # Sets the status, prints the JSON error body, and returns an empty
      # string for the route value. Routes must NOT return a body string:
      # when a status-level error handler is registered (the JSON `error 404`
      # that blocks Kemal's HTML default), Kemal's `process_request` raises
      # `CustomException` instead of printing the returned value — so the
      # body must already be on the response.
      def error_response(env, status : Int32, message : String, details : Array(ValidationError)? = nil, meta : Hash(String, String)? = nil) : String
        env.response.status_code = status
        env.response.content_type = "application/json"
        no_store(env)
        env.response.print(json_error(status, message, details, meta))
        log_request_error(env, status, message, details)
        ""
      end

      # Sets the status, prints any payload as JSON, and returns an empty
      # string for the route value (same convention as `error_response`:
      # the body must already be on the response). A pre-rendered JSON
      # string prints verbatim instead of a second `to_json` pass; anything
      # else that responds to `to_json` is serialized. Statuses 400 and
      # above also carry `Cache-Control: no-store`.
      def write_json(env, status : Int32, payload) : String
        env.response.status_code = status
        env.response.content_type = "application/json"
        no_store(env) if status >= 400
        env.response.print(payload.is_a?(String) ? payload : payload.to_json)
        ""
      end

      # Emits a single INFO-traceable log line for any 4xx/5xx response so
      # operators can see *why* a request failed without grepping response
      # bodies. Successes (2xx) are not logged here — Kemal's request log
      # already covers them. Routed through `facet.http` so it can be
      # filtered independently from Kemal's request log.
      private def log_request_error(env, status : Int32, message : String, details : Array(ValidationError)?) : Nil
        return if status < 400
        line = "#{env.request.method} #{env.request.path} → #{status} #{message}"
        if details && !details.empty?
          rendered = details.map { |d| d.field ? "#{d.field}: #{d.message}" : d.message }
          line = "#{line} (#{rendered.join(", ")})"
        end
        if status >= 500
          HTTP_LOG.error { line }
        else
          HTTP_LOG.warn { line }
        end
      end

      # Writes a 204 No Content response (no body).
      def write_no_content(env) : Nil
        env.response.status_code = 204
      end

      # ── Document meta builder ─────────────────────────────────────────────

      # Builds the `meta` object for a single document response.
      # `mid` is the last mutation ULID — takes `mutation_id` if provided,
      # otherwise falls back to `proj.state`.
      def document_meta(
        proj : Mutation::Client::Projection,
        mutation_id : String? = nil,
      ) : NamedTuple
        # Read `proj.meta` once — all keys come from the same hash.
        meta_h = proj.meta.as_h?
        sv = meta_h.try { |h| h["schema_version"]?.try(&.as_i?) }
        parent_id_val = meta_h.try { |h| h["parent_id"]?.try(&.as_s?) }
        migration_error_val = meta_h.try { |h| h["migration_error"]?.try(&.as_s?) }

        result = {
          id:             proj.id,
          uri:            Facet::Document::DocURI.from_projection_id(proj.domain, proj.doc_type, proj.id).to_s,
          mid:            mutation_id || proj.state,
          domain:         proj.domain,
          doc_type:       proj.doc_type,
          version:        proj.version,
          schema_version: sv || 1,
          display_name:   proj.display_name,
          created_at:     proj.created_at.to_rfc3339,
          updated_at:     proj.updated_at.to_rfc3339,
        }

        # Include parent_id in meta if present
        if parent_id_val
          result = result.merge({parent_id: parent_id_val})
        end

        # Surface the lazy-migration failure marker (B-342): a row that
        # serves stale content because its migration failed must be
        # discoverable through the API, not only in the `projections.meta`
        # column.
        if migration_error_val
          result = result.merge({migration_error: migration_error_val})
        end

        result
      end

      # ── Result writing (unified for all Document and Doctype results) ───────

      # Sets the env status and returns the JSON body for a Document or Doctype
      # operation result. The return value is used as the Kemal route body.
      # The `db` connection resolves the doctype definitions the response
      # presentation needs (write responses present content through the
      # shared presenter, so invisible fields never reach the wire).
      def write_result(env, result, success_status : Int32 = 200, db : DB::Connection? = nil) : String
        case result
        # Write responses carry the single-document validator too: the write
        # produced a new projection `state`, and the header matches the
        # `meta.mid` in the body. The next GET serves the same validator.
        in Facet::Document::CreateWithChildren::Result
          Caching.set_etag_header(env, result.projection.state)
          write_document_with_children_result(env, result, success_status, db)
        in Facet::Document::Create::Result
          Caching.set_etag_header(env, result.projection.state)
          write_document_result(env, result.projection, mutation_id: result.mutation_id, status: success_status, db: db)
        in Facet::Document::Action::Result
          Caching.set_etag_header(env, result.projection.state)
          write_document_result(env, result.projection, mutation_id: result.mutation_id, status: success_status, db: db)
        in Facet::Document::Update::Result
          Caching.set_etag_header(env, result.projection.state)
          write_document_result(env, result.projection, mutation_id: result.mutation_id, db: db)
        in Facet::Document::Read::Result
          env.response.headers["X-Document-Migrated"] = result.migrated.to_s
          # Nested child reads share the single-document validator: the
          # projection `state` is the ULID of the last mutation applied, so
          # any mutation on the child produces a new ETag (see the module
          # doc in `Caching` and `doc/backend/http-layer.md` → HTTP Caching).
          doc_tag = result.projection.state
          if Caching.not_modified?(env, doc_tag)
            Caching.write_not_modified(env, doc_tag)
            ""
          else
            Caching.set_etag_header(env, doc_tag)
            write_document_result(env, result.projection)
          end
        in Facet::Document::Delete::Result
          write_no_content(env)
          ""
        in Facet::Doctype::Update::Result
          resolve_updated_doctype_projection(env, result.mutation_id)
        in Facet::ServiceError
          env.response.headers["X-Document-Deleted"] = "true" if result.status == 410
          error_response(env, result.status, result.message, result.details, result.meta)
        end
      end

      # Writes a single-document response in { data, meta } format.
      # `data` is the document's content fields (the user-defined data).
      # `meta` contains all system fields (mid, domain, doc_type, version, …).
      # Content goes through the shared presenter: when a db connection is
      # available, invisible fields and unknown keys are omitted for Real
      # principals (read results are already masked — presentation is
      # idempotent); without one, the content passes verbatim.
      private def write_document_result(
        env,
        proj : Mutation::Client::Projection,
        mutation_id : String? = nil,
        status : Int32 = 200,
        db : DB::Connection? = nil,
      ) : String
        env.response.status_code = status
        env.response.content_type = "application/json"
        content = present_content(env, proj, db)
        {
          data: content,
          meta: document_meta(proj, mutation_id: mutation_id),
        }.to_json
      end

      # Presents one projection's content through the shared presenter.
      # Uses the given connection when present; otherwise opens a read-only
      # one (definitions are cached, so the cost is one pooled checkout).
      private def present_content(env, proj : Mutation::Client::Projection, db : DB::Connection?) : JSON::Any
        auth = HTTP::Helpers.auth_context(env)
        if db
          Facet::Document::Presenter.present_projection(proj, auth, db)
        else
          Database.with_db(:read_only) { |ro| Facet::Document::Presenter.present_projection(proj, auth, ro) }
        end
      end

      # Writes a compound create response (parent + children). Parent and
      # every child present through the shared presenter with their own
      # doctype definition — invisible child fields never reach the wire.
      private def write_document_with_children_result(
        env,
        result : Facet::Document::CreateWithChildren::Result,
        status : Int32,
        db : DB::Connection? = nil,
      ) : String
        env.response.status_code = status
        env.response.content_type = "application/json"
        content = present_content(env, result.projection, db)
        auth = HTTP::Helpers.auth_context(env)
        children = if db
                     children_to_json(env, result.children, result.projection.domain, db, auth)
                   else
                     Database.with_db(:read_only) { |ro| children_to_json(env, result.children, result.projection.domain, ro, auth) }
                   end
        {
          data:     content,
          meta:     document_meta(result.projection, mutation_id: result.mutation_id),
          children: children,
        }.to_json
      end

      # Recursively converts nested ChildResult entries to { data, meta } format.
      # Each child presents through the shared presenter with the child
      # doctype's own definition (no second masking algorithm).
      private def children_to_json(
        env,
        children : Hash(String, Array(Facet::Document::CreateWithChildren::ChildResult)),
        domain : String,
        db : DB::Connection,
        auth : Facet::RBAC::AuthContext,
      ) : JSON::Any
        json = {} of String => JSON::Any
        children.each do |rel_name, child_list|
          arr = child_list.map do |child|
            # Meta mirrors the parent shape (`document_meta`): the child id
            # and URI identify the persisted row, and the timestamps come
            # from the child projection — never fabricated.
            meta = {
              id:             child.id,
              uri:            Facet::Document::DocURI.from_projection_id(domain, child.doc_type, child.id).to_s,
              mid:            child.mut_id,
              domain:         domain,
              doc_type:       child.doc_type,
              version:        1,
              schema_version: 1,
              created_at:     child.created_at.to_rfc3339,
              updated_at:     child.updated_at.to_rfc3339,
            }
            meta_json = JSON.parse(meta.to_json)
            child_defn = Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{child.doc_type}")
            child_content = Facet::Document::Presenter.present_content(child.content, auth, child_defn)
            entry = {
              "data"     => child_content,
              "meta"     => meta_json,
              "children" => children_to_json(env, child.children, domain, db, auth),
            }
            JSON::Any.new(entry)
          end
          json[rel_name] = JSON::Any.new(arr)
        end
        JSON::Any.new(json)
      end

      # Resolves and returns the updated doctype projection for the PUT response.
      private def resolve_updated_doctype_projection(env, mutation_id : String) : String
        # For Doctype::Update we don't have the projection at hand — we need
        # to fetch it from the mutation_id. But that's complex; instead we
        # return a simpler response. The mutation id is the projection's
        # new `state`, so it doubles as the single-document ETag validator.
        # An unchanged re-save carries the row's current `state` — the same
        # validator the preceding GET served, so a client sees no change.
        Caching.set_etag_header(env, mutation_id)
        env.response.status_code = 200
        env.response.content_type = "application/json"
        {mid: mutation_id}.to_json
      end

      # ── Audit result writers ────────────────────────────────────────────

      # Writes an Audit::List result to the response. The error branch
      # prints through `error_response`: a returned error body is dropped
      # when a status-level error handler is registered (see the contract
      # comment on `error_response`).
      def write_audit_list_result(env, result)
        case result
        in Facet::Audit::List::Result
          env.response.status_code = 200
          env.response.content_type = "application/json"
          # `count` is the capped total from offset 0; `more` comes from the
          # service and is true only when counting hit the cap.
          count, _ = capped_count(result.total, 0)
          {
            data: result.items.map { |m| audit_mutation_hash(m) },
            meta: {count: count, more: result.more},
          }.to_json
        in Facet::ServiceError
          error_response(env, result.status, result.message)
        end
      end

      # Writes an Audit::Rollback result to the response. A cluster-scope
      # rollback reports every undoed document instead of one projection.
      # The snapshot content presents through the shared presenter when a
      # db connection is available (the restore/rollback response never
      # leaks invisible fields back to the caller). The error branch prints
      # through `error_response` — a returned error body is dropped when a
      # status-level error handler is registered.
      #
      # A document-scope result carries `cascade_restored` — one entry per
      # composition child the restore brought back. The key rides on the
      # single-document body and stays present for a plain rollback (empty
      # array), so the 200 shape is stable.
      def write_audit_rollback_result(env, result, db : DB::Connection? = nil)
        case result
        in Facet::Audit::Rollback::Result
          env.response.status_code = 200
          env.response.content_type = "application/json"
          content = present_content(env, result.projection, db)
          {
            data:             content,
            meta:             document_meta(result.projection, mutation_id: result.mutation_id),
            cascade_restored: result.cascade_restored.map do |child|
              {
                domain:   child.domain,
                doc_type: child.doc_type,
                doc_id:   child.doc_id,
                mut_id:   child.mut_id,
              }
            end,
          }.to_json
        in Facet::Audit::Rollback::ClusterResult
          env.response.status_code = 200
          env.response.content_type = "application/json"
          {
            trace:     result.trace,
            count:     result.documents.size,
            documents: result.documents.map do |undo|
              {
                domain:   undo.domain,
                doc_type: undo.doc_type,
                doc_id:   undo.doc_id,
                mut_id:   undo.mutation_id,
                outcome:  undo.outcome,
              }
            end,
          }.to_json
        in Facet::ServiceError
          error_response(env, result.status, result.message)
        end
      end

      # Converts a MutationRecord to a JSON-safe hash. `app` is the
      # `app.App` projection id when the mutation was made through an app
      # token or an app-owned API key; `null` otherwise. `channel` is the
      # authentication surface and the `cause_*` fields describe the direct
      # trigger (all read from the typed provenance columns on `mutations`).
      # `display_name` is the target document's label — populated by the
      # aggregate history (`include=children`), `null` in plain mode.
      # `redacted` lists the content paths whose values the service removed
      # from `arguments` for this caller (empty when unredacted).
      private def audit_mutation_hash(m : Facet::Audit::List::MutationRecord) : NamedTuple
        {
          id:           m.id,
          domain:       m.domain,
          doc_type:     m.doc_type,
          doc_id:       m.doc_id,
          idx:          m.idx,
          action:       m.action,
          actioner_id:  m.actioner_id,
          arguments:    m.arguments,
          redacted:     m.redacted,
          channel:      m.channel,
          app:          m.app,
          api_key:      m.api_key,
          acting_role:  m.acting_role,
          cause_kind:   m.cause_kind,
          cause_name:   m.cause_name,
          cause_event:  m.cause_event,
          cause_source: m.cause_source,
          cause_parent: m.cause_parent,
          cause_trace:  m.cause_trace,
          emitted_at:   m.emitted_at.to_rfc3339,
          display_name: m.display_name,
        }
      end

      # Converts a list of projections to { data, meta } format for collection.
      # When `select` is provided, only those top-level fields from `content` are included in `data`.
      def projection_list(items : Array(Mutation::Client::Projection), select_fields : Array(String)? = nil) : Array(JSON::Any)
        items.map do |proj|
          meta_any = JSON.parse(document_meta(proj).to_json)
          data = if select_fields
                   subset_json(proj.content, select_fields)
                 else
                   proj.content
                 end
          JSON::Any.new({
            "data" => data,
            "meta" => meta_any,
          })
        end
      end

      # Returns a new JSON object containing only the requested top-level fields.
      # Returns the original value if it's not a JSON object.
      def subset_json(content : JSON::Any, select_fields : Array(String)) : JSON::Any
        h = content.as_h?
        return content if h.nil?

        selected = {} of String => JSON::Any
        select_fields.each do |field|
          if h.has_key?(field)
            selected[field] = h[field]
          end
        end
        JSON::Any.new(selected)
      end

      # ── Capped count helpers ─────────────────────────────────────────────

      # Rows a list count may read past the page offset before it gives up.
      # Every `meta.count` / `meta.more` surface shares this cap so the two
      # numbers mean the same thing on every route. Benchmark (50k rows):
      # an indexed sort costs 0.05 ms at 51 rows and 0.26 ms at 1001, and an
      # unindexed JSONB sort 15.1 ms vs 21.2 ms — the sort dominates, so the
      # wider window is cheap.
      COUNT_CAP = 1000

      # Computes a capped count and `more` flag.
      #
      # `raw_count` is the result of
      # `SELECT COUNT(*) FROM (SELECT 1 FROM ... LIMIT COUNT_CAP+1 OFFSET offset)`.
      # `count` is `offset + min(raw_count, COUNT_CAP)` — the real number of
      # matching rows from the page offset, truncated at the cap. `more` is
      # true only when counting was truncated, so `count` is a floor, never
      # an inflated figure.
      #
      # `max_count` overrides the cap for surfaces with a smaller sub-list
      # window (artifact grants/references).
      def capped_count(raw_count : Int64, offset : Int32, max_count : Int64 = COUNT_CAP.to_i64) : {Int64, Bool}
        if raw_count > max_count
          {offset.to_i64 + max_count, true}
        else
          {offset.to_i64 + raw_count, false}
        end
      end
    end
  end
end
