# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../error"
require "../rbac/grant"

module Facet
  module App
    # Authoring-time validation for the `app.App` `grants` field.
    #
    # Runs from the doctype-keyed branches in `Document::Create` and
    # `Document::Update` (the `core.DomainGrant` precedent): every entry
    # must parse as a `Grant`, and every target must be concrete. The
    # wildcard form (`crm.*`) is refused — an application names the
    # doctypes it uses, one entry each, so the setup-time usability check
    # (`GrantResolver.role_usable?`) and the runtime enforcer agree entry
    # by entry, carve-outs included. Malformed entries are refused with
    # the same gate instead of failing at first request (a grant that
    # cannot parse would 401 the app's key on every route, naming
    # nothing).
    module GrantsAuthoring
      # Validates the raw `grants` value. Returns one `ValidationError`
      # per offending entry, `field` carrying the entry index
      # (`grants[0].target`). `nil` (field absent) passes — the doctype
      # default applies.
      def self.validate(raw : JSON::Any?) : Array(ValidationError)
        errors = [] of ValidationError
        return errors if raw.nil?

        entries = raw.as_a?
        unless entries
          errors << ValidationError.new(
            field: "grants",
            message: "App grants must be an array of {target, actions} objects",
            code: "schema",
          )
          return errors
        end

        entries.each_with_index do |entry, i|
          grant = begin
            RBAC::Grant.from_json(entry)
          rescue ex : ArgumentError
            errors << ValidationError.new(
              field: "grants[#{i}]",
              message: ex.message || "Grant entry is malformed",
              code: "schema",
            )
            next
          end
          next unless grant.wildcard_target?
          errors << ValidationError.new(
            field: "grants[#{i}].target",
            message: "Wildcard grant target '#{grant.target}' is not allowed — name the concrete doctype the app uses",
            code: "wildcard_target",
          )
        end
        errors
      end
    end
  end
end
