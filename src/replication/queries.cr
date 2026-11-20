# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "./registry"
require "./binding"

module Facet
  module Replication
    # Read-side query helpers for the replication handler.
    #
    # `referencing_docs` is the only public query: given a `Binding` and a
    # source document id, return the ids of every non-deleted consumer
    # document whose `via` field points at the source. Backed by the
    # reference btree index created by `Index::Manager` on every
    # `content->>'<ref_field>'` partial to `(domain, doc_type, deleted_at)`.
    module Queries
      # Returns the ids of consumer documents whose `ref_field` equals
      # the qualified form of `source_id`. Reference field values are stored
      # fully qualified (`{domain}.{Doctype}.{id}`), but the event payload
      # carries only the opaque source `projections.id`; we rebuild the
      # qualified form using the binding's declared `source_doctype`.
      #
      # `null` / empty `source_id` returns an empty array — nothing
      # references a missing id.
      def self.referencing_docs(
        db : DB::Connection,
        binding : Binding,
        source_id : String,
      ) : Array(String)
        return [] of String if source_id.empty?

        qualified_id = "#{binding.source_doctype}.#{source_id}"

        db.query_all(
          <<-SQL,
            SELECT id FROM projections
            WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL
              AND content->>$3 = $4
          SQL
          binding.consumer_domain,
          binding.consumer_doctype,
          binding.ref_field,
          qualified_id,
          as: String
        )
      end
    end
  end
end
