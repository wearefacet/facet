# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../util/string_util"
require "../templating"

module Facet
  module Document
    # Computes the `display_name` column for `projections` and stages it on
    # the `harness.mutation_display_name` GUC for the PL/pgSQL trigger.
    #
    # In contrast to `Document::Search` (whose corpus is computed in Crystal
    # too), display_name computation needs reference resolution — a
    # reference field's label comes from the referenced document's stored
    # row. The trigger therefore stays dumb: it reads the GUC value and
    # stores it.
    #
    # The template is Jinja2 (rendered by `Templating`), e.g.
    # `"{{ first_name }} {{ last_name }}"`. Reference fields resolve to the
    # referenced document's stored `display_name` (no recursion — that
    # document's display_name was computed at its own write time). When
    # resolution fails (deleted target, no template, etc.) the fallback is
    # the target doctype's bare name (e.g. `"Company"`), never the raw UUID.
    module DisplayName
      GUC_NAME = "harness.mutation_display_name"

      # Maximum length of a stored `display_name`, in characters. Computed
      # values are truncated to fit via `StringUtil.truncate`. Matches the
      # `projections.display_name` column width (migration 0001).
      MAX_LENGTH = 255

      # Swap point for cross-domain reference resolution. The protocol lives
      # in `Templating::ReferenceResolver`.
      alias ReferenceResolver = Templating::ReferenceResolver

      # Resolves reference fields by reading the `projections` table on the
      # same database the mutation is being written to. Shares the caller's
      # transaction via the injected `DB::Connection`.
      #
      # Tombstoned rows are deliberately **not** filtered out — their
      # `display_name` is preserved on delete (see migration 0002), so a
      # stale-but-still-meaningful label renders on the referencing side
      # after the target is deleted.
      class DatabaseReferenceResolver < ReferenceResolver
        def initialize(@db : DB::Database | DB::Connection)
        end

        # `doc_id` is the stored reference value: a fully qualified
        # `{domain}.{Doctype}.{id}` string. The `projections.id` of the
        # referenced document may be either the bare opaque id (the normal
        # `Document::Create` path — a ULID) or, for seed fixtures and the
        # `core.DocType` / `core.Domain` meta-doctypes, the qualified form
        # itself. To stay correct across both, we first query by the raw
        # qualified value, then fall back to the opaque id (the qualified
        # value with its `{domain}.{Doctype}.` prefix stripped).
        def resolve(qualified_target_doctype : String, doc_id : String) : String?
          dot = qualified_target_doctype.index('.')
          return nil unless dot && dot > 0
          domain = qualified_target_doctype[0...dot]
          doctype = qualified_target_doctype[(dot + 1)..]

          # Fast path: the stored value is the projection id as-is.
          result = query_display_name(domain, doctype, doc_id)
          return result unless result.nil?

          # Fallback: strip the `{domain}.{Doctype}.` prefix and retry. This
          # covers the normal `Document::Create` write path where the opaque
          # id (a ULID) is stored on the projection while the reference
          # value carries the qualified form.
          opaque_id = strip_qualified_prefix(doc_id, qualified_target_doctype)
          return nil if opaque_id == doc_id
          query_display_name(domain, doctype, opaque_id)
        end

        private def query_display_name(domain : String, doctype : String, id : String) : String?
          @db.query_one?(
            <<-SQL,
              SELECT display_name
              FROM projections
              WHERE domain = $1 AND doc_type = $2 AND id = $3
            SQL
            domain, doctype, id,
            as: String?
          )
        end

        # Extracts the opaque id from a stored reference value. The value
        # may be qualified (`{domain}.{Doctype}.{id}`) — in which case the
        # `{domain}.{Doctype}.` prefix is stripped — or already bare (the
        # legacy form). Returns the input unchanged when no prefix matches.
        private def strip_qualified_prefix(value : String, qualified_target_doctype : String) : String
          prefix = "#{qualified_target_doctype}."
          return value[prefix.size..] if value.starts_with?(prefix)
          value
        end
      end

      # ── Public API ────────────────────────────────────────────────────

      # Computes the display_name string for `content` according to the
      # template on `definition`. Returns nil when the doctype has no
      # template (the trigger will then store NULL).
      #
      # Raises `Templating::Error` when the template fails to render — the
      # mutation is rejected.
      def self.compute(
        definition : Doctype::DoctypeDefinition,
        content : JSON::Any,
        resolver : ReferenceResolver,
      ) : String?
        template = definition.display_name
        return nil if template.nil? || template.empty?

        bindings = Templating::Context.build(definition, content, resolver)
        replaced = Templating::Engine.render(template, bindings)

        Util::StringUtil.truncate(replaced, MAX_LENGTH, "...")
      end

      # Stages the computed display_name on the transaction-local GUC so
      # the PL/pgSQL trigger can store it. Sets the GUC to an empty string
      # when the doctype has no template — this is the explicit "no value"
      # signal that mirrors the `Document::Search` contract.
      def self.set_guc(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        content : JSON::Any,
        resolver : ReferenceResolver = DatabaseReferenceResolver.new(db),
      ) : Nil
        stage(db, compute(definition, content, resolver))
      end

      # Stages an already computed display_name value (or nil for no
      # template) on the transaction-local GUC.
      def self.stage(db : DB::Connection, value : String?) : Nil
        db.exec("SELECT set_config($1, $2, true)", GUC_NAME, value || "")
      end
    end
  end
end
