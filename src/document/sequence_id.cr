# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"
require "../util/sequence"
require "../doctype/doctype_definition"

module Facet
  module Document
    # Sequence-based document identifiers for doctypes that declare an
    # `identifier` template. `Document::Create` calls `generate` inside the
    # create transaction; on overflow the caller falls back to a ULID.
    module SequenceId
      # Takes an advisory lock for the (domain, doctype) pair, reads the
      # latest value from `sequence_identifiers`, increments it via
      # `Util::Sequence.next`, and upserts the new value back.
      #
      # Returns the generated identifier, or `nil` on overflow.
      def self.generate(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        id_defn : Doctype::IdentifierDefinition,
      ) : String?
        # Advisory lock key derived from domain+doctype name. `String#hash`
        # returns `UInt64`; PostgreSQL's `pg_advisory_xact_lock` is declared
        # `bigint` (signed `Int64`), so values above `Int64::MAX` overflow the
        # cast and the driver rejects them. Wrapping via `to_i64!` preserves
        # the full 64-bit hash distribution (the lock key only needs to be
        # deterministic per doctype name — collisions across distinct names
        # are tolerable and rare).
        lock_key = "seq:#{domain}:#{doc_type}".hash.to_i64!
        db.exec("SELECT pg_advisory_xact_lock($1)", lock_key)

        template = id_defn.template
        last_value = db.query_one?(
          "SELECT last_value FROM sequence_identifiers WHERE domain = $1 AND doc_type = $2",
          domain, doc_type,
          as: String,
        )

        result = Util::Sequence.next(template, last_value)
        return nil if result.overflow?

        new_id = result.value
        return nil if new_id.nil?

        db.exec(
          <<-SQL,
            INSERT INTO sequence_identifiers (domain, doc_type, last_value)
            VALUES ($1, $2, $3)
            ON CONFLICT (domain, doc_type) DO UPDATE SET last_value = EXCLUDED.last_value
          SQL
          domain, doc_type, new_id,
        )

        new_id
      end
    end
  end
end
