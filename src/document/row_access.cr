# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../database"
require "../util/projections"
require "../doctype/doctype_definition"
require "../doctype/definition_store"

module Facet
  module Document
    # Row access primitives for the document store: id canonicalization,
    # row locking with the aggregate-root chain, and doctype definition
    # lookup. Emits SQL. Holds no HTTP types.
    module RowAccess
      extend self

      # ── Document id resolution ────────────────────────────────────────────

      # Resolves an `:id` path segment to the canonical `projections.id`.
      #
      # Reference values are stored fully qualified ("identity.Person.<id>")
      # and clients pass such tokens back as the `:id` segment (reference
      # capsule clicks open "/Api/{domain}/{doctype}/{token}"). The stored
      # row id is the bare opaque id for documents created through the write
      # path, and the qualified form itself for seed bundles and the
      # `core.*` meta-doctypes (the same duality
      # `Document::DisplayName::DatabaseReferenceResolver` bridges). The
      # exact id wins; otherwise the prefix-stripped id is tried. A token
      # whose row does not exist is returned unchanged, so the downstream
      # read produces its normal non-disclosing 404. Bare ids (the common
      # case) skip the lookup entirely.
      def canonical_doc_id(domain : String, doc_type : String, raw_id : String) : String
        prefix = "#{domain}.#{doc_type}."
        return raw_id unless raw_id.starts_with?(prefix)
        stripped = raw_id[prefix.size..]
        Database.with_db do |db|
          if Util::Projections.row_exists?(db, domain, doc_type, raw_id)
            raw_id
          elsif Util::Projections.row_exists?(db, domain, doc_type, stripped)
            stripped
          else
            raw_id
          end
        end
      end

      # ── Locking ───────────────────────────────────────────────────────────

      # Locks a projection row FOR UPDATE for the given document.
      # Returns `true` if the row exists (and is now locked), `false` if not found.
      def lock_projection_for_update(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : Bool
        row = db.query_one?(
          <<-SQL,
            SELECT 1 FROM projections
            WHERE domain = $1 AND doc_type = $2 AND id = $3
            FOR UPDATE
          SQL
          domain, doc_type, doc_id
        ) do |rs|
          rs.read(Int32)
        end

        !row.nil?
      end

      # Locks a projection row FOR SHARE (for aggregate root when editing a child).
      # Reports nothing: a missing row locks nothing and answers `nil`.
      # A caller that needs a missing-row answer uses
      # `lock_live_projection_for_update` (B-344, B-276).
      def lock_projection_for_share(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : Nil
        db.exec(
          "SELECT id FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 FOR SHARE",
          domain, doc_type, doc_id
        )
      end

      # Locks a projection row FOR UPDATE and reports whether it is live —
      # it exists and is not soft-deleted. Unlike `lock_projection_for_update`
      # a tombstone answers `false`, and unlike `lock_projection_for_share`
      # the zero-row result is a usable answer the caller surfaces as its
      # non-disclosing 404 (B-344). The row lock holds to the end of the
      # transaction, so a concurrent delete of the same row cannot commit
      # between the check and the caller's write.
      def lock_live_projection_for_update(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : Bool
        row = db.query_one?(
          <<-SQL,
            SELECT 1 FROM projections
            WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL
            FOR UPDATE
          SQL
          domain, doc_type, doc_id
        ) do |rs|
          rs.read(Int32)
        end

        !row.nil?
      end

      # Resolves the aggregate root for a document based on its doctype
      # definition. Returns `{domain, doc_type, doc_id, is_self?}`.
      #
      # A doctype is either an aggregate root or an owned child
      # (`member_of`). The fallback branch covers the struct-default
      # shape (`aggregate_root: false`, no `member_of`), which the
      # runtime treats as its own root — `Doctype::Check` reports it as
      # a root mislabel on authored definitions.
      def resolve_aggregate_root(
        defn : Doctype::DoctypeDefinition,
        doc_domain : String,
        doc_id : String,
      ) : {String, String, String, Bool}
        member_of = defn.member_of
        if !defn.aggregate_root && !member_of.nil?
          {doc_domain, member_of.as(String), doc_id, false}
        else
          {doc_domain, defn.doctype, doc_id, true}
        end
      end

      # Locks the aggregate root of a child document FOR SHARE.
      # Locks only the specific parent document, not any row of the same type.
      def lock_parent_for_share(
        db : DB::Connection,
        domain : String,
        defn : Doctype::DoctypeDefinition,
        parent_id : String,
      ) : Nil
        member_of = defn.member_of
        return if member_of.nil?

        lock_projection_for_share(db, domain, member_of, parent_id)
      end

      # Locks a document FOR UPDATE and its aggregate root FOR SHARE.
      # Returns `true` if the document was found and locked, `false` otherwise.
      def lock_with_chain(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : Bool
        locked = lock_projection_for_update(db, domain, doc_type, doc_id)
        return false unless locked

        doctype_id = "#{domain}.#{doc_type}"
        defn = fetch_doctype_defn(db, doctype_id)
        if defn && !defn.aggregate_root
          agg_domain, agg_type, agg_id, _ = resolve_aggregate_root(defn, domain, doc_id)
          lock_projection_for_share(db, agg_domain, agg_type, agg_id)
        end

        true
      end

      # ── Doctype definition lookup ─────────────────────────────────────────

      # Fetches a doctype definition by its qualified ID.
      # Returns `Doctype::DoctypeDefinition` on success, or `nil` when not found.
      def fetch_doctype_defn(
        db : DB::Connection,
        doctype_id : String,
      ) : Doctype::DoctypeDefinition?
        Doctype::DefinitionStore.fetch(db, doctype_id)
      end
    end
  end
end
