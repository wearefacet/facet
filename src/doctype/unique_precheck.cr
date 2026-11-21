# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../error"

module Facet
  module Doctype
    # Duplicate scan for fields that gain `unique: true` on a doctype
    # update.
    #
    # `Index::Manager` turns a `unique: true` field into a `unique_btree`
    # index on `projections`. On a live doctype that already holds data,
    # the index creation fails when two live rows share one value — the
    # tracking row settles into `error` status and the database-level
    # enforcement never exists until the data is cleaned and
    # `facet index:retry` runs. This check runs before the doctype
    # mutation is written, so the update answers `422` with the duplicate
    # values named instead of shipping a definition whose backstop index
    # cannot build.
    #
    # The scan groups on the same expression the index enforces
    # (`content->>'field'`) over live rows, so a passing scan guarantees
    # the `CREATE UNIQUE INDEX` succeeds (up to the race with concurrent
    # writes, which the index itself then rejects).
    #
    # Draft domains skip the scan: publish copies structure only, so a
    # draft definition meets fresh data on the live domain.
    module UniquePrecheck
      # Maximum duplicate values named per field in the error details.
      # The count stays exact; only the sample is capped.
      MAX_SAMPLE = 5

      # Returns one validation error per newly-unique field that already
      # holds duplicate values among live rows. `current_def` is the
      # stored definition, `definition` the incoming one.
      def self.validate_added_unique(
        db : DB::Connection,
        current_def : DoctypeDefinition,
        definition : DoctypeDefinition,
      ) : Array(ValidationError)
        errors = [] of ValidationError

        definition.fields.each do |field_name, field|
          next unless field.unique
          next if current_def.fields[field_name]?.try(&.unique)

          if dupes = duplicate_values(db, definition.domain, definition.doctype, field_name)
            sample = dupes.first(MAX_SAMPLE).join(", ")
            count_note = dupes.size > MAX_SAMPLE ? " (and #{dupes.size - MAX_SAMPLE} more)" : ""
            errors << ValidationError.new(
              field: field_name,
              message: "cannot set unique: #{dupes.size} documents already share values: #{sample}#{count_note}",
              code: "unique",
            )
          end
        end

        errors
      end

      # Returns the values that appear on more than one live row, or `nil`
      # when the field is duplicate-free. Only scalar JSON values
      # participate — null, absent, and non-scalar values are never
      # constrained, matching `Document::UniqueConstraint` and the index
      # (PostgreSQL treats NULLs as distinct in a btree unique index).
      private def self.duplicate_values(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        field_name : String,
      ) : Array(String)?
        rows = db.query_all(
          <<-SQL,
            SELECT content->>'#{field_name}' AS value, COUNT(*) AS n
            FROM projections
            WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL
              AND jsonb_typeof(content->'#{field_name}') IN ('string', 'number', 'boolean')
            GROUP BY 1
            HAVING COUNT(*) > 1
            ORDER BY n DESC
          SQL
          domain, doc_type,
          as: {String, Int64}
        )

        rows.map { |value, _| value }
      end
    end
  end
end
