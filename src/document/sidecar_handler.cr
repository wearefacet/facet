# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../http/helpers"
require "../util/qualified_ref"
require "../rbac"
require "../rbac/read_enforcer"
require "../rbac/write_enforcer"
require "./create"
require "./list"
require "./row_access"

module Facet
  module Document
    # Handlers for the nested sidecar routes:
    #
    # - `POST /Api/:domain/:doctype/:id/:segment` — create a sidecar document
    #   attached to the host document.
    # - `GET /Api/:domain/:doctype/:id/:segment` — list the sidecar documents
    #   attached to the host document.
    # - `GET/PATCH/DELETE /Api/:domain/:doctype/:id/:segment/:sidecar_id` —
    #   read, update, and delete a single sidecar document.
    #
    # The `:segment` must match a key in the host doctype's `sidecars` map
    # (dispatched by `RestRoutes`). The handler populates the sidecar's
    # `target` reference from the path and rejects a `target` supplied in
    # the create body.
    #
    # Authorization is two-gated: read on the host record (non-disclosing
    # 404 on failure) PLUS the cross-domain nested grant on the host-scoped
    # path (see `WriteEnforcer.authorize_sidecar_create` /
    # `ReadEnforcer.sidecar_authorized?`). Flat grants on the sidecar
    # doctype do not participate in the nested route.
    module SidecarHandler
      # Creates a sidecar document attached to the host document.
      #
      # Runs inside the caller's transaction (`Database.with_transaction` in
      # `RestRoutes`) so the mutation and the post-commit event flush share
      # the caller's transaction.
      def self.create(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        host_id : String,
        segment : String,
        body : JSON::Any,
        auth_ctx : RBAC::AuthContext,
        cause : Mutation::Cause? = nil,
      ) : Facet::Document::Create::Result | Facet::ServiceError
        host_defn = HTTP::Helpers.fetch_doctype_defn(db, "#{host_domain}.#{host_doctype}")
        return Facet::ServiceError.new(404, "Unknown doctype: #{host_domain}.#{host_doctype}") if host_defn.nil?

        sidecar_ref = host_defn.sidecars[segment]?
        return Facet::ServiceError.new(404, "Unknown sidecar '#{segment}'") if sidecar_ref.nil?

        # Gate 1: the caller must be able to read the host record. No read
        # grant on the host doctype at all answers 403 — the class-level
        # denial the write gates give. A grant holder that cannot see the
        # host (or a missing host) answers the non-disclosing 404.
        if RBAC::ReadEnforcer.read_denied?(host_domain, host_doctype, auth_ctx)
          return Facet::ServiceError.new(403, "Forbidden")
        end
        return Facet::ServiceError.new(404, "Not found") unless RBAC::ReadEnforcer.parent_authorized?(db, host_domain, host_doctype, host_id, auth_ctx)

        # Host existence holds for every principal. Gate 1's system bypass
        # skips the row check (`ReadEnforcer.parent_authorized?` returns true
        # for any id), so a system-attributed create could otherwise land a
        # sidecar aimed at a missing or tombstoned host — a dangling row no
        # host route can reach (B-344). The FOR UPDATE lock also closes the
        # gate-to-create race: a concurrent host delete cannot commit until
        # this transaction ends.
        return Facet::ServiceError.new(404, "Not found") unless RowAccess.lock_live_projection_for_update(db, host_domain, host_doctype, host_id)

        # Gate 2: the cross-domain nested grant (`create hr.Employee.Comment`).
        # Flat grants on the sidecar doctype do not participate — the host
        # read gate above restricts to reachable host records, and prefix
        # matching lets a host `create` grant imply the nested grant.
        sidecar_domain, sidecar_doctype = split_qualified(sidecar_ref.doctype)
        return Facet::ServiceError.new(403, "Forbidden") unless RBAC::WriteEnforcer.authorize_sidecar_create(db, host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_ctx)

        # The route owns `target`. Reject it in the body with a 400 — clearer
        # than the 422 `read_only` validation error the validator would raise.
        body_hash = body.as_h?
        return Facet::ServiceError.new(422, "Request body must be a JSON object") if body_hash.nil?
        if body_hash.has_key?(sidecar_ref.column)
          return Facet::ServiceError.new(400, "The '#{sidecar_ref.column}' field is set by the route and must not be supplied in the body")
        end
        body_hash[sidecar_ref.column] = JSON::Any.new("#{host_domain}.#{host_doctype}.#{host_id}")

        # The REST route passes no cause (a root `request` mutation); the
        # agent tools carry their calling surface's cause through.
        Document::Create.call(db, sidecar_domain, sidecar_doctype, body_hash.to_json, auth_ctx, cause: cause, allow_system_writes: true, skip_authorization: true)
      end

      # Lists the sidecar documents attached to the host document.
      #
      # `page` / `items_per_page` default to the REST route's fixed first
      # page of 1000; the agent tools pass the caller's paging arguments
      # through so a host with more records than one page stays reachable.
      def self.list(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        host_id : String,
        segment : String,
        auth_ctx : RBAC::AuthContext,
        page : Int32 = 1,
        items_per_page : Int32 = 1000,
      ) : Facet::Document::List::Result | Facet::ServiceError
        host_defn = HTTP::Helpers.fetch_doctype_defn(db, "#{host_domain}.#{host_doctype}")
        return Facet::ServiceError.new(404, "Unknown doctype: #{host_domain}.#{host_doctype}") if host_defn.nil?

        sidecar_ref = host_defn.sidecars[segment]?
        return Facet::ServiceError.new(404, "Unknown sidecar '#{segment}'") if sidecar_ref.nil?

        if RBAC::ReadEnforcer.read_denied?(host_domain, host_doctype, auth_ctx)
          return Facet::ServiceError.new(403, "Forbidden")
        end
        return Facet::ServiceError.new(404, "Not found") unless RBAC::ReadEnforcer.parent_authorized?(db, host_domain, host_doctype, host_id, auth_ctx)

        # Secondary read gate: the caller must hold a nested read grant
        # (`read hr.Employee.Comment`). Prefix matching lets a host `read`
        # grant imply it. Flat grants on the sidecar doctype do not
        # participate — they serve the flat endpoint only. The grant is
        # class-level, so a denial answers 403 — the same answer the
        # sidecar write gates give. Row-level filtering still
        # happens in `Document::List` via the `target` reference filter.
        sidecar_domain, sidecar_doctype = split_qualified(sidecar_ref.doctype)
        unless RBAC::ReadEnforcer.sidecar_authorized?(db, host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_ctx)
          return Facet::ServiceError.new(403, "Forbidden")
        end

        filter = {"#{sidecar_ref.column}__eq" => JSON::Any.new("#{host_domain}.#{host_doctype}.#{host_id}")}
        # The `target` lookup is an internal integrity filter, not a user
        # query: it runs against the known host row, so it bypasses the
        # authored `filters` capability gate and the field-visibility gate,
        # and validates against the type's runtime ceiling only.
        result = Document::List.call(db, sidecar_domain, sidecar_doctype, filters: filter, auth_context: auth_ctx, page: page, items_per_page: items_per_page, skip_authorization: true, skip_filter_capability_check: true)
        # No aggregate is requested on this path, so the aggregate member of
        # `Document::List.call`'s return union never occurs. The case keeps
        # the narrow return contract and records the impossibility for the
        # compiler.
        case result
        in Facet::Document::List::Result, Facet::ServiceError
          result
        in Facet::Document::List::AggregateResult
          raise "SidecarHandler.list never requests an aggregate"
        end
      end

      # Reads a single sidecar document through the host's nested route.
      #
      # Two-gate contract as above: host read gate (non-disclosing 404) plus
      # the nested sidecar read grant (also surfaced as a non-disclosing 404,
      # matching the collection path — a 403 would leak the sidecar doctype's
      # existence). The flat route stays the admin path with its own grants.
      def self.read(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        host_id : String,
        segment : String,
        sidecar_id : String,
        auth_ctx : RBAC::AuthContext,
      ) : Facet::Document::Read::Result | Facet::ServiceError
        resolved = resolve_sidecar_ref(db, host_domain, host_doctype, segment)
        if err = resolved[1]
          return err
        end
        sidecar_ref = resolved[0].as(Doctype::SidecarRef)

        if RBAC::ReadEnforcer.read_denied?(host_domain, host_doctype, auth_ctx)
          return Facet::ServiceError.new(403, "Forbidden")
        end
        return Facet::ServiceError.new(404, "Not found") unless RBAC::ReadEnforcer.parent_authorized?(db, host_domain, host_doctype, host_id, auth_ctx)

        sidecar_domain, sidecar_doctype = split_qualified(sidecar_ref.doctype)
        unless RBAC::ReadEnforcer.sidecar_authorized?(db, host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_ctx)
          return Facet::ServiceError.new(403, "Forbidden")
        end

        return Facet::ServiceError.new(404, "Not found") unless sidecar_targets_host?(db, sidecar_domain, sidecar_doctype, sidecar_ref.column, sidecar_id, host_reference(host_domain, host_doctype, host_id))

        Document::Read.call(db, sidecar_domain, sidecar_doctype, sidecar_id, auth_ctx, skip_authorization: true)
      end

      # Updates a single sidecar document through the host's nested route.
      #
      # Host read gate (non-disclosing 404) plus the nested `update` grant on
      # the host-scoped path; a grant denial surfaces as 403 (same contract
      # as the nested create). The sidecar's `target` reference is read_only,
      # so a body that tries to re-point it fails validation with 422.
      def self.update(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        host_id : String,
        segment : String,
        sidecar_id : String,
        body : String,
        auth_ctx : RBAC::AuthContext,
      ) : Facet::Document::Update::Result | Facet::ServiceError
        resolved = resolve_sidecar_ref(db, host_domain, host_doctype, segment)
        if err = resolved[1]
          return err
        end
        sidecar_ref = resolved[0].as(Doctype::SidecarRef)

        if RBAC::ReadEnforcer.read_denied?(host_domain, host_doctype, auth_ctx)
          return Facet::ServiceError.new(403, "Forbidden")
        end
        return Facet::ServiceError.new(404, "Not found") unless RBAC::ReadEnforcer.parent_authorized?(db, host_domain, host_doctype, host_id, auth_ctx)

        sidecar_domain, sidecar_doctype = split_qualified(sidecar_ref.doctype)
        return Facet::ServiceError.new(403, "Forbidden") unless RBAC::WriteEnforcer.authorize_sidecar_update(db, host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_ctx)

        return Facet::ServiceError.new(404, "Not found") unless sidecar_targets_host?(db, sidecar_domain, sidecar_doctype, sidecar_ref.column, sidecar_id, host_reference(host_domain, host_doctype, host_id))

        Document::Update.call(db, sidecar_domain, sidecar_doctype, sidecar_id, body, auth_ctx, skip_authorization: true)
      end

      # Deletes (tombstones) a single sidecar document through the host's
      # nested route. Same two-gate contract as `update`, against the
      # `delete` action.
      def self.delete(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        host_id : String,
        segment : String,
        sidecar_id : String,
        auth_ctx : RBAC::AuthContext,
      ) : Facet::Document::Delete::Result | Facet::ServiceError
        resolved = resolve_sidecar_ref(db, host_domain, host_doctype, segment)
        if err = resolved[1]
          return err
        end
        sidecar_ref = resolved[0].as(Doctype::SidecarRef)

        if RBAC::ReadEnforcer.read_denied?(host_domain, host_doctype, auth_ctx)
          return Facet::ServiceError.new(403, "Forbidden")
        end
        return Facet::ServiceError.new(404, "Not found") unless RBAC::ReadEnforcer.parent_authorized?(db, host_domain, host_doctype, host_id, auth_ctx)

        sidecar_domain, sidecar_doctype = split_qualified(sidecar_ref.doctype)
        return Facet::ServiceError.new(403, "Forbidden") unless RBAC::WriteEnforcer.authorize_sidecar_delete(db, host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_ctx)

        return Facet::ServiceError.new(404, "Not found") unless sidecar_targets_host?(db, sidecar_domain, sidecar_doctype, sidecar_ref.column, sidecar_id, host_reference(host_domain, host_doctype, host_id))

        Document::Delete.call(db, sidecar_domain, sidecar_doctype, sidecar_id, auth_ctx, skip_authorization: true)
      end

      # Resolves the sidecar reference declared by the host doctype for the
      # per-document handlers. Returns `{ref, nil}` on success, or
      # `{nil, error}` — the error is the shape the handlers surface for an
      # unknown host or segment. The per-document paths need the reference
      # itself, because they bind the sidecar row to the host through the
      # `column` it declares. Public so `RestRoutes` resolves the sidecar
      # doctype through the same path (it swallows the error and falls
      # through to the nested-children matcher).
      def self.resolve_sidecar_ref(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        segment : String,
      ) : {Doctype::SidecarRef?, Facet::ServiceError?}
        host_defn = HTTP::Helpers.fetch_doctype_defn(db, "#{host_domain}.#{host_doctype}")
        if host_defn.nil?
          return {nil, Facet::ServiceError.new(404, "Unknown doctype: #{host_domain}.#{host_doctype}")}
        end

        sidecar_ref = host_defn.sidecars[segment]?
        if sidecar_ref.nil?
          return {nil, Facet::ServiceError.new(404, "Unknown sidecar '#{segment}'")}
        end

        {sidecar_ref, nil}
      end

      # The qualified reference token a sidecar row stores in its `target`
      # column for this host record.
      private def self.host_reference(host_domain : String, host_doctype : String, host_id : String) : String
        "#{host_domain}.#{host_doctype}.#{host_id}"
      end

      # True when the sidecar row exists and its `target` reference points
      # at this host record. The per-document nested route binds the two
      # here: the collection path binds them with a `target__eq` filter
      # (`list`), and the per-document path must bind them the same way,
      # or a caller who can read one host record reaches any sidecar by id
      # (S5). The lookup is a direct projection read — an internal
      # integrity check on one known row, so it needs no filter grammar and
      # no capability or visibility gate. It takes `FOR SHARE` when the
      # session can take a row lock, so a concurrent re-point cannot commit
      # between the check and the caller's write; a read-only session
      # (the read path) cannot lock, and needs none. A tombstone answers
      # `false` — `Document::Read/Update/Delete` own the lifecycle answer,
      # and a deleted sidecar is not reachable through its host.
      private def self.sidecar_targets_host?(
        db : DB::Connection,
        sidecar_domain : String,
        sidecar_doctype : String,
        column : String,
        sidecar_id : String,
        expected_target : String,
      ) : Bool
        lock = db.query_one("SHOW transaction_read_only", as: String) == "on" ? "" : " FOR SHARE"
        target = db.query_one?(
          "SELECT content->>$4 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL#{lock}",
          sidecar_domain, sidecar_doctype, sidecar_id, column,
          as: String?
        )
        !target.nil? && target == expected_target
      end

      # Splits a qualified doctype id on the FIRST dot only. Delegates to
      # `Util::QualifiedRef.split_doctype` — one split rule for the
      # qualified reference storage contract. Public so `RestRoutes` can
      # resolve the sidecar domain/doctype for the sidecar-collection ETag.
      def self.split_qualified(qualified : String) : {String, String}
        Util::QualifiedRef.split_doctype(qualified)
      end
    end
  end
end
