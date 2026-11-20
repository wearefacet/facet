# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../config"
require "../database"
require "../http/helpers"
require "../jobs/manager"
require "../rbac"
require "../rbac/write_enforcer"
require "../util/script_helpers"
require "./ahead_migration_job"
require "./reproject_job"

module Facet
  module Doctype
    # HTTP routes for the doctype maintenance surface — the backend of
    # `/Configure/platform/maintenance`.
    #
    # `POST /Api/core/DocType/:id/reproject`           enqueue `doctype_reproject`
    # `POST /Api/core/DocType/:id/migrate_ahead`       enqueue `doctype_migrate_ahead`
    # `GET  /Api/core/DocType/:id/maintenance_status`  ahead / blocked counts
    # `GET  /Api/core/DocType/:id/maintenance_jobs`    the doctype's job rows
    #
    # `:id` is the qualified doctype id (`crm.Company`) — the same form the
    # `PUT /Api/core/DocType/:id` and `GET .../check` routes serve.
    #
    # Authorization mirrors the check route: the caller must hold update
    # permission on the `core.DocType` document — the gate of everyone who
    # may edit the schema, and therefore may re-project or re-migrate it.
    # Mutating routes refuse preview sessions (`422`) and require CSRF.
    #
    # Both job kinds run once (`max_attempts: 1`) with the queue's long
    # lease horizon; an enqueue for a doctype that already carries a
    # `pending` or `running` row of the same kind answers `409`. Execution
    # acts as the system — the job does not re-run the gate; the
    # requester's identity rides the payload for the jobs-table display
    # only.
    module MaintenanceRoutes
      # The job kinds this surface owns, for the jobs-list filter.
      JOB_KINDS = [ReprojectJob::KIND, AheadMigrationJob::KIND]

      def self.register : Nil
        post "/Api/core/DocType/:id/reproject" do |env|
          handle_enqueue(env, ReprojectJob::KIND)
        end

        post "/Api/core/DocType/:id/migrate_ahead" do |env|
          handle_enqueue(env, AheadMigrationJob::KIND)
        end

        get "/Api/core/DocType/:id/maintenance_status" do |env|
          handle_status(env)
        end

        get "/Api/core/DocType/:id/maintenance_jobs" do |env|
          handle_jobs(env)
        end
      end

      # ── Enqueue ─────────────────────────────────────────────────────────

      # Shared enqueue path for both maintenance kinds. Gate order: CSRF,
      # preview refusal, definition existence (`404`), write gate (`403`),
      # dedupe (`409`), then the `202` enqueue body.
      private def self.handle_enqueue(env, kind : String)
        return unless HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        auth = HTTP::Helpers.auth_context(env)
        return error(env, 422, "Maintenance is not available in preview mode") if auth.preview?

        qualified = env.params.url["id"]
        parts = split_qualified(qualified)
        return error(env, 422, "Invalid doctype id '#{qualified}' (expected 'domain.Doctype')") if parts.nil?
        domain = parts[0]
        doc_type = parts[1]

        checked = Database.with_db(:read_only) do |db|
          gate = enqueue_gate(db, qualified, auth)
          next gate if gate.is_a?(Facet::ServiceError)
          job_enqueued?(db, kind, domain, doc_type)
        end
        case checked
        in Facet::ServiceError then return error(env, checked.status, checked.message)
        in Bool                then return error(env, 409, "#{job_label(kind)} for #{qualified} is already pending or running — wait for it to finish or read the jobs list") if checked
        end

        payload = build_payload(auth, domain, doc_type)
        job_id = enqueue_job(kind, payload)

        HTTP::Helpers.write_json(env, 202, {
          job_id:     job_id,
          status_url: "/Api/core/DocType/#{qualified}/maintenance_jobs",
        })
      end

      # The human label the 409 dedupe message names. The raw kind is an
      # internal token; the banner on the maintenance page shows this text.
      private def self.job_label(kind : String) : String
        kind == AheadMigrationJob::KIND ? "An ahead-migration job" : "A re-project job"
      end

      # The enqueue-time gate: the definition must resolve (`404`) and the
      # caller must hold update permission on the `core.DocType` document
      # (`403`) — the same gate the doctype update and check routes hold.
      private def self.enqueue_gate(
        db : DB::Connection,
        qualified : String,
        auth : RBAC::AuthContext,
      ) : Facet::ServiceError?
        return Facet::ServiceError.new(404, "Doctype '#{qualified}' not found") if DefinitionStore.fetch(db, qualified).nil?
        return Facet::ServiceError.new(403, "Forbidden") unless RBAC::WriteEnforcer.authorize_update(db, "core", "DocType", qualified, auth)
        nil
      end

      # True when a `pending` or `running` row of *kind* already exists for
      # the doctype — the same authority `Cron::WebhookReconcile` reads.
      # The check is advisory (two racing enqueues can both pass); the
      # services' optimistic row checks keep concurrent runs correct.
      private def self.job_enqueued?(db : DB::Connection, kind : String, domain : String, doc_type : String) : Bool
        db.query_one?(
          <<-SQL,
            SELECT 1 FROM background_jobs
            WHERE kind = $1
              AND payload->>'domain' = $2
              AND payload->>'doc_type' = $3
              AND status IN ('pending', 'running')
            LIMIT 1
          SQL
          kind, domain, doc_type, as: Int32) ? true : false
      end

      # Enqueues through the jobs manager when the subsystem is up and
      # falls back to a direct row insert in enqueue-only mode — the same
      # shim the import/export routes run. `max_attempts: 1`: a job runs
      # once, the operator fixes the input and submits again.
      private def self.enqueue_job(kind : String, payload : JSON::Any) : String
        lease_ttl_s = Config.instance.jobs.long_lease_ttl_s

        if mgr = Jobs::Manager.instance
          mgr.enqueue(kind, payload,
            max_attempts: 1,
            backoff: [] of Int32,
            lease_ttl_s: lease_ttl_s,
          )
        else
          Database.with_db do |db|
            id = Util::ScriptHelpers.ulid
            Jobs::Queries.insert(
              db, id, kind, payload,
              max_attempts: 1,
              backoff: [] of Int32,
              lease_ttl_s: lease_ttl_s,
            )
            id
          end
        end
      end

      # The payload: coordinates and identity references only. `role_id` is
      # the enqueuer's qualified `iam.Roles` reference — display data for
      # the jobs table, never re-resolved for authorization.
      private def self.build_payload(auth : RBAC::AuthContext, domain : String, doc_type : String) : JSON::Any
        payload = {
          "domain"     => JSON::Any.new(domain),
          "doc_type"   => JSON::Any.new(doc_type),
          "account_id" => JSON::Any.new(auth.account_id),
        } of String => JSON::Any

        principal = auth.principal
        if principal.is_a?(RBAC::Principal::Real)
          payload["role_id"] = JSON::Any.new("iam.Roles.#{principal.active_role.role_id}")
        end

        JSON.parse(payload.to_json)
      end

      # ── Status counts ───────────────────────────────────────────────────

      # `GET .../maintenance_status` — the numbers the maintenance page
      # shows before the operator pulls a trigger: rows below the current
      # definition version, rows carrying the `migration_error` marker,
      # and the version itself.
      private def self.handle_status(env)
        auth = HTTP::Helpers.auth_context(env)
        qualified = env.params.url["id"]
        parts = split_qualified(qualified)
        return error(env, 422, "Invalid doctype id '#{qualified}' (expected 'domain.Doctype')") if parts.nil?
        domain = parts[0]
        doc_type = parts[1]

        result = Database.with_db(:read_only) do |db|
          defn = DefinitionStore.fetch(db, qualified)
          if defn.nil?
            next Facet::ServiceError.new(404, "Doctype '#{qualified}' not found")
          elsif !RBAC::WriteEnforcer.authorize_update(db, "core", "DocType", qualified, auth)
            next Facet::ServiceError.new(403, "Forbidden")
          end
          StatusCounts.new(ahead_count(db, domain, doc_type, defn.schema_version), blocked_count(db, domain, doc_type), defn.schema_version)
        end
        return error(env, result.status, result.message) if result.is_a?(Facet::ServiceError)

        HTTP::Helpers.write_json(env, 200, {
          doctype_id:      qualified,
          current_version: result.current_version,
          ahead_count:     result.ahead,
          blocked_count:   result.blocked,
        })
      end

      private record StatusCounts, ahead : Int32, blocked : Int32, current_version : Int32

      private def self.ahead_count(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        current_version : Int32,
      ) : Int32
        db.query_one(<<-SQL, domain, doc_type, current_version, as: Int64).to_i32
          SELECT count(*) FROM projections
          WHERE domain = $1 AND doc_type = $2
            AND deleted_at IS NULL
            AND COALESCE(
              CASE WHEN meta->>'schema_version' ~ '^[0-9]+$'
                   THEN (meta->>'schema_version')::int END, 1) < $3
        SQL
      end

      private def self.blocked_count(db : DB::Connection, domain : String, doc_type : String) : Int32
        db.query_one(<<-SQL, domain, doc_type, as: Int64).to_i32
          SELECT count(*) FROM projections
          WHERE domain = $1 AND doc_type = $2
            AND deleted_at IS NULL
            AND meta->'migration_error' IS NOT NULL
        SQL
      end

      # ── Jobs list ───────────────────────────────────────────────────────

      # `GET .../maintenance_jobs?page=&items=` — the doctype's maintenance
      # job rows, newest first. Doctype-scoped on purpose: every operator
      # with the gate sees every run of that doctype, which is the audit
      # trail the page displays. `more` is page-relative (fetch one extra
      # row); there is no exact total.
      private def self.handle_jobs(env)
        auth = HTTP::Helpers.auth_context(env)
        qualified = env.params.url["id"]
        parts = split_qualified(qualified)
        return error(env, 422, "Invalid doctype id '#{qualified}' (expected 'domain.Doctype')") if parts.nil?
        domain = parts[0]
        doc_type = parts[1]

        parsed = parse_page(env)
        return error(env, 422, "page and items must be positive integers") if parsed.nil?
        page = parsed[0]
        items = parsed[1]

        gate = Database.with_db(:read_only) do |db|
          enqueue_gate(db, qualified, auth)
        end
        return error(env, gate.status, gate.message) if gate.is_a?(Facet::ServiceError)

        rows = Database.with_db(:read_only) do |db|
          fetch_jobs(db, domain, doc_type, page, items)
        end

        total = Database.with_db(:read_only) do |db|
          count_jobs(db, domain, doc_type, page, items)
        end

        # `count` is the real number of matching jobs from this page's
        # offset, truncated at the shared cap; `more` is true only when
        # counting was truncated (B-297).
        HTTP::Helpers.write_json(env, 200, {
          data: rows.map { |row| job_row_json(row) },
          meta: {count: total, more: total > HTTP::Helpers::COUNT_CAP, page: page},
        })
      end

      record JobRow,
        id : String,
        kind : String,
        status : String,
        attempts : Int32,
        max_attempts : Int32,
        last_error : String?,
        result : JSON::Any?,
        account_id : String?,
        role_id : String?,
        created_at : Time,
        updated_at : Time

      # Capped count of the jobs matching this doctype, from the page
      # offset, bounded by the shared cap.
      private def self.count_jobs(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        page : Int32,
        items : Int32,
      ) : Int64
        offset = (page - 1) * items
        db.query_one(
          <<-SQL,
            SELECT COUNT(*) FROM (
              SELECT 1 FROM background_jobs
              WHERE kind = ANY($1)
                AND payload->>'domain' = $2
                AND payload->>'doc_type' = $3
              ORDER BY created_at DESC, id DESC
              LIMIT #{HTTP::Responders::COUNT_CAP + 1} OFFSET #{offset}
            ) AS sub
          SQL

          JOB_KINDS, domain, doc_type,
          as: Int64,
        )
      end

      private def self.fetch_jobs(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        page : Int32,
        items : Int32,
      ) : Array(JobRow)
        offset = (page - 1) * items
        rows = db.query_all(
          <<-SQL,
            SELECT id, kind, status, attempts, max_attempts, last_error, result,
                   payload->>'account_id' AS account_id, payload->>'role_id' AS role_id,
                   created_at, updated_at
            FROM background_jobs
            WHERE kind = ANY($1)
              AND payload->>'domain' = $2
              AND payload->>'doc_type' = $3
            ORDER BY created_at DESC, id DESC
            LIMIT $4 OFFSET $5
          SQL
          JOB_KINDS, domain, doc_type, items, offset,
          as: {String, String, String, Int32, Int32, String?, JSON::Any?, String?, String?, Time, Time},
        )
        rows.map do |r|
          JobRow.new(
            id: r[0], kind: r[1], status: r[2], attempts: r[3], max_attempts: r[4],
            last_error: r[5], result: r[6], account_id: r[7], role_id: r[8],
            created_at: r[9], updated_at: r[10],
          )
        end
      end

      private def self.job_row_json(row : JobRow) : NamedTuple
        {
          id:           row.id,
          kind:         row.kind,
          status:       row.status,
          attempts:     row.attempts,
          max_attempts: row.max_attempts,
          last_error:   row.last_error,
          result:       row.result,
          account_id:   row.account_id,
          role_id:      row.role_id,
          created_at:   row.created_at.to_rfc3339,
          updated_at:   row.updated_at.to_rfc3339,
        }
      end

      # ── Shared helpers ──────────────────────────────────────────────────

      # Splits a qualified doctype id into its domain and doctype parts.
      # Returns `nil` when the id carries no dot or starts with one.
      private def self.split_qualified(qualified : String) : {String, String}?
        dot = qualified.index('.')
        return nil if dot.nil? || dot.zero?
        {qualified[0...dot], qualified[(dot + 1)..]}
      end

      # Page/items from the query string. `items` caps at 100; a
      # non-numeric or non-positive value answers `422` through the `nil`
      # return.
      private def self.parse_page(env) : {Int32, Int32}?
        page = (env.params.query["page"]? || "1").to_i?
        items = (env.params.query["items"]? || "25").to_i?
        return nil if page.nil? || items.nil? || page < 1 || items < 1

        {page, Math.min(items, 100)}
      end

      private def self.error(env, status : Int32, message : String)
        HTTP::Helpers.error_response(env, status, message)
      end
    end
  end
end
