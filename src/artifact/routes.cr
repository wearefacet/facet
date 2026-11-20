# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../config"
require "../http/helpers"
require "../http/list_request"
require "../rbac"
require "../iam/helpers"
require "./uploader"
require "./store"
require "./access"
require "./grants"
require "./upload_grants"
require "./admin"
require "./serve"

module Facet
  module Artifact
    # HTTP routes for the artifact subsystem.
    #
    # Three origin surfaces per `doc/backend/artifact.md`:
    #
    # - **API routes** (`/Api/core/artifacts/…`) — served from the API
    #   origin (`base_url`), authenticated through the standard
    #   `AuthHandler` / `Helpers.auth_context` chain. Used by the frontend
    #   to render artifact metadata, mint capability URLs, and revoke.
    #
    # - **Admin routes** (`/Api/Artifacts…`) — the operator surface, a
    #   pseudo-doctype path like `/Api/Indexes` (artifacts span every
    #   domain). Gated by `read *.*`; revocation goes through the shared
    #   grant route and additionally accepts the `revoke *.*` action.
    #
    # - **Serve route** (`GET /A/:gid` on `artifact_base_url`) — bearer
    #   URL, *no* auth context. The signature is the only credential; CORS
    #   is blocked and no cookies are sent because the origin is separate.
    #
    # - **Upload capability route** (`POST /A/upload/:uid` on the same
    #   origin) — the one-time bridge an MCP agent POSTs its multipart
    #   body through. Same credential model as the serve route: the
    #   signature is the only credential; the minted record carries the
    #   account and role.
    #
    # The serve route runs on the same Kemal router as the API routes.
    # In production the deployment front-splits by host, so the serve
    # origin never serves cookies and never receives a CORS preflight.
    # The route itself enforces the response hardening (`nosniff`, the
    # CSP, `Content-Disposition`) even when the request arrives on the
    # API origin — defense in depth.
    module Routes
      # Registers all artifact routes on the Kemal router. Idempotent —
      # Kemal rejects duplicate-path registration.
      def self.register : Nil
        register_metadata_routes
        register_grant_routes
        register_admin_routes
        register_download_route
        register_serve_route
        register_upload_capability_route
      end

      # ── Metadata routes ────────────────────────────────────────────────

      private def self.register_metadata_routes : Nil
        # `POST /Api/core/artifacts` — standalone upload.
        #
        # Accepts a single multipart `file` part and returns the artifact id +
        # metadata. Provenance is bound to the uploader's account via the
        # synthetic `_account` owner-row convention (`ACCOUNT_OWNER_*` in
        # `Artifact::Store`) — the artifact is readable by the uploader until
        # it is either linked into a document (which writes a document-scoped
        # owner row via the re-attach flow) or swept by prune once its
        # `created_at` passes the prune window.
        #
        # The artifact id is the only value the frontend needs to drag into a
        # longtext (as `[filename](urn:facet:artifact:<id>)`) or substitute
        # into a `file` field value. The grant URL is fetched separately on
        # render via `GET /Api/core/artifacts/:id`, like any other artifact.
        post "/Api/core/artifacts" do |env|
          handle_upload(env)
        end

        # `GET /Api/core/artifacts/:id` — metadata + a freshly-minted
        # ephemeral grant URL. Auth: standard. The caller must be able to
        # read the artifact (provenance-based access check).
        get "/Api/core/artifacts/:id" do |env|
          handle_metadata(env)
        end
      end

      # Handler for `POST /Api/core/artifacts` — the standalone upload.
      private def self.handle_upload(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        auth = Facet::HTTP::Helpers.auth_context(env)
        if auth.system?
          return Facet::HTTP::Helpers.error_response(env, 403, "System principal cannot upload standalone artifacts")
        end

        # The upload route consults no role permission (it is open to every
        # authenticated caller and attributes the row to them), so the
        # unauthenticated caller must be refused here — the anonymous
        # fallback context (and the fail-closed denied context) would
        # otherwise open a write channel no role governs.
        if auth.account_id == "anonymous"
          return Facet::HTTP::Helpers.error_response(env, 401, "Authentication required")
        end

        perform_account_upload(env, auth)
      end

      # Shared tail of both standalone-upload paths — the authenticated REST
      # route above and the signed capability route below: the multipart
      # gate, the parse, the `Uploader.upload` call under the `_account`
      # owner convention, and the `201` metadata response. Every failure
      # answer is written here; the caller only supplies the auth context.
      private def self.perform_account_upload(env, auth_context : ::Facet::RBAC::AuthContext) : Nil
        content_type = env.request.headers["Content-Type"]?
        unless content_type && content_type.starts_with?("multipart/form-data")
          return Facet::HTTP::Helpers.error_response(
            env, 415,
            "Uploads must be multipart/form-data with a 'file' part",
          )
        end

        filename : String? = nil
        tempfile = File.tempfile("facet-upload")
        begin
          wrote_bytes = false
          begin
            ::HTTP::FormData.parse(env.request) do |part|
              next unless part.name == "file"
              filename = part.filename || "upload"
              IO.copy(part.body, tempfile)
              wrote_bytes = true
              break
            end
          rescue ex : ::HTTP::FormData::Error
            return Facet::HTTP::Helpers.error_response(env, 422, "Invalid multipart body: #{ex.message}")
          end

          unless wrote_bytes
            return Facet::HTTP::Helpers.error_response(env, 422, "Multipart body must include a 'file' part")
          end

          tempfile.flush
          tempfile.rewind

          result = Database.with_transaction do |db|
            begin
              ::Facet::Artifact::Uploader.upload(
                db, tempfile, filename.to_s, auth_context,
                domain: ::Facet::Artifact::Store::ACCOUNT_OWNER_DOMAIN,
                doc_type: ::Facet::Artifact::Store::ACCOUNT_OWNER_DOC_TYPE,
                doc_id: auth_context.account_id,
                field_path: ::Facet::Artifact::Store::ACCOUNT_OWNER_FIELD_PATH,
                view_tag: nil,
              )
            rescue ex : ::Facet::Artifact::Uploader::UploadError
              Facet::ServiceError.new(ex.status, ex.message.to_s)
            end
          end

          case result
          in Facet::ServiceError
            Facet::HTTP::Helpers.error_response(env, result.status, result.message)
          in ::Facet::Artifact::Uploader::Result
            Facet::HTTP::Helpers.write_json(env, 201, {
              id:        result.artifact_id,
              filename:  result.filename,
              mime_type: result.mime_type,
              size:      result.size,
              sha256:    result.signature_sha256,
            })
          end
        ensure
          tempfile.close
          File.delete?(tempfile.path)
        end
      end

      # `POST /A/upload/:uid?exp=…&sig=…` — the one-time upload capability.
      # The signature is the only credential; the ambient auth context (the
      # anonymous fallback the AuthHandler pins for a credential-less
      # request) is ignored — the route builds its own context from the
      # consumed record and revalidates it against live state.
      private def self.register_upload_capability_route : Nil
        post "/A/upload/:uid" do |env|
          handle_upload_capability(env)
        end
      end

      private def self.handle_upload_capability(env) : Nil
        uid = env.params.url["uid"]
        exp_param = env.params.query["exp"]?
        sig_param = env.params.query["sig"]?

        # Same log hygiene as the serve route: the signature never reaches
        # the request log. The params are read above, before the strip.
        strip_query_from_log(env)

        # Cheap gate first: a wrong content type must not burn the
        # capability — the agent can fix its request and reuse the URL.
        content_type = env.request.headers["Content-Type"]?
        unless content_type && content_type.starts_with?("multipart/form-data")
          return Facet::HTTP::Helpers.error_response(
            env, 415,
            "Uploads must be multipart/form-data with a 'file' part",
          )
        end

        consumed = Facet::Artifact::UploadGrants.consume(uid, exp_param, sig_param)
        unless consumed.is_a?(Facet::Artifact::UploadGrants::Capability)
          return render_upload_capability_error(env, consumed.as(Facet::Artifact::UploadGrants::Failure))
        end

        # Live-state revalidation — the mint does not freeze a stale
        # principal. Runs on its own read-only connection.
        auth_context = Database.with_db(:read_only) do |db|
          Facet::Artifact::UploadGrants.build_auth_context(db, consumed)
        end
        unless auth_context
          return render_upload_capability_error(env, Facet::Artifact::UploadGrants::Failure::Stale)
        end

        perform_account_upload(env, auth_context)
      end

      # The 403 body for a failed capability. Every failure answers the
      # same status; the `reason` field is the machine-readable distinction
      # an agent acts on (`expired` / `already_used` → re-mint via
      # request_artifact_upload; `invalid_signature` / `unknown` → the URL
      # is wrong; `stale` → re-mint after the account or role recovers).
      private def self.render_upload_capability_error(
        env,
        failure : Facet::Artifact::UploadGrants::Failure,
      ) : Nil
        reason = Facet::Artifact::UploadGrants.failure_reason(failure)
        message = case failure
                  in .invalid_signature? then "Upload capability signature is invalid"
                  in .expired?           then "Upload capability has expired"
                  in .already_used?      then "Upload capability was already used or unknown — request a fresh one"
                  in .stale?             then "The account or role that minted this upload capability is no longer valid"
                  end
        Facet::HTTP::Helpers.write_json(env, 403, {error: message, reason: reason})
      end

      # Handler for `GET /Api/core/artifacts/:id` — metadata + fresh grant
      # URL. The URL rotates on every fetch.
      private def self.handle_metadata(env) : Nil
        auth = Facet::HTTP::Helpers.auth_context(env)
        artifact_id = env.params.url["id"]

        Database.with_db do |db|
          artifact = Facet::Artifact::Store.find_artifact(db, artifact_id)
          if artifact.nil?
            next Facet::HTTP::Helpers.error_response(env, 404, "Artifact not found")
          end
          if artifact.deleted_at
            next Facet::HTTP::Helpers.error_response(env, 410, "Artifact deleted")
          end

          unless Facet::Artifact::Access.can_read?(db, auth, artifact_id)
            next Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
          end

          # Mint a fresh ephemeral grant URL so the client can stream
          # bytes from the artifact origin with a one-shot 60s window
          # (6h for media). The URL rotates on every fetch.
          grant = Facet::Artifact::Grants.mint_ephemeral(db, auth, artifact_id)
          respond_grant(env, 200, grant) do |g|
            {
              id:         artifact.id,
              filename:   artifact.filename,
              mime_type:  artifact.mime_type,
              size:       artifact.size,
              sha256:     artifact.signature_sha256,
              url:        g.url,
              expires_at: g.expires_at.try(&.to_rfc3339),
            }
          end
        end
      end

      # ── Grant routes ────────────────────────────────────────────────────

      private def self.register_grant_routes : Nil
        # `POST /Api/core/artifacts/:id/grant` — mint an ephemeral grant.
        # Auth: standard read access on the artifact (the route checks
        # `can_read?` again so callers cannot bypass by calling `Grants`
        # directly through a different path).
        post "/Api/core/artifacts/:id/grant" do |env|
          handle_grant(env)
        end

        # `POST /Api/core/artifacts/:id/publish` — mint a permanent grant.
        # Auth: `publish_artifact` named action on the owner's doctype
        # scoped to the owner's `doc_id`. The caller MUST supply
        # `owner_id` in the JSON body so the grant is bound to a specific
        # provenance row (not auto-selected from any readable owner).
        post "/Api/core/artifacts/:id/publish" do |env|
          handle_publish(env)
        end

        # `DELETE /Api/core/artifacts/grants/:gid` — revoke a grant.
        # Auth: system or `publish_artifact` on the grant's underlying
        # owner document (the same permission that minted it).
        delete "/Api/core/artifacts/grants/:gid" do |env|
          handle_revoke(env)
        end
      end

      # Handler for `POST /Api/core/artifacts/:id/grant` — mints an
      # ephemeral grant for a caller with read access on the artifact.
      private def self.handle_grant(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        auth = Facet::HTTP::Helpers.auth_context(env)
        artifact_id = env.params.url["id"]

        Database.with_db do |db|
          unless Facet::Artifact::Access.can_read?(db, auth, artifact_id)
            next Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
          end

          respond_grant(env, 201, Facet::Artifact::Grants.mint_ephemeral(db, auth, artifact_id)) do |g|
            {
              grant_id:    g.grant_id,
              artifact_id: g.artifact_id,
              url:         g.url,
              expires_at:  g.expires_at.try(&.to_rfc3339),
            }
          end
        end
      end

      # Handler for `POST /Api/core/artifacts/:id/publish` — mints a
      # permanent grant bound to the provenance row named in the body.
      private def self.handle_publish(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        auth = Facet::HTTP::Helpers.auth_context(env)
        artifact_id = env.params.url["id"]

        body = Facet::HTTP::Helpers.parse_body(env)
        if body.nil? || body.empty?
          return Facet::HTTP::Helpers.error_response(env, 422, "Request body is required")
        end

        begin
          parsed = JSON.parse(body)
        rescue ex : JSON::ParseException
          return Facet::HTTP::Helpers.error_response(env, 422, "Invalid JSON: #{ex.message}")
        end

        owner_id = parsed["owner_id"]?.try(&.as_s?)
        unless owner_id
          return Facet::HTTP::Helpers.error_response(env, 422, "Body must include 'owner_id' (the provenance row to publish against)")
        end

        Database.with_db do |db|
          # Sanity-check that the owner row actually points at the
          # artifact in the URL — defends against mismatched path / body
          # inputs (the caller's been told the artifact id from show /
          # list, but the owner_id may be stale or fabricated).
          owner = Facet::Artifact::Store.find_owner_row(db, owner_id)
          if owner.nil? || owner.artifact_id != artifact_id
            next Facet::HTTP::Helpers.error_response(env, 404, "Owner row not found for this artifact")
          end

          respond_grant(env, 201, Facet::Artifact::Grants.mint_permanent(db, auth, owner_id)) do |g|
            {
              grant_id:    g.grant_id,
              artifact_id: g.artifact_id,
              url:         g.url,
              permanent:   true,
            }
          end
        end
      end

      # Handler for `DELETE /Api/core/artifacts/grants/:gid` — revokes a
      # grant. Answers 204 on success; `Grants.revoke` errors map to the
      # standard error response (404 when the grant or its owner row is
      # gone, 403 on a permission denial).
      private def self.handle_revoke(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        auth = Facet::HTTP::Helpers.auth_context(env)
        grant_id = env.params.url["gid"]

        Database.with_db do |db|
          case res = Facet::Artifact::Grants.revoke(db, auth, grant_id)
          in Nil
            Facet::HTTP::Helpers.write_no_content(env)
          in Facet::Artifact::Grants::Error
            Facet::HTTP::Helpers.error_response(env, res.status, res.message)
          end
        end
      end

      # ── Admin routes ──────────────────────────────────────────────
      #
      # The operator surface behind `/Configure/platform/artifacts` — a
      # pseudo-doctype path (`/Api/Artifacts`) because the artifact store
      # is transversal and belongs to no domain. `HTTP::DomainGate` passes
      # the prefix through unchanged. The listings are read-only and
      # gated by `Artifact::Admin` (`read *.*`, deny-only-`Denied`); the
      # force-delete route is a write, gated by the `purge *.*` operator
      # action.
      private def self.register_admin_routes : Nil
        # `GET|QUERY /Api/Artifacts` — the artifact listing with child-table
        # counts. Same list grammar as `/Api/Indexes` (page / items /
        # filters / sort) and the platform `{ data, meta }` shape. On QUERY
        # the parameters ride the body only.
        get "/Api/Artifacts" do |env|
          handle_admin_list(env)
        end

        query "/Api/Artifacts" do |env|
          handle_admin_query(env)
        end

        # `DELETE /Api/Artifacts/:id` — force delete (security deletion).
        # Destroys the artifact row, its storage object, and every child
        # row via cascade; writes the `iam.ArtifactEvent` audit document
        # transactionally. Gated by the `purge *.*` operator action
        # (deny-only-`Denied`) with the system bypass. Dangling
        # `urn:facet:artifact:` references in document content are accepted
        # by design. The optional JSON body carries `{reason}` — the
        # operator's free-text why, stored on the audit event's `details`.
        # CSRF-checked like every other destructive route: a cookie session
        # must present the `X-Requested-With` header, bearer API keys are
        # exempt (the shared `require_csrf` bypass).
        delete "/Api/Artifacts/:id" do |env|
          handle_admin_purge(env)
        end

        # `GET /Api/Artifacts/:id/grants` — every grant minted against the
        # artifact, newest first, capped at `Artifact::Admin::SUB_LIST_CAP`.
        get "/Api/Artifacts/:id/grants" do |env|
          handle_admin_grants(env)
        end

        # `GET /Api/Artifacts/:id/references` — the `artifact_references`
        # rows joined with the referencing document's projection.
        get "/Api/Artifacts/:id/references" do |env|
          handle_admin_references(env)
        end
      end

      # Handler for `GET /Api/Artifacts` — builds the list request from
      # the query string and renders the listing.
      private def self.handle_admin_list(env) : Nil
        list_req = HTTP::Helpers.get_list_request(env) || return
        render_admin_list(env, list_req)
      end

      # Handler for `QUERY /Api/Artifacts` — the list parameters ride the
      # body only; `query_list_request` answers 422 when the URL carries
      # query parameters.
      private def self.handle_admin_query(env) : Nil
        list_req = HTTP::Helpers.query_list_request(env) || return
        render_admin_list(env, list_req)
      end

      # Handler for `DELETE /Api/Artifacts/:id` — force delete (security
      # deletion) with the operator's optional free-text reason. CSRF
      # checked like every destructive route: bearer API keys bypass.
      private def self.handle_admin_purge(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        auth = Facet::HTTP::Helpers.auth_context(env)
        artifact_id = env.params.url["id"]

        reason : String? = nil
        if (body = Facet::HTTP::Helpers.parse_body(env)) && !body.empty?
          begin
            reason = JSON.parse(body)["reason"]?.try(&.as_s?)
          rescue ex : JSON::ParseException
            return Facet::HTTP::Helpers.error_response(env, 422, "Invalid JSON: #{ex.message}")
          end
        end

        result = Database.with_db do |db|
          res = Artifact::Purge.destroy(db, auth, artifact_id, reason)
          Event::Publisher.flush
          res
        end
        case result
        in Artifact::Purge::Result
          Facet::HTTP::Helpers.write_no_content(env)
        in Facet::ServiceError
          Facet::HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      # Handler for `GET /Api/Artifacts/:id/grants` — every grant minted
      # against the artifact, newest first, capped at
      # `Artifact::Admin::SUB_LIST_CAP`.
      private def self.handle_admin_grants(env) : Nil
        result = Database.with_db(:read_only) do |db|
          Artifact::Admin.grants(db, HTTP::Helpers.auth_context(env), env.params.url["id"])
        end
        case result
        in Artifact::Admin::GrantsResult
          count, more = HTTP::Helpers.capped_count(result.total, 0, Artifact::Admin::SUB_LIST_CAP.to_i64)
          HTTP::Helpers.write_json(env, 200, {
            data: result.items.map { |row| admin_grant_hash(row) },
            meta: {count: count, more: more},
          })
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      # Handler for `GET /Api/Artifacts/:id/references` — the
      # `artifact_references` rows joined with the referencing document's
      # projection.
      private def self.handle_admin_references(env) : Nil
        result = Database.with_db(:read_only) do |db|
          Artifact::Admin.references(db, HTTP::Helpers.auth_context(env), env.params.url["id"])
        end
        case result
        in Artifact::Admin::ReferencesResult
          count, more = HTTP::Helpers.capped_count(result.total, 0, Artifact::Admin::SUB_LIST_CAP.to_i64)
          HTTP::Helpers.write_json(env, 200, {
            data: result.items.map { |row| admin_reference_hash(row) },
            meta: {count: count, more: more},
          })
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      # Shared render for the `GET` and `QUERY` artifact listing.
      private def self.render_admin_list(env, list_req) : Nil
        HTTP::Helpers.accept_query(env)
        result = Database.with_db(:read_only) do |db|
          Artifact::Admin.list(
            db,
            filters: list_req.filters,
            sort: list_req.sort,
            page: list_req.page,
            items_per_page: list_req.items,
            auth_context: HTTP::Helpers.auth_context(env),
          )
        end
        case result
        in Artifact::Admin::Result
          # `count` is the real number of matching artifacts from this
          # page's offset, truncated at the shared cap; `more` is true only
          # when counting was truncated (B-297).
          count, _ = HTTP::Helpers.capped_count(result.total, 0)
          more = result.total > HTTP::Helpers::COUNT_CAP
          HTTP::Helpers.write_json(env, 200, {
            data: result.items.map { |row| admin_artifact_hash(row) },
            meta: {count: count, more: more},
          })
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      private def self.admin_artifact_hash(row : Artifact::Admin::ArtifactRow) : NamedTuple
        {
          id:              row.id,
          filename:        row.filename,
          mime_type:       row.mime_type,
          size:            row.size,
          sha256:          row.signature_sha256,
          deleted_at:      row.deleted_at.try(&.to_rfc3339),
          created_at:      row.created_at.to_rfc3339,
          uploaded_by:     row.uploaded_by,
          owner_count:     row.owner_count,
          grant_count:     row.grant_count,
          reference_count: row.reference_count,
        }
      end

      private def self.admin_grant_hash(row : Artifact::Admin::GrantRow) : NamedTuple
        {
          id:          row.id,
          artifact_id: row.artifact_id,
          owner_id:    row.owner_id,
          kind:        row.kind,
          expires_at:  row.expires_at.try(&.to_rfc3339),
          epoch:       row.epoch,
          created_by:  row.created_by,
          created_at:  row.created_at.to_rfc3339,
        }
      end

      private def self.admin_reference_hash(row : Artifact::Admin::ReferenceRow) : NamedTuple
        {
          domain:            row.domain,
          doc_type:          row.doc_type,
          resource_id:       row.resource_id,
          display_name:      row.display_name,
          resource_field:    row.resource_field,
          last_reference_at: row.last_reference_at.to_rfc3339,
        }
      end

      # ── Download gateway route ──────────────────────────────────────────
      #
      # `GET /Api/core/artifacts/:id/download` — auth-gated mint-and-redirect.
      #
      # Cookie/bearer authenticated (standard `Helpers.auth_context`) for the
      # browser-session path. Verifies `Access.can_read?` on the artifact,
      # mints an ephemeral grant, and returns `302 Found` with `Location`
      # set to the signed serve URL. The browser follows the redirect to
      # `artifact_base_url`; the serve route (`GET /A/:gid`) streams the
      # bytes.
      #
      # App-origin path: when **both** `?app=APP_ID` and an
      # `Origin` header are present, the request is attributed to an
      # anonymous app caller. The `Origin` must be registered as an
      # `allowed_origins` entry on the named app (`OAuth::OriginCache`),
      # and the `?app=` value must match the origin's owning app id — this
      # prevents a cross-app impersonation attack. The read is gated against
      # the app's grant ceiling (`Access.can_read_for_app?`), not a user
      # role.
      #
      # The "ignore `?app=` when `Origin` is absent" rule: a shared link
      # opened from curl / email / a browser context that sends no `Origin`
      # falls through to the cookie/bearer path, ignoring `?app=` entirely.
      # This keeps shareable URLs annotated with `?app=` working in
      # non-browser contexts.
      private def self.register_download_route : Nil
        get "/Api/core/artifacts/:id/download" do |env|
          artifact_id = env.params.url["id"]
          app_param = env.params.query["app"]?
          origin_header = env.request.headers["Origin"]?

          if (origin = origin_header) && !origin.empty? && (app = app_param) && !app.empty?
            serve_app_origin(env, app, origin, artifact_id)
          else
            serve_authenticated(env, artifact_id)
          end
        end
      end

      # ── Download gateway internals ─────────────────────────────────────

      # Cookie/bearer path. Writes the whole response: an error status, or
      # the 302 redirect to the signed URL.
      #
      # Auth note: a credential-less request carries the anonymous
      # context (the AuthHandler pins it when the `iam.Roles.anonymous`
      # role projection exists), so the gateway evaluates `Access.can_read?`
      # under the anonymous role's read grants. We additionally detect a
      # `nil` fiber-local context — the handler-disabled (tests) and
      # misconfigured case, where `Helpers.auth_context` would fall back to
      # the system bypass — and answer 401 so the bypass can never mint a
      # grant through this route.
      private def self.serve_authenticated(env, artifact_id : String) : Nil
        # No pinned context: the handler is disabled (tests) or the request
        # bypassed the chain. Answers 401 so the system fallback can never
        # mint a grant here.
        if Fiber.current.auth_context.nil?
          Facet::HTTP::Helpers.error_response(env, 401, "Unauthorized")
          return
        end

        auth = Facet::HTTP::Helpers.auth_context(env)

        Database.with_db do |db|
          unless Facet::Artifact::Access.can_read?(db, auth, artifact_id)
            # Operator fallback — the artifact admin page lists every row of
            # the store to `download *.*` holders; this lets the same role
            # view or download the bytes behind the listing (provenance
            # cannot cover account-scoped standalone uploads or artifacts
            # whose provenance documents are gone). deny-only-`Denied`:
            # `mint_ephemeral_for_operator` re-checks the action, so a
            # scoped-but-not-denied result falls through to the mint and
            # cannot escalate beyond the listing's own gate.
            result = auth.can?(Facet::Artifact::Grants::DOWNLOAD_ACTION, "*.*")
            if result.is_a?(::Facet::RBAC::CanResult::Denied)
              Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
              next
            end

            next respond_grant_redirect(
              env, Facet::Artifact::Grants.mint_ephemeral_for_operator(db, auth, artifact_id),
            )
          end

          respond_grant_redirect(env, Facet::Artifact::Grants.mint_ephemeral(db, auth, artifact_id))
        end
      end

      # Anonymous app-origin path. Writes the whole response: 403 on an
      # origin/app_id mismatch, a disabled app, or a read denial; 302 on
      # success.
      # `?app=` is consulted **only** when an `Origin` header is present — the
      # route dispatches here only when both are non-empty.
      private def self.serve_app_origin(
        env,
        app_param : String,
        origin : String,
        artifact_id : String,
      ) : Nil
        # The origin must be registered as an `allowed_origins` entry on some
        # app, and the owning app's id MUST equal `?app=`. This is the
        # cross-app impersonation guard: an attacker on `evil.example`
        # cannot impersonate `app_B` by passing `?app=app_B` — their origin
        # is not registered for `app_B`.
        resolved_app_id = Facet::OAuth::OriginCache.app_for_origin(origin)
        if resolved_app_id.nil? || resolved_app_id != app_param
          Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
          return
        end

        Database.with_db do |db|
          # Defense-in-depth: the origin cache filters to active apps at
          # rebuild, but the cache is invalidate-only — a race between a
          # disable event and cache rebuild could leak a stale "active". The
          # projection-row gate here keeps the disabled-app case correct
          # even under that race.
          app_row = load_app_projection(db, app_param)
          unless app_row && app_row["status"]? == "active"
            Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
            next
          end

          app_scope = Facet::RBAC::AppScope.from_content(app_param, app_row)
          unless Facet::Artifact::Access.can_read_for_app?(db, app_scope, artifact_id)
            Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
            next
          end

          respond_grant_redirect(
            env, Facet::Artifact::Grants.mint_ephemeral_for_app(
            db, app_param, app_scope, artifact_id,
          ),
          )
        end
      end

      # Renders a mint-and-respond result: the block renders the success
      # payload for a signed URL, and `Error` maps to the standard error
      # response. Returns "" (the route-block convention — the body must
      # already be on the response).
      private def self.respond_grant(
        env,
        status : Int32,
        grant : Facet::Artifact::Grants::SignedURL | Facet::Artifact::Grants::Error,
        &payload : Facet::Artifact::Grants::SignedURL -> _
      ) : String
        case grant
        in Facet::Artifact::Grants::SignedURL
          Facet::HTTP::Helpers.write_json(env, status, payload.call(grant))
        in Facet::Artifact::Grants::Error
          Facet::HTTP::Helpers.error_response(env, grant.status, grant.message)
        end
      end

      # Renders a mint result for the download gateway: redirects to the
      # signed URL on success, maps `Error` to the standard error response.
      private def self.respond_grant_redirect(env, grant : Facet::Artifact::Grants::SignedURL | Facet::Artifact::Grants::Error) : Nil
        case grant
        in Facet::Artifact::Grants::SignedURL
          issue_redirect(env, grant)
        in Facet::Artifact::Grants::Error
          Facet::HTTP::Helpers.error_response(env, grant.status, grant.message)
        end
      end

      # Writes the 302 + `Location` + `Cache-Control: no-store` for a freshly
      # minted grant. `no-store` prevents the browser from caching the
      # redirect target across requests; each click re-enters the gateway,
      # re-mints, re-302s. Shared by both gateway branches so the redirect
      # hardening stays in one place.
      private def self.issue_redirect(env, grant : Facet::Artifact::Grants::SignedURL) : Nil
        env.response.status_code = 302
        env.response.headers["Location"] = grant.url
        env.response.headers["Cache-Control"] = "no-store"
      end

      # Loads the `app.App` projection content for the named app id. Returns
      # `nil` when the row does not exist or is tombstoned (the caller is the
      # download gateway; it does not need to distinguish the two).
      private def self.load_app_projection(db : DB::Connection, app_id : String) : JSON::Any?
        row = db.query_one?(
          <<-SQL,
            SELECT content
            FROM projections
            WHERE domain = 'app' AND doc_type = 'App' AND id = $1
              AND deleted_at IS NULL
          SQL
          app_id,
          as: JSON::Any,
        )
        row
      end

      private def self.register_serve_route : Nil
        # `GET /A/:gid?exp=…&sig=…` — streams artifact bytes for a signed
        # capability URL. No auth context, no cookie, no CORS. Always
        # served from the separate artifact origin in production.
        get "/A/:gid" do |env|
          grant_id = env.params.url["gid"]
          exp_param = env.params.query["exp"]?
          sig_param = env.params.query["sig"]?

          # Strip query strings from access logs on this origin. Kemal
          # logs through the request log; the setter below clears
          # `env.request.query`, so `env.request.resource` then returns
          # the bare path for the log middleware. Defence-in-depth —
          # operators should also configure the front splitter to strip
          # the query.
          strip_query_from_log(env)

          result = Database.with_db(:read_only) do |db|
            Facet::Artifact::Grants.verify(db, grant_id, exp_param, sig_param)
          end

          case result
          in Facet::Artifact::Grants::ValidResult
            Serve.stream_artifact(env, result.artifact)
          in Facet::Artifact::Grants::InvalidResult
            env.response.status_code = 403
            env.response.content_type = "application/json"
            env.response.print({error: "Forbidden"}.to_json)
          end
        end
      end

      # Removes the query string from the request. Kemal's request log
      # prints `request.resource` after the route returns. An empty query
      # rewrites the resource to the bare path. The signature does not
      # reach the request log. Operators should also strip queries at the
      # gateway.
      private def self.strip_query_from_log(env) : Nil
        # The setter clears the query on the parsed request URI. It also
        # empties the parsed query params. `resource` then returns the
        # bare path.
        env.request.query = ""
      end
    end
  end
end
