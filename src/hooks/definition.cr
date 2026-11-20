# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Hooks
    module Definition
      # One hook declared on `core.Domain.content.hooks`.
      #
      # `kind` is `:event` or `:schedule`. For an `event` hook the `source_*`
      # fields select which source mutations fire the hook. For a `schedule`
      # hook `schedule` holds the 5-field cron expression.
      #
      # Parsed from the `core.Domain` projection's `content.hooks` array —
      # there is no dedicated `Domain::Definition` class today, so this
      # mirrors how `Grants::Registry` reads grant documents inline from
      # the projections table.
      record Hook,
        id : String,
        kind : Symbol,
        script : String,
        # `:event` source selector. `source_domain` is required; the other
        # two are optional (nil / nil means "all doctypes / all events").
        source_domain : String?,
        source_doc_type : String?,
        source_events : Array(String)?,
        # `:schedule` cron expression (5-field, UTC).
        schedule : String?,
        # The domain whose projection declares this hook. Set by
        # `Hooks::Registry#build` (which knows the owning `core.Domain`
        # row) and used by `Hooks::Handler`/`Hooks::Scheduler` to pin
        # `document.*` writes to the owning domain. `nil` when the hook
        # comes from `Definition.parse` directly (authoring-time path).
        owning_domain : String? = nil do
        # Returns a copy of this hook with `owning_domain` stamped.
        # Used by the registry build path — `Definition.parse` does
        # not know which domain projection a hook was parsed from.
        def with_owning_domain(domain : String) : Hook
          Hook.new(
            id: id,
            kind: kind,
            script: script,
            source_domain: source_domain,
            source_doc_type: source_doc_type,
            source_events: source_events,
            schedule: schedule,
            owning_domain: domain,
          )
        end
      end

      # Parses the `hooks` array from a `core.Domain` projection's content.
      #
      # Returns a tuple `{hooks, errors}`. When `content` has no `hooks`
      # key the array is empty and the errors list is empty — a domain that
      # declares no hooks is valid (backward compatible with domains created
      # before this feature). Malformed entries are recorded as
      # `ValidationError`s rather than raised; the caller (the authoring
      # gate in `Document::Update`, or the `/check` diagnostic in
      # `Domain::Check`) decides whether to reject or warn.
      def self.parse(content : JSON::Any) : {Array(Hook), Array(Facet::ValidationError)}
        hooks = [] of Hook
        errors = [] of Facet::ValidationError

        raw = content["hooks"]?
        return {hooks, errors} if raw.nil?

        arr = raw.as_a?
        unless arr
          errors << error("hooks", "'hooks' must be an array of objects")
          return {hooks, errors}
        end

        arr.each_with_index do |entry, index|
          parse_entry(entry, index, hooks, errors)
        end

        {hooks, errors}
      end

      # ── Private ──────────────────────────────────────────────────────

      private def self.parse_entry(
        entry : JSON::Any,
        index : Int32,
        hooks : Array(Hook),
        errors : Array(Facet::ValidationError),
      ) : Nil
        h = entry.as_h?
        unless h
          errors << error("hooks.#{index}", "hook entry must be an object")
          return
        end

        prefix = "hooks.#{index}"

        id = required_string(h, "id", prefix, errors)
        return if id.nil?

        kind_raw = h["kind"]?.try(&.as_s?)
        unless kind_raw
          errors << error("#{prefix}.kind", "hook '#{id}' is missing 'kind' (expected 'event' or 'schedule')")
          return
        end

        kind = case kind_raw
               when "event"    then :event
               when "schedule" then :schedule
               else
                 errors << error("#{prefix}.kind", "hook '#{id}' has unsupported kind '#{kind_raw}' (expected 'event' or 'schedule')")
                 return
               end

        script = required_string(h, "script", prefix, errors)
        return if script.nil?

        case kind
        when :event
          source = h["source"]?.try(&.as_h?)
          source_domain = required_string(source, "domain", "#{prefix}.source", errors)
          return if source_domain.nil?

          source_doc_type = optional_string(source, "doc_type")
          source_events = optional_string_array(source, "events")

          hooks << Hook.new(
            id: id,
            kind: :event,
            script: script,
            source_domain: source_domain,
            source_doc_type: source_doc_type,
            source_events: source_events,
            schedule: nil,
          )
        when :schedule
          schedule = required_string(h, "schedule", prefix, errors)
          return if schedule.nil?

          hooks << Hook.new(
            id: id,
            kind: :schedule,
            script: script,
            source_domain: nil,
            source_doc_type: nil,
            source_events: nil,
            schedule: schedule,
          )
        end
      end

      private def self.required_string(
        h : Hash(String, JSON::Any)?,
        key : String,
        prefix : String,
        errors : Array(Facet::ValidationError),
      ) : String?
        if h.nil?
          errors << error("#{prefix}.#{key}", "field '#{key}' is required")
          return nil
        end

        value = h[key]?
        if value.nil?
          errors << error("#{prefix}.#{key}", "field '#{key}' is required")
          return nil
        end

        str = value.as_s?
        unless str
          errors << error("#{prefix}.#{key}", "field '#{key}' must be a string")
          return nil
        end

        if str.empty?
          errors << error("#{prefix}.#{key}", "field '#{key}' must not be empty")
          return nil
        end

        str
      end

      private def self.optional_string(h : Hash(String, JSON::Any)?, key : String) : String?
        return nil if h.nil?
        h[key]?.try(&.as_s?)
      end

      private def self.optional_string_array(h : Hash(String, JSON::Any)?, key : String) : Array(String)?
        return nil if h.nil?
        value = h[key]?
        return nil if value.nil? || (arr = value.as_a?).nil?
        arr.map { |v| v.as_s? || "" }
      end

      private def self.error(field : String, message : String) : Facet::ValidationError
        Facet::ValidationError.new(field: field, message: message, code: "schema")
      end
    end
  end
end
