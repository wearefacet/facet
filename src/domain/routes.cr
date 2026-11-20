# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../event"
require "../http/helpers"
require "../rbac"
require "../rbac/write_enforcer"
require "../iam/jwt"
require "../iam/token_emitter"
require "./draft"
require "./publish"
require "./drop"
require "./check"
require "../doctype/definition_error"

module Facet
  module Domain
    # HTTP routes for draft domain lifecycle (draft, publish, check).
    #
    # Registered by `HTTP::Server.routes`.
    module Routes
      # Successful issuance of a preview-session token.
      record PreviewSessionResult,
        token : String,
        expires_at : Int64

      # Non-disclosing refusal for the two domain-creation doors. It names
      # the requirement and the fix — the same style as the deep-child
      # hint in the REST routes — without revealing the caller's grants.
      CREATE_REQUIRES_ELECTED_ROLE = "domain creation requires an elected role that grants create on core.Domain — " \
                                     "a domain-editor grant applies only under a role that carries the scoped domain-editor permissions"

      def self.register : Nil
        post "/Api/core/Domain/draft" do |env|
          handle_create_draft(env)
        end

        post "/Api/core/Domain/:id/draft" do |env|
          handle_draft_from(env)
        end

        get "/Api/core/Domain/:id/check" do |env|
          handle_check(env)
        end

        post "/Api/core/Domain/:id/publish" do |env|
          handle_publish(env)
        end

        post "/Api/core/Domain/:id/preview-session" do |env|
          handle_create_preview_session(env)
        end

        post "/Api/core/Domain/:id/drop" do |env|
          handle_drop(env)
        end
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.handle_create_draft(env)
        return unless HTTP::Helpers.require_csrf(env)

        body = HTTP::Helpers.parse_body(env) || "{}"
        auth_ctx = HTTP::Helpers.auth_context(env)
        result = Database.with_transaction do |db|
          unless Facet::RBAC::WriteEnforcer.authorize_create(db, "core", "Domain", auth_ctx)
            next Facet::ServiceError.new(403, CREATE_REQUIRES_ELECTED_ROLE)
          end
          Facet::Domain::Draft.create(db, body, auth_ctx.account_id)
        end
        Event::Publisher.flush
        case result
        in Facet::Domain::Draft::Result
          env.response.status_code = 201
          {data: result.projection.content, meta: HTTP::Helpers.document_meta(result.projection, mutation_id: result.mutation_id)}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      private def self.handle_draft_from(env)
        return unless HTTP::Helpers.require_csrf(env)

        auth_ctx = HTTP::Helpers.auth_context(env)
        source_id = env.params.url["id"]

        result = Database.with_transaction do |db|
          unless Facet::RBAC::WriteEnforcer.authorize_create(db, "core", "Domain", auth_ctx)
            next Facet::ServiceError.new(403, CREATE_REQUIRES_ELECTED_ROLE)
          end
          # The service gate (B-240) also requires a scoped `create
          # core.Domain` caller to edit the source domain.
          Facet::Domain::Draft.create_from(db, source_id, auth_ctx.account_id, auth_ctx)
        end
        Event::Publisher.flush
        case result
        in Facet::Domain::Draft::Result
          env.response.status_code = 201
          {data: result.projection.content, meta: HTTP::Helpers.document_meta(result.projection, mutation_id: result.mutation_id)}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      private def self.handle_check(env)
        auth_ctx = HTTP::Helpers.auth_context(env)
        domain_id = env.params.url["id"]

        result = Database.with_db(:read_only) do |db|
          unless Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "Domain", domain_id, auth_ctx)
            next Facet::ServiceError.new(403, "Forbidden")
          end
          Facet::Domain::Check.call(db, domain_id)
        end

        case result
        in Facet::Domain::Check::Result
          env.response.status_code = 200
          serialize_issue = ->(issue : Facet::Domain::Check::Issue) do
            h = {
              "severity" => issue.severity.to_s,
              "category" => issue.category.to_s,
              "message"  => issue.message,
            }
            if f = issue.field
              h["field"] = f
            end
            h
          end

          domain_issues_json = result.domain_issues.map { |issue| serialize_issue.call(issue) }
          doctypes_json = result.doctypes.map do |dt|
            {
              doctype_id:  dt.doctype_id,
              issue_count: dt.issues.size,
              issues:      dt.issues.map { |issue| serialize_issue.call(issue) },
              notices:     dt.notices.map { |notice| serialize_issue.call(notice) },
            }
          end
          total = result.domain_issues.size + result.doctypes.sum(&.issues.size)
          {data: {domain: result.domain, issue_count: total, domain_issues: domain_issues_json, doctypes: doctypes_json}}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      # Post-commit `display_name` backfill for the rows a publish imported:
      # a reference-token template may have resolved against a doctype that
      # only landed later in the same batch. Reads the landed target
      # definitions, not the draft's — the draft is gone at this point.
      private def self.backfill_published_documents(
        draft_id : String,
        target_name : String,
        documents : Facet::Domain::PublishDocuments::Selection?,
        publish_result : Facet::Domain::Publish::Result | Facet::ServiceError,
      ) : Nil
        return if documents.nil?
        return unless publish_result.is_a?(Facet::Domain::Publish::Result)
        return if publish_result.documents_imported.zero?

        Database.with_db do |db|
          definitions = Facet::Domain::Copy.fetch_source_doctype_definitions(db, target_name)
          Facet::Domain::Publish.backfill_imported_documents(db, draft_id, target_name, definitions, documents)
        end
      end

      private def self.handle_publish(env)
        return unless HTTP::Helpers.require_csrf(env)

        body = HTTP::Helpers.parse_body(env) || "{}"
        auth_ctx = HTTP::Helpers.auth_context(env)
        draft_id = env.params.url["id"]

        parsed = begin
          JSON.parse(body)
        rescue
          return HTTP::Helpers.error_response(env, 422, "Invalid JSON body")
        end

        # Body-shape gate (B-59): the key reads below index the parsed body
        # as an object; a non-object body would surface as a 500.
        unless parsed.as_h?
          return HTTP::Helpers.error_response(
            env, 422,
            "Body must be a JSON object (got #{Facet::Doctype::StrictKeys.json_kind(parsed)})"
          )
        end

        target_name = parsed["target_name"]?.try(&.as_s?)
        if target_name.nil? || target_name.empty?
          return HTTP::Helpers.error_response(env, 422, "Body must include 'target_name' field")
        end

        overwrite = parsed["overwrite"]?.try(&.as_bool) || false

        documents, documents_error = Facet::Domain::Publish.parse_documents_field(parsed["documents"]?)
        return HTTP::Helpers.error_response(env, 422, documents_error.message) if documents_error

        publish_result = Database.with_transaction do |db|
          unless Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "Domain", draft_id, auth_ctx)
            next Facet::ServiceError.new(403, "Forbidden")
          end
          Facet::Domain::Publish.call(
            db, draft_id, target_name,
            actioner_id: auth_ctx.account_id, overwrite: overwrite, auth_context: auth_ctx,
            documents: documents,
          )
        end

        Event::Publisher.flush

        backfill_published_documents(draft_id, target_name, documents, publish_result)

        case publish_result
        in Facet::Domain::Publish::Result
          env.response.status_code = 200
          {data: {
            domain:             publish_result.target_domain,
            draft:              false,
            warnings:           publish_result.warnings,
            documents_imported: publish_result.documents_imported,
            grant_tickets:      publish_result.grant_tickets.map do |ticket|
              {
                producer: ticket.producer,
                filed:    ticket.filed,
                active:   ticket.active,
                dropped:  ticket.dropped,
                edges:    ticket.edges.map { |edge| {doctype: edge.doctype, tags: edge.tags} },
              }
            end,
          }}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, publish_result.status, publish_result.message)
        end
      end

      # Deletes a domain (draft or live). Gated by the `delete` permission on
      # `core.Domain` — the same permission the generic document route would
      # check — because a drop is a delete of the domain document plus its
      # owned surface. `Domain::Drop` owns the policy guards (system domains,
      # live-source drafts) and the audit record.
      private def self.handle_drop(env)
        return unless HTTP::Helpers.require_csrf(env)

        auth_ctx = HTTP::Helpers.auth_context(env)
        domain_id = env.params.url["id"]

        result = Database.with_transaction do |db|
          unless Facet::RBAC::WriteEnforcer.authorize_delete(db, "core", "Domain", domain_id, auth_ctx)
            next Facet::ServiceError.new(403, "Forbidden")
          end
          Facet::Domain::Drop.call(db, domain_id, auth_ctx.account_id)
        end

        Event::Publisher.flush
        case result
        in Facet::Domain::Drop::Result
          env.response.status_code = 200
          env.response.content_type = "application/json"
          {data: {domain: result.domain, deleted: true}}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      # Issues a preview-mode capability token scoped to a draft domain. The
      # caller proves, against their real identity, that they may edit the
      # draft's definition — gated by `update core.Domain` on the draft row,
      # the same row-level gate the domain PATCH and publish routes run. A
      # scoped grant (the editor role's `$domain_editor`) bites here, so a
      # token only reaches callers who may edit that draft's definition; on
      # success they receive a short-lived `typ: "preview"` JWT naming
      # `preview_domain`.
      #
      # The token bypasses the role/permission system entirely: authorization
      # is reduced to one rule (the target domain equals `preview_domain`),
      # enforced by `RBAC::PreviewEnforcer`. The draft must still be
      # `draft = true` at issuance — previewing a published domain has no
      # meaning (the user can interact with it directly under their real
      # role).
      private def self.handle_create_preview_session(env)
        return unless HTTP::Helpers.require_csrf(env)

        auth_ctx = HTTP::Helpers.auth_context(env)
        draft_id = env.params.url["id"]

        # A preview token must be attributed to a real account — system bypass
        # and denied principals cannot produce a capability token (there is
        # no real account to attribute the mutation audit log to). Role-based
        # checks like `editor` can edit draft doctypes; `system` is only
        # ever reached from internal callers (migrations, specs with
        # AuthHandler disabled), for which preview is meaningless.
        if auth_ctx.system? || auth_ctx.preview? ||
           (auth_ctx.principal.is_a?(Facet::RBAC::Principal::Real) &&
           auth_ctx.principal.as(Facet::RBAC::Principal::Real).active_role.role_id == "denied")
          return HTTP::Helpers.error_response(env, 403, "Forbidden")
        end

        result = Database.with_db(:read_only) do |db|
          # Gate on `update core.Domain` for the draft itself. A capability
          # token must only reach callers who may edit the draft's
          # definition — not merely any editor of the `core` domain.
          unless Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "Domain", draft_id, auth_ctx)
            next Facet::ServiceError.new(403, "Forbidden")
          end

          # Load the draft domain projection; reject unless `draft = true`.
          row = db.query_one?(
            "SELECT content FROM projections " \
            "WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 " \
            "AND deleted_at IS NULL",
            draft_id,
            as: JSON::Any,
          )
          next Facet::ServiceError.new(404, "Draft domain '#{draft_id}' not found") unless row

          content_h = row.as_h?
          next Facet::ServiceError.new(422, "Draft domain '#{draft_id}' has invalid content") unless content_h

          unless content_h["draft"]?.try(&.raw) == true
            next Facet::ServiceError.new(422, "Domain '#{draft_id}' is not a draft — preview is for drafts only")
          end

          # Issue the token. `role` is the caller's current active role name
          # (carried for OpenTelemetry attribution only — the preview
          # principal does not consult it). `sid` is a fresh opaque id, NOT
          # a RedisSession id.
          real = auth_ctx.principal.as(Facet::RBAC::Principal::Real)
          role_name = real.active_role.role_id
          sid = Random::Secure.urlsafe_base64(24)
          payload, exp = Facet::IAM::JWT.build_preview_payload(
            account_id: auth_ctx.account_id,
            sid: sid,
            role: role_name,
            preview_domain: draft_id,
          )
          token = Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)

          PreviewSessionResult.new(token: token, expires_at: exp)
        end

        case result
        in PreviewSessionResult
          env.response.status_code = 201
          {data: {token: result.token, preview_domain: draft_id, expires_at: result.expires_at}}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end
    end
  end
end
