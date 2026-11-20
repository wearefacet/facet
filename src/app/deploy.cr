# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../error"
require "../http/helpers"
require "../rbac"
require "../artifact/multipart"
require "../doctype/definition_store"
require "../document/create"
require "../document/update"
require "../util/script_helpers"

module Facet
  module App
    # The deploy route: `POST /Api/app/:id/deploy`.
    #
    # One multipart request uploads a build and (optionally) activates it:
    # the `$content` part carries the deployment JSON, one part per file
    # named `files[<i>].file`. The existing multipart intake
    # (`Artifact::Multipart.parse` + `upload_files`) spools, decides the
    # mime type (file name first — static build assets are all text —
    # magic bytes as fallback), uploads, substitutes artifact ids, and
    # writes owner rows — all inside the create transaction. A failed file
    # rolls the whole deploy back; no half-uploaded build can ever exist.
    #
    # The mutation goes through `Document::Create` so event sourcing,
    # WebSocket invalidation, and audit attribution all hold: the actioner
    # is the operator account or the service account, and `meta.app` carries
    # the app id. The route's own gate replaces the standard create gate —
    # deploying is app-scoped self-management, not a data-doctype access,
    # so the service account needs no grants for `app.*`.
    #
    # One gate for every caller — "your grant ∩ role carries `deploy` on
    # `app.App`":
    #
    # | Caller             | Credential                     | Check                       |
    # | ------------------ | ------------------------------ | --------------------------- |
    # | Dashboard operator | session cookie                 | CSRF header + `deploy` on   |
    # |                    |                                | `app.App` (standard model)  |
    # | CLI / automation   | `Authorization: Bearer fct_…`  | no CSRF; `deploy` must sit  |
    # |                    | or OAuth app token             | in grant ∩ role (Layer-1    |
    # |                    |                                | pre-check + standard model) |
    #
    # `WriteEnforcer.authorize_action` applies the same named-action rules
    # as update: a scoped permission only passes when the target row
    # satisfies the scope's `where`, and an app-scoped caller additionally
    # needs the action inside its grant ceiling. Key liveness (including
    # the active-app gate) ran in `AuthHandler`; the route never re-verifies
    # the token. A role without `deploy` (e.g. the seeded
    # `editor`) cannot deploy; an OAuth app token passes — the same gate applies
    # to its account's active role; and an app
    # that deploys itself needs `deploy` in its grants and service role.
    module Deploy
      # Safe-path rule for `files[].path`: no leading `/`, no `..`, no empty
      # segment, valid UTF-8, bounded length. Storage paths never see the
      # filesystem, but serving maps URLs through them, so the rule closes
      # traversal and normalization bugs at the door.
      PATH_MAX_LENGTH = 1024

      def self.register : Nil
        post "/Api/app/:id/deploy" do |env|
          app_id = env.params.url["id"]?.try(&.to_s)
          if app_id.nil? || app_id.empty?
            next HTTP::Helpers.error_response(env, 422, "Missing 'id' path parameter")
          end

          caller = authorize_caller(env) || next

          parsed = Facet::Artifact::Multipart.parse(env)
          if parsed.is_a?(Facet::ServiceError)
            next HTTP::Helpers.error_response(env, parsed.status, parsed.message)
          end

          # The caller's `$content` never reaches the mutation verbatim:
          # the route-owned `activate` key is read and stripped, `files[].file`
          # values are nulled (the artifact ids must come from THIS request's
          # file parts, never from the caller's JSON), and `app_id`/`revision`
          # are injected below. Rebuild the parsed multipart over the
          # sanitized JSON so `upload_files` substitutes into clean content.
          parsed_content = parse_content(parsed.content, env.request.query_params["activate"]? == "true")
          if parsed_content.is_a?(Facet::ServiceError)
            Facet::Artifact::Multipart.cleanup(parsed)
            next HTTP::Helpers.error_response(env, parsed_content.status, parsed_content.message)
          end
          sanitized, activate = parsed_content
          parsed = Facet::Artifact::Multipart::ParsedMultipart.new(sanitized, parsed.files)

          result = begin
            Database.with_transaction do |db|
              run_deploy(db, app_id, caller, parsed, activate)
            end
          rescue ex : Facet::Artifact::Multipart::UploadFailed
            Facet::Artifact::Multipart.cleanup(parsed)
            next HTTP::Helpers.error_response(env, ex.error.status, ex.error.message)
          end

          Facet::Artifact::Multipart.cleanup(parsed)
          Event::Publisher.flush

          # A ServiceError returned from the transaction block means the gate
          # or a lookup failed before any write happened — nothing to roll
          # back, surface it directly.
          if result.is_a?(Facet::ServiceError)
            next HTTP::Helpers.error_response(env, result.status, result.message)
          end

          env.response.status_code = 201
          env.response.content_type = "application/json"
          env.response.print(result.to_json)
        end
      end

      # ── Private ────────────────────────────────────────────────────────────

      # Credential gate. Bearer callers (an app-owned API key or an OAuth
      # app token) authenticate through `AuthHandler` and carry their
      # resolved grant — cookie-free, so no CSRF applies. Cookie-session
      # callers keep the CSRF defence used on every cookie-authenticated
      # mutating route. Writes the error response and returns nil when the
      # caller is refused.
      private def self.authorize_caller(env) : RBAC::AuthContext?
        context = Fiber.current.auth_context
        if context.nil? || context.system? || context.preview?
          HTTP::Helpers.error_response(env, 401, "Authentication required")
          return nil
        end

        if bearer_token(env).nil? && env.request.headers["X-Requested-With"]?.nil?
          HTTP::Helpers.error_response(env, 403, "CSRF: Missing X-Requested-With header")
          return nil
        end

        context
      end

      # The deploy transaction body: deploy gate, app gate, multipart
      # upload, mutation, optional activation. All-or-nothing — the caller
      # rescues `UploadFailed` so the transaction rolls back as one unit.
      # A returned `ServiceError` means a pre-write gate failed; the caller
      # surfaces it directly (nothing has been written yet).
      private def self.run_deploy(
        db : DB::Connection,
        app_id : String,
        caller : RBAC::AuthContext,
        parsed : Facet::Artifact::Multipart::ParsedMultipart,
        activate : Bool,
      )
        # One gate for every caller: the `deploy` named action on
        # `app.App`. Session callers need a role permission; app-scoped
        # callers additionally need the action inside their grant ceiling
        # (the Layer-1 pre-check inside the enforcer). A scoped permission
        # only passes when the target row satisfies the scope's `where` —
        # the same rule as update.
        return Facet::ServiceError.new(403, "Forbidden") unless RBAC::WriteEnforcer.authorize_action(db, "app", "App", app_id, "deploy", caller)

        # A draft or disabled app cannot receive a deployment on any
        # credential path. Neither can a registration marked `no_asset` —
        # a headless app (the CLI tool registration) is not a deploy
        # target and never gains a host.
        app = load_app(db, app_id)
        return Facet::ServiceError.new(404, "App not found") unless app
        status = app.as_h["status"]?.try(&.as_s?) || "draft"
        return Facet::ServiceError.new(422, "App is not active") unless status == "active"
        return Facet::ServiceError.new(422, "App does not accept deployments") if app.as_h["no_asset"]?.try(&.as_bool?) == true

        defn = Facet::Doctype::DefinitionStore.fetch(db, "app.Deployment")
        return Facet::ServiceError.new(500, "app.Deployment doctype is not seeded") unless defn

        doc_id = Util::ScriptHelpers.ulid
        # Static build assets are all text — the sniffer cannot tell html,
        # css, and js apart. The file name decides the stored type (both
        # first-party clients send the build path as the part file name);
        # the sniffer stays the fallback for unknown names.
        uploaded = Facet::Artifact::Multipart.upload_files(
          db, caller, parsed, defn, "app", "Deployment", doc_id, caller.account_id,
          mime_from_extension: true,
        )

        # Every entry must carry an artifact id now — an entry without a
        # matching file part means the request was incomplete.
        validate_uploaded_files(uploaded)

        content = uploaded.as_h
        content["app_id"] = JSON::Any.new("app.App.#{app_id}")
        content["revision"] = JSON::Any.new(next_revision(db, app_id))

        created = Facet::Document::Create.create_from_parsed(
          db, "app", "Deployment", uploaded, caller, caller.account_id,
          doc_id: doc_id,
          allow_system_writes: true, # revision is read_only; the route is its only writer
          skip_authorization: true,  # the route's own gate ran above
          # `app_id` comes from the URL path, not the caller's body, and the
          # gate above proved `deploy` reach on that exact row — the
          # reference check must not additionally demand a read grant on it.
          trusted_reference_fields: Set{"app_id"},
        )
        if created.is_a?(Facet::ServiceError)
          raise Facet::Artifact::Multipart::UploadFailed.new(created)
        end

        if activate
          patch = {"active_deployment" => "app.Deployment.#{doc_id}"}.to_json
          updated = Facet::Document::Update.call(
            db, "app", "App", app_id, patch,
            RBAC::AuthContext.system, # the gate ran above; the system context writes the pointer
            actioner_id: caller.account_id)
          if updated.is_a?(Facet::ServiceError)
            raise Facet::Artifact::Multipart::UploadFailed.new(updated)
          end
        end

        {
          id:        doc_id,
          revision:  content["revision"].as_i64?,
          activated: activate,
          files:     content["files"].as_a.size,
        }
      end

      # True when the request carries a bearer credential in the
      # Authorization header (an app-owned API key or an OAuth app token).
      # The shared extractor reads the `Bearer` scheme only, cookie-free.
      private def self.bearer_token(env) : String?
        HTTP::Helpers.extract_access_token(env, schemes: ["Bearer"], cookie: false)
      end

      # Parses `$content` once and strips everything the route owns before
      # the mutation sees the content: the `activate` key (route metadata,
      # never a doctype field — a leftover key here fails document
      # validation) and caller-supplied `files[].file` values, which must
      # come from this request's own file parts. Returns the sanitized JSON
      # plus the activation flag; the query-string form ORs on top.
      private def self.parse_content(raw : String, query_activate : Bool) : {String, Bool} | Facet::ServiceError
        content = begin
          JSON.parse(raw)
        rescue ex : JSON::ParseException
          return Facet::ServiceError.new(422, "Invalid JSON in '$content' part: #{ex.message}")
        end
        hash = content.as_h?
        return Facet::ServiceError.new(422, "'$content' must be a JSON object") unless hash

        activate = false
        if flag = hash.delete("activate")
          activate = (b = flag.as_bool?) ? b : (flag.as_s? == "true")
        end

        if files = hash["files"]?.try(&.as_a?)
          files.each do |entry|
            entry.as_h?.try(&.delete("file"))
          end
        end

        activate = activate || query_activate
        {content.to_json, activate}
      end

      # Validates the post-upload files array: each entry needs a safe path
      # and an artifact id (substituted by the multipart intake). Raises
      # `UploadFailed` so the transaction — owner rows included — rolls back.
      private def self.validate_uploaded_files(uploaded : JSON::Any) : Nil
        hash = uploaded.as_h?
        unless hash
          raise Facet::Artifact::Multipart::UploadFailed.new(Facet::ServiceError.new(422, "'$content' must be a JSON object"))
        end

        files = hash["files"]?.try(&.as_a?)
        if files.nil? || files.empty?
          raise Facet::Artifact::Multipart::UploadFailed.new(Facet::ServiceError.new(422, "files must be a non-empty array"))
        end

        files.each_with_index do |entry, i|
          item = entry.as_h?
          raise path_error(i, "path is required") unless item

          path = item["path"]?.try(&.as_s?)
          raise path_error(i, "path is required") if path.nil? || path.empty?
          raise path_error(i, "path '#{path}' is not a safe relative path") unless safe_path?(path)
          raise path_error(i, "path '#{path}' exceeds #{PATH_MAX_LENGTH} characters") if path.size > PATH_MAX_LENGTH

          artifact_id = item["file"]?.try(&.as_s?)
          if artifact_id.nil? || artifact_id.empty?
            raise path_error(i, "file is missing — a file part named 'files[#{i}].file' must accompany every entry")
          end
        end
      end

      # Safe-path rule: no leading `/`, no `.` or `..` segments, no empty
      # segments, valid UTF-8.
      private def self.safe_path?(path : String) : Bool
        return false unless path.valid_encoding?
        return false if path.starts_with?("/")
        path.split('/').each do |segment|
          return false if segment.empty? || segment == "." || segment == ".."
        end
        true
      end

      private def self.path_error(index : Int32, message : String) : Facet::Artifact::Multipart::UploadFailed
        Facet::Artifact::Multipart::UploadFailed.new(
          Facet::ServiceError.new(422, "files[#{index}].#{message}")
        )
      end

      # The next `revision` for the app: max + 1 over the app's live
      # deployments. Reference values are stored qualified; the bare form is
      # matched too so directly-authored rows (bare app_id) still count.
      private def self.next_revision(db : DB::Connection, app_id : String) : Int64
        max = db.query_one?(
          <<-SQL,
            SELECT COALESCE(MAX((content->>'revision')::bigint), 0)
            FROM projections
            WHERE domain = 'app' AND doc_type = 'Deployment'
              AND deleted_at IS NULL
              AND (content->>'app_id' = $1 OR content->>'app_id' = $2)
          SQL
          "app.App.#{app_id}", app_id,
          as: Int64,
        ) || 0_i64
        max + 1
      end

      private def self.load_app(db : DB::Connection, app_id : String) : JSON::Any?
        db.query_one?(
          "SELECT content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL",
          app_id,
          as: JSON::Any,
        )
      end
    end
  end
end
