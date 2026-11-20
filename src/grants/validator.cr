# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../validation_error"

module Facet
  module Grants
    # Authoring-time validator for `core.DomainGrant` documents.
    #
    # Attaches to grant create/update (via `Document::Update`'s
    # `validate_rbac_definitions?` dispatch and `Document::Create`'s
    # equivalent gate) and runs on demand from the `/check` report. The
    # typed field schema already covers shape (required reference,
    # array-of-objects, non-empty strings via `required: true`); this
    # validator adds the rules the schema cannot express:
    #
    # 1. The grant's `consumer_domain` must differ from the parent domain —
    #    a self-grant is invalid (same-domain edges need no grant, D7).
    # 2. Resource entry `doctype` values are valid CamelCase names.
    # 3. Resource entry `tags` carry no empty strings.
    #
    # There is deliberately no closed tag vocabulary: producers invent
    # their own labels (D10). A diagnostic flags grant tags that no
    # producer field carries — the `/check` report, not this validator.
    module Validator
      record ResourceEntry,
        doctype : String,
        tags : Array(String)

      # Parses the `resources` array of a grant document. Returns the
      # parsed entries, or nil when the array is absent/malformed beyond
      # what the typed schema allows (the schema gate owns those errors).
      def self.parse_resources(raw : JSON::Any?) : Array(ResourceEntry)?
        arr = raw.try(&.as_a?)
        return nil if arr.nil?

        entries = [] of ResourceEntry
        arr.each do |item|
          h = item.as_h? || return nil
          doctype = h["doctype"]?.try(&.as_s?) || return nil
          tags_raw = h["tags"]?.try(&.as_a?) || return nil
          tags = tags_raw.map { |t| t.as_s? || return nil }
          entries << ResourceEntry.new(doctype: doctype, tags: tags)
        end
        entries
      end

      # Validates one grant document. `parent_domain` is the domain the
      # grant document lives under (the producer); `consumer_domain` is the
      # grant's reference target id (bare domain name — reference storage
      # qualifies it, so the prefix is stripped here at the read boundary).
      def self.validate(
        parent_domain : String,
        consumer_domain : String?,
        resources : JSON::Any?,
        errors : Array(Facet::ValidationError),
      ) : Nil
        consumer = consumer_domain.try { |c| c.starts_with?("core.Domain.") ? c["core.Domain.".size..] : c }

        if consumer.nil? || consumer.empty?
          errors << Facet::ValidationError.new(
            field: "consumer_domain",
            message: "Grant must name a consumer domain",
            code: "schema",
          )
        elsif consumer == parent_domain
          errors << Facet::ValidationError.new(
            field: "consumer_domain",
            message: "Grant consumer must differ from the parent domain — a self-grant is invalid (same-domain edges need no grant)",
            code: "schema",
          )
        end

        entries = parse_resources(resources)
        if entries.nil?
          errors << Facet::ValidationError.new(
            field: "resources",
            message: "Grant resources must be an array of {doctype, tags} objects",
            code: "schema",
          )
          return
        end

        entries.each_with_index do |entry, i|
          prefix = "resources[#{i}]"
          unless entry.doctype.matches?(/^[A-Z][a-zA-Z0-9]*$/)
            errors << Facet::ValidationError.new(
              field: "#{prefix}.doctype",
              message: "Resource doctype '#{entry.doctype}' is not a valid CamelCase name",
              code: "schema",
            )
          end

          entry.tags.each_with_index do |tag, j|
            next unless tag.blank?
            errors << Facet::ValidationError.new(
              field: "#{prefix}.tags[#{j}]",
              message: "Resource tag must not be empty",
              code: "schema",
            )
          end
        end
      end
    end
  end
end
