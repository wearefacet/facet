# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

require "../database"
require "../error"
require "../event"

module Facet
  module Assistant
    # Neutral tool-result envelope, shared by every assistant surface
    # (`DomainBuilder::Registrar` and the workspace registrar).
    #
    # A tool callback returns a JSON string. A success payload is
    # `{"ok":true,"data":...}`. An error payload is
    # `{"ok":false,"error":"...","details":[...]}` so the LLM can recover.
    #
    # `tool_mutation` runs one write-tool call: it opens (or joins) a
    # transaction, calls the service, flushes queued events on success, and
    # renders the envelope.
    module Tools
      # Renders a JSON success string for a tool callback.
      def self.ok(data) : String
        {ok: true, data: data}.to_json
      end

      # Renders a JSON error string for a tool callback. `details` carries
      # validation errors; the key is omitted when absent or empty.
      def self.error(message : String, details : Array(ValidationError)? = nil) : String
        if details && !details.empty?
          {ok: false, error: message, details: details}.to_json
        else
          {ok: false, error: message}.to_json
        end
      end

      # Converts a registry tool schema (`AgentTools::Registry::Entry#input_schema`,
      # a parsed JSON-Schema object) into the `parameters:` shape that
      # `Agent#register_tool` accepts. Tool schemas stay defined once, in
      # the registry: assistant registrars expose the same name,
      # description, and schema that MCP clients see.
      def self.schema_parameters(input_schema : JSON::Any) : Hash(String, JSON::Any)
        schema = input_schema.as_h?
        raise ArgumentError.new("Tool input_schema must be a JSON object, got: #{input_schema.inspect}") unless schema
        schema
      end

      # Builds a JSON-Schema object describing an object with the given
      # properties and required keys. Property values are written verbatim
      # into the schema — callers pass the same `{"type" => "string"}`-shape
      # the OpenAI tools API expects. A property value may nest hashes (an
      # `items` schema) and carry scalar constraints (`minItems`); nesting
      # recurses.
      def self.schema_object(
        properties : Hash(String, Hash(String, V)),
        required : Array(String),
      ) : Hash(String, JSON::Any) forall V
        props = {} of String => JSON::Any
        properties.each do |name, schema|
          h = {} of String => JSON::Any
          schema.each { |k, v| h[k] = schema_value(v) }
          props[name] = JSON::Any.new(h)
        end
        {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new(props),
          "required"   => JSON::Any.new(required.map { |r| JSON::Any.new(r) }),
        }
      end

      # Wraps one property-schema value as JSON::Any. Scalars wrap directly;
      # nested hashes recurse, so an `items` schema survives as an object.
      private def self.schema_value(value : String | Int | Float | Bool | Hash(String, V)) : JSON::Any forall V
        case value
        when String then JSON::Any.new(value)
        when Int    then JSON::Any.new(value.to_i64)
        when Float  then JSON::Any.new(value.to_f64)
        when Bool   then JSON::Any.new(value)
        else
          h = {} of String => JSON::Any
          value.each { |k, v| h[k] = schema_value(v) }
          JSON::Any.new(h)
        end
      end

      # Runs one write-tool mutation: opens (or joins) a transaction, calls
      # the service, flushes queued events on success, and renders the tool
      # envelope. `service` must return a `{{result_type}} |
      # Facet::ServiceError` union; the block runs on the success variant and
      # must return its payload via `ok`. Any unexpected exception escapes to
      # the agent-cr tool-call error handler.
      macro tool_mutation(db, service, result_type, &block)
        ::Facet::Database.with_transaction({{db}}, ignore_if_set: true) do |txn|
          result = {{service}}
          case result
          in {{result_type}}
            ::Facet::Event::Publisher.flush
            {{block.body}}
          in ::Facet::ServiceError
            ::Facet::Assistant::Tools.error(result.message, result.details)
          end
        end
      end
    end
  end
end
