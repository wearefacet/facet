# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../doctype/doctype_definition"
require "../util/money"
require "../validation_error"

module Facet
  module Document
    # Lifecycle gate for `money` field values.
    #
    # Runs after schema validation: `MoneyType#validate` owns the shape of a
    # money object and the `registered?` rule (an unknown ticker fails there
    # as a `schema` error). This module owns only the active/inactive rule —
    # a money value that points at a registered but inactive currency adds an
    # `inactive_currency` error. It reads the in-process registry snapshot
    # (`Util::Currency`), so it needs no DB access, and it does not re-check
    # shapes.
    #
    # Two entry points, one per write path:
    #
    # - `check_create` runs on the full document: every money path in the
    #   document must point at an active currency.
    # - `check_update` runs on the merged document against the stored
    #   content: only money paths whose ticker changed in this update are
    #   compared. A path re-saved with the same ticker passes even when the
    #   currency row went inactive after the value was stored ("stays up and
    #   running"); switching a path to a different currency requires an
    #   active row. Untouched paths keep the same ticker by construction of
    #   the merge, so comparing tickers per path skips them — the same
    #   "only changed fields" outcome `ReferenceCheck` reaches by walking
    #   the patch.
    #
    # The walk covers nested money: recursion into array `items`, object
    # `properties`, and dictionary `values`, with the same dotted path
    # shapes the nested field types report (`prices.0`, `meta.total`,
    # `rates.EUR`).
    module MoneyCurrencyCheck
      # `Write` paths enforce the lifecycle rule. The bulk import passes
      # `Import`: a ticker that is registered but no longer active still
      # imports (the decode path only requires the ticker to be registered),
      # so a bulk replay never fails on liveness. A hand edit on the normal
      # write paths keeps the full rule.
      enum Mode
        Write
        Import
      end

      # Checks every money path of a created document: the ticker must be
      # registered (owned by `MoneyType#validate`) and active. Returns an
      # empty array when the document carries no money values or all of them
      # point at active currencies.
      def self.check_create(
        definition : Doctype::DoctypeDefinition,
        document : JSON::Any,
        mode : Mode = Mode::Write,
      ) : Array(ValidationError)
        return [] of ValidationError if mode.import?

        errors = [] of ValidationError
        doc_hash = document.as_h?
        return errors if doc_hash.nil?

        definition.fields.each do |field_name, field_def|
          walk(field_name, field_def, doc_hash[field_name]?, nil, false, errors)
        end

        errors
      end

      # Checks money paths of the merged (post-patch) document against the
      # stored content. A money path whose ticker stayed the same passes;
      # a path with a new or changed ticker must point at an active
      # currency. Money the patch removed (now null / absent) is not
      # checked — there is no new ticker to admit.
      def self.check_update(
        definition : Doctype::DoctypeDefinition,
        merged : JSON::Any,
        old_content : JSON::Any,
        mode : Mode = Mode::Write,
      ) : Array(ValidationError)
        return [] of ValidationError if mode.import?

        errors = [] of ValidationError
        merged_hash = merged.as_h?
        return errors if merged_hash.nil?

        old_hash = old_content.as_h?
        definition.fields.each do |field_name, field_def|
          walk(field_name, field_def, merged_hash[field_name]?, old_hash.try(&.[field_name]?), true, errors)
        end

        errors
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Walks one definition node against its value (and, on the update
      # path, the stored value at the same path). Recursion mirrors the
      # nested field types: array → `items`, object → `properties`,
      # dictionary → `values` (`dictionary_value`).
      private def self.walk(
        path : String,
        field_def : Doctype::FieldDefinition,
        value : JSON::Any?,
        old_value : JSON::Any?,
        compare_old : Bool,
        errors : Array(ValidationError),
      ) : Nil
        return if value.nil? || value.raw.nil?

        case field_def.type.try(&.type_name)
        when "money"
          ticker = money_ticker(value)
          return if ticker.nil?
          return if compare_old && money_ticker(old_value) == ticker
          enforce_active(path, ticker, errors)
        when "array"
          walk_array(path, field_def, value, old_value, compare_old, errors)
        when "object"
          walk_object(path, field_def, value, old_value, compare_old, errors)
        when "dictionary"
          walk_dictionary(path, field_def, value, old_value, compare_old, errors)
        end
      end

      # Recurses into array elements on the item definition, pairing each
      # element with the stored element at the same index.
      private def self.walk_array(
        path : String,
        field_def : Doctype::FieldDefinition,
        value : JSON::Any,
        old_value : JSON::Any?,
        compare_old : Bool,
        errors : Array(ValidationError),
      ) : Nil
        arr = value.as_a?
        return if arr.nil?
        items_def = field_def.items
        return if items_def.nil?

        old_arr = old_value.try(&.as_a?)
        arr.each_with_index do |item, idx|
          next if item.raw.nil?
          walk("#{path}.#{idx}", items_def, item, old_arr.try(&.[idx]?), compare_old, errors)
        end
      end

      # Recurses into declared object properties only. Unknown keys already
      # fail in `ObjectType#validate`; this walk never sees them as money.
      private def self.walk_object(
        path : String,
        field_def : Doctype::FieldDefinition,
        value : JSON::Any,
        old_value : JSON::Any?,
        compare_old : Bool,
        errors : Array(ValidationError),
      ) : Nil
        obj = value.as_h?
        return if obj.nil?
        props = field_def.properties
        return if props.nil?

        old_obj = old_value.try(&.as_h?)
        obj.each do |key, sub_value|
          sub_def = props[key]?
          next if sub_def.nil?
          next if sub_value.raw.nil?
          walk("#{path}.#{key}", sub_def, sub_value, old_obj.try(&.[key]?), compare_old, errors)
        end
      end

      # Recurses into dictionary values on the value definition, pairing
      # each key with the stored value at the same key.
      private def self.walk_dictionary(
        path : String,
        field_def : Doctype::FieldDefinition,
        value : JSON::Any,
        old_value : JSON::Any?,
        compare_old : Bool,
        errors : Array(ValidationError),
      ) : Nil
        obj = value.as_h?
        return if obj.nil?
        dict_val = field_def.dictionary_value
        return if dict_val.nil?

        old_obj = old_value.try(&.as_h?)
        obj.each do |key, sub_value|
          next if sub_value.raw.nil?
          walk("#{path}.#{key}", dict_val, sub_value, old_obj.try(&.[key]?), compare_old, errors)
        end
      end

      # Extracts the ticker of a stored money object. A value without a
      # `currency` member is skipped — `MoneyType#validate` already reports
      # the missing member as `required`.
      private def self.money_ticker(value : JSON::Any?) : String?
        obj = value.try(&.as_h?)
        obj.try { |h| h["currency"]?.try(&.as_s?) }
      end

      # Adds the inactive-currency error under the money path. An
      # unregistered ticker lands here only when the schema validation was
      # skipped or raced a registry change — it keeps failing as a `schema`
      # error in `MoneyType#validate`, so this module stays silent for it.
      private def self.enforce_active(path : String, ticker : String, errors : Array(ValidationError)) : Nil
        currency = Util::Currency.find(ticker)
        return if currency.nil?
        return if currency.active

        errors << ValidationError.new(
          field: "#{path}.currency",
          message: "must be an active currency (got '#{ticker}', which is inactive)",
          code: "inactive_currency",
          params: {"value" => ticker},
        )
      end
    end
  end
end
