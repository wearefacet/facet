# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../util/money_filter_value"
require "../rbac/field_visibility"

module Facet
  module ImportExport
    # CSV cell codec for the document import/export concern.
    #
    # Encodes a document row to CSV cells and decodes a CSV row to document
    # content. Pure logic — no database, no jobs. The caller owns the CSV
    # text layer (`CSV.build` / `CSV.parse`); this module works on arrays of
    # cells. See the cell conventions table in `doc/backend/import-export.md`.
    module CsvSerializer
      # A row-level decode failure. `field` names the offending column;
      # `nil` for row-shape failures that no single field owns. The message
      # names the field too, so the row failure is self-describing.
      class RowError < ::Exception
        getter field : String?

        def initialize(@field : String?, message : String)
          super(@field ? "field '#{@field}': #{message}" : message)
        end
      end

      ID_COLUMN = "id"

      # Scalar types whose cell is the stored text, verbatim. `secret`
      # values carry no material — a stage handle exports as text and a
      # marker object exports as JSON.
      private TEXT_TYPES = Set{"string", "longtext", "enum", "phone", "url", "color", "date", "datetime", "reference", "file", "secret"}

      # First characters a spreadsheet evaluates as a formula. A text cell
      # that starts with one exports with a guard prefix (see
      # `formula_guarded`), so the sheet shows the text instead of running it.
      private FORMULA_TRIGGERS = Set{'=', '+', '-', '@', '\t'}

      # Numeric scalars stored as JSON numbers; the cell is decimal text.
      private NUMBER_TYPES = Set{"integer", "duration"}

      # Header row: a leading `id` column, then one column per declared
      # field the caller can see, in definition order. A field the caller
      # cannot see is omitted, so the header agrees with the read-masked
      # row cells (`mask_content` drops the same fields). Server-managed
      # fields stay in the header (export writes them) but decode drops
      # them.
      def self.header(definition : Doctype::DoctypeDefinition, auth_context : RBAC::AuthContext) : Array(String)
        [ID_COLUMN] + visible_field_names(definition, auth_context)
      end

      # Header row for the import contract: a leading `id` column, then
      # every declared field in definition order. Import accepts the full
      # declared-field set regardless of the caller's field visibility —
      # the write plane refuses an invisible write later, and a
      # server-managed column is dropped by decode. This keeps the import
      # contract independent of the export header (which omits invisible
      # fields).
      def self.declared_header(definition : Doctype::DoctypeDefinition) : Array(String)
        [ID_COLUMN] + definition.fields.keys
      end

      # Encodes one document row: the id, then one cell per field the
      # caller can see, in definition order — the same field set `header`
      # emits, so the header and the row cells stay aligned. Absent and
      # null content values encode as empty cells.
      def self.encode_row(id : String, content : JSON::Any, definition : Doctype::DoctypeDefinition, auth_context : RBAC::AuthContext) : Array(String)
        row = [id]
        visible_field_names(definition, auth_context).each do |name|
          row << encode_cell(content[name]?, definition.fields[name])
        end
        row
      end

      # The declared field names the caller can see, in definition order.
      # Shared by `header` and `encode_row` so the two never disagree.
      private def self.visible_field_names(definition : Doctype::DoctypeDefinition, auth_context : RBAC::AuthContext) : Array(String)
        definition.fields.keys.select do |name|
          RBAC::FieldVisibility.field_visible?(auth_context, definition.fields[name])
        end
      end

      # Header row for a view export: the column keys in order, verbatim.
      # The route validates every key before enqueue, so the header is
      # exactly the caller's selection — keys, not display labels (the
      # full-doctype header keeps its id-leading field list). The
      # definition rides the signature for call-site symmetry only.
      def self.header(definition : Doctype::DoctypeDefinition, columns : Array(String)) : Array(String)
        columns.dup
      end

      # Encodes one document row for a view export: one cell per requested
      # column, in the caller's order. Column resolution:
      #
      # - `id` — the row id.
      # - `created_at` / `updated_at` — the row timestamp in the export
      #   timezone as `YYYY-MM-DD HH:MM:SS`, or UTC RFC-3339 when no
      #   timezone was requested.
      # - a declared field — the shared type-aware cell (`encode_cell`),
      #   with one view-only exception: a `datetime` value shifts from its
      #   stored UTC RFC-3339 form into the export timezone (same
      #   `YYYY-MM-DD HH:MM:SS` format; a value that fails to parse stays
      #   verbatim).
      # - anything else — an empty cell (the route validates the keys;
      #   this is the defensive fallback).
      def self.encode_view_row(
        id : String,
        content : JSON::Any,
        created_at : Time,
        updated_at : Time,
        definition : Doctype::DoctypeDefinition,
        columns : Array(String),
        location : Time::Location? = nil,
      ) : Array(String)
        columns.map do |key|
          case key
          when ID_COLUMN    then id
          when "created_at" then timestamp_cell(created_at, location)
          when "updated_at" then timestamp_cell(updated_at, location)
          else
            field = definition.fields[key]?
            next "" if field.nil?
            view_field_cell(content[key]?, field, location)
          end
        end
      end

      # Strips the server-managed fields (computed, read-only, replicated)
      # from a JSON-format row's content object. The CSV decode drops their
      # columns for the same reason — `Document::Validation` rejects user
      # writes that set them — and the compute path re-derives them.
      def self.strip_server_managed(content : JSON::Any, definition : Doctype::DoctypeDefinition) : Hash(String, JSON::Any)
        out = {} of String => JSON::Any
        obj = content.as_h? || {} of String => JSON::Any
        obj.each do |name, value|
          field = definition.fields[name]?
          next if field.nil? || server_managed_field?(field)
          out[name] = value
        end
        out
      end

      # Decodes one CSV row against the given header. Returns the row id
      # (`nil` when the cell or the whole column is empty — the manifest
      # resolves a generated ULID) and the decoded content.
      #
      # An empty cell decodes to an explicit `null` (clears the field on
      # update). A column missing from the header leaves the field
      # untouched — no entry in the decoded content. Server-managed fields
      # are export-only and never enter the decode target.
      def self.decode_row(headers : Array(String), cells : Array(String), definition : Doctype::DoctypeDefinition) : {id: String?, content: Hash(String, JSON::Any)}
        if cells.size != headers.size
          raise RowError.new(nil, "row has #{cells.size} cells but the header declares #{headers.size} columns")
        end

        index = {} of String => Int32
        headers.each_with_index do |name, i|
          if index.has_key?(name)
            raise RowError.new(name, "duplicate column '#{name}'")
          end
          index[name] = i
        end

        headers.each do |name|
          next if name == ID_COLUMN || definition.fields.has_key?(name)
          raise RowError.new(name, "column '#{name}' is not a field of #{definition.domain}.#{definition.doctype}")
        end

        id : String? = nil
        if i = index[ID_COLUMN]?
          id = cells[i] unless cells[i].empty?
        end

        content = {} of String => JSON::Any
        definition.fields.each do |name, field|
          next if server_managed_field?(field)
          i = index[name]?
          next if i.nil?
          content[name] = decode_cell(cells[i], name, field)
        end

        {id: id, content: content}
      end

      # ── Encode ────────────────────────────────────────────────────

      private def self.encode_cell(value : JSON::Any?, field : Doctype::FieldDefinition) : String
        return "" if value.nil? || value.raw.nil?
        return value.to_json if field.collection

        type_name = field.type.try(&.type_name) || ""
        scalar_cell(value, type_name) || value.to_json
      end

      # Cell text for the scalar conventions, or `nil` when the type is a
      # structured one (period, dateperiod, object, array, dictionary,
      # child, any, data) — or when the stored shape sits outside its
      # type's own convention. The caller falls back to JSON, which keeps
      # every cell round-trip safe.
      private def self.scalar_cell(value : JSON::Any, type_name : String) : String?
        if TEXT_TYPES.includes?(type_name)
          value.as_s?.try { |text| formula_guarded(text) }
        elsif NUMBER_TYPES.includes?(type_name)
          int_cell(value)
        elsif type_name == "boolean"
          boolean_cell(value)
        elsif type_name == "money"
          money_cell(value)
        end
      end

      # Formula-injection guard: one leading `'` on a text cell that starts
      # with a trigger character. The spreadsheet shows the text and skips
      # evaluation. `text_cell` strips the same prefix on decode, so the
      # round trip keeps the stored value. RFC-4180 quoting alone does not
      # stop a sheet from evaluating the cell, so the prefix is the guard.
      private def self.formula_guarded(text : String) : String
        first = text[0]?
        return text unless first && FORMULA_TRIGGERS.includes?(first)
        "'#{text}"
      end

      private def self.int_cell(value : JSON::Any) : String?
        value.as_i64?.try(&.to_s)
      end

      private def self.boolean_cell(value : JSON::Any) : String?
        b = value.as_bool?
        return nil unless b
        b ? "true" : "false"
      end

      # `"<currency> <value>"` as one literal string. The stored `value`
      # string is written verbatim after the ticker — never a re-formatted
      # float. A money object that lacks a member falls back to JSON (`nil`
      # return) so a malformed stored shape stays round-trip safe.
      private def self.money_cell(value : JSON::Any) : String?
        obj = value.as_h?
        return nil unless obj
        currency = obj["currency"]?.try(&.as_s?)
        amount = obj["value"]?.try(&.as_s?)
        return nil if currency.nil? || amount.nil?
        "#{currency} #{amount}"
      end

      # The system timestamp cell: `YYYY-MM-DD HH:MM:SS` in the export
      # timezone, UTC RFC-3339 when no timezone was requested (the full
      # export's contract, and the defensive default).
      private def self.timestamp_cell(time : Time, location : Time::Location?) : String
        return time.to_rfc3339 if location.nil?
        time.in(location).to_s("%Y-%m-%d %H:%M:%S")
      end

      # A doctype field cell for a view export: the shared type-aware
      # codec, with the `datetime` shift applied when an export timezone
      # was requested.
      private def self.view_field_cell(value : JSON::Any?, field : Doctype::FieldDefinition, location : Time::Location?) : String
        cell = encode_cell(value, field)
        return cell if cell.empty? || location.nil?
        return cell unless field.type.try(&.type_name) == "datetime"
        shift_datetime_cell(cell, location)
      end

      # Shifts one datetime cell from its stored UTC RFC-3339 form into the
      # export timezone. A stored value outside the ISO-8601 grammar (a
      # malformed row, a JSON array from a collection field) stays verbatim.
      private def self.shift_datetime_cell(cell : String, location : Time::Location) : String
        time = Time.parse_iso8601(cell)
        time.in(location).to_s("%Y-%m-%d %H:%M:%S")
      rescue Time::Format::Error
        cell
      end

      # ── Decode ────────────────────────────────────────────────────────

      # Computed (`data`), read-only, and replicated fields are
      # export-only: `Document::Validation` rejects user writes that set
      # them, so decode drops the columns and `Document::Update`'s patch
      # semantics keep the stored values untouched.
      private def self.server_managed_field?(field : Doctype::FieldDefinition) : Bool
        field.computed? || field.read_only? || field.replicated?
      end

      private def self.decode_cell(raw : String, field_name : String, field : Doctype::FieldDefinition) : JSON::Any
        return JSON::Any.new(nil) if raw.empty?

        return parse_json_cell(raw, field_name) if field.collection

        type_name = field.type.try(&.type_name) || ""
        if TEXT_TYPES.includes?(type_name)
          text_cell(raw, field_name, type_name)
        elsif NUMBER_TYPES.includes?(type_name)
          number_cell(raw, field_name)
        elsif type_name == "boolean"
          decode_boolean(raw, field_name)
        elsif type_name == "money"
          decode_money(raw, field_name)
        else
          parse_json_cell(raw, field_name)
        end
      end

      private def self.text_cell(raw : String, field_name : String, type_name : String) : JSON::Any
        # One leading `'` marks the formula-injection guard added on encode
        # — strip it before the type rules apply.
        raw = raw.lchop("'") if raw.starts_with?('\'')
        # A secret marker object rides as JSON; a stage handle stays text.
        return parse_json_cell(raw, field_name) if type_name == "secret" && raw.starts_with?("{")
        JSON::Any.new(raw)
      end

      private def self.number_cell(raw : String, field_name : String) : JSON::Any
        i = raw.to_i64?
        if i.nil?
          raise RowError.new(field_name, "must be an integer (got '#{raw}')")
        end
        JSON::Any.new(i)
      end

      private def self.decode_boolean(raw : String, field_name : String) : JSON::Any
        case raw
        when "true"  then JSON::Any.new(true)
        when "false" then JSON::Any.new(false)
        else
          raise RowError.new(field_name, "must be 'true' or 'false' (got '#{raw}')")
        end
      end

      # A money cell is `"<currency> <amount>"` — the currency prefix is
      # required, because a spreadsheet cell must not guess a currency. The
      # cell parses through the `Util::MoneyFilterValue` grammar, which
      # validates the ticker against the currency registry and the amount
      # as a decimal. The decoded value echoes the amount text verbatim and
      # builds the structured `{"value", "currency"}` object before the row
      # reaches `Document::Create` / `Document::Update`.
      private def self.decode_money(raw : String, field_name : String) : JSON::Any
        match = raw.match(/^([A-Z]{3})\s+(.+)$/)
        if match.nil?
          raise RowError.new(field_name, "requires a currency prefix (e.g. 'USD 1.0') — got '#{raw}'")
        end

        begin
          Util::MoneyFilterValue.parse(raw)
        rescue ex : ArgumentError
          raise RowError.new(field_name, ex.message.to_s)
        end

        JSON::Any.new({
          "value"    => JSON::Any.new(match[2]),
          "currency" => JSON::Any.new(match[1]),
        })
      end

      private def self.parse_json_cell(raw : String, field_name : String) : JSON::Any
        JSON.parse(raw)
      rescue ex : JSON::ParseException
        raise RowError.new(field_name, "is not valid JSON: #{ex.message}")
      end
    end
  end
end
