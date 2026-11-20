# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../error"

module Facet
  module HTTP
    # Recursive resolver for nested child routes via the `*rest` glob param.
    #
    # The Radix router captures `*rest` as a single string. This handler
    # splits it into segments and walks the doctype composition tree:
    #
    #   /Api/:domain/:doctype/:id/*rest
    #
    #   rest segments: [rel_name, child_id, rel_name, child_id, ...]
    #
    #   - Odd number of segments  → list children (the final segment is a
    #     relationship name, e.g. "career_events").
    #   - Even number of segments → target a specific child document
    #     (alternating rel_name / child_id).
    #
    # Example:
    #   GET /Api/hr/Employee/e1/career_events       → list CareerEvents for e1
    #   GET /Api/hr/Employee/e1/career_events/c3     → read CareerEvent c3
    #   GET /Api/hr/Employee/e1/career_events/c3/notes → (future: list notes)
    #
    # Supported HTTP methods are delegated to the caller via a block that
    # receives `{domain, doc_type, doc_id}` of the final target resource.
    class NestedPathResolver
      # Result of resolving a rest path against the doctype tree.
      #
      # - `target`: the final doctype to operate on
      # - `parent_defn`: the immediate parent doctype definition
      # - `parent_id`: the ID of the immediate parent document
      # - `mode`: whether this is a `list` (collection) or `get` (single document)
      struct Resolved
        getter target : ResolvedTarget
        getter parent_defn : Doctype::DoctypeDefinition
        getter parent_id : String
        getter mode : Mode

        enum Mode
          List
          Get
        end

        def initialize(@target : ResolvedTarget, @parent_defn : Doctype::DoctypeDefinition, @parent_id : String, @mode : Mode)
        end
      end

      # The final target of resolution: the doctype to operate on.
      struct ResolvedTarget
        getter domain : String
        getter doc_type : String
        getter doc_id : String?

        def initialize(@domain : String, @doc_type : String, @doc_id : String? = nil)
        end
      end

      # Resolves a rest path into a {Resolved}, or returns an {Error}.
      #
      # * `db` — database connection
      # * `domain` — domain from the URL (e.g. "hr")
      # * `root_doctype` — the root doctype name (e.g. "Employee")
      # * `root_id` — the root document ID
      # * `rest_segments` — split of the `*rest` URL param (may be empty)
      #
      # The resolution walks the composition tree by looking up each
      # relationship name in the parent's `children` hash.
      def self.resolve(
        db : DB::Connection,
        domain : String,
        root_doctype : String,
        root_id : String,
        rest_segments : Array(String),
      ) : Resolved | Facet::ServiceError
        if rest_segments.empty?
          # No nesting — target is the root document itself
          return Facet::ServiceError.new(400, "No rest segments provided")
        end

        # Walk the tree: each pair is (rel_name, optional_child_id).
        current_domain = domain
        current_doctype = root_doctype
        current_parent_id = root_id
        last_defn = nil

        # We'll iterate pairs: rel_name at 0, child_id at 1, rel_name at 2, ...
        idx = 0
        while idx < rest_segments.size
          rel_name = rest_segments[idx]

          doctype_id = "#{current_domain}.#{current_doctype}"
          defn = Helpers.fetch_doctype_defn(db, doctype_id)
          if defn.nil?
            return Facet::ServiceError.new(404, "Unknown doctype: #{doctype_id}")
          end
          parent_defn = defn
          last_defn = parent_defn

          child_defn = parent_defn.children[rel_name]?
          if child_defn.nil?
            return Facet::ServiceError.new(404, "Unknown child relationship '#{rel_name}' for #{doctype_id}")
          end

          child_doctype = child_defn.doctype

          # Next segment is either a child ID (if we have more after) or we're listing
          if idx + 1 < rest_segments.size
            child_id = rest_segments[idx + 1]
            current_doctype = child_doctype
            current_parent_id = child_id
            idx += 2
          else
            # Last segment is a relationship name → list children
            target = ResolvedTarget.new(domain, child_doctype)
            return Resolved.new(target, parent_defn, current_parent_id, Resolved::Mode::List)
          end
        end

        # We've consumed all segments — target a specific document.
        # Use the cached definition to avoid a redundant fetch.
        target = ResolvedTarget.new(domain, current_doctype, current_parent_id)
        if last_defn.nil? || last_defn.doctype != current_doctype
          doctype_id = "#{domain}.#{current_doctype}"
          defn = Helpers.fetch_doctype_defn(db, doctype_id)
          if defn.nil?
            return Facet::ServiceError.new(404, "Unknown doctype: #{doctype_id}")
          end
          last_defn = defn
        end

        Resolved.new(target, last_defn, current_parent_id, Resolved::Mode::Get)
      end
    end
  end
end
