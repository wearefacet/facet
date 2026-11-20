# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../util/diacritic_fold"
require "../util/string_util"
require "../templating"

module Facet
  module Document
    # Computes the `search` corpus for `projections` and stages it on the
    # `harness.mutation_search` GUC for the PL/pgSQL trigger. The trigger
    # stays dumb: it reads the GUC value and stores it.
    #
    # The doctype's `search` definition is a Jinja2 template (rendered by
    # `Templating`), e.g. `"{{ first_name }} {{ last_name }}"`. The rendered
    # corpus is whitespace-normalised, accent-folded (`Util::DiacriticFold`),
    # and truncated to `MAX_LENGTH` — the column feeds trigram substring
    # search (`ILIKE '%term%'`). The query side folds the term too, so a
    # term without diacritics matches an accented corpus.
    #
    # A doctype whose definition declares no `search` template stages a
    # fallback corpus instead (B-115): the document's `display_name` value —
    # already resolved by the caller — runs through the same pipeline, so
    # the bare `search` filter matches the folded label like every templated
    # doctype. A nil or blank value still stages the empty string, and the
    # trigger stores a NULL `search` column. Doctypes written without a
    # definition (`ProjectionGucs.clear_all`, e.g. `core.Domain`) end at the
    # same NULL.
    module Search
      GUC_NAME = "harness.mutation_search"

      # Maximum length of a stored `search` corpus, in characters.
      MAX_LENGTH = 256

      # Sets the search corpus GUC within the current transaction. Call
      # this immediately before inserting a mutation row. `display_name` is
      # the document's already-resolved display label — the fallback corpus
      # source for a doctype that declares no `search` template.
      def self.set_guc(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        content : JSON::Any,
        display_name : String?,
        resolver : Templating::ReferenceResolver = DisplayName::DatabaseReferenceResolver.new(db),
      ) : Nil
        value = compute(definition, content, resolver, display_name) || ""
        db.exec("SELECT set_config($1, $2, true)", GUC_NAME, value)
      end

      # Computes the search corpus. With a template, the rendered corpus
      # goes through the shared normalise → fold → truncate pipeline. With
      # no template (nil or empty), the `display_name` value runs through
      # the same pipeline — the template-less fallback corpus (B-115). That
      # path needs no resolver: the value arrives already resolved.
      #
      # Returns nil when the corpus ends up empty — the trigger then stores
      # NULL. Raises `Templating::Error` when the template fails to render —
      # the mutation is rejected.
      def self.compute(
        definition : Doctype::DoctypeDefinition,
        content : JSON::Any,
        resolver : Templating::ReferenceResolver,
        display_name : String? = nil,
      ) : String?
        template = definition.search
        return finalize(display_name) if template.nil? || template.empty?

        bindings = Templating::Context.build(definition, content, resolver, display_name)
        rendered = Templating::Engine.render(template, bindings)
        finalize(rendered)
      end

      # Shared corpus tail for both paths — normalise, fold, truncate. One
      # helper so the template path and the fallback path cannot drift.
      private def self.finalize(raw : String?) : String?
        return nil if raw.nil?

        # A missing optional field can leave whitespace runs or a fully
        # empty corpus — normalise so search quality does not degrade.
        normalized = raw.gsub(/\s+/, " ").strip
        return nil if normalized.empty?
        # Fold before truncation: case folding can grow the string
        # (`ß`→`ss`), and the cap applies to the stored length.
        folded = Util::DiacriticFold.fold(normalized)
        return nil if folded.empty?
        Util::StringUtil.truncate(folded, MAX_LENGTH, "")
      end
    end
  end
end
