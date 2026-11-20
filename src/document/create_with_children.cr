# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "pg"
require "./create"
require "./validation"
require "./recompute"
require "../doctype/definition_store"
require "../rbac"
require "../error"

module Facet
  module Document
    # Service for atomically creating a parent document with its child
    # documents in a single transaction.
    #
    # Accepts a **compound body** with `$content` (parent fields) and
    # an optional `$children` map (child relationship name → array of
    # child bodies). When only `$content` is present, it behaves
    # identically to `Document::Create`.
    #
    # ### Wire format
    #
    # ```json
    # POST /Api/hr/Employee
    # {
    #   "$content": {
    #     "status": "active",
    #     "job_title": "Software Engineer"
    #   },
    #   "$children": {
    #     "career_events": [
    #       { "event_type": "hired", "effective_date": "..." }
    #     ]
    #   }
    # }
    # ```
    #
    # ### Atomicity
    #
    # All creates (parent + children) run in a single PG transaction.
    # If any child fails (RBAC, validation, script error), the entire
    # operation is rolled back.
    #
    # ### Parent linkage
    #
    # Every child create (plain body and recursive compound) stages
    # `meta.parent_id` pointing at the parent created in the same call, so
    # the child's mutation rows stamp `mutations.parent_doc_id` and the
    # child is reachable through the parent's aggregate surfaces (nested
    # routes, cascade, history feed).
    module CreateWithChildren
      # The only two top-level keys a compound body may carry. Every other
      # key is refused — the relationship name belongs under `$children`.
      COMPOUND_KEYS = Set{"$content", "$children"}

      # A single child result entry. When the child was itself a compound
      # body with `$children`, `children` carries the nested results. The
      # timestamps come from the child projection — the responder echoes
      # them so the wire response matches the persisted rows.
      record ChildResult,
        id : String,
        doc_type : String,
        mut_id : String,
        content : JSON::Any,
        created_at : Time,
        updated_at : Time,
        children : Hash(String, Array(ChildResult)) = {} of String => Array(ChildResult)

      # Result returned on success.
      record Result,
        projection : Mutation::Client::Projection,
        mutation_id : String,
        children : Hash(String, Array(ChildResult)) = {} of String => Array(ChildResult)

      # Creates a document with optional children from a compound body.
      #
      # The `body` is expected to be a JSON string that may contain
      # `$content` and optionally `$children` keys.
      #
      # When `$content` is absent, the entire body is treated as the
      # document content (backward-compatible with `Document::Create`).
      #
      # Returns `Result` on success, `Error` on failure.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        body : String,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "document.create_with_children" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type

          actioner_id = auth_context.account_id
          actioner_id ||= "system"

          parsed = begin
            JSON.parse(body)
          rescue ex : JSON::ParseException
            return Telemetry.record_error(span, Facet::ServiceError.new(422, "Invalid JSON body: #{ex.message}"))
          end

          parsed_hash = parsed.as_h?
          if parsed_hash.nil?
            return Telemetry.record_error(span, Facet::ServiceError.new(422, "Body must be a JSON object"))
          end

          result = if parsed_hash.has_key?("$content")
                     create_compound(db, domain, doc_type, parsed_hash, auth_context, actioner_id)
                   else
                     # Plain body — delegate to Document::Create (backward compat)
                     inner = Document::Create.call(db, domain, doc_type, body, auth_context)
                     case inner
                     in Document::Create::Result
                       Result.new(projection: inner.projection, mutation_id: inner.mutation_id)
                     in Facet::ServiceError
                       inner
                     end
                   end

          case result
          in Result
            span["doc_id"] = result.projection.id
            span["mutation_id"] = result.mutation_id
            span["child_count"] = result.children.values.sum(&.size).to_s
          in Facet::ServiceError
            Telemetry.record_error(span, result)
          end

          result
        end
      end

      # ── Private ────────────────────────────────────────────────────────

      private def self.create_compound(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        parsed_hash : Hash(String, JSON::Any),
        auth_context : RBAC::AuthContext,
        actioner_id : String,
        parent_id : String? = nil,
        composition_prefix : Array(String)? = nil,
      ) : Result | Facet::ServiceError
        # 1. The compound body has exactly two top-level keys. Anything else
        # is silently dropped by the extraction below, so refuse it here —
        # the bare-body create door answers 422 for the same key.
        unknown = parsed_hash.keys.reject { |k| COMPOUND_KEYS.includes?(k) }
        unless unknown.empty?
          return Facet::ServiceError.new(422,
            "Unknown top-level key(s) in a compound body: #{unknown.join(", ")} — " \
            "send child rows under '$children'")
        end

        # 2. Extract $content
        content_val = parsed_hash["$content"]
        unless content_val.as_h?
          return Facet::ServiceError.new(422, "'$content' must be a JSON object")
        end

        # 3. Extract optional $children
        children_raw = parsed_hash["$children"]?.try(&.as_h?) || {} of String => JSON::Any

        # 4. Fetch the parent doctype definition
        doctype_id = "#{domain}.#{doc_type}"
        defn = Doctype::DefinitionStore.fetch!(db, doctype_id)
        return defn if defn.is_a?(Facet::ServiceError)

        # 5. Validate $children keys against the doctype's children definitions
        children_raw.each_key do |rel_name|
          unless defn.children.has_key?(rel_name)
            return Facet::ServiceError.new(422, "Unknown child relationship '#{rel_name}' for #{doctype_id}")
          end
        end

        # 6. Create the parent document. A nested compound call (this
        # compound body is itself a child of an outer compound create)
        # stamps `meta.parent_id` so its rows link to the outer parent,
        # and authorizes on the accumulated composition path.
        parent_meta : Hash(String, JSON::Any)? = parent_id ? {"parent_id" => JSON::Any.new(parent_id)} : nil
        parent_result = Document::Create.create_from_parsed(
          db, domain, doc_type, content_val, auth_context, actioner_id,
          meta_overrides: parent_meta,
          authorize_path: composition_prefix, # nil → bare-path gate on the root
        )
        case parent_result
        in Facet::ServiceError
          return parent_result
        in Document::Create::Result
          parent_projection = parent_result.projection
          parent_mut_id = parent_result.mutation_id
        end

        # 7. Process children — all or nothing. The children authorize on
        # the composition path rooted at THIS compound parent.
        children_results = create_children(
          db, domain, defn, children_raw, parent_projection.id, auth_context, actioner_id,
          (composition_prefix || [] of String) + [doc_type],
        )
        return children_results if children_results.is_a?(Facet::ServiceError)

        # Each child create ran the parent-recompute pass for the
        # relationship-named computed fields — the parent content changed
        # after the projection above was fetched. Re-read it so the wire
        # response carries the final (converged) content.
        final_projection = parent_projection
        unless children_results.empty?
          begin
            final_projection = Mutation::Client.fetch_projection(db, domain, doc_type, parent_projection.id)
          rescue DB::NoResultsError | PG::Error
            final_projection = parent_projection
          end
        end

        Result.new(
          projection: final_projection,
          mutation_id: parent_mut_id,
          children: children_results,
        )
      end

      # Creates every entry of a compound body's `$children` map under the
      # freshly created parent. Returns the per-relationship results, or the
      # first failure — the caller's transaction then rolls the parent back
      # with it (all or nothing). `composition_prefix` is the doctype chain
      # from the aggregate root down to the parent.
      private def self.create_children(
        db : DB::Connection,
        domain : String,
        parent_defn : Doctype::DoctypeDefinition,
        children_raw : Hash(String, JSON::Any),
        parent_id : String,
        auth_context : RBAC::AuthContext,
        actioner_id : String,
        composition_prefix : Array(String) = [] of String,
      ) : Hash(String, Array(ChildResult)) | Facet::ServiceError
        children_results = {} of String => Array(ChildResult)

        children_raw.each do |rel_name, child_bodies_raw|
          child_def = parent_defn.children[rel_name]
          child_doctype = child_def.doctype

          # Validate same-domain (children are always same-domain)
          child_doctype_id = "#{domain}.#{child_doctype}"
          child_defn = Doctype::DefinitionStore.fetch!(db, child_doctype_id,
            message: "Child doctype '#{child_doctype_id}' not found", status: 422)
          return child_defn if child_defn.is_a?(Facet::ServiceError)

          # Resolve child bodies array
          child_bodies = child_bodies_raw.as_a?
          if child_bodies.nil?
            return Facet::ServiceError.new(422, "'#{rel_name}' must be an array of child document bodies")
          end

          child_results = [] of ChildResult

          child_bodies.each do |child_body|
            result = create_single_child(
              db, domain, child_doctype, child_body, parent_id, auth_context, actioner_id,
              composition_prefix,
            )
            case result
            in ChildResult
              child_results << result
            in Facet::ServiceError
              return child_creation_error(rel_name, result)
            end
          end

          children_results[rel_name] = child_results
        end

        children_results
      end

      # Creates one child document of a compound body. A body carrying
      # `$content` is itself a compound create (recursion); a plain body
      # goes straight through the create service. Both stage
      # `meta.parent_id` so the child's mutation rows link to the parent.
      #
      # `composition_prefix` carries the doctype chain from the aggregate
      # root — the child's create authorizes on the composition path, the
      # same rule the nested REST routes apply.
      private def self.create_single_child(
        db : DB::Connection,
        domain : String,
        child_doctype : String,
        child_body : JSON::Any,
        parent_id : String,
        auth_context : RBAC::AuthContext,
        actioner_id : String,
        composition_prefix : Array(String),
      ) : ChildResult | Facet::ServiceError
        child_hash = child_body.as_h?
        return Facet::ServiceError.new(422, "Each child must be a JSON object") if child_hash.nil?

        if child_hash.has_key?("$content")
          # Recursive compound child — this child has its own children.
          # It is stamped as a child of the parent being created; its own
          # children are stamped by the recursion.
          sub_result = create_compound(
            db, domain, child_doctype, child_hash, auth_context, actioner_id,
            parent_id: parent_id,
            composition_prefix: composition_prefix,
          )
          return sub_result unless sub_result.is_a?(Result)

          ChildResult.new(
            id: sub_result.projection.id,
            doc_type: child_doctype,
            mut_id: sub_result.mutation_id,
            content: sub_result.projection.content,
            created_at: sub_result.projection.created_at,
            updated_at: sub_result.projection.updated_at,
            children: sub_result.children,
          )
        else
          # Plain child body — no nested children.
          child_result = Document::Create.create_from_parsed(
            db, domain, child_doctype, child_body, auth_context, actioner_id,
            meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
            authorize_path: composition_prefix + [child_doctype],
          )
          return child_result unless child_result.is_a?(Document::Create::Result)

          proj = child_result.projection
          ChildResult.new(
            id: proj.id,
            doc_type: child_doctype,
            mut_id: child_result.mutation_id,
            content: proj.content,
            created_at: proj.created_at,
            updated_at: proj.updated_at,
          )
        end
      end

      # Prefixes a child creation failure with the relationship name so the
      # caller can tell which child failed.
      private def self.child_creation_error(rel_name : String, err : Facet::ServiceError) : Facet::ServiceError
        Facet::ServiceError.new(
          status: err.status,
          message: "Failed to create child '#{rel_name}': #{err.message}",
          details: err.details,
        )
      end
    end
  end
end
