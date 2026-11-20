# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "big"
require "db"
require "../../doctype/doctype_definition"
require "../../rbac"
require "../../error"
require "../../util/filter_clauses"

module Facet
  module Document
    module List
      # Field aggregates for document lists: the `aggregate` / `field`
      # validation and the one-statement `<FN>/COUNT` runner behind
      # `List.call`. `count` is not a field aggregate — the list service
      # runs it through its own capped COUNT path.
      module Aggregate
        # Result of a field-aggregate request (`aggregate` = `sum`, `avg`,
        # `min`, or `max`). `value` is the response payload — a JSON number
        # (or a decimal string when the value exceeds the `Int64` range or
        # carries a fractional part; JSON null for `avg` / `min` / `max` over
        # an empty set) for `integer` / `duration` fields, or an object of
        # `{ticker => decimal-string}` for `money` fields. `count` is the
        # number of matching rows that produced the value, computed by the
        # same SQL statement.
        record AggregateResult,
          value : JSON::Any,
          count : Int64

        # System-supported `aggregate` modes. Mirrors `HTTP::ListRequest::AGGREGATES`
        # so the service layer can validate the value without importing HTTP types —
        # `List.call` accepts the raw string and rejects unknown values with 422.
        AGGREGATES = Set{"count", "sum", "avg", "min", "max"}

        # Aggregates that operate on a declared doctype field and therefore
        # require the `field` parameter (`count` runs field-free). All share
        # one SQL shape: `<FN>(...) + COUNT(*)` over the full filtered set.
        FIELD_AGGREGATES = Set{"sum", "avg", "min", "max"}

        # Field types the field aggregates accept. `integer` and `duration`
        # aggregate as plain numerics (scalar `value`); `money` aggregates
        # into a `{ticker => amount}` bag, one entry per currency present in
        # the filtered set. Every other field type is rejected with 422 —
        # none has numeric aggregate semantics. Deliberately NOT
        # `Util::FilterClauses.typed_field_type`, which also matches
        # `boolean` (no numeric aggregate semantics).
        AGGREGATE_FIELD_TYPES = Set{"integer", "duration", "money"}

        # Validates the `field` parameter when `aggregate` is one of the
        # field aggregates (`sum`, `avg`, `min`, `max`); returns `nil` for
        # any other aggregate or for a valid, visible field. All failures
        # surface before any SQL runs:
        # - 422 missing `field`
        # - 422 dotted paths (nested-field lookup is not supported — top-level
        #   doctype fields only, mirroring the typed filter path which uses
        #   the field name verbatim as `content->'field'`)
        # - 422 field not declared on the doctype
        # - 403 field's `view` tags not covered by the caller's `visible_tags`
        #   (`RBAC::ReadEnforcer.field_visible?` — fail closed). Checked
        #   BEFORE the type gate so a hidden field's type never leaks through
        #   a 422 message.
        # - 422 field type without numeric aggregate semantics (only
        #   `integer`, `duration`, and `money` are aggregable)
        def self.validate_aggregate_field(
          definition : Doctype::DoctypeDefinition,
          aggregate : String?,
          field : String?,
          auth_context : RBAC::AuthContext,
        ) : Facet::ServiceError?
          return nil unless aggregate.in?(FIELD_AGGREGATES)
          return Facet::ServiceError.new(422, "aggregate=#{aggregate} requires a field parameter") if field.nil?

          if field.includes?('.')
            return Facet::ServiceError.new(422, "field '#{field}' must be a top-level doctype field")
          end
          field_def = definition.fields[field]?
          return Facet::ServiceError.new(422, "Unknown field: #{field}") if field_def.nil?
          unless RBAC::ReadEnforcer.field_visible?(auth_context, field_def)
            return Facet::ServiceError.new(403, "field '#{field}' is not visible to the active role")
          end
          type_name = field_def.type.try(&.type_name)
          return Facet::ServiceError.new(422, "field '#{field}' has no declared type") if type_name.nil?
          unless AGGREGATE_FIELD_TYPES.includes?(type_name)
            return Facet::ServiceError.new(422, "field '#{field}' is not a numeric field (type: #{type_name})")
          end
          nil
        end

        # The 422 for a field aggregate without a `field` parameter, or nil
        # when the request carries one (or is not a field aggregate). The
        # message does not depend on the field name, so it leaks nothing.
        # Extracted so `Document::List.call` stays inside ameba's complexity
        # budget.
        def self.missing_field_error(aggregate : String?, field : String?) : Facet::ServiceError?
          return nil unless aggregate.in?(FIELD_AGGREGATES)
          return Facet::ServiceError.new(422, "aggregate=#{aggregate} requires a field parameter") if field.nil?

          nil
        end

        # The 422 for a `field` parameter without a field aggregate (`sum`,
        # `avg`, `min`, `max`), or nil when the pair is consistent. `field`
        # is only the target of the field aggregates — `count` runs
        # field-free — so with any other `aggregate` value, including none,
        # a present `field` would vanish into a `200` (B-358). The message
        # mirrors `missing_field_error` and echoes only values the caller
        # sent, so it leaks nothing.
        def self.orphan_field_error(aggregate : String?, field : String?) : Facet::ServiceError?
          return nil if field.nil? || aggregate.in?(FIELD_AGGREGATES)

          Facet::ServiceError.new(422, "field=#{field} requires an aggregate parameter (sum, avg, min, or max)")
        end

        # The combined 422 for an inconsistent `aggregate` / `field` pair,
        # or nil when the pair is consistent. One call site in
        # `Document::List.call` keeps the method inside ameba's complexity
        # budget. Field visibility runs first: a field the active role cannot
        # see answers 403, never a 422 that names it.
        def self.field_param_error(
          aggregate : String?,
          field : String?,
          definition : Doctype::DoctypeDefinition,
          auth_context : RBAC::AuthContext,
          skip_authorization : Bool,
        ) : Facet::ServiceError?
          invisible_field_error(field, definition, auth_context, skip_authorization) ||
            missing_field_error(aggregate, field) ||
            orphan_field_error(aggregate, field)
        end

        # The 403 for a `field` parameter the active role cannot see, or nil.
        # Runs before `field_param_error`: a field the caller may not read
        # answers 403, never a 422 that names it. The check is a pure tag test
        # on the definition, so it reads no row.
        def self.invisible_field_error(
          field : String?,
          definition : Doctype::DoctypeDefinition,
          auth_context : RBAC::AuthContext,
          skip_authorization : Bool,
        ) : Facet::ServiceError?
          return nil if field.nil? || skip_authorization

          field_def = definition.fields[field]?
          return nil if field_def.nil?
          return nil if RBAC::ReadEnforcer.field_visible?(auth_context, field_def)

          Facet::ServiceError.new(403, "field '#{field}' is not visible to the active role")
        end

        # The empty-set aggregate payload, served without inspecting the
        # field: `sum` reports 0 (the total of nothing), `avg` / `min` /
        # `max` report JSON null, and `count` is 0. The shape stays constant
        # per aggregate mode and never depends on the field — a caller with
        # no read grant gets this for every field name, declared or not,
        # tagged or not, so the response cannot enumerate the schema. A
        # `money` field answers the scalar shape too: telling the bag apart
        # would require reading the field definition, and that is exactly
        # the observation this payload must deny.
        def self.empty_field_result(aggregate : String) : AggregateResult
          value = aggregate == "sum" ? aggregate_value_json("0") : aggregate_value_json(nil)
          AggregateResult.new(value: value, count: 0)
        end

        # Dispatches the validated field aggregate by declared field type:
        # `money` groups by currency into a `{ticker => amount}` bag,
        # `integer` / `duration` produce a scalar.
        def self.run_field_aggregate(
          db : DB::Connection,
          definition : Doctype::DoctypeDefinition,
          aggregate : String,
          where_sql : String,
          all_params : Array(::DB::Any),
          field : String,
        ) : {JSON::Any, Int64}
          if Util::FilterClauses.money_field?(definition, field)
            run_aggregate_money(db, aggregate, where_sql, all_params, field)
          else
            run_aggregate_numeric(db, aggregate, where_sql, all_params, field)
          end
        end

        # The PG aggregate function for a validated field aggregate. The
        # aggregate value is whitelisted against `FIELD_AGGREGATES` before
        # this interpolation, so the upcase is injection-safe.
        private def self.aggregate_sql_fn(aggregate : String) : String
          aggregate.upcase
        end

        # Runs the field-aggregate statement for a validated `integer` /
        # `duration` field. One statement computes the aggregate and the
        # contributing row count — no LIMIT, no ORDER BY: the aggregate
        # honours the total (unlike `aggregate=count`, which caps at 1000).
        #
        # `sum` keeps `COALESCE(..., 0)` so an empty result set reports 0 —
        # "the total of nothing". `avg` / `min` / `max` have no meaningful
        # value over an empty set and report JSON `null`. The `numeric`
        # result is cast to `text` so PG emits the exact canonical decimal —
        # `aggregate_value_json` then decides null/number/string emission.
        private def self.run_aggregate_numeric(
          db : DB::Connection,
          aggregate : String,
          where_sql : String,
          all_params : Array(::DB::Any),
          field : String,
        ) : {JSON::Any, Int64}
          fn = aggregate_sql_fn(aggregate)
          inner = if aggregate == "sum"
                    "COALESCE(#{fn}(jsonb_as_numeric(content->'#{field}')), 0)"
                  else
                    "#{fn}(jsonb_as_numeric(content->'#{field}'))"
                  end
          value, count = db.query_one(
            <<-SQL,
              SELECT
                #{inner}::numeric::text AS v,
              COUNT(*)::int8          AS c
              FROM projections
              WHERE #{where_sql}
            SQL


            args: all_params,
            as: {String?, Int64}
          )
          {aggregate_value_json(value), count}
        end

        # Encodes an aggregated numeric for the aggregate response. `nil` (an
        # empty result set under `avg` / `min` / `max`) emits as JSON null.
        # Integral values that fit `Int64` emit as JSON numbers (the common
        # case for `integer` / `duration` fields); anything wider or with a
        # fractional part emits as the exact decimal string PG produced, so
        # no precision is lost and no exponent notation enters the payload.
        private def self.aggregate_value_json(text : String?) : JSON::Any
          return JSON::Any.new(nil) if text.nil?
          value = BigDecimal.new(text)
          if value.integer? && value >= Int64::MIN && value <= Int64::MAX
            JSON::Any.new(value.to_i64)
          else
            JSON::Any.new(text)
          end
        end

        # Runs the field-aggregate statement for a validated `money` field,
        # grouped by the stored currency ticker — one row per currency
        # present in the filtered set. Amounts are exact decimal strings
        # (PG's `numeric` text form), preserving precision across currencies;
        # currencies with no matching rows are naturally absent from the bag.
        #
        # `COALESCE(..., 0)` keeps the bag contract airtight: a currency
        # group whose money payloads all fail the numeric extraction (malformed
        # `value` member) reports 0 instead of a null bag entry.
        #
        # A money payload missing its `currency` member (malformed row) has
        # no ticker to report under, so its group is left out of the bag —
        # its rows still count toward `count`.
        private def self.run_aggregate_money(
          db : DB::Connection,
          aggregate : String,
          where_sql : String,
          all_params : Array(::DB::Any),
          field : String,
        ) : {JSON::Any, Int64}
          fn = aggregate_sql_fn(aggregate)
          bag = {} of String => JSON::Any
          count = 0_i64
          db.query(<<-SQL, args: all_params) do |rs|
              SELECT
                content#>>'{#{field},currency}'                                     AS ccy,
                COALESCE(#{fn}(facet_money_value_as_numeric(content->'#{field}')), 0)::numeric::text AS v,
                COUNT(*)::int8                                                       AS c
              FROM projections
              WHERE #{where_sql}
              GROUP BY content#>>'{#{field},currency}'
            SQL
            rs.each do
              ccy = rs.read(String?)
              amount = rs.read(String)
              count += rs.read(Int64)
              bag[ccy] = JSON::Any.new(amount) if ccy
            end
          end
          {JSON::Any.new(bag), count}
        end
      end
    end
  end
end
