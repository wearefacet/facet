# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../mutation/client"
require "../doctype/definition_store"
require "../doctype/doctype_definition"
require "../error"
require "../event"
require "../secrets/store"
require "../secrets/adoption"
require "./links"
require "./search"
require "../artifact/owners"

module Facet
  module Document
    # Generic recursive document-copy primitive.
    #
    # Copies a single document and **all its owned children** (depth-first)
    # from a source domain into a target domain. Each copied document gets a
    # fresh ULID doc_id; `meta.parent_id` is remapped through the recursion so
    # nested children link to their new parent. Content is copied verbatim
    # except for fields the caller rewrites via the `content_transformer`
    # callback.
    #
    # The child traversal mirrors `Document::Delete#cascade_delete_children`:
    # only `children:` entries whose target doctype declares
    # `member_of == parent_doctype` are walked (true ownership, not routing
    # associates).
    #
    # Used by `Domain::Copy.structure` to copy a doctype's child documents
    # (`core.DocumentView`, etc.) when drafting from or publishing a domain.
    #
    # ## Identity handling
    #
    # - `doc_id` — always regenerated as a fresh ULID.
    # - `meta.parent_id` — remapped to the new parent's doc_id via
    #   `new_parent_id` (passed by the caller for the top-level copy, and by
    #   the recursion for each nested child). Without `new_parent_id` the key
    #   is dropped — the copy becomes a root. A copy must never inherit the
    #   source's parent linkage: the source parent is not the copy's parent,
    #   and a stale id would link the copy to a document that did not create
    #   it (polluting that parent's aggregate feed).
    # - Reference fields (`type: reference`) — copied verbatim. A draft may
    #   reference live-domain documents; the reference targets are not copied
    #   (cross-domain references, not owned children).
    # - Unique fields (`unique: true`) — copied verbatim. The target draft
    #   domain is empty, so per-domain unique constraints cannot conflict. A
    #   future same-domain copy would need explicit unique-value handling.
    #
    # ## Atomicity
    #
    # Runs entirely within the caller's transaction — no inner transaction is
    # opened. A crash before commit leaves the source intact and the target
    # partially created; the operation is retryable (target rows are either
    # absent or fully committed).
    module Copy
      # A content transformer rewrites fields in the copied document's content.
      # Receives the source content, the source doc_id, and the new doc_id;
      # returns the rewritten content.
      alias ContentTransformer = JSON::Any, String, String -> JSON::Any

      # Internal exception used to abort a copy when an owner-row append
      # fails (e.g. the actor cannot read an artifact). Raised inside the
      # transaction so it rolls back, then caught and converted to the
      # `ServiceError` return value.
      private class CopyAborted < ::Exception
        getter error : Facet::ServiceError

        def initialize(@error : Facet::ServiceError)
          super(@error.message)
        end
      end

      # Copies `doc_id` (and recursively all owned children) from
      # `from_domain` into `to_domain`, returning the new top-level doc_id.
      #
      # `new_parent_id` is the `meta.parent_id` to stamp on the top-level
      # copy. When `nil`, the copy's `meta.parent_id` is dropped — the copy
      # becomes a root; the source's linkage is never inherited. The
      # recursion always passes the freshly-created parent's doc_id so
      # children link correctly.
      #
      # `content_transformer` is an optional callback that rewrites content
      # fields on each copied document (e.g. remapping `parent_doctype` from
      # the source domain's qualified id to the target's).
      def self.deep_copy(
        db : DB::Connection,
        from_domain : String,
        to_domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        *,
        new_parent_id : String? = nil,
        content_transformer : ContentTransformer? = nil,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
      ) : String | Facet::ServiceError
        source = Mutation::Client.fetch_projection(db, from_domain, doc_type, doc_id)

        new_doc_id = Util::ScriptHelpers.ulid

        content = source.content
        content = content_transformer.call(content, doc_id, new_doc_id) unless content_transformer.nil?

        # Build meta: preserve everything from the source except parent_id.
        # With `new_parent_id` the copy is stamped into its new parent;
        # without one the key is dropped — the copy becomes a root. The
        # source's linkage is never inherited (a stale id would pollute the
        # source parent's aggregate feed).
        meta_h = source.meta.as_h? || {} of String => JSON::Any
        meta_h = meta_h.dup
        if new_parent_id
          meta_h["parent_id"] = JSON::Any.new(new_parent_id)
        else
          meta_h.delete("parent_id")
        end
        meta_json = JSON::Any.new(meta_h).to_json

        # Resolve the doctype definition in the target domain so the links and
        # search GUCs are set correctly for the projection trigger.
        target_defn = Doctype::DefinitionStore.fetch(db, "#{to_domain}.#{doc_type}")

        begin
          # A savepoint (not `ignore_if_set: true`) so that when the owner
          # append fails, the partial copy — the target document mutation —
          # rolls back to the savepoint even when this runs inside a caller's
          # transaction (e.g. `Domain::Copy.structure`). The caller sees the
          # `ServiceError` and no half-copied document persists.
          Database.with_transaction(db) do |txn|
            if target_defn
              # Secret slots travel with the copy: hash payloads copy as-is,
              # sealed payloads re-seal under the target binding, token
              # markers are stripped (a token must not serve two documents).
              # The content that lands carries fresh markers — the source
              # versions mean nothing to the copy. Runs inside the
              # transaction so a failure aborts the whole copy.
              content = copy_secret_slots(
                txn, content, target_defn,
                "#{from_domain}.#{doc_type}.#{doc_id}",
                "#{to_domain}.#{doc_type}.#{new_doc_id}",
              )
              Document::ProjectionGucs.set_all(txn, target_defn, content)
            else
              # No definition (e.g. core.Domain fallback) — stage empty GUCs.
              Document::ProjectionGucs.clear_all(txn)
            end

            mut_id = Mutation::Client.create(
              txn,
              to_domain,
              doc_type,
              doc_id: new_doc_id,
              content: content.to_json,
              meta: meta_json,
              actioner_id: actioner_id,
            )

            # Append an owner row for every artifact the copied content
            # references, against the target document. The actor must be able
            # to read each artifact (system bypasses); a non-readable artifact
            # fails loud so the copy does not silently grant provenance over
            # bytes the actor cannot see.
            if target_defn
              append_result = Artifact::Owners.append_for_document(
                txn, auth_context, content, target_defn, to_domain, doc_type, new_doc_id, actioner_id,
              )
              raise CopyAborted.new(append_result) if append_result.is_a?(Facet::ServiceError)
            end

            Event::Publisher.enqueue(
              domain: to_domain, doc_type: doc_type, doc_id: new_doc_id,
              event: "created", mutation_id: mut_id, actioner_id: actioner_id,
            )
          end
        rescue e : CopyAborted
          return e.error
        end

        # Recurse into owned children (depth-first).
        child_result = copy_children_of(
          db, from_domain, to_domain, doc_type, doc_id, new_doc_id,
          actioner_id, content_transformer, auth_context,
        )
        return child_result if child_result.is_a?(Facet::ServiceError)

        new_doc_id
      end

      # ── Secret slot copying ──────────────────────────────────────

      # Walks `content` for secret leaves (top-level fields + object
      # properties — the placements the definition layer allows). A leaf
      # carrying a marker must have a matching source slot (mode +
      # version) — the same forge guard as adoption; a token marker is
      # stripped instead of copied. Every copied hash/sealed slot gets a
      # fresh marker built from the copy's own version.
      private def self.copy_secret_slots(
        txn : DB::Connection,
        content : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        from_ref : String,
        to_ref : String,
      ) : JSON::Any
        mutable = JSON.parse(content.to_json)
        root = mutable.as_h?
        return mutable if root.nil?

        changed = false
        defn.fields.each do |name, field|
          changed = copy_walk(root, name, field, name, txn, from_ref, to_ref) || changed
        end

        changed ? mutable : content
      end

      private def self.copy_walk(
        container : Hash(String, JSON::Any),
        key : String,
        field : Doctype::FieldDefinition,
        slot : String,
        txn : DB::Connection,
        from_ref : String,
        to_ref : String,
      ) : Bool
        value = container[key]?
        return false if value.nil?

        type = field.type
        return false if type.nil?

        case type.type_name
        when "secret"
          copy_leaf(container, key, value, field, slot, txn, from_ref, to_ref)
        when "object"
          props = field.properties
          return false if props.nil?
          nested = value.as_h?
          return false if nested.nil?

          changed = false
          props.each do |prop, sub|
            changed = copy_walk(nested, prop, sub, "#{slot}.#{prop}", txn, from_ref, to_ref) || changed
          end
          changed
        else
          false
        end
      end

      private def self.copy_leaf(
        container : Hash(String, JSON::Any),
        key : String,
        value : JSON::Any,
        field : Doctype::FieldDefinition,
        slot : String,
        txn : DB::Connection,
        from_ref : String,
        to_ref : String,
      ) : Bool
        obj = value.as_h?
        return false if obj.nil?
        return false unless obj.keys.to_set == Secrets::Adoption::MARKER_KEYS

        mode = field.mode
        return false if mode.nil?

        from = Secrets.resolve(from_ref)
        to = Secrets.resolve(to_ref)

        # Forge guard — the marker must match the source slot exactly.
        src = txn.query_one?("SELECT mode, version FROM secrets " \
                             "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4",
          from.domain, from.doc_type, from.doc_id, slot,
          as: {String, Int32})
        abort_copy(422, Secrets::Adoption::MARKER_REJECTED) if src.nil?
        src_mode, src_version = src.as({String, Int32})
        abort_copy(422, Secrets::Adoption::MARKER_REJECTED) unless src_mode == mode &&
                                                                   obj["version"].as_i? == src_version

        if mode == "token"
          container.delete(key)
          return true
        end

        begin
          Secrets.copy_slot(txn, from_ref, to_ref, slot)
        rescue ex : ArgumentError
          abort_copy(422, ex.message || "Secret slot copy failed")
        end

        dst = txn.query_one?("SELECT version FROM secrets " \
                             "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4",
          to.domain, to.doc_type, to.doc_id, slot,
          as: Int32)
        abort_copy(500, "Secret slot copy did not land") if dst.nil?

        container[key] = Secrets::Adoption.build_marker(mode, dst.as(Int32))
        true
      end

      private def self.abort_copy(status : Int32, message : String) : NoReturn
        raise CopyAborted.new(Facet::ServiceError.new(status, message))
      end

      # Copies only the owned children of `source_doc_id` into the target
      # domain, stamping `new_parent_id` as each child's `meta.parent_id`.
      #
      # Used when the parent document itself was already created by a
      # specialised path (e.g. `Domain::Copy.upsert_doctype_definition` uses a
      # deterministic `{domain}.{doctype}` identity rather than a ULID) and
      # only the nested children need to flow through the generic recursive
      # copy.
      def self.copy_children_of(
        db : DB::Connection,
        from_domain : String,
        to_domain : String,
        parent_doctype : String,
        source_parent_id : String,
        new_parent_id : String,
        actioner_id : String,
        content_transformer : ContentTransformer? = nil,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
      ) : Facet::ServiceError?
        parent_defn = Doctype::DefinitionStore.fetch(db, "#{from_domain}.#{parent_doctype}")
        return unless parent_defn

        copy_owned_children(
          db, from_domain, to_domain, parent_defn, source_parent_id, new_parent_id,
          actioner_id, content_transformer, auth_context,
        )
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Walks `parent_defn.children`, finds each owned child doctype
      # (`member_of == parent_doctype`), queries all live children of the
      # source parent, and recurses `deep_copy` for each.
      private def self.copy_owned_children(
        db : DB::Connection,
        from_domain : String,
        to_domain : String,
        parent_defn : Doctype::DoctypeDefinition,
        source_parent_id : String,
        new_parent_id : String,
        actioner_id : String,
        content_transformer : ContentTransformer?,
        auth_context : RBAC::AuthContext,
      ) : Facet::ServiceError?
        return if parent_defn.children.empty?

        parent_doctype = parent_defn.doctype

        parent_defn.children.each_value do |child_def|
          child_doctype = child_def.doctype
          child_defn = Doctype::DefinitionStore.fetch(db, "#{from_domain}.#{child_doctype}")
          next unless child_defn && child_defn.member_of == parent_doctype

          child_ids = Mutation::Client.owned_child_ids(db, from_domain, child_doctype, source_parent_id, order_by_id: true)

          child_ids.each do |child_id|
            child_result = deep_copy(
              db, from_domain, to_domain, child_doctype, child_id, actioner_id,
              new_parent_id: new_parent_id,
              content_transformer: content_transformer,
              auth_context: auth_context,
            )
            return child_result if child_result.is_a?(Facet::ServiceError)
          end
        end

        nil
      end
    end
  end
end
