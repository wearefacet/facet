# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet::Settings
  # Registry and validation of the allowed preference keys.
  #
  # Every writable `(app, key)` pair must have a `Descriptor` registered here.
  # `Service.update` rejects unregistered pairs with HTTP 422 so the
  # `account_settings` table cannot become an unvalidated dumping ground.
  # Adding a preference = adding one entry to `REGISTRY`.
  module Keys
    # Value kind accepted for a preference key.
    enum Kind
      String
      Bool
      Object
      Array
    end

    # Descriptor for one preference key under one application.
    record Descriptor,
      app : String,
      key : String,
      kind : Kind,
      default : JSON::Any

    # The registered set of preference keys. The hash is keyed by
    # `{app, key}` to disambiguate keys across application scopes.
    REGISTRY = {
      {"core", "timezone"}                => Descriptor.new("core", "timezone", Kind::String, JSON::Any.new("UTC")),
      {"core", "language"}                => Descriptor.new("core", "language", Kind::String, JSON::Any.new("en")),
      {"core", "pinned_doctypes"}         => Descriptor.new("core", "pinned_doctypes", Kind::Array, JSON::Any.new([] of JSON::Any)),
      {"core", "pinned_collection_views"} => Descriptor.new("core", "pinned_collection_views", Kind::Array, JSON::Any.new([] of JSON::Any)),
      # Gates the first-run welcome tour for the account. The tour's dismiss
      # checkbox and final CTAs write `false`; the Settings page writes `true`
      # to replay the tour on the next app load.
      {"core", "show_welcome"} => Descriptor.new("core", "show_welcome", Kind::Bool, JSON::Any.new(true)),
      # Gates the client-side in-app delivery (bell, badge, WebSocket
      # subscription). `Send` ignores it: inserts are unconditional, so
      # re-enabling shows the notifications accrued while muted.
      {"notifications", "in_app"} => Descriptor.new("notifications", "in_app", Kind::Bool, JSON::Any.new(true)),
    } of {String, String} => Descriptor

    # Allowed language codes. Adding a language is a one-line change.
    ALLOWED_LANGUAGES = Set{"en", "fr"}

    # Account keys whose default is a server-level policy instead of the
    # static registry default. The mapping names the `core.SystemSettings`
    # path each key reads: an account with no row of its own follows the
    # server default (the instance's `localization.*` setting), and the
    # registry default stays the last tier for a fresh install whose
    # settings document is missing. See `Service.default_for`.
    SERVER_DEFAULTS = {
      {"core", "timezone"} => "localization.default_timezone",
      {"core", "language"} => "localization.default_language",
    } of {String, String} => String

    # Returns the descriptor for an `(app, key)` pair, or `nil` if it is not
    # registered.
    def self.descriptor?(app : String, key : String) : Descriptor?
      REGISTRY[{app, key}]?
    end

    # Lists the descriptors registered for one application scope.
    def self.for_app(app : String) : Array(Descriptor)
      REGISTRY.values.select { |d| d.app == app }
    end

    # Validates an `(app, key, value)` triple against the registry.
    # Returns `nil` on success, or an error message on failure.
    def self.validate(app : String, key : String, value : JSON::Any) : String?
      descriptor = descriptor?(app, key)
      return "Unknown setting '#{app}.#{key}'" if descriptor.nil?

      message = validate_kind(descriptor, value)
      return message if message

      validate_value(descriptor, value)
    end

    # Checks that the JSON value matches the descriptor's kind.
    private def self.validate_kind(descriptor : Descriptor, value : JSON::Any) : String?
      case descriptor.kind
      when Kind::String
        value.as_s? ? nil : "Setting '#{descriptor.app}.#{descriptor.key}' must be a string"
      when Kind::Bool
        # `value.as_bool?` returns the value itself for a real `false`, which is
        # falsy — test the raw type so both booleans pass.
        value.raw.is_a?(Bool) ? nil : "Setting '#{descriptor.app}.#{descriptor.key}' must be a boolean"
      when Kind::Object
        value.as_h? ? nil : "Setting '#{descriptor.app}.#{descriptor.key}' must be an object"
      when Kind::Array
        value.as_a? ? nil : "Setting '#{descriptor.app}.#{descriptor.key}' must be an array"
      end
    end

    # Value-level validation for keys whose string values have an allow-list.
    private def self.validate_value(descriptor : Descriptor, value : JSON::Any) : String?
      case {descriptor.app, descriptor.key}
      when {"core", "timezone"}
        # Must be a loadable IANA timezone. `UTC` is always valid.
        name = value.as_s
        begin
          Time::Location.load(name)
          nil
        rescue ex
          "Invalid timezone '#{name}': #{ex.message}"
        end
      when {"core", "language"}
        ALLOWED_LANGUAGES.includes?(value.as_s) ? nil : "Unsupported language '#{value.as_s}'"
      when {"core", "pinned_doctypes"}
        validate_pinned_doctypes(value)
      when {"core", "pinned_collection_views"}
        validate_pinned_collection_views(value)
      else
        nil
      end
    end

    # Validates the `pinned_doctypes` array: every element must be a qualified
    # doctype name (`domain.Doctype`).
    private def self.validate_pinned_doctypes(value : JSON::Any) : String?
      items = value.as_a
      items.each do |item|
        return "pinned_doctypes must only contain strings" unless item.as_s?
        name = item.as_s
        parts = name.split('.', 2)
        if parts.size != 2 || parts[0].empty? || parts[1].empty?
          return "Invalid doctype name '#{name}'"
        end
      end
      nil
    end

    # Validates the `pinned_collection_views` array: every element must be a
    # non-empty CollectionView projection id (a ULID, globally unique — no
    # doctype qualifier is stored).
    private def self.validate_pinned_collection_views(value : JSON::Any) : String?
      items = value.as_a
      items.each do |item|
        return "pinned_collection_views must only contain strings" unless item.as_s?
        return "pinned_collection_views must not contain empty strings" if item.as_s.empty?
      end
      nil
    end
  end
end
