# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "digest/sha256"

module Facet
  module Index
    # Generates PostgreSQL index names and access expressions for the
    # index management system.
    #
    # All indexes on the `projections` table use the `idx_env_` prefix
    # so they can be discovered and managed programmatically.
    module Naming
      # Maximum PostgreSQL identifier length (NAMEDATALEN = 63 by default).
      MAX_IDENTIFIER_LENGTH = 63

      # Prefix for all managed index names.
      PREFIX = "idx_env_"

      # Generates a deterministic, collision-free PostgreSQL index name.
      #
      # Pattern: `idx_env_{domain}_{sha256(domain,doctype,field,type)[0..N]}`
      #
      # Uses a SHA-256 hex digest of the full (domain, doctype, field, index_type)
      # tuple keyed into a compact substring, avoiding truncation collisions
      # that the previous middle-slice approach suffered from.
      def self.index_name(
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
      ) : String
        # Build a stable input for the hash
        hash_input = "#{domain}\0#{doc_type}\0#{field_name}\0#{index_type}"
        hex_hash = Digest::SHA256.hexdigest(hash_input)

        # Package: prefix + domain + hash suffix, truncated to 63 chars.
        # Domain is included as a prefix for human readability in `\di+` output.
        #
        # The slug is sanitised to lowercase `[a-z0-9_]` because the name is
        # embedded unquoted in `CREATE INDEX` / `DROP INDEX` SQL. PostgreSQL
        # folds unquoted identifiers to lowercase, so any uppercase letter
        # would silently mismatch the row stored in `doctype_indexes` (which
        # retains the Crystal-side string); and any character outside the
        # unquoted-identifier grammar (`-`, `.`, space, …) breaks the SQL
        # parser with `syntax error at or near "-"` (or similar). The SHA
        # suffix still disambiguates domains whose slugs collide (e.g.
        # `new-crm` vs `new.crm`) because the hash input retains the original
        # domain string verbatim.
        domain_slug = domain.downcase.gsub(/[^a-z0-9_]/, '_')
        base = "#{PREFIX}#{domain_slug}_#{hex_hash}"
        base.byte_slice(0, MAX_IDENTIFIER_LENGTH)
      end

      # Returns the JSONB access expression for a field in the projections
      # `content` column.
      #
      # For scalar indexes (btree, gin_trgm):
      #   - Simple field:    `content->>'field'`
      #   - Nested field:    `content#>>'{parent,child}'`
      #
      # `btree_numeric` is a btree variant for `integer` / `duration` fields:
      # it reads the JSONB value directly (`content->'field'`, not the text
      # extract) and routes it through the IMMUTABLE `jsonb_as_numeric`
      # helper so the index preserves numeric ordering (0, 10, 20, 100)
      # rather than lexicographic ('0', '10', '100', '20'). Filter and sort
      # emit the same expression so range scans and typed ORDER BY can use
      # the index.
      #
      # `btree_money` and `btree_money_currency` are the money-field
      # counterparts. `btree_money` is a COMPOSITE expression btree over
      # `(facet_money_value_as_numeric(content->'field'), content#>>'{field,currency}')`
      # so a single index scan can serve both the currency-prefixed value
      # filters (`price__gte="USD 1000"`) and the currency-agnostic ones.
      # `btree_money_currency` is a plain btree on the currency text extract
      # for the `__currency` operator.
      #
      # For JSONB indexes (gin_jsonb):
      #   - Simple field:    `content->'field'`
      #   - Nested field:    `content#>'{parent,child}'`
      #
      # For GiST range indexes (`gist_tstzrange`, `gist_daterange`):
      #   - The index expression reads `content#>>'{field,start}'` and
      #     `content#>>'{field,end}'` (the period's two stored bounds)
      #     and wraps them in a PostgreSQL range constructor:
      #     `tstzrange((...start)::timestamptz, (...end)::timestamptz, '[)')`
      #     for `period`, and `daterange((...start)::date, (...end)::date,
      #     '[]')` for `dateperiod`. The bounds convention differs:
      #     `[)` exclusive upper for `period` (dense continuum), `[]`
      #     inclusive both ends for `dateperiod` (finite, countable days).
      # ameba:disable Metrics/CyclomaticComplexity
      def self.access_expression(field_name : String, index_type : String) : String
        parts = field_name.split('.')

        case index_type
        when "btree", "unique_btree", "gin_trgm"
          if parts.size == 1
            "content->>'#{parts[0]}'"
          else
            "content#>>'{#{parts.join(",")}}'"
          end
        when "btree_numeric"
          if parts.size == 1
            "jsonb_as_numeric(content->'#{parts[0]}')"
          else
            # Nested numeric field: traverse to the jsonb sub-value, then
            # coerce via the helper.
            "jsonb_as_numeric(content#>'{#{parts.join(",")}}')"
          end
        when "btree_money"
          # Composite money index: (numeric_value, currency_text). The
          # leading column is the IMMUTABLE cast so value-range scans and
          # currency-agnostic filters both use the index.
          if parts.size == 1
            "facet_money_value_as_numeric(content->'#{parts[0]}'), content#>>'{#{parts[0]},currency}'"
          else
            path = parts.join(",")
            "facet_money_value_as_numeric(content#>'{#{path}}'), content#>>'{#{path},currency}'"
          end
        when "btree_money_currency"
          if parts.size == 1
            "content#>>'{#{parts[0]},currency}'"
          else
            path = parts.join(",")
            "content#>>'{#{path},currency}'"
          end
        when "gin_jsonb"
          if parts.size == 1
            "content->'#{parts[0]}'"
          else
            "content#>'{#{parts.join(",")}}'"
          end
        when "gist_tstzrange"
          range_expression(field_name, "facet_tstzrange")
        when "gist_daterange"
          range_expression(field_name, "facet_daterange")
        else
          raise ArgumentError.new("Unknown index type: #{index_type.inspect}")
        end
      end

      # Returns the partial index WHERE clause scoped to a domain and doctype,
      # excluding deleted documents.
      def self.where_clause(domain : String, doc_type : String) : String
        "domain = '#{domain}' AND doc_type = '#{doc_type}' AND deleted_at IS NULL"
      end

      # Returns the CREATE INDEX SQL for a given descriptor.
      #
      # Two variants are emitted based on the `concurrent` flag:
      #
      # * `concurrent: true` (default — production path): `CREATE INDEX
      #   CONCURRENTLY IF NOT EXISTS ...`. This does not block writes against
      #   `projections` and can run outside a transaction block. It does two
      #   table scans and waits for any in-flight transactions to commit, so
      #   it is significantly slower than the non-concurrent form on small
      #   tables. Failure may leave an INVALID index behind, which is cleaned
      #   up by the manager's best-effort DROP.
      # * `concurrent: false` (test path — `Index::Manager.synchronous?`):
      #   `CREATE INDEX IF NOT EXISTS ...` (no `CONCURRENTLY`). Single table
      #   scan, no waiting, can run inside a transaction block. Used by the
      #   spec suite to avoid the per-test SHARE-lock contention and the
      #   background-fiber join overhead the concurrent form requires.
      #
      # The access expression is wrapped in an extra pair of parentheses.
      # PostgreSQL's `CREATE INDEX ... USING <method> (<expr>)` parser does
      # *not* accept a bare multi-token expression like `content->>'email'`
      # — the `->>` operator collides with the surrounding method-list
      # grammar and produces `syntax error at or near "->>"`. Wrapping it
      # as `(content->>'email')` parses correctly. Function-call-shaped
      # expressions (the GiST range helpers) are unaffected by the extra
      # parens, so we apply it unconditionally below.
      def self.create_index_sql(
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
        *,
        concurrent : Bool = true,
      ) : String
        name = index_name(domain, doc_type, field_name, index_type)
        access = "(#{access_expression(field_name, index_type)})"
        where = where_clause(domain, doc_type)
        keyword = concurrent ? "CREATE INDEX CONCURRENTLY" : "CREATE INDEX"
        unique_keyword = concurrent ? "CREATE UNIQUE INDEX CONCURRENTLY" : "CREATE UNIQUE INDEX"

        case index_type
        when "btree", "btree_numeric", "btree_money_currency"
          "#{keyword} IF NOT EXISTS #{name} ON projections USING btree (#{access}) WHERE #{where}"
        when "btree_money"
          # Composite btree: access_expression returns a comma-separated tuple
          # `(numeric_value, currency_text)`. Each column is wrapped
          # individually in parens (the parser rejects multi-token
          # unparenthesised expressions like `content#>>'{...}'` inside
          # `USING btree (...)`), and the column list itself is emitted
          # without an extra outer wrap — PostgreSQL parses a comma list
          # directly as a column list.
          cols = access_expression(field_name, index_type)
          col_list = cols.split(", ").map { |c| "(#{c})" }.join(", ")
          "#{keyword} IF NOT EXISTS #{name} ON projections USING btree (#{col_list}) WHERE #{where}"
        when "unique_btree"
          "#{unique_keyword} IF NOT EXISTS #{name} ON projections USING btree (#{access}) WHERE #{where}"
        when "gin_trgm"
          "#{keyword} IF NOT EXISTS #{name} ON projections USING gin (#{access} gin_trgm_ops) WHERE #{where}"
        when "gin_jsonb"
          "#{keyword} IF NOT EXISTS #{name} ON projections USING gin (#{access} jsonb_ops) WHERE #{where}"
        when "gist_tstzrange", "gist_daterange"
          # `range_ops` is the default GiST opclass for PostgreSQL range
          # types (tstzrange, daterange). Explicit opclass is omitted —
          # GiST picks `range_ops` automatically when the indexed
          # expression is a range type. `access` is already parenthesised
          # as `(facet_tstzrange(...))`; we keep that wrap here for
          # uniformity, GiST accepts it.
          "#{keyword} IF NOT EXISTS #{name} ON projections USING gist (#{access}) WHERE #{where}"
        else
          raise ArgumentError.new("Unknown index type: #{index_type.inspect}")
        end
      end

      # Returns the DROP INDEX SQL.
      #
      # Two variants are emitted based on `concurrent` (mirroring
      # `create_index_sql`). The default `true` produces
      # `DROP INDEX CONCURRENTLY IF EXISTS`; the test-mode variant
      # (`concurrent: false`) emits a plain `DROP INDEX IF EXISTS` which
      # is allowed inside a transaction block and avoids the
      # SHARE-row-exclusive lock that the concurrent form requires.
      def self.drop_index_sql(
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
        *,
        concurrent : Bool = true,
      ) : String
        name = index_name(domain, doc_type, field_name, index_type)
        keyword = concurrent ? "DROP INDEX CONCURRENTLY IF EXISTS" : "DROP INDEX IF EXISTS"
        "#{keyword} #{name}"
      end

      # Returns the `CREATE STATISTICS` SQL for the btree index of a field,
      # or `nil` when the index type has no text-extract expression.
      #
      # The planner collects no statistics on a bare `content->>'field'`
      # expression, so it falls back to the default selectivity estimate
      # (0.5 %). On a selective equality filter that estimate is far too
      # large, and the default `ORDER BY id LIMIT n` plan (walk
      # `projections_pkey`, stop early) looks cheaper than the field index —
      # PostgreSQL then walks the whole doctype and filters. The extended
      # statistics object gives the expression real statistics, so the
      # planner picks the field index.
      #
      # One statistics object serves every btree variant of a field (the
      # text extract is the shared expression), so the object is named after
      # the field and not the index type. `IF NOT EXISTS` makes a second
      # variant a no-op. Only the `btree` and `unique_btree` families are
      # served: they are the equality lookups whose selectivity estimate is
      # the problem. `gin_trgm` and the GiST/GIN families are left alone —
      # their operators are not equality lookups over the text extract.
      def self.create_statistics_sql(
        domain : String,
        doc_type : String,
        field_name : String,
        index_type : String,
        *,
        statistics_target : Int32? = nil,
      ) : String?
        return nil unless statistics_expression?(index_type)

        name = statistics_name(domain, doc_type, field_name)
        access = access_expression(field_name, index_type)
        target = statistics_target ? " (statistics_target = #{statistics_target})" : ""
        "CREATE STATISTICS IF NOT EXISTS #{name}#{target} ON (#{access}) FROM projections"
      end

      # Returns the `DROP STATISTICS` SQL for a field's statistics object.
      def self.drop_statistics_sql(domain : String, doc_type : String, field_name : String) : String
        "DROP STATISTICS IF EXISTS #{statistics_name(domain, doc_type, field_name)}"
      end

      # The deterministic name of a field's extended statistics object. It
      # embeds the domain slug exactly as `index_name` does, for the same
      # reason (the name is emitted unquoted).
      def self.statistics_name(domain : String, doc_type : String, field_name : String) : String
        hash_input = "#{domain}\0#{doc_type}\0#{field_name}\0statistics"
        hex_hash = Digest::SHA256.hexdigest(hash_input)
        domain_slug = domain.downcase.gsub(/[^a-z0-9_]/, '_')
        base = "#{PREFIX}st_#{domain_slug}_#{hex_hash}"
        base.byte_slice(0, MAX_IDENTIFIER_LENGTH)
      end

      # True for the index types whose access expression is the plain text
      # extract `content->>'field'` — the equality-lookup family the
      # statistics object serves.
      private def self.statistics_expression?(index_type : String) : Bool
        case index_type
        when "btree", "unique_btree"
          true
        else
          false
        end
      end

      # Builds the two-leaf range expression for `gist_tstzrange` and
      # `gist_daterange` indexes. The stored JSONB shape for a period /
      # dateperiod field is `{"start": ..., "end": ...}`, so the index
      # reads both leaves as text and passes them to the IMMUTABLE helper
      # functions from migration `0002_indexing.sql`.
      #
      # The IMMUTABLE wrappers (`facet_tstzrange`, `facet_daterange`)
      # take text arguments and perform the cast internally — the
      # `tstzrange(text, text, ...)` / `daterange(text, text, ...)` casts
      # inside the wrapper are STABLE not IMMUTABLE, but the doctype
      # validation layer guarantees well-formed ISO-8601 inputs, so the
      # cast result is actually deterministic and the IMMUTABLE marking
      # on the wrapper truthfully reflects the runtime guarantee.
      #
      # `field_name` may be a dotted path if the period is nested inside
      # an object (e.g. `address.tenure`).
      private def self.range_expression(field_name : String, ctor_fn : String) : String
        parts = field_name.split('.')
        leaf_path = parts.size == 1 ? parts[0] : parts.join(",")
        start_path = "#{leaf_path},start"
        end_path = "#{leaf_path},end"
        "#{ctor_fn}(content#>>'{#{start_path}}', content#>>'{#{end_path}}')"
      end
    end
  end
end
