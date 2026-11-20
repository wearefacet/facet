# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../../database"
require "../../config"
require "../../http/helpers"
require "../../rbac"
require "../../rbac/read_enforcer"
require "../../rbac/write_enforcer"
require "../../jobs/queries"
require "../../artifact/store"
require "../../artifact/uploader"
require "../../iam/api_key"
require "../../util/projections"
require "../../util/script_helpers"
require "../../import_export/artifacts"
require "../../import_export/caller_context"
require "./archive"
require "./export"
require "./import"
require "./export_job"
require "./import_job"

module Facet
  module Domain
    module Portable
      # HTTP routes for the portable-domain import/export concern.
      #
      # Registered by `HTTP::Server.routes` before the document
      # import/export routes, so `/Api/core/Domain/import` and
      # `/Api/core/Domain/import_export/:job_id` answer the domain
      # concern, never the document concern's flat routes for the
      # `core.Domain` doctype.
      #
      # All routes authenticate through the normal JWT middleware. The
      # write-shaped POSTs require the `X-Requested-With` header (the
      # CSRF rule, with the IAM API-key-bearer bypass). The status and
      # download routes are requester-scoped: the job payload carries
      # the requesting `account_id`, and the route answers only when it
      # matches the caller. An unknown job, a foreign account, and a
      # pruned artifact all answer `404`, never `403`, so job ids do
      # not leak.
      #
      # Export gates on **read** access to the `core.Domain` document
      # (the domain document); import gates on **write** access — create
      # for a fresh import, update for a merge onto an existing domain —
      # the same gates the draft / publish / drop lifecycle routes hold.
      # Export over HTTP is definition-only: a bundle that carries a
      # `documents/` section refuses (`422`), because read access to the
      # domain document must not widen into read access to every
      # document row, and the import job would write those rows around
      # per-doctype permissions.
      module Routes
        # The job kinds whose status/download the concern's routes serve.
        STATUS_JOB_KINDS = Set{"domain_export", "domain_import"}

        def self.register : Nil
          post "/Api/core/Domain/:id/export" do |env|
            handle_export_enqueue(env)
          end

          post "/Api/core/Domain/import" do |env|
            handle_import_enqueue(env)
          end

          get "/Api/core/Domain/import_export/:job_id" do |env|
            handle_status(env)
          end

          get "/Api/core/Domain/import_export/:job_id/download" do |env|
            handle_download(env)
          end
        end

        # ── Export enqueue ─────────────────────────────────────────────

        # `POST /Api/core/Domain/:id/export`. Gates on read access to the
        # domain document (`404` non-disclosing), refuses a draft domain
        # up front (`422` — the job would refuse too, but a synchronous
        # answer is a better contract for a deterministic rejection),
        # enqueues the `domain_export` job with the queue's long lease
        # horizon, and answers `202` with the job id. `wait=true` polls
        # the job row and resolves to the zip itself; the timeout falls
        # back to the `202` enqueue body with the job still running.
        private def self.handle_export_enqueue(env)
          return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

          domain = env.params.url["id"]

          auth = HTTP::Helpers.auth_context(env)
          return error(env, 422, "Export is not available in preview mode") if auth.preview?

          gate = Database.with_db { |db| export_gate(db, domain, auth) }
          if gate.is_a?(ServiceError)
            return error(env, gate.status, gate.message)
          end

          payload = export_payload(auth, domain)
          job_id = enqueue_job(ExportJob::KIND, payload)
          status_url = "/Api/core/Domain/import_export/#{job_id}"

          if env.params.query["wait"]? == "true" && wait_for_job(env, job_id)
            ""
          else
            enqueue_body(env, job_id, status_url)
          end
        end

        # The enqueue-time gates: existence (`404` for a missing domain),
        # read access (`404` non-disclosing for a denial), and the draft
        # refusal (`422`). Existence is checked before the enforcer — a
        # scopeless read permission matches every row, including a missing
        # one, so the enforcer alone cannot answer `404` here.
        private def self.export_gate(db : DB::Connection, domain : String, auth : RBAC::AuthContext) : ServiceError?
          content = fetch_domain_content(db, domain)
          return ServiceError.new(404, "Not found") if content.nil?

          unless RBAC::ReadEnforcer.authorized?(db, "core", "Domain", domain, auth)
            return ServiceError.new(404, "Not found")
          end

          if domain_draft?(content)
            return ServiceError.new(
              422,
              "Domain '#{domain}' is a draft — scratch data is not portable. Publish it first.",
            )
          end
          nil
        end

        private def self.fetch_domain_content(db : DB::Connection, domain : String) : JSON::Any?
          db.query_one?(
            "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'Domain' " \
            "AND id = $1 AND deleted_at IS NULL",
            domain,
            as: JSON::Any,
          )
        end

        # The `draft` flag — any missing or non-`true` value is `false`
        # (fail-closed, matching `Doctype::Create#draft_domain?`).
        private def self.domain_draft?(content : JSON::Any) : Bool
          content.as_h? && content["draft"]? && content["draft"].raw == true || false
        end

        # The job payload: coordinates and identity references only.
        private def self.export_payload(auth : RBAC::AuthContext, domain : String) : JSON::Any
          payload = {
            "domain"     => JSON::Any.new(domain),
            "account_id" => JSON::Any.new(auth.account_id),
          } of String => JSON::Any

          if role_reference = ImportExport::CallerContext.role_reference(auth)
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

        # ── Import enqueue ─────────────────────────────────────────────

        # `POST /Api/core/Domain/import`. Body: the bundle archive (zip or
        # tarball). Query: `into=<name>` renames the target domain,
        # `merge=true` selects the upsert branch, `wait=true` polls.
        #
        # Gate order: when `into` names the target on the query string,
        # the write gate runs BEFORE the body spool and the archive check
        # — an unauthorized caller must not be able to probe the
        # bundle-format contract (B-208). A bundle-derived target (no
        # `into`) needs the parsed bundle to name the target, so on that
        # branch the parse stays first and the gate runs inside
        # `stage_import`.
        #
        # The bundle parses synchronously (`Archive.read`) so a malformed
        # archive, a documents-carrying bundle, a refused target, and the
        # permission gates all answer before any job row exists — the job
        # re-reads and re-checks everything at execution time.
        private def self.handle_import_enqueue(env)
          return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

          auth = HTTP::Helpers.auth_context(env)
          return error(env, 422, "Import is not available in preview mode") if auth.preview?

          if gate_error = import_pre_gate_error(env, auth)
            return error(env, gate_error.status, gate_error.message)
          end

          spooled = spool_upload(env)
          return error(env, spooled.status, spooled.message) if spooled.is_a?(BodyError)

          begin
            unless archive_magic?(spooled.path)
              return error(env, 422, "Bundle must be a zip or tar.gz archive")
            end

            staged = Database.with_db { |db| stage_import(db, env, auth, spooled.path) }
            if staged.is_a?(ServiceError)
              return error(env, staged.status, staged.message)
            end

            job_id = enqueue_job(ImportJob::KIND, staged.payload)
            status_url = "/Api/core/Domain/import_export/#{job_id}"

            if env.params.query["wait"]? == "true" && wait_for_job(env, job_id)
              ""
            else
              Facet::HTTP::Helpers.write_json(env, 202, {
                job_id:        job_id,
                target_domain: staged.target,
                status_url:    status_url,
              })
            end
          ensure
            File.delete?(spooled.path)
          end
        end

        # Spools the request body to a temp file. `413` when the upload
        # exceeds `artifact.max_upload_bytes` — the same status and
        # message the upload routes answer, so one client-side rule
        # covers both. The cap is checked per chunk, before the whole
        # body ever sits in memory.
        #
        # Once the cap is crossed the body is drained and discarded up to a
        # hard ceiling before the 413 is written. Answering while the client
        # is still writing makes the edge (Caddy) see a half-read upstream
        # exchange and report 502 instead of relaying the 413 — the drain
        # keeps the status reliable. A body past the hard ceiling is not
        # drained: the connection closes and the caller reads a transport
        # error, which is the correct signal for an upload far past the cap.
        private def self.spool_upload(env) : Spooled | BodyError
          max_bytes = Config.instance.artifact.max_upload_bytes
          hard_ceiling = max_bytes * 2

          io = env.request.body
          return BodyError.new(422, "Import requires a request body") if io.nil?
          body = io

          path = File.tempname("facet-domain-import")
          total = 0_i64
          over_cap = false
          File.open(path, "wb") do |f|
            buf = Bytes.new(65_536)
            loop do
              read = body.read(buf)
              break if read == 0
              total += read
              if total > max_bytes
                over_cap = true
                return BodyError.new(413, "Upload exceeds the maximum allowed size (#{max_bytes} bytes)") if total > hard_ceiling
                next
              end
              f.write(buf[0, read])
            end
          end

          if over_cap
            return BodyError.new(413, "Upload exceeds the maximum allowed size (#{max_bytes} bytes)")
          end

          Spooled.new(path: path, size: total)
        end

        private record BodyError, status : Int32, message : String
        private record Spooled, path : String, size : Int64

        # The pre-parse gate for a query-string target (B-208). Returns
        # the error response to write — a `422` for a refused target
        # name, a `403` for a denied write — or nil when the caller may
        # proceed. Read-only: nothing is staged here. The gate holds the
        # same decision `stage_import` holds later: create for a fresh
        # import, update for a merge onto an existing domain.
        private def self.import_pre_gate_error(env, auth : RBAC::AuthContext) : ServiceError?
          into = env.params.query["into"]?
          return nil if into.nil? || into.empty?

          if name_error = invalid_target_name(into)
            return name_error
          end

          merge = env.params.query["merge"]? == "true"
          gate_message = Database.with_db(:read_only) do |db|
            target_exists = Util::Projections.exists?(db, "core", "Domain", into)
            denied_write_message(db, auth, into, target_exists && merge)
          end
          gate_message ? ServiceError.new(403, gate_message) : nil
        end

        # The container sniff: zip (`PK` signatures) or gzip. `Archive.zip?`
        # covers zip by extension or magic; the gzip bytes are checked here
        # so a garbage upload answers `422` with a clean message instead of
        # a `tar` process error.
        private def self.archive_magic?(path : String) : Bool
          return true if Archive.zip?(path)
          return false unless File.file?(path)

          header = Bytes.new(2)
          File.open(path, "rb") do |f|
            return false unless f.read_fully?(header)
          end
          header == Bytes[0x1f, 0x8b]
        end

        # One staged import run: parse the bundle, validate the request
        # against the target, gate, stage the artifact, assemble the
        # payload. Every failure is a `ServiceError` — nothing was
        # enqueued and no artifact row persists on the failure path (the
        # artifact stages last).
        private def self.stage_import(
          db : DB::Connection,
          env,
          auth : RBAC::AuthContext,
          bundle_path : String,
        ) : Staged | ServiceError
          begin
            bundle = Archive.read(bundle_path)
          rescue ex : Archive::Error
            return ServiceError.new(422, "Unreadable bundle: #{ex.message}")
          end

          unless bundle.documents.empty?
            return ServiceError.new(
              422,
              "Bundle carries document data — import over HTTP is definition-only",
            )
          end

          into = env.params.query["into"]?
          if into && !into.empty?
            if error = invalid_target_name(into)
              return error
            end
          end
          merge = env.params.query["merge"]? == "true"

          target = into && !into.empty? ? into : bundle.source_domain
          target_exists = Util::Projections.exists?(db, "core", "Domain", target)

          # Gate before conflict: a caller without the write permission
          # the operation would use never learns whether the target
          # exists. A fresh import answers under the create gate even
          # when the target exists — the operation it asked for is a
          # create, so create is the permission it must hold.
          gate_message = denied_write_message(db, auth, target, target_exists && merge)
          return ServiceError.new(403, gate_message) if gate_message

          if target_exists && !merge
            return ServiceError.new(
              409,
              "Domain '#{target}' already exists; pass merge=true to overwrite.",
            )
          end

          artifact = ImportExport::Artifacts.put(
            db, File.open(bundle_path, "rb"), "#{bundle.source_domain}.facet-domain.zip", "application/zip",
            auth,
          )

          Staged.new(
            payload: import_payload(auth, artifact.artifact_id, bundle.source_domain, into, merge),
            target: target,
          )
        end

        private record Staged, payload : JSON::Any, target : String

        # The live-domain name grammar, shared with `Domain::Publish`:
        # lowercase alphanumeric + dashes, no `_` prefix (reserved for
        # drafts).
        private def self.invalid_target_name(name : String) : ServiceError?
          if name.starts_with?('_')
            return ServiceError.new(422, "Target name '#{name}' must not start with '_' — that prefix is reserved for drafts")
          end
          unless name.matches?(/^[a-z][a-z0-9\-]*$/)
            return ServiceError.new(
              422,
              "Target name '#{name}' is invalid — must be lowercase alphanumeric (a-z, 0-9, -) and start with a letter",
            )
          end
          nil
        end

        # The write gate: update permission on the existing `core.Domain`
        # document for a merge onto a live domain, create permission for
        # a fresh import (also the gate a refused `409` target answers
        # under — the same order the enqueue route holds).
        private def self.denied_write_message(
          db : DB::Connection,
          auth : RBAC::AuthContext,
          target : String,
          merge_onto_existing : Bool,
        ) : String?
          authorized = if merge_onto_existing
                         RBAC::WriteEnforcer.authorize_update(db, "core", "Domain", target, auth)
                       else
                         RBAC::WriteEnforcer.authorize_create(db, "core", "Domain", auth)
                       end
          authorized ? nil : "Forbidden"
        end

        # The job payload: coordinates, identity references, and the
        # ownerless artifact id — never bundle content.
        private def self.import_payload(
          auth : RBAC::AuthContext,
          bundle_artifact_id : String,
          source_domain : String,
          into : String?,
          merge : Bool,
        ) : JSON::Any
          payload = {
            "bundle_artifact_id" => JSON::Any.new(bundle_artifact_id),
            "source_domain"      => JSON::Any.new(source_domain),
            "into"               => JSON::Any.new(into),
            "merge"              => JSON::Any.new(merge),
            "account_id"         => JSON::Any.new(auth.account_id),
          } of String => JSON::Any

          if role_reference = ImportExport::CallerContext.role_reference(auth)
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

        # `GET /Api/core/Domain/import_export/:job_id` — the job's
        # caller-facing outcome. Requester-scoped: another account's job
        # id is a `404`. `result` is null while the row is
        # pending/running and carries the handler's payload once the
        # outcome is written.
        private def self.handle_status(env)
          job_id = env.params.url["job_id"]

          own = Database.with_db(:read_only) { |db| requester_payload(db, env, job_id) }
          return error(env, 404, "Not found") unless own

          outcome = Database.with_db(:read_only) { |db| Jobs::Queries.find_outcome(db, job_id) }
          return error(env, 404, "Not found") unless outcome

          Facet::HTTP::Helpers.write_json(env, 200, {
            id:     job_id,
            status: outcome.status,
            error:  outcome.error,
            result: outcome.result,
          })
        end

        # ── Download ────────────────────────────────────────────────────

        # `GET /Api/core/Domain/import_export/:job_id/download` — streams
        # the export zip. Only a succeeded export produces a file: a
        # pending/running/failed job, an import, or a pruned artifact all
        # answer `404` — there is nothing to download, and the answer
        # never distinguishes the cases.
        private def self.handle_download(env)
          job_id = env.params.url["job_id"]

          resolved = Database.with_db(:read_only) do |db|
            found = requester_payload(db, env, job_id)
            next nil unless found
            next nil unless found.kind == ExportJob::KIND

            outcome = Jobs::Queries.find_outcome(db, job_id)
            next nil unless outcome && outcome.status == "succeeded"

            artifact_id = outcome.result.try(&.as_h?).try(&.["artifact_id"]?).try(&.as_s?)
            next nil if artifact_id.nil? || artifact_id.empty?

            artifact = Artifact::Store.find_artifact(db, artifact_id)
            next nil if artifact.nil? || artifact.deleted_at

            domain = found.payload["domain"]?.try(&.as_s?) || "domain"
            {artifact: artifact, domain: domain}
          end
          return error(env, 404, "Not found") unless resolved

          stream_zip(env, resolved[:domain], resolved[:artifact])
        end

        # ── Wait mode ───────────────────────────────────────────────────

        # Polls the job row every `wait_poll_ms` until the row is terminal
        # or the deadline passes. Returns `true` when the response is
        # written — export: the zip on success, `422` with the error on
        # an expected failure, `500` on a crash-class failure; import:
        # the report JSON on success, the same failure mapping. Returns
        # `false` on timeout — the caller then answers the `202` enqueue
        # body and the job keeps running. The wait never cancels a job.
        private def self.wait_for_job(env, job_id : String) : Bool
          cfg = Config.instance.import_export
          deadline = Time.instant + cfg.wait_timeout_s.seconds

          loop do
            resolved = Database.with_db(:read_only) do |db|
              job = requester_payload(db, env, job_id)
              next nil unless job
              next nil unless outcome = Jobs::Queries.find_outcome(db, job_id)
              next nil unless terminal?(outcome.status)
              {kind: job.kind, status: outcome.status, error: outcome.error, result: outcome.result}
            end

            if resolved
              write_outcome(env, job_id, resolved)
              return true
            end

            return false if Time.instant >= deadline
            sleep cfg.wait_poll_ms.milliseconds
          end
        end

        # The wait-mode terminal shapes: success → the export streams or
        # the import report answers `200`; an expected failure (the
        # result carries the `expected` marker) → `422` with the error;
        # a crash-class failure → `500` with the job id.
        private def self.write_outcome(
          env,
          job_id : String,
          resolved : {kind: String, status: String, error: String?, result: JSON::Any?},
        ) : Nil
          if resolved[:status] == "succeeded"
            if resolved[:kind] == ExportJob::KIND
              artifact_id = resolved[:result].try(&.as_h?).try(&.["artifact_id"]?).try(&.as_s?)
              if artifact_id.nil? || artifact_id.empty?
                return Facet::HTTP::Helpers.write_json(env, 500, {job_id: job_id, error: "Export result carries no artifact id"})
              end

              resolved2 = Database.with_db(:read_only) do |db|
                artifact = Artifact::Store.find_artifact(db, artifact_id)
                next nil if artifact.nil? || artifact.deleted_at
                domain = find_job_domain(db, job_id)
                next nil if domain.nil?
                {artifact: artifact, domain: domain}
              end
              unless resolved2
                return Facet::HTTP::Helpers.write_json(env, 500, {job_id: job_id, error: "Export artifact is gone (pruned)"})
              end

              return stream_zip(env, resolved2[:domain], resolved2[:artifact])
            end

            return Facet::HTTP::Helpers.write_json(env, 200, {
              job_id:  job_id,
              status:  "succeeded",
              domain:  resolved[:result].try(&.as_h?).try(&.["domain"]?),
              created: resolved[:result].try(&.as_h?).try(&.["created"]?),
              report:  resolved[:result],
            })
          end

          expected = resolved[:result].try(&.as_h?).try(&.["expected"]?)
          if expected
            return Facet::HTTP::Helpers.write_json(env, 422, {
              job_id: job_id,
              status: "failed",
              error:  resolved[:error],
            })
          end

          Facet::HTTP::Helpers.write_json(env, 500, {job_id: job_id, error: resolved[:error]})
        end

        # ── Shared internals ────────────────────────────────────────────

        # The requester-scoping gate: the job row must exist, its kind
        # must be one of the concern's kinds, and its `account_id` must
        # match the caller. Every mismatch is a `nil` — the caller
        # renders the non-disclosing `404`.
        private def self.requester_payload(db : DB::Connection, env, job_id : String) : Jobs::Job?
          job = Jobs::Queries.find(db, job_id)
          return nil unless job
          return nil unless STATUS_JOB_KINDS.includes?(job.kind)
          return nil unless job.payload.as_h?.try(&.["account_id"]?.try(&.as_s?)) == HTTP::Helpers.auth_context(env).account_id

          job
        end

        private def self.terminal?(status : String) : Bool
          status == "succeeded" || status == "failed"
        end

        # The exported domain name for a wait-mode stream: the job
        # payload's `domain` field, re-read from the row.
        private def self.find_job_domain(db : DB::Connection, job_id : String) : String?
          job = Jobs::Queries.find(db, job_id)
          job.try(&.payload.as_h?).try(&.["domain"]?).try(&.as_s?)
        end

        # Streams artifact bytes with the export headers: the stored MIME
        # type, `nosniff`, no-store, and an attachment with the
        # `{domain}.facet-domain.zip` filename. Plain full-body streaming.
        private def self.stream_zip(env, domain : String, artifact : Artifact::Store::Artifact) : Nil
          filename = "#{domain}.facet-domain.zip"
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

        # Enqueues through the jobs manager when the subsystem is up (the
        # manager inserts the row and wakes the running worker when one
        # exists) and falls back to a direct row insert in enqueue-only
        # mode — in test contexts without a manager the job row must
        # still exist, because the status route reads it. `max_attempts:
        # 1` for both kinds: a job runs once, the caller fixes the input
        # and submits again.
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

        private def self.enqueue_body(env, job_id : String, status_url : String) : String
          Facet::HTTP::Helpers.write_json(env, 202, {job_id: job_id, status_url: status_url})
        end

        private def self.error(env, status : Int32, message : String) : String
          Facet::HTTP::Helpers.error_response(env, status, message)
        end
      end
    end
  end
end
