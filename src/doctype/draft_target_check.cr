# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../error"
require "../util/projections"
require "./field_definition"
require "./doctype_definition"

module Facet
  module Doctype
    # Rejects cross-domain reference targets that point at a draft domain
    # (B-287).
    #
    # Publish is copy-and-drop (`Domain::Publish` via
    # `Domain::Copy.structure`): the draft's definitions are re-created
    # under the live domain name and the draft rows are dropped. The copy
    # rewrites only the definitions' own-domain tokens, so a cross-domain
    # target stored draft-qualified (`_b61xk3m2p9qw.Payroll`) can never
    # resolve after publish — every document value later written into the
    # field fails `reference_target_not_found`. This check keeps such
    # targets out of stored definitions: `Doctype::Create` and
    # `Doctype::Update` run it before persist and answer 422.
    #
    # Rule scope:
    # - every reference declaration: `reference` fields, `collection: true`
    #   references, and reference fields nested in `items`, `properties`,
    #   and dictionary `values`;
    # - references qualified with the definition's own domain stay legal,
    #   inside a draft domain too. A bare target is not legal anywhere —
    #   the schema gate (`ReferenceType#validate_definition`, F02-01)
    #   rejects it first — but this check still treats one as same-domain
    #   defensively, so a stray bare target can never surface as a
    #   cross-domain draft error;
    # - cross-domain references to a live domain stay legal (forward
    #   references are legitimate).
    #
    # Draft detection: the stored `draft` flag on the target domain's
    # `core.Domain` row is the authority. When no row is reachable (dropped
    # draft, never-created name), the `_`-prefixed draft-name convention
    # (`Domain::Draft.generate_name`) decides — a live domain name can
    # never start with `_` (the strict domain regex forbids it).
    module DraftTargetCheck
      # Returns one error per offending reference declaration. Empty when
      # the definition holds no draft-qualified cross-domain target.
      def self.validate(db : DB::Connection, definition : DoctypeDefinition) : Array(ValidationError)
        errors = [] of ValidationError
        definition.fields.each do |name, field|
          walk(field, name, definition.domain, db, errors)
        end
        errors
      end

      # ── Private ──────────────────────────────────────────────────────

      # Checks one field, then recurses into its sub-schema slots. The
      # error path is dot-joined (`payrolls.items`, `meta.owner`,
      # `ext.values`), matching the `ValidationError` field-path
      # convention.
      private def self.walk(
        field : FieldDefinition,
        path : String,
        own_domain : String,
        db : DB::Connection,
        errors : Array(ValidationError),
      ) : Nil
        check(field, path, own_domain, db, errors)

        if items = field.items
          walk(items, "#{path}.items", own_domain, db, errors)
        end
        if properties = field.properties
          properties.each do |name, sub_field|
            walk(sub_field, "#{path}.#{name}", own_domain, db, errors)
          end
        end
        if dictionary_value = field.dictionary_value
          walk(dictionary_value, "#{path}.values", own_domain, db, errors)
        end
      end

      private def self.check(
        field : FieldDefinition,
        path : String,
        own_domain : String,
        db : DB::Connection,
        errors : Array(ValidationError),
      ) : Nil
        return unless field.reference?

        target = field.doctype
        return if target.nil? || target.empty?

        # A bare target never reaches this check through the authoring
        # doors — the schema gate (`ReferenceType#validate_definition`)
        # rejects it first. Treating one as same-domain is defensive: a
        # dot-less string cannot name a cross-domain draft. A target
        # qualified with the definition's own domain is same-domain too.
        return unless target.includes?('.')
        target_domain = target.split('.', 2)[0]
        return if target_domain == own_domain

        return unless draft_domain?(db, target_domain)

        errors << ValidationError.new(
          field: path,
          message: "field '#{path}' references doctype '#{target}' but domain '#{target_domain}' is still a draft — publish the domain before referencing its doctypes",
          code: "schema",
          params: {"value" => target},
        )
      end

      # Reads the stored `draft` flag from the target domain's `core.Domain`
      # projection. A missing or tombstoned row falls back to the
      # `_`-prefix draft-name convention. The fallback is fail-closed in
      # the right direction: a `_`-prefixed name can never belong to a live
      # domain, so treating it as a draft only ever rejects a target that
      # can never resolve.
      private def self.draft_domain?(db : DB::Connection, domain : String) : Bool
        return Util::Projections.draft_domain?(db, domain) if Util::Projections.exists?(db, "core", "Domain", domain)
        domain.starts_with?('_')
      end
    end
  end
end
