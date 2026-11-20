# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./doctype_definition"
require "../templating"
require "../error"

module Facet
  module Doctype
    module CollectionView
      # Authoring-time validation for the calendar `title_template` on a
      # `core.CollectionView`.
      #
      # The template renders client-side (see
      # `frontend/src/lib/templating.ts`) against the parent doctype's
      # document content, so the backend cannot render it — but it can
      # reject a template that could never render meaningfully: a syntax
      # error, or a root variable the parent doctype does not declare.
      # Without this gate such a template lands silently and every chip
      # degrades to the fallback label.
      #
      # The rules mirror the doctype-template validation in
      # `Doctype::Validation.validate_template`:
      #
      # - The template must compile (`Templating::Engine.roots`).
      # - Every root variable must reference a declared field of the
      #   **parent** doctype, the reserved `content` variable, or a system
      #   timestamp (`created_at` / `updated_at` — every projection row
      #   carries them).
      # - The `display_name` root is rejected: the client renderer does not
      #   bind it, and the display name is already what a chip shows when
      #   the view stores no template.
      #
      # Runs from the doctype-keyed authoring branches in `Document::Create`
      # and `Document::Update`, and from the portable-import authoring gate.
      module TitleTemplate
        # The config path the template lives at — also the `field` value of
        # every raised error, following the ValidationError field-path
        # convention.
        FIELD_PATH = "config.calendar.title_template"

        # System-managed timestamp roots. Not part of a doctype definition's
        # declared fields, but present on every projection row the client
        # renders (the same two the view editor offers as table columns).
        SYSTEM_ROOTS = Set{"created_at", "updated_at"}

        # Validates the raw template string against the parent doctype's
        # definition. Returns one `ValidationError` per problem; a nil,
        # blank, or whitespace-only template passes (the view then falls
        # back to the document's display name client-side).
        def self.validate(
          template : String?,
          parent_definition : DoctypeDefinition,
        ) : Array(ValidationError)
          errors = [] of ValidationError
          return errors if template.nil? || template.strip.empty?

          roots = begin
            Templating::Engine.roots(template)
          rescue ex : Templating::Error
            errors << ValidationError.new(
              field: FIELD_PATH,
              message: ex.message || "invalid template",
              code: "template",
            )
            return errors
          end

          roots.each do |root|
            next if root == Templating::Context::CONTENT_VARIABLE
            next if parent_definition.fields.has_key?(root)
            next if SYSTEM_ROOTS.includes?(root)
            if root == Templating::Context::DISPLAY_NAME_VARIABLE
              errors << ValidationError.new(
                field: FIELD_PATH,
                message: "title template must not reference the display_name column — the chip falls back to it when no template is set",
                code: "template",
              )
            else
              errors << ValidationError.new(
                field: FIELD_PATH,
                message: "title template: '#{root}' is not defined in the doctype fields",
                code: "template",
              )
            end
          end
          errors
        end
      end
    end
  end
end
