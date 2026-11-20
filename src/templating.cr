# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "crinja"
require "json"
require "./doctype/doctype_definition"

# Jinja2 template rendering for derived document surfaces (`display_name`,
# `search`). Wraps Crinja with the project's conventions:
#
# - Templates are plain text. Autoescape is off.
# - Compiled templates are cached per source string. The template set is the
#   set of doctype definitions, so the cache is bounded.
# - Missing document fields render empty. They never raise — an absent
#   optional field is a normal data state. Genuine template errors (bad
#   syntax, unknown filter, type error) raise `Templating::Error` and fail
#   the mutation.
# - Variable roots are collectable for authoring-time validation.
module Facet
  module Templating
    # Raised when a template fails to compile or render. Carries the Crinja
    # message; the caller surfaces it as an HTTP error (the mutation is
    # rejected and its transaction rolls back).
    class Error < ::Exception; end

    # Resolves a reference field to the referenced document's stored label.
    # The same protocol as `Document::DisplayName::ReferenceResolver`.
    abstract class ReferenceResolver
      # Returns the stored `display_name` for the referenced document, or
      # nil when the target row does not exist or has no display_name.
      abstract def resolve(qualified_target_doctype : String, doc_id : String) : String?
    end
  end
end

require "./templating/engine"
require "./templating/context"
