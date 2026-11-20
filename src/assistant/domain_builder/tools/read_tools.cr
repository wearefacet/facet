# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../../../doctype/definition_store"
require "../../../doctype/check"
require "../../../document/read"
require "../../../document/list"
require "../../../mutation/client"
require "../auth"
require "../skills"

module Facet
  module Assistant
    module DomainBuilder
      module Registrar
        # ── Read-only tools ────────────────────────────────────────────

        # Lists every live `core.Domain` projection — lets the LLM inspect
        # existing domains for reference.
        private def self.register_list_domains(agent : Agent, db : DB::Connection) : Nil
          agent.register_tool(
            "list_domains",
            "List all live (non-draft) domains registered in the system. Each row has {id, description, draft}. Use to inspect existing domains for reference patterns.",
            schema_object(properties: {} of String => Hash(String, String), required: [] of String),
          ) do |_args|
            rows = db.query_all(
              "SELECT id, content->>'description', (content->>'draft')::bool FROM projections WHERE domain='core' AND doc_type='Domain' AND deleted_at IS NULL ORDER BY id",
              as: {String, String?, Bool?},
            ).map do |(id, description, draft)|
              {
                "id"          => JSON::Any.new(id),
                "description" => JSON::Any.new(description),
                "draft"       => JSON::Any.new(draft),
              }
            end
            Tools.ok(rows)
          end
        end

        # Lists doctype definitions visible under a (default: draft)
        # domain. Returns summary rows, not full definitions — use
        # `get_doctype` to read the full definition of a specific doctype.
        private def self.register_list_doctypes(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "list_doctypes",
            "List doctype definitions under a domain (default: the draft domain). Returns summary rows: {id, domain, doctype, schema_version, description}.",
            schema_object(
              properties: {"domain" => {"type" => "string"}},
              required: [] of String,
            ),
          ) do |args|
            domain = args["domain"]?.try(&.as_s?) || context.draft_domain
            rows = db.query_all(
              "SELECT id, content->>'domain', content->>'doctype', content->>'schema_version', content->>'description' FROM projections WHERE domain='core' AND doc_type='DocType' AND deleted_at IS NULL AND content->>'domain' = $1 ORDER BY id",
              domain,
              as: {String, String, String, String?, String?},
            ).map do |(id, d_domain, d_doctype, sv_str, description)|
              sv = sv_str.try(&.to_i?) || 1
              {
                "id"             => JSON::Any.new(id),
                "domain"         => JSON::Any.new(d_domain),
                "doctype"        => JSON::Any.new(d_doctype),
                "schema_version" => JSON::Any.new(sv),
                "description"    => JSON::Any.new(description),
              }
            end
            Tools.ok(rows)
          end
        end

        # Reads the full definition of a single doctype by its qualified id
        # (e.g. `"hr.Employee"`). Works cross-domain — the model can inspect
        # live doctypes as reference while building the draft.
        private def self.register_get_doctype(agent : Agent, db : DB::Connection) : Nil
          agent.register_tool(
            "get_doctype",
            "Read the full DoctypeDefinition for a qualified doctype id (e.g. 'hr.Employee'). Works cross-domain. Returns {doctype_id, definition}.",
            schema_object(
              properties: {"doctype_id" => {"type" => "string"}},
              required: ["doctype_id"],
            ),
          ) do |args|
            doctype_id = req_s("doctype_id")

            defn = Facet::Doctype::DefinitionStore.fetch_uncached(db, doctype_id)
            next Tools.error("Doctype '#{doctype_id}' not found") if defn.nil?

            Tools.ok({
              "doctype_id" => JSON::Any.new(doctype_id),
              "definition" => JSON.parse(defn.to_json),
            })
          end
        end

        # Reads the full content of a `core.Domain` projection — grants,
        # context_sets, draft flag, etc.
        private def self.register_get_domain(agent : Agent, db : DB::Connection) : Nil
          agent.register_tool(
            "get_domain",
            "Read the full content of a core.Domain projection. Returns {id, description, draft, grants, context_sets}.",
            schema_object(
              properties: {"domain" => {"type" => "string"}},
              required: ["domain"],
            ),
          ) do |args|
            domain = req_s("domain")

            row = fetch_core_content(db, "Domain", domain)
            next Tools.error("Domain '#{domain}' not found") if row.nil?

            content = row.as_h? || {} of String => JSON::Any
            Tools.ok({
              "id"           => JSON::Any.new(domain),
              "description"  => content["description"]? || JSON::Any.new(""),
              "draft"        => content["draft"]? || JSON::Any.new(false),
              "grants"       => content["grants"]? || JSON::Any.new([] of JSON::Any),
              "context_sets" => content["context_sets"]? || JSON::Any.new({} of String => JSON::Any),
            })
          end
        end

        # Lists documents in the draft domain. The `domain` is locked to
        # `context.draft_domain` regardless of what the model passes.
        private def self.register_list_documents(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "list_documents",
            "List documents of a given doctype in the draft domain. Returns {items: [{doc_id, content, parent_id?}], total} — use doc_id with get_document, update-ready sampling, or as a child's parent_id.",
            schema_object(
              properties: {
                "doctype" => {"type" => "string"},
                "limit"   => {"type" => "integer"},
              },
              required: ["doctype"],
            ),
          ) do |args|
            doctype = req_s("doctype")

            limit = args["limit"]?.try(&.as_i?) || 20

            result = Facet::Document::List.call(
              db,
              context.draft_domain,
              doctype,
              page: 1,
              items_per_page: limit,
              auth_context: Auth.auth_context,
            )

            case result
            in Facet::Document::List::Result
              items = result.items.map do |proj|
                h = {
                  "doc_id"  => JSON::Any.new(proj.id),
                  "content" => proj.content,
                } of String => JSON::Any
                if pid = proj.meta.as_h?.try(&.["parent_id"]?).try(&.as_s?)
                  h["parent_id"] = JSON::Any.new(pid)
                end
                JSON::Any.new(h)
              end
              Tools.ok({items: items, total: result.total})
            in Facet::ServiceError
              Tools.error(result.message)
            in Facet::Document::List::AggregateResult
              # Unreachable: this tool never requests an aggregate. The union
              # member exists because `Document::List.call` can return one.
              Tools.error("list_documents never returns an aggregate")
            end
          end
        end

        # Reads a single document in the draft domain.
        private def self.register_get_document(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "get_document",
            "Read a single document by doctype and doc_id from the draft domain.",
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

            result = Facet::Document::Read.call(
              db,
              context.draft_domain,
              doctype,
              doc_id,
              Auth.auth_context,
            )

            case result
            in Facet::Document::Read::Result
              Tools.ok({doc_id: doc_id, content: result.projection.content})
            in Facet::ServiceError
              Tools.error(result.message)
            end
          end
        end

        # Lists `core.DocumentView` templates attached to a doctype in the
        # draft. Returns summary rows {doc_id, parent_doctype, kind} — use
        # `get_document_view` to read a full template. Lets the model avoid
        # duplicate `(doctype, kind)` collisions before creating.
        private def self.register_list_document_views(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "list_document_views",
            "List DocumentView templates for a doctype in the draft domain. `doctype` is the qualified doctype id (e.g. '#{context.draft_domain}.Widget'). Returns {items:[{doc_id, parent_doctype, kind}]}.",
            schema_object(
              properties: {"doctype" => {"type" => "string"}},
              required: ["doctype"],
            ),
          ) do |args|
            doctype = req_s("doctype")

            if err = ensure_doctype_in_draft!(db, context, doctype)
              next Tools.error(err)
            end

            items = db.query_all(
              "SELECT id, content->>'parent_doctype', content->>'kind' FROM projections WHERE domain='core' AND doc_type='DocumentView' AND deleted_at IS NULL AND content->>'parent_doctype' = $1 ORDER BY id",
              doctype,
              as: {String, String, String},
            ).map do |(doc_id, parent_doctype, kind)|
              {
                "doc_id"         => JSON::Any.new(doc_id),
                "parent_doctype" => JSON::Any.new(parent_doctype),
                "kind"           => JSON::Any.new(kind),
              }
            end
            Tools.ok({items: items})
          end
        end

        # Reads a single `core.DocumentView` template by its doc_id.
        private def self.register_get_document_view(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "get_document_view",
            "Read a single DocumentView template by doc_id from the draft domain. Returns {doc_id, parent_doctype, kind, template}.",
            schema_object(
              properties: {"doc_id" => {"type" => "string"}},
              required: ["doc_id"],
            ),
          ) do |args|
            doc_id = req_s("doc_id")

            if err = ensure_view_in_draft!(db, context, doc_id)
              next Tools.error(err)
            end

            row = fetch_core_content(db, "DocumentView", doc_id)
            next Tools.error("DocumentView '#{doc_id}' not found") if row.nil?

            content = row.as_h? || {} of String => JSON::Any
            Tools.ok({
              "doc_id"         => JSON::Any.new(doc_id),
              "parent_doctype" => content["parent_doctype"]? || JSON::Any.new(""),
              "kind"           => content["kind"]? || JSON::Any.new(""),
              "template"       => content["template"]? || JSON::Any.new({} of String => JSON::Any),
            })
          end
        end

        # Lists `core.CollectionView` children of a doctype in the draft.
        # Returns summary rows {doc_id, name, surface} — use
        # `get_collection_view` to read the full config.
        private def self.register_list_collection_views(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "list_collection_views",
            "List CollectionView (saved listing surface) children of a doctype in the draft domain. `doctype` is the qualified doctype id (e.g. '#{context.draft_domain}.Widget'). Returns {items:[{doc_id, name, surface}]}.",
            schema_object(
              properties: {"doctype" => {"type" => "string"}},
              required: ["doctype"],
            ),
          ) do |args|
            doctype = req_s("doctype")

            if err = ensure_doctype_in_draft!(db, context, doctype)
              next Tools.error(err)
            end

            items = db.query_all(
              "SELECT id, content->>'name', content->>'surface' FROM projections WHERE domain='core' AND doc_type='CollectionView' AND deleted_at IS NULL AND meta->>'parent_id' = $1 ORDER BY id",
              doctype,
              as: {String, String, String},
            ).map do |(doc_id, name, surface)|
              {
                "doc_id"  => JSON::Any.new(doc_id),
                "name"    => JSON::Any.new(name),
                "surface" => JSON::Any.new(surface),
              }
            end
            Tools.ok({items: items})
          end
        end

        # Reads a single `core.CollectionView` by its doc_id.
        private def self.register_get_collection_view(agent : Agent, db : DB::Connection, context : Context) : Nil
          agent.register_tool(
            "get_collection_view",
            "Read a single CollectionView by doc_id from the draft domain. Returns {doc_id, name, surface, config, owner_id}.",
            schema_object(
              properties: {"doc_id" => {"type" => "string"}},
              required: ["doc_id"],
            ),
          ) do |args|
            doc_id = req_s("doc_id")

            if err = ensure_collection_view_in_draft!(db, context, doc_id)
              next Tools.error(err)
            end

            row = fetch_core_content(db, "CollectionView", doc_id)
            next Tools.error("CollectionView '#{doc_id}' not found") if row.nil?

            content = row.as_h? || {} of String => JSON::Any
            Tools.ok({
              "doc_id"   => JSON::Any.new(doc_id),
              "name"     => content["name"]? || JSON::Any.new(""),
              "surface"  => content["surface"]? || JSON::Any.new(""),
              "config"   => content["config"]? || JSON::Any.new({} of String => JSON::Any),
              "owner_id" => content["owner_id"]? || JSON::Any.new(nil),
            })
          end
        end

        # Runs `Doctype::Check` against a doctype — the iteration engine.
        private def self.register_check_doctype(agent : Agent, db : DB::Connection) : Nil
          agent.register_tool(
            "check_doctype",
            "Run cross-doctype diagnostics for a single doctype. Also validates the doctype's DocumentView templates structurally and warns when a standard view kind (view, form, quickView, inline, card) is not defined. Returns {doctype_id, issues:[{severity,category,field,message}]}. Use after every create/update to confirm integrity.",
            schema_object(
              properties: {"doctype_id" => {"type" => "string"}},
              required: ["doctype_id"],
            ),
          ) do |args|
            doctype_id = args["doctype_id"]?.try(&.as_s?)
            next Tools.error("Missing 'doctype_id' argument") if doctype_id.nil?

            result = Facet::Doctype::Check.call(db, doctype_id)

            case result
            in Facet::Doctype::Check::Result
              issues = result.issues.map do |issue|
                h = {
                  "severity" => JSON::Any.new(issue.severity.to_s),
                  "category" => JSON::Any.new(issue.category.to_s),
                  "message"  => JSON::Any.new(issue.message),
                }
                if f = issue.field
                  h["field"] = JSON::Any.new(f)
                end
                h
              end
              Tools.ok({doctype_id: result.doctype_id, issues: issues})
            in Facet::ServiceError
              Tools.error(result.message)
            end
          end
        end

        # Returns the raw markdown body of a skill file. Unlike every other
        # tool, the success payload is NOT a JSON envelope — it is the skill's
        # markdown source verbatim (the body already begins with a `# Title`
        # heading). Returning it raw avoids JSON-escaping the markdown, which
        # cuts token cost and keeps the text readable to the model. Errors
        # still use the standard `{ok:false, error:...}` envelope.
        private def self.register_read_skill(agent : Agent) : Nil
          agent.register_tool(
            "read_skill",
            "Read a good-practice skill file by its name (e.g. 'iteration-workflow', 'field-types'). Returns the skill's raw markdown body.",
            schema_object(
              properties: {"name" => {"type" => "string"}},
              required: ["name"],
            ),
          ) do |args|
            name = args["name"]?.try(&.as_s?)
            next Tools.error("Missing 'name' argument") if name.nil?

            skill = Skills.read(name)
            next Tools.error("Skill '#{name}' not found") unless skill

            skill.body
          end
        end

        # Reads the live `content` of one `core.<T>` projection by id, or
        # `nil` when the row is missing or tombstoned. Shared by the
        # projection-reading tools.
        private def self.fetch_core_content(
          db : DB::Connection,
          doc_type : String,
          id : String,
        ) : JSON::Any?
          db.query_one?("SELECT content FROM projections WHERE domain='core' AND doc_type=$1 AND id=$2 AND deleted_at IS NULL",
            doc_type, id,
          ) do |rs|
            rs.read(JSON::Any)
          end
        end
      end
    end
  end
end
