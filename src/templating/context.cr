# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Templating
    # Builds the template variable bindings for a document mutation.
    #
    # Binding rules:
    #
    # - Every declared field name is bound as a top-level variable, so
    #   `{{ first_name }}` and `{{ address.postal_code }}` both work.
    # - A field missing from the content binds to a blank node — it renders
    #   empty and swallows further attribute access. An absent optional
    #   field is a normal data state, not a render error.
    # - Reference fields resolve to the referenced document's stored
    #   `display_name` via the injected `ReferenceResolver`. When
    #   resolution fails, the fallback is the target doctype's bare name,
    #   never the raw id.
    # - Money objects (a `{value, currency}` pair of strings) render as
    #   `"<currency> <value>"` instead of a JSON dump. Detection is
    #   shape-based, so nested money values format too.
    # - The raw document content tree is exposed as `content` for advanced
    #   templates (`{{ content.address.postal_code | upper }}`).
    # - The reserved `display_name` variable carries the document's display
    #   label when the caller supplies one (`Document::Search` passes it for
    #   `search` templates). A nil or empty value binds the blank node — the
    #   variable renders empty, like an absent optional field. Reserved
    #   variables bind after the field loop, so they win over a doctype
    #   field of the same name.
    module Context
      # Reserved variable that exposes the raw document content.
      CONTENT_VARIABLE = "content"

      # Reserved variable that exposes the document's display label. A
      # `search` template may reference it (`{{ display_name }}`); the
      # caller binds the already-resolved label. A `display_name` template
      # must not reference it — the validator rejects the self-reference.
      DISPLAY_NAME_VARIABLE = "display_name"

      # Builds the bindings for `content` according to `definition`.
      # `resolver` is required for reference resolution; without it,
      # reference fields fall back to the target doctype's bare name.
      # `display_name` is the document's already-resolved display label for
      # the reserved variable (nil when the caller has none).
      def self.build(
        definition : Doctype::DoctypeDefinition,
        content : JSON::Any,
        resolver : ReferenceResolver? = nil,
        display_name : String? = nil,
      ) : Crinja::Variables
        content_hash = content.as_h? || {} of String => JSON::Any

        bindings = Crinja::Variables.new
        definition.fields.each do |name, field|
          if field.reference?
            bindings[name] = Crinja::Value.new(
              resolve_reference(name, field, definition, content_hash, resolver)
            )
          elsif field.type.try(&.type_name) == "money"
            bindings[name] = Node.money(content_hash[name]?)
          elsif value = content_hash[name]?
            bindings[name] = Node.wrap(value)
          else
            bindings[name] = Node.blank
          end
        end

        # Reserved variables bind after the field loop, so they win over a
        # doctype field of the same name — the same precedence `content`
        # already has.
        if display_name.nil? || display_name.empty?
          bindings[DISPLAY_NAME_VARIABLE] = Node.blank
        else
          bindings[DISPLAY_NAME_VARIABLE] = Crinja::Value.new(display_name)
        end
        bindings[CONTENT_VARIABLE] = Node.wrap(content)
        bindings
      end

      # A content node inside the Crinja runtime. Objects resolve members
      # dynamically: a missing member resolves to the blank node, so a
      # nested path over absent optional fields renders empty instead of
      # raising. A node printed as a leaf renders empty — the same
      # behaviour the old stringify had for objects.
      #
      # `Crinja::Object` puts the class into the runtime's `Raw` union;
      # `crinja_attribute` is the name-based lookup the resolver calls.
      private class Node
        include Crinja::Object

        BLANK = new(nil)

        @data : Hash(String, JSON::Any)?

        def initialize(@data : Hash(String, JSON::Any)?)
        end

        def self.blank : Crinja::Value
          Crinja::Value.new(BLANK)
        end

        # Wraps a JSON value for the runtime:
        # - object → a walkable `Node`
        # - money-shaped object → the formatted `"<currency> <value>"` string
        # - array → a runtime array of wrapped elements
        # - scalar → the native value
        # - null / nothing → the blank node
        def self.wrap(value : JSON::Any?) : Crinja::Value
          return blank if value.nil?
          case raw = value.raw
          when Hash(String, JSON::Any)
            if money = money_string(raw)
              Crinja::Value.new(money)
            else
              Crinja::Value.new(new(raw))
            end
          when Array(JSON::Any)
            Crinja::Value.new(raw.map { |element| wrap(element) })
          when Bool, Int64, Float64, String
            Crinja::Value.new(raw)
          else
            blank
          end
        end

        def crinja_attribute(attr : Crinja::Value) : Crinja::Value
          hash = @data
          child = hash.try(&.[attr.to_string]?)
          child ? Node.wrap(child) : Node.blank
        end

        # Crinja's `Value#truthy?` treats only `false`, `0`, `nil`, and
        # `Undefined` as falsy — a custom object would always be truthy.
        # The equality hook is the one available seam: the blank node
        # compares equal to `false`, so `{% if missing_field %}` follows
        # the false branch like an absent Jinja2 value.
        def ==(other : Bool) : Bool
          @data.nil? ? !other : false
        end

        def to_s(io : IO) : Nil
        end

        # Wraps the value of a declared `money` field. A well-formed money
        # object formats as `"<currency> <value>"`; anything else (missing
        # members, a non-object value) renders empty — the validator
        # rejects these at write time, so this is a defensive path.
        def self.money(value : JSON::Any?) : Crinja::Value
          hash = value.try(&.as_h?)
          if hash && (formatted = money_string(hash))
            Crinja::Value.new(formatted)
          else
            blank
          end
        end

        # Formats a stored money value
        # (`{"value":"...","currency":"..."}`) as `"<currency> <value>"`.
        # Returns nil when the object does not carry both members as
        # strings — the caller then keeps the raw object.
        private def self.money_string(raw : Hash(String, JSON::Any)) : String?
          currency = raw["currency"]?.try(&.as_s?)
          amount = raw["value"]?.try(&.as_s?)
          return nil if currency.nil? || currency.empty? || amount.nil? || amount.empty?
          "#{currency} #{amount}"
        end
      end

      # Resolves a top-level reference field to its display label. The
      # stored value is the referenced document's id (a string, or an array
      # of strings — the first element wins; a chip is a single label).
      private def self.resolve_reference(
        name : String,
        field : Doctype::FieldDefinition,
        definition : Doctype::DoctypeDefinition,
        content_hash : Hash(String, JSON::Any),
        resolver : ReferenceResolver?,
      ) : String
        target = field.qualified_doctype
        return "" unless target

        id_str = id_from_value(content_hash[name]?)
        return target_doctype_label(target) if id_str.nil? || id_str.empty?

        qualified = qualify_target_doctype(target, definition.domain)
        resolved = resolver.try(&.resolve(qualified, id_str))
        resolved || target_doctype_label(qualified)
      end

      # Extracts the referenced doc id from a content value. Reference
      # fields may hold a single string or an array of strings.
      private def self.id_from_value(value : JSON::Any?) : String?
        return nil if value.nil?
        case raw = value.raw
        when String
          raw
        when Array(JSON::Any)
          raw.first?.try(&.as_s?)
        else
          nil
        end
      end

      # Qualifies a target doctype relative to the source domain. Bare names
      # (`"Company"`) are prefixed with the source domain; already-qualified
      # names (`"crm.Company"`) are returned unchanged.
      private def self.qualify_target_doctype(target : String, source_domain : String) : String
        target.includes?('.') ? target : "#{source_domain}.#{target}"
      end

      # Returns the bare doctype name from a qualified identifier, used as
      # the resolution fallback (e.g. `"Company"` from `"crm.Company"`).
      private def self.target_doctype_label(qualified : String) : String
        qualified.split('.').last? || qualified
      end
    end
  end
end
