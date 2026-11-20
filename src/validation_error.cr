# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  # A single structured validation error.
  #
  # Carries a `field` path (nil for non-field-scoped errors like Lua script
  # rejections, RBAC permission checks, or compute failures) and a stable
  # `code` tag so clients can branch on machine-readable categories instead
  # of parsing human-readable messages.
  #
  # Field paths use dot-separated segments. Array indices are bare numeric
  # segments, so `items[3]["name"]` is reported as `items.3.name` and
  # `period["start"]` as `period.start`. The frontend groups errors by the
  # leading segment to attribute them to top-level form fields.
  struct ValidationError
    include JSON::Serializable

    # Dot-separated field path, or `nil` for general (non-field) errors
    # (script rejections, RBAC, compute, schema-level doctype failures).
    getter field : String?

    # Human-readable explanation. Wording may change — clients should
    # branch on `code`, not on substrings of `message`.
    getter message : String

    # Stable machine-readable category tag. See the table below for the
    # canonical set used by Facet services.
    #
    # | code              | Producers                                                  |
    # | ----------------- | --------------------------------------------------------- |
    # | `required`        | required field missing or null                             |
    # | `invalid_type`    | value does not match the field's declared type            |
    # | `unknown_field`   | input contains a key absent from the doctype definition    |
    # | `read_only`       | a read-only / replicated field was set by the caller       |
    # | `reserved`        | a system-reserved field name was used                     |
    # | `unique`          | a `unique: true` constraint was violated                   |
    # | `invalid_format`  | value present but malformed (pattern, ISO date, …)        |
    # | `inactive_currency` | money value points at a registered but inactive currency (Document::MoneyCurrencyCheck) |
    # | `out_of_range`    | numeric / length-bound violation (e.g. period start ≥ end, string shorter than `min`)        |
    # | `compute`         | a compute function called `error(msg)`                   |
    # | `compute_runtime` | a compute function raised an unexpected exception         |
    # | `script`          | a lifecycle hook or action called `ctx.error(msg)`         |
    # | `rbac`            | authoring-time RBAC permission validation failed          |
    # | `context_set`     | a domain context set definition was malformed             |
    # | `named_scope`     | a doctype named scope referenced an undeclared context set  |
    # | `schema`          | doctype-definition-level validation failure               |
    # | `template`        | DocumentView template structural validation failure       |
    # | `argument`        | an action argument was missing or invalid                 |
    getter code : String?

    # Structured interpolations for a templated `code`, so a client can
    # render the text itself instead of pasting `message`. Producers stamp
    # only what their message interpolates today; the names come from a
    # small standardized set:
    #
    # - `value`   — the offending value (or the identifier that stands in
    #   for one: a ticker, an enum key, a target doctype)
    # - `expected` — description of the expected type (`invalid_type`)
    # - `format`  — description of the expected format (`invalid_format`)
    # - `allowed` — the allowed value list (`invalid_format`)
    # - `min` / `max` — numeric or length bounds (`too_long`, `out_of_range`)
    # - `reason`  — free-text bound rule (`out_of_range`)
    #
    # `message` stays the universal fallback: it is never localized and it
    # is what consumers that do not render (MCP, webhooks, logs) display.
    # The serialization omits `params` when nil so the wire form stays
    # short for producers that do not stamp.
    getter params : Hash(String, String)?

    def initialize(
      @message : String,
      @field : String? = nil,
      @code : String? = nil,
      @params : Hash(String, String)? = nil,
    )
    end

    # Compact JSON: omits `field`, `code`, and `params` when nil so the
    # wire form stays short for the common case
    # (`{"field": "subject", "message": "...", "code": "required"}`).
    def to_json(builder : JSON::Builder) : Nil
      builder.object do
        builder.field("field", field) unless field.nil?
        builder.field("message", message)
        builder.field("code", code) unless code.nil?
        builder.field("params", params) unless params.nil?
      end
    end
  end
end
