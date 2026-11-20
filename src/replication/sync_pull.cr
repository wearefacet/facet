# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "pg"
require "../doctype/doctype_definition"
require "../grants"
require "../mutation/client"
require "./binding"

module Facet
  module Replication
    # Write-time hook that pulls the initial value of a replicated field
    # from its source document into the consumer's content.
    #
    # Invoked from `Document::Create.create_from_parsed` (for all replicate
    # fields whose `via` value is non-null) and from `Document::Update.call`
    # (only for replicate fields whose `via` field changed). The pulled
    # values become part of the same mutation that's being persisted — no
    # extra event is emitted, no async round-trip is needed.
    #
    # This is the **only** path that produces the initial value of a
    # replica field. The async handler (step 5) propagates *later* source
    # changes; it does not back-fill the initial value.
    #
    # ## Source-not-found
    #
    # If the source projection does not exist or is deleted, the replica
    # field is left `null` and the miss is logged. The consumer is still
    # created/updated — a missing source is a soft failure, not a hard one.
    #
    # ## Grant gate
    #
    # Before pulling an initial value across domains, the pull re-checks
    # `Grants::Registry.covers?` against the source field's tags (untagged
    # → `["default"]`). No coverage → the replica stays `null` and the
    # miss is logged. Same-domain pulls skip the gate (D7). This closes
    # the hole where a binding built while a grant was active kept pulling
    # after deactivation, or a `via` change re-pulled a field no grant
    # covers.
    module SyncPull
      Log = ::Log.for("facet.replication.sync_pull")

      # Pulls replica values into `content` for every replicate field on
      # `definition` whose `via` field is present in `changed_via_fields`
      # (or, when `changed_via_fields` is `nil`, for *all* replicate fields
      # with a non-null `via` value — the create path).
      #
      # Mutates and returns the `content` hash. Idempotent: existing replica
      # values are overwritten only if the source value differs.
      def self.call(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        content : JSON::Any,
        changed_via_fields : Set(String)? = nil,
      ) : JSON::Any
        # Collect (replica_field, via_field, source_field) tuples that need a pull.
        pulls = collect_pulls(definition, changed_via_fields)
        return content if pulls.empty?

        content_h = content.as_h?.dup || {} of String => JSON::Any
        changed = false

        pulls.each do |target|
          via_value = content_h[target.via_field]?
          next if via_value.nil? || via_value.raw.nil?

          source_id = via_value.as_s?
          next if source_id.nil? || source_id.empty?

          new_value = fetch_source_field(db, definition, target.via_field, source_id, target.source_field)
          if new_value.nil?
            # Source not found / deleted → leave replica as-is (no change).
            next
          end

          if content_h[target.replica_field]? != new_value
            content_h[target.replica_field] = new_value
            changed = true
          end
        end

        return content unless changed
        JSON::Any.new(content_h)
      end

      # ── Private ──────────────────────────────────────────────────────

      private struct PullTarget
        getter replica_field : String
        getter via_field : String
        getter source_field : String

        def initialize(@replica_field, @via_field, @source_field)
        end
      end

      # Collects the (replica_field, via_field, source_field) tuples to pull.
      # When `changed_via_fields` is `nil`, every replicate field is included
      # (create path). Otherwise only those whose `via` is in the set.
      private def self.collect_pulls(
        definition : Doctype::DoctypeDefinition,
        changed_via_fields : Set(String)?,
      ) : Array(PullTarget)
        targets = [] of PullTarget

        definition.fields.each do |field_name, field_def|
          rep_config = field_def.replicate
          next if rep_config.nil?

          via = rep_config.via
          if changed_via_fields && !changed_via_fields.includes?(via)
            next
          end

          targets << PullTarget.new(field_name, via, rep_config.field)
        end

        targets
      end

      # Fetches a single scalar field from a source projection, identified by
      # resolving the reference field's target doctype on the consumer definition.
      # Returns the field value as `JSON::Any`, or `nil` if the source is
      # missing/deleted or the field is absent.
      private def self.fetch_source_field(
        db : DB::Connection,
        consumer_definition : Doctype::DoctypeDefinition,
        via_field : String,
        source_id : String,
        source_field : String,
      ) : JSON::Any?
        ref_field_def = consumer_definition.fields[via_field]?
        return nil if ref_field_def.nil?

        source_qualified = ref_field_def.qualified_doctype
        return nil if source_qualified.nil?

        source_domain, source_doctype = parse_qualified(source_qualified)
        return nil if source_domain.nil? || source_doctype.nil?

        # Declaration + secret gates — see `resolve_source_field`. A field
        # removed from the source definition must not be copied from a
        # stale stored value into new replica rows, and a secret source
        # field is never copied (B-164). Both apply to same-domain edges
        # too, not only the cross-domain grant path below.
        source_field_def = resolve_source_field(db, source_qualified, source_field)
        return nil if source_field_def.nil?

        # Grant gate (G2) — fail closed for cross-domain pulls. Same-domain
        # edges need no grant (D7). No coverage → replica stays null, miss
        # logged.
        if source_domain != consumer_definition.domain
          field_tags = source_field_def.tags || [Grants::DEFAULT_TAG]
          unless Grants::Registry.covers?(db, consumer_definition.domain, source_domain, source_doctype, field_tags)
            Log.warn do
              "SyncPull: no active grant from '#{source_domain}' to '#{consumer_definition.domain}' " \
              "covering '#{source_qualified}.#{source_field}' (tags: #{field_tags.join(", ")}) — replica stays null"
            end
            return nil
          end
        end

        # The `via` field value is stored as a fully qualified reference
        # (`{domain}.{Doctype}.{opaque}`); the `projections.id` column holds
        # only the opaque id, so strip the prefix before the lookup.
        opaque_id = strip_qualified_prefix(source_id, source_qualified)

        content = begin
          Mutation::Client.fetch_content(db, source_domain, source_doctype, opaque_id)
        rescue DB::NoResultsError | PG::Error
          Log.debug { "SyncPull source not found: #{source_qualified}.#{opaque_id}" }
          nil
        end

        return nil if content.nil?

        value = content.as_h?.try(&.[source_field]?)
        if value.nil?
          Log.debug { "SyncPull source field '#{source_field}' absent on #{source_qualified}.#{opaque_id}" }
        end
        value
      end

      # Resolves the source field definition and re-asserts the two copy
      # gates:
      #
      # - **Declaration gate** — the source field must still be declared on
      #   the source doctype. A field removed from the source definition
      #   must not be copied from a stale stored value into new replica
      #   rows.
      # - **Secret gate** — a secret source field is never copied into a
      #   replica (B-164). The authoring-time invariant refuses new
      #   declarations, but a consumer registered before the source field
      #   existed would start pulling the secret's marker object the
      #   moment the producer lands.
      #
      # Both gates apply to same-domain edges too, not only the
      # cross-domain grant path. Returns nil when either gate refuses; the
      # caller leaves the replica null.
      private def self.resolve_source_field(
        db : DB::Connection,
        source_qualified : String,
        source_field : String,
      ) : Doctype::FieldDefinition?
        source_defn = Doctype::DefinitionStore.fetch(db, source_qualified)
        source_field_def = source_defn.try(&.fields[source_field]?)
        if source_field_def.nil?
          Log.debug { "SyncPull source field '#{source_field}' not declared on #{source_qualified} — leaving replica null" }
          return nil
        end

        if source_field_def.type.try(&.type_name) == "secret"
          Log.warn do
            "SyncPull: source field '#{source_qualified}.#{source_field}' is a secret — replica stays null"
          end
          return nil
        end

        source_field_def
      end

      # Strips the `{domain}.{Doctype}.` prefix from a stored reference
      # value to extract the opaque `projections.id`. Returns the value
      # unchanged when it is already a bare id (defensive fallback for
      # rows written before the qualified-storage contract).
      private def self.strip_qualified_prefix(value : String, qualified : String) : String
        prefix = "#{qualified}."
        return value[prefix.size..] if value.starts_with?(prefix)
        value
      end

      # Splits "domain.Doctype" into {domain, doctype}. Returns {nil, nil}
      # on malformed input.
      private def self.parse_qualified(qualified : String) : {String?, String?}
        parts = qualified.split('.', 2)
        if parts.size == 2
          {parts[0], parts[1]}
        else
          {nil, nil}
        end
      end
    end
  end
end
