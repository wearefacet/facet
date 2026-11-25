# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "csv"
require "json"
require "kemal"
require "../database"
require "../config"
require "../error"
require "../validation_error"
require "../http/helpers"
require "../rbac"
require "../iam/helpers"
require "../doctype/definition_store"
require "../document/filter_compiler"
require "../jobs/queries"
require "../artifact/uploader"
require "../artifact/store"
require "../iam/api_key"
require "../util/script_helpers"
require "./caller_context"
require "./export"
require "./export_job"
require "./import"
require "./import_job"
require "./csv_serializer"
require "./staging"
require "./job_queue"

module Facet
  module ImportExport
    # HTTP routes for the document import/export concern.
    #
    # Registered by `HTTP::Server.routes` before the REST catch-all, so
    # `/Api/:domain/:doctype/import_export/:job_id` never reaches the
    # nested-children matcher with `import_export` read as a document id.
    #
    # All routes authenticate through the normal JWT middleware. The
    # write-shaped POST requires the `X-Requested-With` header (the CSRF
    # rule), with the API-key-bearer bypass the IAM routes use. The status
    # and download routes are requester-scoped: the job payload carries
    # the requesting account id, and the route answers only when it
    # matches the caller — any other account's job, an unknown job, or a
    # pruned artifact answers `404`, never `403`, so job ids do not leak.
    module Routes
      # Query params the export route owns. `format` selects the output
      # format and `wait` is the mode switch; `sort` / `page` / `per_page`
      # / `items` are pagination knobs the list action accepts but export
      # must refuse — the keyset contract fixes the output to id order,
      # and silent acceptance would make a wrong export look correct.
      RESERVED_QUERY_KEYS = Set{"format", "wait", "sort", "page", "per_page", "items"}

      # The job kinds whose status/download the concern's routes serve.
      STATUS_JOB_KINDS = Set{"document_export", "document_import"}

      # The system columns a view export may name, beside the doctype's own
      # field keys. `deleted_at` is out of the set: the view export is
      # live-only, matching the export service's WHERE clause.
      VIEW_EXPORT_SYSTEM_COLUMNS = Set{"id", "created_at", "updated_at"}

      def self.register : Nil
        post "/Api/:domain/:doctype/export" do |env|
          handle_export_enqueue(env)
        end

        post "/Api/:domain/:doctype/export_view" do |env|
          handle_export_view_enqueue(env)
        end

        post "/Api/:domain/:doctype/import" do |env|
          handle_import_enqueue(env)
        end

        get "/Api/:domain/:doctype/import_export/:job_id" do |env|
          handle_status(env)
        end

        get "/Api/:domain/:doctype/import_export/:job_id/download" do |env|
          handle_download(env)
        end
      end

      # ── Export enqueue ─────────────────────────────────────────────

      # `POST /Api/:domain/:doctype/export`. Validates the format and the
      # filter params against the definition (a malformed filter answers
      # `422` here, not in the job), enqueues the `document_export` job
      # with the queue's long lease horizon, and answers `202` with the
      # job id. `wait=true` polls the job row and resolves to the file
      # itself; the timeout falls back to the `202` enqueue body with the
      # job still running.
      private def self.handle_export_enqueue(env)
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]

        auth = HTTP::Helpers.auth_context(env)
        return HTTP::Helpers.error_response(env, 422, "Export is not available in preview mode") if auth.preview?

        format = env.params.query["format"]?
        unless format && Document::Export::FORMATS.includes?(format)
          named = format || "(missing)"
          return HTTP::Helpers.error_response(env, 422, "Unknown or missing format: #{named} (supported: csv, json)")
        end

        return rejected_params_guard(env) unless reserved_params(env).empty?

        filters = export_filters(env)

        outcome = resolve_export_target(ExportRequest.new(
          domain: domain,
          doc_type: doc_type,
          filters: filters,
          auth: auth,
          format: format,
        ))

        payload = case outcome
                  in ServiceError
                    return HTTP::Helpers.error_response(env, outcome.status, outcome.message)
                  in JSON::Any
                    outcome
                  end

        job_id = JobQueue.enqueue_job(Document::ExportJob::KIND, payload)
        status_url = "/Api/#{domain}/#{doc_type}/import_export/#{job_id}"

        if env.params.query["wait"]? == "true" && wait_for_job(env, domain, doc_type, job_id)
          ""
        else
          enqueue_body(env, job_id, status_url)
        end
      end

      # `POST /Api/:domain/:doctype/export_view` — the table-view export.
      # The structured payload (columns, sort, filters, timezone) does not
      # fit the flat export's query-string form, so it rides a JSON body
      # with the QUERY method's media-type gate: a non-JSON Content-Type
      # answers `415`, a malformed or non-object body `422`. Every
      # validation fails loud at enqueue — unknown and duplicate column
      # keys name themselves, an invalid timezone names the zone, filters
      # compile once against the definition. Enqueues the same
      # `document_export` job with the extended payload and answers `202`
      # with the job id; `wait=true` is the only accepted query param and
      # reuses the flat export's wait plumbing.
      private def self.handle_export_view_enqueue(env)
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]

        auth = HTTP::Helpers.auth_context(env)
        return HTTP::Helpers.error_response(env, 422, "Export is not available in preview mode") if auth.preview?

        stray = env.params.query.map(&.first).reject { |key| key == "wait" }
        stray.uniq!
        stray.sort!
        unless stray.empty?
          return HTTP::Helpers.error_response(env, 422, "Unknown query parameter(s): #{stray.join(", ")} — the view payload rides the JSON body")
        end

        body = parse_view_body(env)
        return HTTP::Helpers.error_response(env, body.status, body.message) if body.is_a?(ServiceError)

        columns = parse_view_columns(body)
        return HTTP::Helpers.error_response(env, columns.status, columns.message) if columns.is_a?(ServiceError)

        sort = parse_view_sort(body)
        return HTTP::Helpers.error_response(env, sort.status, sort.message) if sort.is_a?(ServiceError)

        filters = parse_view_filters(body)
        return HTTP::Helpers.error_response(env, filters.status, filters.message) if filters.is_a?(ServiceError)

        timezone = parse_view_timezone(body)
        return HTTP::Helpers.error_response(env, timezone.status, timezone.message) if timezone.is_a?(ServiceError)

        outcome = resolve_export_target(ExportRequest.new(
          domain: domain,
          doc_type: doc_type,
          filters: filters,
          auth: auth,
          format: "csv",
          columns: columns,
          sort: sort,
          timezone: timezone,
        ))

        payload = case outcome
                  in ServiceError
                    return HTTP::Helpers.error_response(env, outcome.status, outcome.message)
                  in JSON::Any
                    outcome
                  end

        job_id = JobQueue.enqueue_job(Document::ExportJob::KIND, payload)
        status_url = "/Api/#{domain}/#{doc_type}/import_export/#{job_id}"

        if env.params.query["wait"]? == "true" && wait_for_job(env, domain, doc_type, job_id)
          ""
        else
          enqueue_body(env, job_id, status_url)
        end
      end

      # The view-export body: present bodies must declare a JSON media
      # type (`415` otherwise) and parse to a JSON object (`422`
      # otherwise). An absent body parses as an empty object — the
      # required-`columns` check names the real problem.
      private def self.parse_view_body(env) : ServiceError | Hash(String, JSON::Any)
        raw = HTTP::Helpers.parse_body(env)
        return {} of String => JSON::Any if raw.nil? || raw.empty?

        unless HTTP::Helpers.json_content_type?(env.request.headers["Content-Type"]?)
          return ServiceError.new(415, "Unsupported media type — the export_view body must be application/json")
        end

        parsed = begin
          JSON.parse(raw)
        rescue
          return ServiceError.new(422, "Invalid JSON body")
        end
        obj = parsed.as_h?
        return ServiceError.new(422, "Invalid JSON body — the export_view body must be a JSON object") unless obj
        obj
      end

      # The `columns` member: required, a non-empty array of strings, no
      # duplicates (the import decoder's duplicate-column rule, symmetric).
      # Unknown keys fail in `resolve_export_target` against the definition.
      private def self.parse_view_columns(body : Hash(String, JSON::Any)) : ServiceError | Array(String)
        raw = body["columns"]?
        return ServiceError.new(422, "columns is required — a non-empty array of column keys") if raw.nil?

        arr = raw.as_a?
        return ServiceError.new(422, "columns must be an array of column keys") if arr.nil?
        return ServiceError.new(422, "columns must not be empty") if arr.empty?

        seen = Set(String).new
        out = [] of String
        arr.each do |value|
          key = value.as_s?
          return ServiceError.new(422, "columns must be an array of strings") if key.nil?
          return ServiceError.new(422, "Duplicate column: '#{key}'") if seen.includes?(key)
          seen << key
          out << key
        end
        out
      end

      # The `sort` member: an optional array of strings in the list
      # operation's field grammar — an optional `-` direction prefix, then
      # `[a-z_.]`. A non-array body, a non-string entry, or an entry
      # outside the field shape answers `422` (B-158): the run must never
      # lose a sort entry silently. Absent — or an empty array — stays
      # `nil`, so the id-order keyset holds.
      private def self.parse_view_sort(body : Hash(String, JSON::Any)) : ServiceError | Array(String)?
        raw = body["sort"]?
        return nil if raw.nil?

        arr = raw.as_a?
        return ServiceError.new(422, "sort must be an array of strings") if arr.nil?

        entries = [] of String
        arr.each do |value|
          s = value.as_s?
          return ServiceError.new(422, "sort must be an array of strings") if s.nil?
          unless s.matches?(HTTP::ListRequest::SORT_FIELD_RE)
            return ServiceError.new(
              422,
              "Invalid sort field: '#{s}' (allowed: an optional '-' prefix, then characters from [a-z_.])"
            )
          end
          entries << s
        end
        entries.empty? ? nil : entries
      end

      # The `filters` member: an optional map, `field__op` → value — the
      # same grammar the flat export accepts in its query string.
      private def self.parse_view_filters(body : Hash(String, JSON::Any)) : ServiceError | Hash(String, JSON::Any)
        raw = body["filters"]?
        return {} of String => JSON::Any if raw.nil?

        obj = raw.as_h?
        return ServiceError.new(422, "filters must be an object of field__op → value") if obj.nil?
        obj
      end

      # The `timezone` member: an optional IANA zone name, validated with
      # `Time::Location.load` at enqueue — the settings registry's rule.
      # Absent stays `nil`, and the CSV cells keep UTC RFC-3339.
      private def self.parse_view_timezone(body : Hash(String, JSON::Any)) : ServiceError | String?
        raw = body["timezone"]?
        return nil if raw.nil?

        name = raw.as_s?
        return ServiceError.new(422, "timezone must be an IANA zone name") if name.nil? || name.empty?

        begin
          Time::Location.load(name)
        rescue ex
          return ServiceError.new(422, "Invalid timezone '#{name}': #{ex.message}")
        end
        name
      end

      # The reserved-parameter rejection: `422` with every offending param
      # named. Export has no sort, no pagination.
      private def self.rejected_params_guard(env) : String
        rejected = reserved_params(env)
        HTTP::Helpers.error_response(env, 422, "Export does not support the #{rejected.join(", ")} parameter(s) — output is always in id order")
      end

      # The reserved query keys present in this request, sorted for a
      # deterministic message.
      private def self.reserved_params(env) : Array(String)
        hits = RESERVED_QUERY_KEYS.select do |k|
          k != "format" && k != "wait" && env.params.query.has_key?(k)
        end
        hits.sort
      end

      # The inputs one export enqueue shares across both the flat and the
      # view route: the doctype coordinates, the compiled filters, the
      # caller, the output format, and — view exports only — the column,
      # sort, and timezone knobs. The view members stay `nil` on the flat
      # route.
      private record ExportRequest,
        domain : String,
        doc_type : String,
        filters : Hash(String, JSON::Any),
        auth : RBAC::AuthContext,
        format : String,
        columns : Array(String)? = nil,
        sort : Array(String)? = nil,
        timezone : String? = nil

      # Resolves the doctype definition and validates the request against
      # it: `404` missing, `403` for a caller with no read grant on the
      # doctype (the list route's class-level gate, so a doomed job is never
      # queued), `422` for the flat-refusal shapes (sidecar / member_of),
      # one filter-compile pass so a malformed filter fails the request, not
      # the job, and — for a view export — one column-key pass against the
      # definition (unknown keys fail loud; a wrong export must not look
      # correct). Returns the assembled job payload on success.
      private def self.resolve_export_target(req : ExportRequest) : ServiceError | JSON::Any
        Database.with_db do |db|
          defn = Doctype::DefinitionStore.fetch(db, "#{req.domain}.#{req.doc_type}")
          next ServiceError.new(404, "Unknown doctype: #{req.domain}.#{req.doc_type}") if defn.nil?

          # Class-level read denial — 403 at enqueue, matching the list
          # route. Without it a caller with no read grant queues a job that
          # fails later with "Forbidden". The job-time gate in
          # `Document::Export` stays as defense in depth.
          if RBAC::ReadEnforcer.list_denied?(req.domain, req.doc_type, req.auth)
            IAM::Helpers.write_layer1_denial(db, req.auth, "read", req.domain, [req.doc_type])
            next ServiceError.new(403, "Forbidden")
          end

          if defn.member_of
            next ServiceError.new(422, "Document '#{req.doc_type}' belongs to '#{defn.member_of}'; export it through the parent's route")
          end
          if defn.sidecar
            next ServiceError.new(422, "Sidecar doctypes cannot be exported through the flat route")
          end

          begin
            Document::FilterCompiler.compile(defn, req.filters, auth_context: req.auth)
          rescue ex : Util::FilterClauses::MoneyFilterError
            next ServiceError.new(422, ex.message.to_s)
          rescue ex : Util::FilterClauses::FilterGrammarError
            next ServiceError.new(422, ex.message.to_s, details: [
              ValidationError.new(field: ex.filter_key, code: ex.reason, message: ex.message.to_s),
            ])
          end

          if cols = req.columns
            unknown = cols.reject { |key| defn.fields.has_key?(key) || VIEW_EXPORT_SYSTEM_COLUMNS.includes?(key) }
            next ServiceError.new(422, "Unknown export column: '#{unknown.first}'") unless unknown.empty?
          end

          export_payload(req)
        end
      end

      # Collects the export filters from the query string. Two accepted
      # spellings, both flowing into the same hash:
      # - `filters[field__op]=value` — the list action's bracket form.
      # - bare `field__op=value` — any key carrying an operator suffix,
      #   plus `search`.
      # Values decode through `HTTP::ListRequest.decode_filter_value` (B-108):
      # a `[`-prefixed value that parses as JSON becomes a real array — the
      # same wire encoding the list action's query string serves, so array
      # operators (`__in`, `__between`) behave identically on both routes.
      # Every other value keeps the raw string form.
      # A key without an operator suffix that is not `search` is not list
      # grammar — it is dropped, the same no-op contract the list action
      # holds for unrecognised keys.
      private def self.export_filters(env) : Hash(String, JSON::Any)
        filters = {} of String => JSON::Any
        env.params.query.each do |key, value|
          next if RESERVED_QUERY_KEYS.includes?(key)
          if key.starts_with?("filters[") && key.ends_with?("]")
            filters[key[8..-2]] = HTTP::ListRequest.decode_filter_value(value)
          elsif key.includes?("__") || key == "search"
            filters[key] = HTTP::ListRequest.decode_filter_value(value)
          end
        end
        filters
      end

      # The job payload: coordinates and identity references only — never
      # row content. `role_id` is the enqueuer's active role; the handler
      # re-reads the role, app, and grant projections at execution time,
      # so an authorization change between enqueue and execution applies.
      # The view-export members ride only when the caller supplied them.
      private def self.export_payload(req : ExportRequest) : JSON::Any
        payload = {
          "domain"     => JSON::Any.new(req.domain),
          "doc_type"   => JSON::Any.new(req.doc_type),
          "format"     => JSON::Any.new(req.format),
          "account_id" => JSON::Any.new(req.auth.account_id),
          "filters"    => JSON::Any.new(req.filters),
        } of String => JSON::Any

        payload["columns"] = JSON.parse(req.columns.to_json) if req.columns
        payload["sort"] = JSON.parse(req.sort.to_json) if req.sort
        payload["timezone"] = JSON::Any.new(req.timezone) if req.timezone

        if role_reference = CallerContext.role_reference(req.auth)
          payload["role_id"] = JSON::Any.new(role_reference)
        end

        if app_id = req.auth.app_id
          payload["app_id"] = JSON::Any.new(app_id)
        end
        if key_id = req.auth.api_key_id
          payload["api_key_id"] = JSON::Any.new(key_id)
        end

        JSON.parse(payload.to_json)
      end

      # ── Import enqueue ─────────────────────────────────────────────

      # `POST /Api/:domain/:doctype/import`. Parses and validates the
      # uploaded file synchronously — a malformed row answers `422` with
      # the row number before any job row exists — stores the file and
      # the row→id manifest as ownerless artifacts, enqueues the
      # `document_import` job, and answers `202` with the row count.
      # `wait=true` resolves to the job report; the timeout falls back to
      # the `202` enqueue body with the job still running.
      private def self.handle_import_enqueue(env)
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]

        auth = HTTP::Helpers.auth_context(env)
        return HTTP::Helpers.error_response(env, 422, "Import is not available in preview mode") if auth.preview?

        file_text = Staging.read_capped_body(env)
        return HTTP::Helpers.error_response(env, file_text.status, file_text.message) if file_text.is_a?(Staging::BodyError)

        format = detect_format(env, file_text)
        unless format
          return HTTP::Helpers.error_response(env, 422, "Cannot detect the file format — send text/csv or application/json (or a format= query param)")
        end

        staged = Database.with_db { |db| Staging.stage_import(db, domain, doc_type, format, file_text, auth) }
        if staged.is_a?(ServiceError)
          return HTTP::Helpers.error_response(env, staged.status, staged.message)
        end

        payload = import_payload(auth, domain, doc_type, format,
          staged.file_artifact.artifact_id, staged.manifest_artifact.artifact_id)
        job_id = JobQueue.enqueue_job(Document::ImportJob::KIND, payload)
        status_url = "/Api/#{domain}/#{doc_type}/import_export/#{job_id}"

        if env.params.query["wait"]? == "true" && wait_for_job(env, domain, doc_type, job_id)
          ""
        else
          enqueue_body(env, job_id, status_url, staged.row_count)
        end
      end

      # The import format: an explicit `format` query param wins, else the
      # Content-Type decides, else the body shape — only a body whose
      # first non-space byte is `[` may pass as JSON. The structural parse
      # validates the detected choice either way; the sniff only picks the
      # parser, it never blesses the content.
      private def self.detect_format(env, body : String) : String?
        explicit = env.params.query["format"]?
        return (Document::Import::FORMATS.includes?(explicit) ? explicit : nil) if explicit

        content_type = env.request.headers["Content-Type"]?.try(&.split(';').first?.try(&.strip))
        return "csv" if content_type == "text/csv"
        return "json" if content_type == "application/json"

        "json" if body.lstrip.starts_with?('[')
      end

      # The job payload: coordinates, identity references, and the two
      # ownerless artifact ids — never row content. `role_id` is the
      # enqueuer's active role; the handler re-reads the caller's role,
      # app, and grant projections at execution time.
      private def self.import_payload(
        auth : RBAC::AuthContext,
        domain : String,
        doc_type : String,
        format : String,
        file_artifact_id : String,
        manifest_artifact_id : String,
      ) : JSON::Any
        payload = {
          "domain"               => JSON::Any.new(domain),
          "doc_type"             => JSON::Any.new(doc_type),
          "format"               => JSON::Any.new(format),
          "account_id"           => JSON::Any.new(auth.account_id),
          "file_artifact_id"     => JSON::Any.new(file_artifact_id),
          "manifest_artifact_id" => JSON::Any.new(manifest_artifact_id),
        } of String => JSON::Any

        if role_reference = CallerContext.role_reference(auth)
          payload["role_id"] = JSON::Any.new(role_reference)
        end
        if app_id = auth.app_id
          payload["app_id"] = JSON::Any.new(app_id)
        end
        if key_id = auth.api_key_id
          payload["api_key_id"] = JSON::Any.new(key_id)
        end

        JSON.parse(payload.to_json)
      end

      # ── Status ──────────────────────────────────────────────────────

      # `GET /Api/:domain/:doctype/import_export/:job_id` — the job's
      # caller-facing outcome. Requester-scoped: another account's job id
      # is a `404`. `result` is null while the row is pending/running and
      # carries the handler's payload once the outcome is written.
      private def self.handle_status(env)
        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        job_id = env.params.url["job_id"]

        own = Database.with_db(:read_only) { |db| requester_payload(db, env, domain, doc_type, job_id) }
        return HTTP::Helpers.error_response(env, 404, "Not found") unless own

        outcome = Database.with_db(:read_only) { |db| Jobs::Queries.find_outcome(db, job_id) }
        return HTTP::Helpers.error_response(env, 404, "Not found") unless outcome

        Facet::HTTP::Helpers.write_json(env, 200, {
          id:     job_id,
          status: outcome.status,
          error:  outcome.error,
          result: outcome.result,
        })
      end

      # ── Download ────────────────────────────────────────────────────

      # `GET /Api/:domain/:doctype/import_export/:job_id/download` —
      # streams the export bytes. Only a succeeded export produces a file:
      # a pending/running/failed job, an import, or a pruned artifact all
      # answer `404` — there is nothing to download, and the answer never
      # distinguishes the cases.
      private def self.handle_download(env)
        domain = env.params.url["domain"]
        doc_type = env.params.url["doctype"]
        job_id = env.params.url["job_id"]

        payload = Database.with_db(:read_only) do |db|
          found = requester_payload(db, env, domain, doc_type, job_id)
          next nil unless found

          outcome = Jobs::Queries.find_outcome(db, job_id)
          next nil unless outcome && outcome.status == "succeeded"

          artifact_id = outcome.result.try(&.as_h?).try(&.["artifact_id"]?).try(&.as_s?)
          next nil if artifact_id.nil? || artifact_id.empty?

          artifact = Artifact::Store.find_artifact(db, artifact_id)
          next nil if artifact.nil? || artifact.deleted_at

          format = found.payload["format"]?.try(&.as_s?) || "csv"
          {artifact: artifact, format: format, view: payload_has_columns?(found)}
        end
        return HTTP::Helpers.error_response(env, 404, "Not found") unless payload

        stream_export(env, domain, doc_type, payload[:format], payload[:artifact], view: payload[:view])
      end

      # ── Wait mode ───────────────────────────────────────────────────

      # Polls the job row every `wait_poll_ms` until the row is terminal
      # or the deadline passes. Returns `true` when the response is
      # written — export: the file on success, `500` with the job id on
      # failure; import: the report JSON on success, `422` with the
      # failing row on an expected failure, `500` on a crash-class
      # failure. Returns `false` on timeout — the caller then answers the
      # `202` enqueue body and the job keeps running. The wait never
      # cancels a job.
      private def self.wait_for_job(env, domain : String, doc_type : String, job_id : String) : Bool
        cfg = Config.instance.import_export
        deadline = Time.instant + cfg.wait_timeout_s.seconds

        loop do
          resolved = Database.with_db(:read_only) do |db|
            job = requester_payload(db, env, domain, doc_type, job_id)
            next nil unless job
            next nil unless outcome = Jobs::Queries.find_outcome(db, job_id)
            next nil unless terminal?(outcome.status)
            {kind: job.kind, status: outcome.status, error: outcome.error, result: outcome.result, view: payload_has_columns?(job)}
          end

          if resolved
            stream_result(env, domain, doc_type, job_id, resolved)
            return true
          end

          return false if Time.instant >= deadline
          sleep cfg.wait_poll_ms.milliseconds
        end
      end

      private def self.stream_result(
        env,
        domain : String,
        doc_type : String,
        job_id : String,
        resolved : {kind: String, status: String, error: String?, result: JSON::Any?, view: Bool},
      ) : Nil
        return write_import_outcome(env, job_id, resolved) if resolved[:kind] == Document::ImportJob::KIND
        return stream_export_result(env, domain, doc_type, job_id, resolved) if resolved[:status] == "succeeded"
        Facet::HTTP::Helpers.write_json(env, 500, {job_id: job_id, error: resolved[:error]})
      end

      # The import wait-mode terminal shapes: succeeded → `200` with the
      # upsert report; an expected failure → `422` with the failing row
      # (the report is one row — nothing was imported); a crash-class
      # failure → `500` with the job id.
      private def self.write_import_outcome(
        env,
        job_id : String,
        resolved : {kind: String, status: String, error: String?, result: JSON::Any?, view: Bool},
      ) : Nil
        if resolved[:status] == "succeeded"
          report = resolved[:result].try(&.as_h?)
          return Facet::HTTP::Helpers.write_json(env, 200, {
            job_id:    job_id,
            status:    "succeeded",
            row_count: report.try(&.["row_count"]?).try(&.as_i?),
            created:   report.try(&.["created"]?).try(&.as_i?),
            updated:   report.try(&.["updated"]?).try(&.as_i?),
            skipped:   report.try(&.["skipped"]?).try(&.as_i?),
          })
        end

        failing_row = resolved[:result].try(&.as_h?).try(&.["row"]?)
        if failing_row
          return Facet::HTTP::Helpers.write_json(env, 422, {
            job_id: job_id,
            status: "failed",
            error:  resolved[:result],
          })
        end

        Facet::HTTP::Helpers.write_json(env, 500, {job_id: job_id, error: resolved[:error]})
      end

      # Streams the finished export's file — the wait-mode success branch
      # for the export kind.
      private def self.stream_export_result(
        env,
        domain : String,
        doc_type : String,
        job_id : String,
        resolved : {kind: String, status: String, error: String?, result: JSON::Any?, view: Bool},
      ) : Nil
        artifact_id = resolved[:result].try(&.as_h?).try(&.["artifact_id"]?).try(&.as_s?)
        if artifact_id.nil? || artifact_id.empty?
          return Facet::HTTP::Helpers.write_json(env, 500, {job_id: job_id, error: "Export result carries no artifact id"})
        end

        artifact = Database.with_db(:read_only) { |db| Artifact::Store.find_artifact(db, artifact_id) }
        unless artifact && artifact.deleted_at.nil?
          return Facet::HTTP::Helpers.write_json(env, 500, {job_id: job_id, error: "Export artifact is gone (pruned)"})
        end

        format = resolved[:result].try(&.as_h?).try(&.["format"]?).try(&.as_s?) || "csv"
        stream_export(env, domain, doc_type, format, artifact, view: resolved[:view])
      end

      # ── Shared internals ────────────────────────────────────────────

      # The requester-scoping gate: the job row must exist, its kind must
      # be one of the concern's kinds, its `domain` / `doc_type` must
      # match the URL (a job id resolves under its own doctype only), and
      # its `account_id` must match the caller. Every mismatch is a `nil`
      # — the caller renders the non-disclosing `404`. Returns the job row
      # itself; callers derive the payload and the kind from it.
      private def self.requester_payload(
        db : DB::Connection,
        env,
        domain : String,
        doc_type : String,
        job_id : String,
      ) : Jobs::Job?
        job = Jobs::Queries.find(db, job_id)
        return nil unless job
        return nil unless STATUS_JOB_KINDS.includes?(job.kind)

        payload = job.payload.as_h?
        return nil if payload.nil?
        return nil unless payload["domain"]?.try(&.as_s?) == domain
        return nil unless payload["doc_type"]?.try(&.as_s?) == doc_type
        return nil unless payload["account_id"]?.try(&.as_s?) == HTTP::Helpers.auth_context(env).account_id

        job
      end

      private def self.terminal?(status : String) : Bool
        status == "succeeded" || status == "failed"
      end

      # The view-export marker, read off a job payload: the presence of
      # `columns` (the job route and wait mode share it, so both derive
      # the same `{domain}.{doctype}.view.{format}` filename the handler
      # stored the artifact under).
      private def self.payload_has_columns?(job : Jobs::Job) : Bool
        job.payload.as_h?.try(&.has_key?("columns")) || false
      end

      # Streams artifact bytes with the export headers: the stored MIME
      # type, `nosniff`, no-store, and an attachment with the
      # `{domain}.{doctype}[.view].{format}` filename. Plain full-body
      # streaming — range support is a media-serving feature of the
      # artifact serve route, not of a data export.
      private def self.stream_export(
        env,
        domain : String,
        doc_type : String,
        format : String,
        artifact : Artifact::Store::Artifact,
        view : Bool = false,
      ) : Nil
        filename = export_filename(domain, doc_type, format, view)
        env.response.headers["Content-Type"] = artifact.mime_type
        env.response.headers["Content-Length"] = artifact.size.to_s
        env.response.headers["Content-Disposition"] = "attachment; filename=\"#{filename}\""
        env.response.headers["X-Content-Type-Options"] = "nosniff"
        env.response.headers["Cache-Control"] = "private, no-store"

        io = Artifact::Uploader.open(artifact.path)
        begin
          IO.copy(io, env.response)
        ensure
          io.close
        end
      end

      # The file name for both the `Content-Disposition` header and the
      # artifact row: `crm.Company.csv`, or `crm.Company.view.csv` for a
      # view export.
      private def self.export_filename(domain : String, doc_type : String, format : String, view : Bool = false) : String
        marker = view ? ".view" : ""
        "#{domain}.#{doc_type}#{marker}.#{format}"
      end

      private def self.enqueue_body(env, job_id : String, status_url : String, row_count : Int32? = nil) : String
        if row_count.nil?
          Facet::HTTP::Helpers.write_json(env, 202, {job_id: job_id, status_url: status_url})
        else
          Facet::HTTP::Helpers.write_json(env, 202, {job_id: job_id, row_count: row_count, status_url: status_url})
        end
      end
    end
  end
end
