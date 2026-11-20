# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "./portable/archive"
require "./portable/import"

module Facet
  module Domain
    # Copies selected draft documents into the publish target.
    #
    # Publish is copy-and-drop: the draft's structure lands under the target
    # name and the draft rows are soft-deleted. Documents are scratch data by
    # default, so a publish normally carries none. A draft whose doctype holds
    # reference data — a status list, a lookup table — needs those rows on the
    # target, and this module carries them.
    #
    # ## Selection
    #
    # `Selection` names the doctypes whose documents travel with the publish.
    # `nil` doctypes means every doctype the draft defines. Names are bare
    # (`Status`) or draft-qualified (`_abc.Status`) — both resolve to the same
    # draft doctype.
    #
    # ## Fresh publish only for existing doctypes
    #
    # A fresh publish targets a free name, so every doctype is new there and
    # every selection is legal. Overwrite publish replaces a live domain: a
    # doctype the live target already defines holds production rows, and
    # merging draft documents into them would mix test data with real data.
    # Such a doctype is refused (`422`) — the caller imports documents only
    # into doctypes the target does not have yet.
    #
    # ## Ordering
    #
    # Rows are created in `sort_order` order when the doctype declares an
    # integer field of that name, then in `position` order, then in id order.
    # The first insert into a projection table fixes the physical order, and
    # every unordered list read follows it, so a status list keeps the order
    # it had in the draft.
    module PublishDocuments
      # The publish body's `documents` field.
      #
      # - `doctypes: nil` — every draft doctype.
      # - `doctypes: []` — nothing; the caller selected no doctype.
      record Selection, doctypes : Array(String)? = nil

      # Fields that order a reference list, in priority order.
      ORDER_FIELDS = ["sort_order", "position"]

      # Reads the selected draft documents into a portable bundle and applies
      # them to `target_domain` inside the caller's transaction. Returns the
      # number of rows created.
      #
      # The definitions must already live under `target_domain` — the caller
      # runs this after the structure copy, so the definition store resolves
      # every target doctype and the document gates can run.
      #
      # Raises `Portable::Import::ImportError` on a refused row; the caller's
      # transaction rolls the whole publish back.
      def self.import(
        db : DB::Connection,
        draft_domain_id : String,
        target_domain : String,
        definitions : Array(Doctype::DoctypeDefinition),
        selection : Selection,
        actioner_id : String,
      ) : Int32
        selected = resolve_selection(definitions, selection)
        return 0 if selected.empty?

        bundle = build_bundle(db, draft_domain_id, selected)
        return 0 if bundle.documents.empty?

        Portable::Import.import_documents(db, bundle, target_domain, actioner_id)
      end

      # Rejects a selection naming a doctype the draft does not define, and a
      # selection naming a doctype the live target already carries when the
      # publish overwrites it. Returns `nil` when the selection is legal.
      def self.validate(
        db : DB::Connection,
        draft_domain_id : String,
        target_domain : String,
        definitions : Array(Doctype::DoctypeDefinition),
        selection : Selection,
        target_exists : Bool,
      ) : Facet::ServiceError?
        draft_names = definitions.map(&.doctype)

        selection.doctypes.try(&.each do |name|
          next if draft_names.includes?(bare_name(name, draft_domain_id))
          return Facet::ServiceError.new(
            422,
            "Doctype '#{name}' is not defined in draft '#{draft_domain_id}' — documents can only be imported from the draft's own doctypes",
          )
        end)

        return nil unless target_exists

        resolve_selection(definitions, selection).each do |definition|
          next unless Doctype::DefinitionStore.fetch_uncached(db, "#{target_domain}.#{definition.doctype}")

          return Facet::ServiceError.new(
            422,
            "Doctype '#{target_domain}.#{definition.doctype}' already exists on the target domain — documents are imported only into new doctypes, " \
            "so draft data cannot mix with live data. Unselect it and publish again.",
          )
        end

        nil
      end

      # Post-commit `display_name` backfill for the imported rows. The
      # publish route calls it after `Event::Publisher.flush`.
      def self.backfill_display_names(
        db : DB::Connection,
        draft_domain_id : String,
        target_domain : String,
        definitions : Array(Doctype::DoctypeDefinition),
        selection : Selection,
      ) : Nil
        selected = resolve_selection(definitions, selection)
        return if selected.empty?

        Portable::Import.backfill_display_names(
          db,
          selected.map { |definition| "#{draft_domain_id}.#{definition.doctype}" },
          draft_domain_id,
          target_domain,
        )
      end

      # ── Private ────────────────────────────────────────────────────────

      # Expands the selection to the draft definitions it names, in draft
      # order. `nil` selects every definition; an empty list selects none.
      private def self.resolve_selection(
        definitions : Array(Doctype::DoctypeDefinition),
        selection : Selection,
      ) : Array(Doctype::DoctypeDefinition)
        requested = selection.doctypes
        return definitions if requested.nil?

        names = requested.map(&.split('.').last)
        definitions.select { |definition| names.includes?(definition.doctype) }
      end

      # Strips an optional draft-qualified prefix from a requested doctype
      # name. `_abc.Status` and `Status` both answer `Status`.
      private def self.bare_name(name : String, draft_domain_id : String) : String
        name.lchop("#{draft_domain_id}.")
      end

      # Builds a portable bundle carrying only the selected doctypes'
      # documents. The bundle's domain entry and definition entries are left
      # empty — the caller already copied the structure, so only the
      # `documents` map matters here.
      private def self.build_bundle(
        db : DB::Connection,
        draft_domain_id : String,
        selected : Array(Doctype::DoctypeDefinition),
      ) : Portable::Archive::Bundle
        documents = {} of String => Array(Portable::Archive::DocumentEntry)

        selected.each do |definition|
          qualified = "#{draft_domain_id}.#{definition.doctype}"
          rows = fetch_documents(db, draft_domain_id, definition)
          documents[qualified] = rows unless rows.empty?
        end

        Portable::Archive::Bundle.new(
          source_domain: draft_domain_id,
          exported_at: Time.utc.to_rfc3339,
          facet_version: "publish",
          domain: Portable::Archive::Entry.new(JSON::Any.new({} of String => JSON::Any), JSON::Any.new({} of String => JSON::Any)),
          doctypes: [] of {doctype: String, entry: Portable::Archive::Entry},
          document_views: {} of String => Array({kind: String, entry: Portable::Archive::Entry}),
          collection_views: {} of String => Array(Portable::Archive::CollectionView),
          documents: documents,
        )
      end

      # Reads every non-deleted draft row of `definition`, ordered by the
      # doctype's list-order field when it has one.
      private def self.fetch_documents(
        db : DB::Connection,
        draft_domain_id : String,
        definition : Doctype::DoctypeDefinition,
      ) : Array(Portable::Archive::DocumentEntry)
        order_field = ORDER_FIELDS.find { |name| orderable?(definition, name) }
        order_sql = order_field ? "(content->>'#{order_field}')::bigint ASC NULLS LAST, id ASC" : "id ASC"

        rows = db.query_all(
          "SELECT id, content, meta FROM projections WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL ORDER BY #{order_sql}",
          draft_domain_id, definition.doctype,
        ) do |rs|
          {rs.read(String), rs.read(JSON::Any), rs.read(JSON::Any)}
        end

        rows.map do |(id, content, meta)|
          Portable::Archive::DocumentEntry.new(id, Portable::Archive::Entry.new(content, meta))
        end
      end

      # True when the doctype declares `name` as an integer field — the only
      # type the order cast in `fetch_documents` accepts.
      private def self.orderable?(definition : Doctype::DoctypeDefinition, name : String) : Bool
        field = definition.fields[name]?
        !field.nil? && field.type.try(&.type_name) == "integer"
      end
    end
  end
end
