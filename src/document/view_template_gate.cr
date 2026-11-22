# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../doctype/view_template_validator"
require "../validation_error"

module Facet
  module Document
    # Write-time semantic gate for the `core.DocumentView` `template` field.
    #
    # The template is a free-form `object` field at the document layer — the
    # definition declares no properties, so the generic schema validation
    # accepts any nested shape. This gate runs
    # `Doctype::ViewTemplateValidator` against the parent doctype's
    # definition and refuses the `:error` issues (nodes the frontend cannot
    # render or the form cannot save) with a 422 at the document write
    # doors. The assistant write tools run the same validator before their
    # mutations, so every door that stores a view now blocks malformed
    # trees.
    #
    # `:warning` issues stay non-blocking: the assistant door reports them
    # in its success payload, `Doctype::Check` names them post-hoc, and the
    # renderer normalizes the shapes it can (duplicate relation column keys
    # included — the first occurrence wins).
    module ViewTemplateGate
      # Validates a whole `core.DocumentView` content object — reads its
      # `template` key and checks it. Used by the create door. The update
      # door validates the SUBMITTED template value (replace-on-write, see
      # `Document::Update::REPLACE_ON_WRITE_FIELDS`), so it calls
      # `template_errors` with the value directly.
      def self.errors(
        db : DB::Connection,
        parent_id : String?,
        document : JSON::Any,
      ) : Array(ValidationError)
        template_errors(db, parent_id, document["template"]?)
      end

      # Validates a template value against the parent doctype definition
      # (`core.DocType` id — the projection the view attaches to). Returns
      # one `ValidationError` per `:error` issue, empty when there is
      # nothing to check: no template, no parent id, an unresolvable parent
      # definition, or a clean tree. Shared by the create and update
      # dispatches.
      def self.template_errors(
        db : DB::Connection,
        parent_id : String?,
        template : JSON::Any?,
      ) : Array(ValidationError)
        return [] of ValidationError unless template
        return [] of ValidationError unless parent_id

        case defn = Doctype::DefinitionStore.fetch!(db, parent_id)
        when Doctype::DoctypeDefinition
          issues = Doctype::ViewTemplateValidator.validate(template, defn)
          Doctype::ViewTemplateValidator.errors(issues).map do |issue|
            ValidationError.new(issue.message, issue.path, "template")
          end
        else
          # An absent or corrupt parent definition skips the check — the
          # write path's other guards own that failure.
          [] of ValidationError
        end
      end
    end
  end
end
