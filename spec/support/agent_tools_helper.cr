# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Agent tool spec helpers ───────────────────────────────────────────────
#
# Shared setup for `spec/agent_tools/*_spec.cr`: builds an authenticated
# `AuthContext` under one of the seeded roles and dispatches a tool call
# directly through `AgentTools.call` (no JSON-RPC framing).

require "../../src/agent_tools"
require "../../src/iam"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"

# Builds an `AuthContext` for the given role. The role must already exist on
# `iam.Roles` — `seed_test_roles` (called by `create_test_account`) seeds
# `iam.Roles.admin`, `iam.Roles.editor`, `iam.Roles.viewer`.
def build_context(db, role : String)
  account_id = create_test_account(db, roles: [role], default_role: role)
  role_content = Facet::IAM::Helpers.find_role_content(db, role).not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

def build_context(db)
  build_context(db, "iam.Roles.viewer")
end

# Builds an `AuthContext` under a bespoke role holding exactly the given
# permission lines (`{"action" => "*", "on" => "*.*"}` shapes). The role is
# created as its own `iam.Roles` projection, so a spec can exercise any
# permission shape — e.g. a pure-wildcard action grant — without touching
# the shared seed roles.
def build_context_with_permissions(db, permissions : Array(Hash(String, String)))
  seed_test_roles(db)
  role_id = "iam.Roles.custom-#{unique_suffix}"
  content = {
    "name"         => "custom-#{unique_suffix}",
    "level"        => 20,
    "description"  => "Bespoke spec role",
    "visible_tags" => ["*"],
    "permissions"  => permissions,
  }.to_json
  Facet::Mutation::Client.create(db, "iam", "Roles", doc_id: role_id,
    content: content, actioner_id: "system")
  account_id = create_test_account(db, roles: [role_id], default_role: role_id)
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated(account_id, active_role)
end

# Dispatches a tool call with JSON-parsed arguments, mirroring how
# `MCP::Routes.tools_call` parses the JSON-RPC `params.arguments` field.
def call_tool(ctx, name, args : String)
  Facet::AgentTools.call(ctx, name, JSON.parse(args))
end

# Same dispatch with an explicit root cause — exercises the cause
# transport into the write services without the registrar involved.
def call_tool_with_cause(ctx, name, args : String, cause : Facet::Mutation::Cause)
  Facet::AgentTools.call(ctx, name, JSON.parse(args), cause)
end

# Builds a minimal doctype named `T<unique>` under domain `#{domain}` with one
# `string` field (`name`, required) and an optional `promote` action whose
# single required arg is `new_title`. `display_name` optionally declares the
# doctype's label template (absent by default, so the projection column stays
# null). `search` optionally declares the search template (absent by default,
# so the doctype stores a NULL search column and matches no search filter).
# Persists it via the document create service as `system`. Returns
# `[domain, doctype]`.
#
# Kept minimal so MCP tool specs can run against a doctype that has no
# cross-doctype references, no computed fields, and no children — keeping
# the focus on the tool adapter, not the doctype fixtures.
def build_simple_doctype(db, domain : String, with_promote : Bool = true, display_name : String? = nil, search : String? = nil) : {String, String}
  ensure_domain(db, domain)
  doctype = "T#{unique_suffix}"
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.promote(ctx, args)
      ctx.root.name = args.new_title
    end
    return export
  LUA
  fields = %({"name": {"type": "string", "required": true, "filters": ["comparison", "text_search"]}})
  actions = with_promote ? %({"promote": {"args": {"new_title": {"type": "string", "required": true}}}}) : "{}"
  dn = display_name ? %("display_name": #{display_name.to_json}, ) : ""
  se = search ? %("search": #{search.to_json}, ) : ""
  # The label gate (B-296) refuses an aggregate root with neither template;
  # default `search` to the reserved `display_name` variable so callers that
  # pass neither still get a valid doctype.
  se = %("search": "{{ display_name }}", ) if dn.empty? && se.empty?
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, #{dn}#{se}"fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{doctype}")
  Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  {domain, doctype}
end

# Creates one document of the given doctype under `system` via `Document::Create`
# and returns its projection id. Useful as a setup primitive for read/write/
# history/action specs.
def create_doc_via_service(db, domain : String, doctype : String, content : String) : String
  res = Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system)
  case res
  in Facet::Document::Create::Result
    res.projection.id
  in Facet::ServiceError
    raise "setup create failed for #{domain}.#{doctype}: #{res.message}"
  end
end

# Builds a parent doctype (aggregate root that declares the `members`
# children collection) and a child doctype (`member_of` the parent, one
# `role` string field). `parent_fields` / `parent_scopes` override the
# parent's field set and named scopes, for RBAC scope cases. Persists both
# definitions via the document create service as `system`. Returns
# `[domain, parent_doctype, child_doctype]`.
def build_parent_child_doctypes(
  db,
  domain : String,
  parent_fields : String = %({}),
  parent_scopes : String = %({}),
) : {String, String, String}
  ensure_domain(db, domain)
  parent = "P#{unique_suffix}"
  child = "C#{unique_suffix}"
  parent_defn = %({"doctype": "#{parent}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": #{parent_fields}, "scopes": #{parent_scopes}, "children": {"members": {"doctype": "#{child}", "collection": true}}})
  child_defn = %({"doctype": "#{child}", "domain": "#{domain}", "aggregate_root": false, "member_of": "#{parent}", "fields": {"role": {"type": "string", "filters": ["equality"]}}})
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{parent}")
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{child}")
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system))
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system))
  {domain, parent, child}
end

# Creates one child document under `parent_id` (stamped as
# `meta.parent_id`, the same way the nested REST route creates children)
# and returns its projection id.
def create_child_doc_via_service(
  db,
  domain : String,
  child_doctype : String,
  parent_id : String,
  content : String,
) : String
  res = Facet::Document::Create.call(
    db, domain, child_doctype, content, Facet::RBAC::AuthContext.system,
    meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
  )
  case res
  in Facet::Document::Create::Result
    res.projection.id
  in Facet::ServiceError
    raise "setup child create failed for #{domain}.#{child_doctype}: #{res.message}"
  end
end
