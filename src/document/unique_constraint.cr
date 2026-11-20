# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../validation_error"
require "../doctype/doctype_definition"

module Facet
  module Document
    # Shared `unique: true` constraint checker.
    #
    # Both `Document::Create` and `Document::Update` enforce the constraint
    # against the `projections` table: a non-deleted row of the same doctype
    # already holds the value. The update path additionally excludes the
    # target document's own row, so a document may keep its existing value.
    #
    # Only scalar top-level values participate. Null, absent, and
    # non-scalar (object/array) values are not constrained — matching the
    # create-time behaviour.
    module UniqueConstraint
      # Returns structured errors for every unique field whose value on
      # `document` collides with a non-deleted row of the same doctype.
      #
      # `exclude_id` excludes the target document's own row (update path);
      # pass `nil` on create.
      def self.check(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        exclude_id : String? = nil,
      ) : Array(ValidationError)
        errors = [] of ValidationError
        doc_hash = document.as_h?
        return errors if doc_hash.nil?

        definition.fields.each do |field_name, field|
          next unless field.unique

          value = doc_hash[field_name]?
          next if value.nil? || value.raw.nil?

          val_str = scalar_string(value.raw)
          next if val_str.nil?

          # `exclude_sql` narrows out the target document's own row on the
          # update path; absent on create, so the query stays 3-arg.
          args = [domain, doc_type, val_str] of ::DB::Any
          exclude_sql = ""
          if exclude_id
            exclude_sql = "AND id <> $4"
            args << exclude_id
          end

          existing = db.query_one?(
            <<-SQL,
             SELECT 1 FROM projections
             WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL
               AND content->>'#{field_name}' = $3 #{exclude_sql}
             LIMIT 1
            SQL


            args: args,
            as: Int32
          )
          if existing
            errors << ValidationError.new(
              field: field_name,
              message: "must be unique, but value '#{val_str}' already exists",
              code: "unique",
              params: {"value" => val_str},
            )
          end
        end

        errors
      end

      # Converts a JSON scalar to the string form used for the
      # `content->>'field'` comparison. Returns `nil` for non-scalar values.
      private def self.scalar_string(raw) : String?
        case raw
        when String  then raw
        when Int64   then raw.to_s
        when Float64 then raw.to_s
        when Bool    then raw.to_s
        else              nil
        end
      end
    end
  end
end
