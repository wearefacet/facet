# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

require "../../doctype/doctype_definition"

module Facet
  module Domain
    module Portable
      # Strips the secret state from a document before it lands in a
      # bundle (`domain:export --omit-secrets`).
      #
      # A `secret` leaf stores sealed bytes in a `secrets` slot row and a
      # marker `{mode, version, set_at}` in the document content. A bundle
      # carries the document, not the slot: on the importing instance the
      # marker names a slot that does not exist, which the import's
      # secret-leaf gate refuses as a forged state (see
      # `doc/backend/portable-domains.md` → Secret-leaf gate on bundled
      # documents). Replacing every marker with `null` makes the bundle
      # importable; the secret state is lost and the fields import unset.
      #
      # The walk is confined to the placements a `secret` field can occupy
      # (top-level fields and one-level `object` properties) — the same
      # confinement `Secrets::Adoption` applies. A `null` leaf is left
      # alone: it already carries no state.
      module SecretStripper
        # Replaces every secret marker in `content` with `null`, in place.
        # Returns `true` when at least one leaf was stripped. A missing or
        # non-object `content` is a no-op.
        def self.strip!(defn : Doctype::DoctypeDefinition, content : JSON::Any) : Bool
          root = content.as_h?
          return false if root.nil?

          changed = false
          defn.fields.each do |name, field|
            type = field.type
            next if type.nil?

            case type.type_name
            when "secret"
              changed = strip_leaf(root, name) || changed
            when "object"
              changed = strip_object(root, name, field) || changed
            end
          end
          changed
        end

        # ── Private ──────────────────────────────────────────────────────

        private def self.strip_object(
          root : Hash(String, JSON::Any),
          name : String,
          field : Doctype::FieldDefinition,
        ) : Bool
          props = field.properties || return false
          nested = root[name]?.try(&.as_h?) || return false

          changed = false
          props.each do |prop, sub|
            next if sub.type.try(&.type_name) != "secret"
            changed = strip_leaf(nested, prop) || changed
          end
          changed
        end

        private def self.strip_leaf(container : Hash(String, JSON::Any), key : String) : Bool
          value = container[key]?
          return false if value.nil? || value.raw.nil?

          container[key] = JSON::Any.new(nil)
          true
        end
      end
    end
  end
end
