# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "./store"
require "./staging"
require "../error"

module Facet
  module Secrets
    # Substitutes stage handles for markers inside a document, inside the
    # mutation's transaction.
    #
    # `Adoption.call` walks the document the way `ArtifactRefs` walks
    # content — restricted to `secret` leaves, which the definition layer
    # confines to top-level fields and `object` properties. For each leaf:
    #
    # - a **stage handle** resolves against `secret_staging`: the row must
    #   be unexpired, stager-bound (`created_by`), mode-matched, and
    #   field-path/domain/doctype-matched. The `secrets` slot is upserted,
    #   the staging row is deleted, and the content carries the marker
    #   `{mode, version, set_at}` — the version comes from the upsert, so
    #   no caller can predict it (the forge guard).
    # - `null` on the merged content clears the slot. The update path
    #   passes the pre-update content, so a field the patch REMOVED
    #   (merge-patch null) clears its slot too — a removed secret must
    #   not leave its value stored. On create (no previous content) an
    #   explicit null keeps null in the content with no slot.
    # - a **marker** is verified against the stored slot — the slot must
    #   exist, the `mode` must match, and the marker version must not be
    #   ahead of the slot version. A marker without a slot, or with a
    #   version ahead of the store, fails closed. This is the forge guard:
    #   an input body cannot fabricate a "set" state, because the version
    #   is only knowable from the store. Older markers stay legal —
    #   `Audit::Rollback` replays content without touching slots (locked
    #   decision 7), so a rolled-back document legitimately carries a
    #   marker older than its slot.
    # - **absent** is a no-op: the slot stays and the marker stays as
    #   merged from the projection.
    # - anything else fails closed (the type layer should have rejected it).
    #
    # Adoption never logs or carries secret material — markers and handles
    # only (invariant 9). Every failure raises `AdoptionError`, which rolls
    # back the ambient transaction; callers convert it to a `ServiceError`.
    module Adoption
      class AdoptionError < ::Exception
        getter error : Facet::ServiceError

        def initialize(@error : Facet::ServiceError)
          super(@error.message)
        end
      end

      HANDLE_RE   = /^sh_[0-9A-HJKMNP-TV-Z]{26}$/
      MARKER_KEYS = Set{"mode", "version", "set_at"}

      HANDLE_REJECTED = "Secret handle is unknown, expired, or not yours"
      MARKER_REJECTED = "Secret marker does not match the stored slot"

      # Every failure message carries the slot path in parentheses, so a
      # multi-secret document names the offending field (the portable
      # import's gate relies on this too — the message rides its 422).
      private def self.fail_with_slot(status : Int32, base : String, slot : String) : NoReturn
        fail(status, "#{base} (#{slot})")
      end

      # Walks `document`, adopts handles, verifies markers, and returns the
      # adopted document (the input unchanged when nothing needed
      # substitution).
      #
      # `txn` is the transaction-scoped connection the caller's mutation
      # runs on — slot upserts, staging deletes, and the mutation land or
      # roll back together.
      def self.call(
        txn : DB::Connection,
        defn : Doctype::DoctypeDefinition,
        document : JSON::Any,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        previous : JSON::Any? = nil,
      ) : JSON::Any
        doc_ref = "#{domain}.#{doc_type}.#{doc_id}"
        mutable = JSON.parse(document.to_json)
        root = mutable.as_h?
        return mutable if root.nil?

        changed = false
        defn.fields.each do |name, field|
          changed = walk_field(root, name, field, name, txn, doc_ref, domain, doc_type, actioner_id) || changed
        end

        # Slots for secret fields the update removed. With merge-patch
        # semantics the removed key is gone from `document`, so the walk
        # above never reaches it — compare against the pre-update content
        # and clear what vanished.
        changed = clear_removed_secret_slots(txn, defn, root, previous, doc_ref) || changed

        changed ? mutable : document
      end

      # Builds the canonical marker for a slot version. Shared with
      # `Document::Copy`, which re-mints markers when secret slots are
      # copied into a new document.
      def self.build_marker(mode : String, version : Int32) : JSON::Any
        JSON.parse({
          "mode"    => mode,
          "version" => version,
          "set_at"  => Time.utc.to_rfc3339,
        }.to_json)
      end

      # ── Private ──────────────────────────────────────────────────

      # Clears the slots of secret leaves that the update removed: a
      # top-level field present before and absent now, or a secret object
      # property present before and absent now. Confined to the same
      # leaves the adoption walk covers (top-level fields and one-level
      # object properties). Returns true when any slot was cleared.
      private def self.clear_removed_secret_slots(
        txn : DB::Connection,
        defn : Doctype::DoctypeDefinition,
        root : Hash(String, JSON::Any),
        previous : JSON::Any?,
        doc_ref : String,
      ) : Bool
        previous_h = previous.try(&.as_h?) || return false

        removed = false
        defn.fields.each do |name, field|
          next if previous_h[name]?.nil?
          type = field.type
          next if type.nil?

          case type.type_name
          when "secret"
            unless root.has_key?(name)
              Secrets.clear(txn, doc_ref, name)
              removed = true
            end
          when "object"
            removed = clear_removed_object_props(txn, field, name, root, previous_h, doc_ref) || removed
          end
        end
        removed
      end

      private def self.clear_removed_object_props(
        txn : DB::Connection,
        field : Doctype::FieldDefinition,
        name : String,
        root : Hash(String, JSON::Any),
        previous_h : Hash(String, JSON::Any),
        doc_ref : String,
      ) : Bool
        props = field.properties || return false
        previous_obj = previous_h[name]?.try(&.as_h?) || return false
        current_obj = root[name]?.try(&.as_h?)

        removed = false
        props.each do |prop, sub|
          next if sub.type.try(&.type_name) != "secret"
          next if previous_obj[prop]?.nil?
          next if current_obj && current_obj.has_key?(prop)
          Secrets.clear(txn, doc_ref, "#{name}.#{prop}")
          removed = true
        end
        removed
      end

      private def self.walk_field(
        container : Hash(String, JSON::Any),
        key : String,
        field : Doctype::FieldDefinition,
        slot : String,
        txn : DB::Connection,
        doc_ref : String,
        domain : String,
        doc_type : String,
        actioner_id : String,
      ) : Bool
        value = container[key]?
        return false if value.nil?

        type = field.type
        return false if type.nil?

        case type.type_name
        when "secret"
          adopt_leaf(container, key, value, field, slot, txn, doc_ref, domain, doc_type, actioner_id)
        when "object"
          props = field.properties
          return false if props.nil?
          nested = value.as_h?
          return false if nested.nil?

          changed = false
          props.each do |prop, sub|
            changed = walk_field(
              nested, prop, sub, "#{slot}.#{prop}",
              txn, doc_ref, domain, doc_type, actioner_id,
            ) || changed
          end
          changed
        else
          false
        end
      end

      private def self.adopt_leaf(
        container : Hash(String, JSON::Any),
        key : String,
        value : JSON::Any,
        field : Doctype::FieldDefinition,
        slot : String,
        txn : DB::Connection,
        doc_ref : String,
        domain : String,
        doc_type : String,
        actioner_id : String,
      ) : Bool
        raw = value.raw

        # Clear intent — the slot goes, the null stays in the content.
        if raw.nil?
          Secrets.clear(txn, doc_ref, slot)
          return false
        end

        if str = value.as_s?
          if str.matches?(HANDLE_RE)
            container[key] = adopt_handle(
              str, field, slot, txn, doc_ref, domain, doc_type, actioner_id,
            )
            return true
          end

          fail_with_slot(422, HANDLE_REJECTED, slot)
        end

        if obj = value.as_h?
          if obj.keys.to_set == MARKER_KEYS
            verify_marker(obj, slot, txn, doc_ref)
            return false
          end

          fail_with_slot(422, MARKER_REJECTED, slot)
        end

        fail_with_slot(422, HANDLE_REJECTED, slot)
      end

      private def self.adopt_handle(
        handle : String,
        field : Doctype::FieldDefinition,
        slot : String,
        txn : DB::Connection,
        doc_ref : String,
        domain : String,
        doc_type : String,
        actioner_id : String,
      ) : JSON::Any
        mode = field.mode
        fail_with_slot(422, HANDLE_REJECTED, slot) if mode.nil?

        row = Staging.load(txn, handle)
        fail_with_slot(422, HANDLE_REJECTED, slot) if row.nil?
        row = row.as(Staging::Row)

        fail_with_slot(422, HANDLE_REJECTED, slot) unless row.expires_at > Time.utc
        fail_with_slot(422, HANDLE_REJECTED, slot) unless row.created_by == actioner_id || actioner_id == "system"
        fail_with_slot(422, HANDLE_REJECTED, slot) unless row.mode == mode
        fail_with_slot(422, HANDLE_REJECTED, slot) unless row.field_path == slot
        fail_with_slot(422, HANDLE_REJECTED, slot) unless row.domain == domain && row.doc_type == doc_type

        payload, ttl = payload_for(row, handle, slot, doc_ref, field)

        version = Secrets.set_payload(
          txn, doc_ref, slot, payload, mode, actioner_id,
          ttl: ttl, meta_json: row.meta.to_json,
        )
        Staging.delete(txn, handle)

        marker(mode, version)
      end

      # Produces the slot payload from a staged row. `sealed` payloads are
      # opened under the staging binding and re-sealed under the final
      # `(doc_ref, slot)` binding — the AAD makes a payload valid for
      # exactly one row. `token` slots take the field's `ttl_seconds` so
      # `consume`'s same-statement TTL check can fire.
      private def self.payload_for(
        row : Staging::Row,
        handle : String,
        slot : String,
        doc_ref : String,
        field : Doctype::FieldDefinition,
      ) : {String, Time::Span?}
        case row.mode
        when "hash"
          {row.value, nil}
        when "sealed"
          plaintext = Codec.open(row.value, Staging.doc_ref(handle), slot)
          {Codec.seal(plaintext, doc_ref, slot), nil}
        when "token"
          ttl = field.ttl_seconds
          fail_with_slot(422, HANDLE_REJECTED, slot) if ttl.nil? || ttl <= 0
          {row.value, Time::Span.new(seconds: ttl)}
        else
          fail_with_slot(422, HANDLE_REJECTED, slot)
        end
      end

      private def self.verify_marker(
        marker : Hash(String, JSON::Any),
        slot : String,
        txn : DB::Connection,
        doc_ref : String,
      ) : Nil
        ref = Secrets.resolve(doc_ref)
        row = txn.query_one?(
          "SELECT mode, version FROM secrets " \
          "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4",
          ref.domain, ref.doc_type, ref.doc_id, slot,
          as: {String, Int32},
        )
        fail_with_slot(422, MARKER_REJECTED, slot) if row.nil?
        mode, version = row.as({String, Int32})

        marker_mode = marker["mode"].as_s?
        marker_version = marker["version"].as_i?
        marker_set_at = marker["set_at"].as_s?
        fail_with_slot(422, MARKER_REJECTED, slot) if marker_mode.nil? || marker_version.nil? || marker_set_at.nil?
        fail_with_slot(422, MARKER_REJECTED, slot) unless marker_mode == mode && marker_version <= version
      end

      private def self.marker(mode : String, version : Int32) : JSON::Any
        build_marker(mode, version)
      end

      private def self.fail(status : Int32, message : String) : NoReturn
        raise AdoptionError.new(Facet::ServiceError.new(status, message))
      end
    end
  end
end
