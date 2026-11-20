# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./read"
require "../doctype/doctype_definition"
require "../doctype/derived_operators"
require "../mutation/client"
require "../rbac/field_visibility"

module Facet
  module Document
    # Shared response presentation for write and read surfaces.
    #
    # Every HTTP responder and agent-tool result that hands a projection
    # (or raw content) back to its caller presents it through here:
    # invisible fields and unknown content keys are omitted for Real
    # principals, System and Preview see content raw. The mask is the same
    # recursive walker the read surfaces use (`RBAC::FieldVisibility`), so
    # a write response carries exactly the shape a masked GET returns —
    # and masking an already-masked projection is a no-op (idempotent).
    #
    # Mutation services deliberately do NOT mask: internal callers need
    # raw projections. The mask lives at presentation boundaries only.
    module Presenter
      # Presents one projection's content for the caller. `definition` is
      # the projection's doctype definition; `nil` (a definition that no
      # longer resolves) keeps Real callers safe by presenting empty
      # content — fail closed.
      def self.present(
        projection : Mutation::Client::Projection,
        auth_context : RBAC::AuthContext,
        definition : Doctype::DoctypeDefinition?,
      ) : JSON::Any
        present_content(projection.content, auth_context, definition)
      end

      # Presents raw content for the caller. Idempotent: content already
      # masked comes back unchanged.
      def self.present_content(
        content : JSON::Any,
        auth_context : RBAC::AuthContext,
        definition : Doctype::DoctypeDefinition?,
      ) : JSON::Any
        return content if definition.nil?
        RBAC::FieldVisibility.mask_content(content, auth_context, definition)
      end

      # Resolves the definition for a projection, fail-closed style: an
      # unknown or deleted doctype presents as empty content for Real
      # principals (never raw). System and Preview read the raw content —
      # the same bypass the read mask applies when no definition resolves.
      def self.present_projection(
        projection : Mutation::Client::Projection,
        auth_context : RBAC::AuthContext,
        db : DB::Connection,
      ) : JSON::Any
        definition = Doctype::DefinitionStore.fetch(db, "#{projection.domain}.#{projection.doc_type}")
        if definition.nil?
          return projection.content if auth_context.system? || auth_context.preview?
          return JSON.parse("{}")
        end
        present(projection, auth_context, definition)
      end
    end
  end
end
