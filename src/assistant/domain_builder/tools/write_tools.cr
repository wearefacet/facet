# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../../../doctype/definition_store"
require "../../../doctype/create"
require "../../../doctype/update"
require "../../../doctype/view_template_validator"
require "../../../document/create"
require "../../../document/delete"
require "../../../mutation/client"
require "../../../util/script_helpers"
require "../../../event"
require "../auth"
require "../context"

module Facet
  module Assistant
    module DomainBuilder
      module Registrar
        # ── Write tools: doctype definitions ──────────────────────────

        # Creates a new doctype definition in the draft domain. The
        # `definition.domain` field is the authority for the draft guard.
        private def self.register_create_doctype(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "create_doctype",
            "Create a new doctype definition. The `definition` argument is a full DoctypeDefinition object (see read_skill('doctype-anatomy')). `definition.domain` MUST match the draft domain '#{context.draft_domain}'. Returns {doctype_id, schema_version} on success.",
            schema_object(
              properties: {
                "definition" => {"type" => "object"},
              },
              required: ["definition"],
            ),
          ) do |args|
            defn_arg = req_any("definition")

            domain = defn_arg["domain"]?.try(&.as_s?)
            if err = ensure_draft_domain(context, domain || "")
              next Tools.error(err)
            end

            body = defn_arg.to_json
            Tools.tool_mutation(db, Facet::Doctype::Create.call(
              txn, "core", "DocType", body, Auth.auth_context_for(context), cause: WRITE_CAUSE), Facet::Doctype::Create::Result) do
              Tools.ok({
                "doctype_id"     => JSON::Any.new(result.projection.id),
                "schema_version" => result.projection.content["schema_version"]? || JSON::Any.new(1),
              })
            end
          end
        end

        # Replaces an existing doctype definition. Fetches the current
        # projection first to enforce the draft guard.
        private def self.register_update_doctype(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "update_doctype",
            "Replace an existing doctype definition with a new version. `definition.domain` MUST match the draft domain '#{context.draft_domain}'. `doctype_id` AND `definition.domain`/`definition.doctype` cannot change. Returns {doctype_id, mutation_id} on success.",
            schema_object(
              properties: {
                "doctype_id" => {"type" => "string"},
                "definition" => {"type" => "object"},
              },
              required: ["doctype_id", "definition"],
            ),
          ) do |args|
            doctype_id = req_s("doctype_id")
            defn_arg = req_any("definition")

            if err = ensure_doctype_in_draft!(db, context, doctype_id)
              next Tools.error(err)
            end

            body = defn_arg.to_json
            Tools.tool_mutation(db, Facet::Doctype::Update.call(
              txn, doctype_id, body, Auth.auth_context_for(context), cause: WRITE_CAUSE), Facet::Doctype::Update::Result) do
              Tools.ok({
                "doctype_id"  => JSON::Any.new(doctype_id),
                "mutation_id" => JSON::Any.new(result.mutation_id),
              })
            end
          end
        end

        # Soft-deletes a doctype definition in the draft domain.
        private def self.register_delete_doctype(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "delete_doctype",
            "Soft-delete a doctype definition. The doctype MUST belong to the draft domain '#{context.draft_domain}'. Returns {doctype_id, deleted:true} on success.",
            schema_object(
              properties: {
                "doctype_id" => {"type" => "string"},
              },
              required: ["doctype_id"],
            ),
          ) do |args|
            doctype_id = req_s("doctype_id")

            if err = ensure_doctype_in_draft!(db, context, doctype_id)
              next Tools.error(err)
            end

            Tools.tool_mutation(db, Facet::Document::Delete.call(
              txn, "core", "DocType", doctype_id, Auth.auth_context_for(context), cause: WRITE_CAUSE), Facet::Document::Delete::Result) do
              Tools.ok({doctype_id: JSON::Any.new(doctype_id), deleted: JSON::Any.new(true)})
            end
          end
        end

        # ── Write tools: document view templates ──────────────────────

        # `core.DocumentView` is a child of `core.DocType`. Its
        # `parent_doctype` field references a doctype ID. Storage identity
        # is `domain="core", doc_type="DocumentView"`.

        private def self.register_create_document_view(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "create_document_view",
            "Create a DocumentView template for a doctype (child of core.DocType). The doctype must belong to the draft domain '#{context.draft_domain}'. Prefer the auto 'input' node for every editable field — it renders the correct control from the field's declared type (enum options, reference target, required flag, url/phone/number keyboards all derive); use a specialized 'input-*' node only to force a control. The template is validated structurally and against the parent doctype definition — malformed trees, input nodes bound to unknown/dotted/container/read-only fields, and input/type affinity mismatches are rejected or warned with a 'details' array (fix the template and retry). Returns {doc_id, parent_doctype, kind, warnings?} on success.",
            schema_object(
              properties: {
                "parent_doctype" => {"type" => "string"},
                "kind"           => {"type" => "string"},
                "template"       => {"type" => "object"},
              },
              required: ["parent_doctype", "kind"],
            ),
          ) do |args|
            parent_doctype = req_s("parent_doctype")
            kind = req_s("kind")
            template = args["template"]?

            if err = ensure_doctype_in_draft!(db, context, parent_doctype)
              next Tools.error(err)
            end

            defn = Facet::Doctype::DefinitionStore.fetch_uncached(db, parent_doctype)
            next Tools.error("Doctype '#{parent_doctype}' not found") if defn.nil?

            view_check = check_view_template(template, defn)
            next Tools.error("DocumentView template validation failed", view_check.errors) unless view_check.errors.empty?

            body_obj = {
              "parent_doctype" => JSON::Any.new(parent_doctype),
              "kind"           => JSON::Any.new(kind),
            }
            body_obj["template"] = template if template

            body = body_obj.to_json
            Tools.tool_mutation(db, Facet::Document::Create.call(
              txn, "core", "DocumentView", body, Auth.auth_context_for(context),
              meta_overrides: {"parent_id" => JSON::Any.new(parent_doctype)}, cause: WRITE_CAUSE,
            ), Facet::Document::Create::Result) do
              ok = {
                "doc_id"         => JSON::Any.new(result.projection.id),
                "parent_doctype" => JSON::Any.new(parent_doctype),
                "kind"           => JSON::Any.new(kind),
              }
              ok["warnings"] = JSON::Any.new(view_check.warnings.map { |w| JSON::Any.new(w) }) unless view_check.warnings.empty?
              Tools.ok(ok)
            end
          end
        end

        private def self.register_update_document_view(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "update_document_view",
            "Update an existing DocumentView template. `template` replaces the full template object; `kind` is optional. Prefer the auto 'input' node for every editable field — it renders the correct control from the field's declared type; use a specialized 'input-*' node only to force a control. The template is validated structurally and against the parent doctype definition — malformed trees, input nodes bound to unknown/dotted/container/read-only fields, and input/type affinity mismatches are rejected or warned with a 'details' array (fix the template and retry). The view must belong to a doctype in the draft domain '#{context.draft_domain}'. Returns {doc_id, updated:true, warnings?} on success.",
            schema_object(
              properties: {
                "doc_id"   => {"type" => "string"},
                "kind"     => {"type" => "string"},
                "template" => {"type" => "object"},
              },
              required: ["doc_id"],
            ),
          ) do |args|
            doc_id = req_s("doc_id")

            if err = ensure_view_in_draft!(db, context, doc_id)
              next Tools.error(err)
            end

            view_warnings = [] of String

            patch = {} of String => JSON::Any
            if k = args["kind"]?.try(&.as_s?)
              patch["kind"] = JSON::Any.new(k)
            end
            if t = args["template"]?
              parent_doctype = db.query_one?("SELECT content->>'parent_doctype' FROM projections WHERE domain='core' AND doc_type='DocumentView' AND id=$1 AND deleted_at IS NULL", doc_id, as: String?)
              defn = parent_doctype ? Facet::Doctype::DefinitionStore.fetch_uncached(db, parent_doctype) : nil
              view_check = check_view_template(t, defn)
              next Tools.error("DocumentView template validation failed", view_check.errors) unless view_check.errors.empty?
              view_warnings = view_check.warnings
              patch["template"] = t
            end
            if patch.empty?
              next Tools.error("At least one of 'kind' or 'template' must be provided")
            end

            body = patch.to_json
            Tools.tool_mutation(db, Facet::Document::Update.call(
              txn, "core", "DocumentView", doc_id, body, Auth.auth_context_for(context), cause: WRITE_CAUSE), Facet::Document::Update::Result) do
              ok = {"doc_id" => JSON::Any.new(doc_id), "updated" => JSON::Any.new(true)}
              ok["warnings"] = JSON::Any.new(view_warnings.map { |w| JSON::Any.new(w) }) unless view_warnings.empty?
              Tools.ok(ok)
            end
          end
        end

        private def self.register_delete_document_view(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "delete_document_view",
            "Soft-delete a DocumentView template. The view must belong to a doctype in the draft domain '#{context.draft_domain}'. Returns {doc_id, deleted:true} on success.",
            schema_object(
              properties: {"doc_id" => {"type" => "string"}},
              required: ["doc_id"],
            ),
          ) do |args|
            doc_id = req_s("doc_id")

            if err = ensure_view_in_draft!(db, context, doc_id)
              next Tools.error(err)
            end

            Tools.tool_mutation(db, Facet::Document::Delete.call(
              txn, "core", "DocumentView", doc_id, Auth.auth_context_for(context), cause: WRITE_CAUSE), Facet::Document::Delete::Result) do
              Tools.ok({doc_id: JSON::Any.new(doc_id), deleted: JSON::Any.new(true)})
            end
          end
        end

        # ── Write tools: collection view templates ─────────────────────

        # `core.CollectionView` is a child of `core.DocType` (member_of).
        # Unlike DocumentView there is NO `parent_doctype` content field —
        # the parent linkage is carried by `meta.parent_id` via the children
        # system. `owner_id` is left to the Lua create hook (general vs
        # personal) and is immutable after create.

        private def self.register_create_collection_view(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "create_collection_view",
            "Create a CollectionView (saved listing surface) for a doctype in the draft domain '#{context.draft_domain}'. `doctype` is the qualified doctype id. `owner_id` is optional: omit for a general (shared) view, set for a personal view. Returns {doc_id, name, surface} on success.",
            schema_object(
              properties: {
                "doctype"  => {"type" => "string"},
                "name"     => {"type" => "string"},
                "surface"  => {"type" => "string"},
                "config"   => {"type" => "object"},
                "owner_id" => {"type" => "string"},
              },
              required: ["doctype", "name", "surface"],
            ),
          ) do |args|
            doctype = req_s("doctype")
            name = req_s("name")
            surface = req_s("surface")
            config = args["config"]?
            owner_id = args["owner_id"]?.try(&.as_s?)

            if err = ensure_doctype_in_draft!(db, context, doctype)
              next Tools.error(err)
            end

            body_obj = {
              "name"    => JSON::Any.new(name),
              "surface" => JSON::Any.new(surface),
            }
            body_obj["config"] = config if config
            body_obj["owner_id"] = JSON::Any.new(owner_id) if owner_id

            body = body_obj.to_json
            Tools.tool_mutation(db, Facet::Document::Create.call(
              txn, "core", "CollectionView", body, Auth.auth_context_for(context),
              meta_overrides: {"parent_id" => JSON::Any.new(doctype)}, cause: WRITE_CAUSE,
            ), Facet::Document::Create::Result) do
              Tools.ok({
                "doc_id"  => JSON::Any.new(result.projection.id),
                "name"    => JSON::Any.new(name),
                "surface" => JSON::Any.new(surface),
              })
            end
          end
        end

        private def self.register_update_collection_view(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "update_collection_view",
            "Update an existing CollectionView. `name`, `surface`, and `config` are optional — pass only what changes. `owner_id` is immutable and cannot be changed here. The view must belong to a doctype in the draft domain '#{context.draft_domain}'. Returns {doc_id, updated:true} on success.",
            schema_object(
              properties: {
                "doc_id"  => {"type" => "string"},
                "name"    => {"type" => "string"},
                "surface" => {"type" => "string"},
                "config"  => {"type" => "object"},
              },
              required: ["doc_id"],
            ),
          ) do |args|
            doc_id = req_s("doc_id")

            if err = ensure_collection_view_in_draft!(db, context, doc_id)
              next Tools.error(err)
            end

            patch = {} of String => JSON::Any
            if n = args["name"]?.try(&.as_s?)
              patch["name"] = JSON::Any.new(n)
            end
            if s = args["surface"]?.try(&.as_s?)
              patch["surface"] = JSON::Any.new(s)
            end
            if c = args["config"]?
              patch["config"] = c
            end
            if patch.empty?
              next Tools.error("At least one of 'name', 'surface', or 'config' must be provided")
            end

            body = patch.to_json
            Tools.tool_mutation(db, Facet::Document::Update.call(
              txn, "core", "CollectionView", doc_id, body, Auth.auth_context_for(context), cause: WRITE_CAUSE), Facet::Document::Update::Result) do
              Tools.ok({doc_id: JSON::Any.new(doc_id), updated: JSON::Any.new(true)})
            end
          end
        end

        private def self.register_delete_collection_view(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "delete_collection_view",
            "Soft-delete a CollectionView. The view must belong to a doctype in the draft domain '#{context.draft_domain}'. Returns {doc_id, deleted:true} on success.",
            schema_object(
              properties: {"doc_id" => {"type" => "string"}},
              required: ["doc_id"],
            ),
          ) do |args|
            doc_id = req_s("doc_id")

            if err = ensure_collection_view_in_draft!(db, context, doc_id)
              next Tools.error(err)
            end

            Tools.tool_mutation(db, Facet::Document::Delete.call(
              txn, "core", "CollectionView", doc_id, Auth.auth_context_for(context), cause: WRITE_CAUSE), Facet::Document::Delete::Result) do
              Tools.ok({doc_id: JSON::Any.new(doc_id), deleted: JSON::Any.new(true)})
            end
          end
        end

        # ── Write tools: sample documents ──────────────────────────────

        # Creates a sample document of a doctype in the draft domain —
        # the LLM uses this to smoke-test the doctype definition, including
        # child documents of a composition (parts under a sample machine).
        private def self.register_create_document(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "create_document",
            "Create a sample document of a doctype in the draft domain '#{context.draft_domain}' to smoke-test a definition. `content` is the document body. For a child doctype (one declaring member_of) pass `parent_id` — the id of a parent document in the draft; the tool refuses `parent_id` on a root doctype. Returns {doc_id, mutation_id} on success.",
            schema_object(
              properties: {
                "doctype"   => {"type" => "string"},
                "content"   => {"type" => "object"},
                "parent_id" => {"type" => "string", "description" => "Parent document id — required for child doctypes (member_of), invalid otherwise"},
              },
              required: ["doctype", "content"],
            ),
          ) do |args|
            doctype = req_s("doctype")

            # Verify the doctype is in the draft domain.
            doctype_id = "#{context.draft_domain}.#{doctype}"
            if err = ensure_doctype_in_draft!(db, context, doctype_id)
              next Tools.error(err)
            end

            parent_id = args["parent_id"]?.try(&.as_s?)
            meta_overrides = nil
            parent_doctype = nil

            # Composition gate — the same one the flat create service runs,
            # pre-empted here so the model gets an actionable message before
            # validation: a child doctype needs a parent that exists in the
            # draft; a root doctype rejects parent_id outright.
            defn = Facet::Doctype::DefinitionStore.fetch_uncached(db, doctype_id)
            next Tools.error("Doctype '#{doctype_id}' not found") if defn.nil?

            if member_of = defn.member_of
              if parent_id.nil?
                next Tools.error("Doctype '#{doctype_id}' is a child of '#{context.draft_domain}.#{member_of}' — pass 'parent_id' to create it under a parent")
              end
              if err = ensure_doc_in_draft!(db, context, context.draft_domain, member_of, parent_id)
                next Tools.error(err)
              end
              parent_doctype = member_of
              meta_overrides = {"parent_id" => JSON::Any.new(parent_id)} of String => JSON::Any
            elsif parent_id
              next Tools.error("Argument 'parent_id' needs a child doctype — '#{doctype_id}' declares no member_of")
            end

            body = req_any("content").to_json
            Tools.tool_mutation(db, create_sample_document(txn, context, doctype, body, meta_overrides, parent_doctype, parent_id), Facet::Document::Create::Result) do
              Tools.ok({
                "doc_id"      => JSON::Any.new(result.projection.id),
                "mutation_id" => JSON::Any.new(result.mutation_id),
              })
            end
          end
        end

        # The create service call with the composition extras applied:
        # locks the parent row for the transaction span and requires it
        # live (B-276 — the lock answer is the tool's "Not found" error),
        # then creates under it. `tool_mutation` evaluates this inside its
        # transaction, so `txn` is live here.
        private def self.create_sample_document(
          txn : DB::Connection,
          context : Context,
          doctype : String,
          body : String,
          meta_overrides : Hash(String, JSON::Any)?,
          parent_doctype : String?,
          parent_id : String?,
        ) : Facet::Document::Create::Result | Facet::ServiceError
          if parent_doctype && parent_id
            unless Facet::Document::RowAccess.lock_live_projection_for_update(txn, context.draft_domain, parent_doctype, parent_id)
              return Facet::ServiceError.new(404, "Not found")
            end
          end
          Facet::Document::Create.call(
            txn, context.draft_domain, doctype, body, Auth.auth_context_for(context),
            meta_overrides: meta_overrides, cause: WRITE_CAUSE,
          )
        end

        # Deletes a sample document in the draft domain.
        private def self.register_delete_document(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "delete_document",
            "Soft-delete a sample document in the draft domain '#{context.draft_domain}'. Returns {doc_id, deleted:true} on success.",
            schema_object(
              properties: {
                "doctype" => {"type" => "string"},
                "doc_id"  => {"type" => "string"},
              },
              required: ["doctype", "doc_id"],
            ),
          ) do |args|
            doctype = req_s("doctype")
            doc_id = req_s("doc_id")

            if err = ensure_doc_in_draft!(db, context, context.draft_domain, doctype, doc_id)
              next Tools.error(err)
            end

            Tools.tool_mutation(db, Facet::Document::Delete.call(
              txn, context.draft_domain, doctype, doc_id, Auth.auth_context_for(context), cause: WRITE_CAUSE), Facet::Document::Delete::Result) do
              Tools.ok({doc_id: JSON::Any.new(doc_id), deleted: JSON::Any.new(true)})
            end
          end
        end
      end
    end
  end
end
