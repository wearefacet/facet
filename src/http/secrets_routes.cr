# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../config"
require "./helpers"
require "../rbac"
require "../doctype/definition_store"
require "../document/artifact_refs"
require "../secrets/store"
require "../secrets/staging"
require "../doctype/field_types/secret_type"

module Facet
  module HTTP
    # HTTP route for out-of-band secret staging.
    #
    # `POST /Api/secrets/stage` — the single entry point through which a
    # secret value reaches the server for a doctype `secret` field. The
    # value never enters a document body: the route stores a codec payload
    # in `secret_staging` and returns a single-use, TTL-bound handle that
    # the client puts into the document instead. The write pipelines
    # resolve the handle during the mutation (`Secrets::Adoption`).
    #
    # Gates, in order (fail closed, non-disclosing):
    # 1. Session principal only — the system bypass and API keys are
    #    rejected. A stage handle is a user-bound capability.
    # 2. The doctype definition must exist; the field path must resolve to
    #    a `secret` leaf. Unknown doctype, unknown field, non-secret field,
    #    and view-tag denial all answer `404` — the same non-disclosing
    #    convention as artifact access.
    # 3. The caller holds `create` **or** `update` on the target doctype
    #    (`RBAC::WriteEnforcer`, the same entry points the REST routes
    #    use). `doc_id` in the body enables the update gate for a caller
    #    staging against an existing document.
    # 4. The leaf's `view` tags must be covered by the caller's
    #    `visible_tags` (mirroring `Artifact::Access.tags_cover?`).
    # 5. For `hash`/`sealed`, the plaintext must satisfy the definition's
    #    `min`/`max`/`pattern` — the only place the plaintext is inspected.
    #    For `token`, the value must be absent: the server generates the
    #    raw token (shared no-confusable alphabet) and returns it exactly
    #    once.
    #
    # No secret material and no handle is ever logged (invariant 9).
    module SecretsRoutes
      # A dotted path of identifier segments, at any depth the definition
      # allows (a secret leaf may sit under one or more `object` fields —
      # e.g. `mail.smtp.password`). Brackets are never legal: slot paths
      # must be shift-stable.
      FIELD_PATH_RE = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/

      # The parsed stage request. `value` is `nil` when absent or JSON null.
      private record StageRequest,
        domain : String,
        doctype : String,
        field_path : String,
        doc_id : String?,
        value : JSON::Any?

      def self.register : Nil
        post "/Api/secrets/stage" do |env|
          handle_stage(env)
        end
      end

      # ── Private ───────────────────────────────────────────────────────

      private def self.handle_stage(env) : String
        return "" unless Helpers.require_csrf(env)

        # Gate 1: session principals only. The system bypass never stages
        # (it writes slots directly), and an API key cannot own a handle.
        auth = Helpers.auth_context(env)
        return Helpers.error_response(env, 403, "Forbidden") if auth.system? || auth.api_key_id

        parsed = parse_stage_body(env)
        return parsed if parsed.is_a?(String)
        request = parsed

        Database.with_db do |db|
          # Gate 2: the doctype and the secret leaf must exist. A path that
          # resolves to a non-secret leaf answers 404 too — the route only
          # acknowledges secret fields.
          resolved = resolve_secret_leaf_or_error(env, db, request.domain, request.doctype, request.field_path)
          return resolved if resolved.is_a?(String)
          leaf = resolved

          # Gate 3: create-or-update permission, mirroring the REST routes.
          unless stage_authorized?(db, auth, request)
            return Helpers.error_response(env, 403, "Forbidden")
          end

          # Gate 4: view-tag coverage, mirroring `Artifact::Access`.
          return Helpers.error_response(env, 404, "Not found") unless view_tags_cover?(auth, leaf)

          mode = leaf.mode
          return Helpers.error_response(env, 404, "Not found") if mode.nil?

          stage_value(env, db, auth, request, leaf, mode)
        end
      end

      # Parses and validates the request body. Returns the `StageRequest`,
      # or the error response body.
      private def self.parse_stage_body(env) : StageRequest | String
        body = Helpers.require_body(env)
        return Helpers.error_response(env, 422, "Request body is required") if body.nil?

        parsed = begin
          JSON.parse(body)
        rescue ex : JSON::ParseException
          return Helpers.error_response(env, 422, "Invalid JSON body: #{ex.message}")
        end

        obj = parsed.as_h?
        return Helpers.error_response(env, 422, "Request body must be a JSON object") if obj.nil?

        domain = obj["domain"]?.try(&.as_s?)
        doctype = obj["doctype"]?.try(&.as_s?)
        field_path = obj["field_path"]?.try(&.as_s?)
        return missing_fields_error(env) if domain.nil? || domain.empty?
        return missing_fields_error(env) if doctype.nil? || doctype.empty?
        return missing_fields_error(env) if field_path.nil? || field_path.empty?

        StageRequest.new(
          domain: domain,
          doctype: doctype,
          field_path: field_path,
          doc_id: obj["doc_id"]?.try(&.as_s?),
          value: obj["value"]?,
        )
      end

      private def self.missing_fields_error(env) : String
        Helpers.error_response(env, 422, "domain, doctype, and field_path are required")
      end

      # Resolves `field_path` against the definition and returns the leaf
      # when — and only when — it is a `secret` leaf. Anything else answers
      # a non-disclosing 404.
      private def self.resolve_secret_leaf_or_error(
        env,
        db : DB::Connection,
        domain : String,
        doctype : String,
        field_path : String,
      ) : Doctype::FieldDefinition | String
        defn = Doctype::DefinitionStore.fetch(db, "#{domain}.#{doctype}")
        return Helpers.error_response(env, 404, "Not found") if defn.nil?

        unless field_path.matches?(FIELD_PATH_RE)
          return Helpers.error_response(env, 404, "Not found")
        end

        leaf = Document::ArtifactRefs.resolve_field_path(defn.as(Doctype::DoctypeDefinition), field_path)
        return Helpers.error_response(env, 404, "Not found") if leaf.nil?

        leaf = leaf.as(Doctype::FieldDefinition)
        return Helpers.error_response(env, 404, "Not found") unless leaf.type.try(&.type_name) == "secret"

        leaf
      end

      # Gate 3: the caller holds `create` on the doctype, or `update` on
      # the document named by `doc_id` (the gate the PATCH route uses).
      private def self.stage_authorized?(
        db : DB::Connection,
        auth : RBAC::AuthContext,
        request : StageRequest,
      ) : Bool
        return true if RBAC::WriteEnforcer.authorize_create(db, request.domain, request.doctype, auth)

        doc_id = request.doc_id
        return false if doc_id.nil?
        RBAC::WriteEnforcer.authorize_update(db, request.domain, request.doctype, doc_id, auth)
      end

      # View-tag gate — `nil`/empty required tags mean "default"; the
      # wildcard covers everything. Mirrors `Artifact::Access.tags_cover?`.
      private def self.view_tags_cover?(
        auth : RBAC::AuthContext,
        leaf : Doctype::FieldDefinition,
      ) : Bool
        principal = auth.principal
        visible_tags = case principal
                       when RBAC::Principal::Real
                         principal.active_role.visible_tags
                       else
                         RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS
                       end

        required = leaf.tags
        required = RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS.to_a if required.nil? || required.empty?
        return true if visible_tags.includes?(RBAC::ActiveRole::WILDCARD_TAG)

        required.all? { |tag| visible_tags.includes?(tag) }
      end

      private def self.stage_value(
        env,
        db : DB::Connection,
        auth : RBAC::AuthContext,
        request : StageRequest,
        leaf : Doctype::FieldDefinition,
        mode : String,
      ) : String
        return stage_token(env, db, auth, request) if mode == "token"

        # hash / sealed: the plaintext is required and constrained here —
        # the only moment the material is inspected.
        plaintext = request.value.try(&.as_s?)
        if plaintext.nil?
          return Helpers.error_response(env, 422, "A plaintext value is required for #{mode} secrets")
        end

        errors = [] of ValidationError
        Doctype::SecretType.new.validate_plaintext(plaintext, leaf, request.field_path, errors)
        unless errors.empty?
          return Helpers.error_response(env, 422, "Secret value rejected", details: errors)
        end

        # Pre-mint the handle: the `sealed` payload binds its AAD to the
        # staging doc_ref derived from it, so the handle must exist before
        # sealing. The same handle then goes into the staging row.
        handle = "sh_" + Util::ScriptHelpers.ulid
        payload = case mode
                  when "hash"
                    Secrets::Codec.hash_payload(plaintext)
                  when "sealed"
                    # Sealed under the staging binding; adoption re-seals
                    # under the final (doc_ref, slot) binding.
                    Secrets::Codec.seal(plaintext, Secrets::Staging.doc_ref(handle), request.field_path)
                  else
                    return Helpers.error_response(env, 422, "Unknown secret mode")
                  end

        Secrets::Staging.insert(
          db, mode, payload, request.domain, request.doctype, request.field_path, auth.account_id,
          handle: handle,
        )
        Helpers.write_json(env, 201, {handle: handle})
      end

      private def self.stage_token(
        env,
        db : DB::Connection,
        auth : RBAC::AuthContext,
        request : StageRequest,
      ) : String
        # A token is server-generated — a caller-supplied value is a
        # contract violation, never input material.
        supplied = request.value
        unless supplied.nil? || supplied.raw.nil?
          return Helpers.error_response(env, 422, "Token secrets are server-generated; do not send a value")
        end

        raw = Secrets::Staging.generate_raw_token
        payload = Secrets::Codec.token_payload(raw)
        handle = Secrets::Staging.insert(
          db, "token", payload, request.domain, request.doctype, request.field_path, auth.account_id,
        )
        Helpers.write_json(env, 201, {handle: handle, token: raw})
      end
    end
  end
end
