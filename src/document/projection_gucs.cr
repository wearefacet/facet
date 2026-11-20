# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../doctype/doctype_definition"
require "./search"
require "./links"
require "./display_name"

module Facet
  module Document
    # Single entry point for staging every transaction-local GUC the
    # mutations trigger reads. Calling `set_all` from each document service
    # keeps search, links, and display_name in sync with the doctype
    # definition and the post-mutation content.
    #
    # GUCs set:
    #   * `harness.mutation_search`        — via `Document::Search`
    #   * `harness.mutation_links`         — via `Document::Links`
    #   * `harness.mutation_display_name`  — via `Document::DisplayName`
    #
    # The computed display_name feeds the search corpus too: a doctype
    # whose definition declares no `search` template stages the folded
    # display_name as the fallback corpus (B-115).
    #
    # `clear_all` stages empty values for all three — used by services that
    # write rows without a doctype definition (e.g. `core.Domain` creates /
    # audit rollback fallback). Such rows keep a NULL `search` corpus.
    module ProjectionGucs
      def self.set_all(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        content : JSON::Any,
      ) : Nil
        display_name = DisplayName.compute(definition, content, DisplayName::DatabaseReferenceResolver.new(db))
        DisplayName.stage(db, display_name)
        Search.set_guc(db, definition, content, display_name)
        Links.set_guc(db, content, definition)
      end

      def self.clear_all(db : DB::Connection) : Nil
        db.exec("SELECT set_config('harness.mutation_search', '', true)")
        db.exec("SELECT set_config($1, $2, true)", Links::GUC_NAME, "[]")
        db.exec("SELECT set_config($1, $2, true)", DisplayName::GUC_NAME, "")
      end
    end
  end
end
