# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../../src/rbac"
require "../../src/doctype/definition_store"
require "../../src/mutation/client"
require "../../src/document"

# ── RBAC shared fixtures ─────────────────────────────────────────────────
#
# Top-level defs in spec files are program-wide: when two files define the
# same name, the last one compiled silently wins. Shared fixtures therefore
# live here, exactly once — never copy them into a spec file (the gate in
# `scripts/check-spec-defs.sh` fails any second public definition).

# Creates the `crm.Project` doctype with the named scopes used by the
# enforcer specs:
#   - `mine`        → {owner_id: $self}
#   - `engineering` → {department: engineering}
#   - `global`      → {owner_id: $null}  (rows with no / null owner)
def create_rbac_project_doctype(db) : Nil
  defn_json = %({
    "doctype": "Project",
    "domain": "crm",
    "schema_version": 1,
    "aggregate_root": true,
    "search": "{{ display_name }}",
    "fields": {
      "title":      {"type": "string"},
      "owner_id":   {"type": "string"},
      "department": {"type": "string"}
    },
    "scopes": {
      "mine":        {"where": {"owner_id": "$self"}},
      "engineering": {"where": {"department": "engineering"}},
      "global":      {"where": {"owner_id": "$null"}}
    }
  })
  Facet::Document::Create.call(
    db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system
  )
end

# Creates a document of the given doctype with `title` set and any
# `content_overrides` merged in. Returns the document id.
def create_rbac_test_doc(db, domain, doc_type, content_overrides = {} of String => String) : String
  doc_id = "test_#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..12]}"
  content = {"title" => JSON::Any.new("test")}
  content_overrides.each { |k, v| content[k] = JSON::Any.new(v) }
  content_json = JSON::Any.new(content).to_json
  Facet::Mutation::Client.create(
    db, domain, doc_type,
    doc_id: doc_id,
    content: content_json,
    actioner_id: "system",
  )
  doc_id
end

# Builds one in-memory `RBAC::Permission` in the array-scope grammar.
def rbac_perm(action : String, on : String, scope : Array(String)? = nil) : Facet::RBAC::Permission
  parts = on.split('.')
  Facet::RBAC::Permission.new(
    action: action,
    domain: parts[0],
    path: parts[1..],
    scope: scope,
  )
end

# Wraps permissions into an `RBAC::ActiveRole` projection twin.
def rbac_role(perms : Array(Facet::RBAC::Permission), role_id : String = "test_role") : Facet::RBAC::ActiveRole
  Facet::RBAC::ActiveRole.new(
    role_id: role_id,
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: perms,
  )
end

# ── RBAC enforcement diagnostics ─────────────────────────────────────────────
#
# A bare `authorized? → false` from an enforcer names no layer. The denial can
# sit in three places:
#
#   1. the permission gate — the role projection granted nothing (`Denied`);
#   2. the scope expansion — the doctype definition lacks the alias (`nil`);
#   3. the row-content match — the projection content fails the predicates.
#
# `rbac_scope_diagnostics` re-walks those layers read-only and returns a
# compact report, so a failing spec's message pinpoints the layer. It issues
# the same trusted reads the enforcers perform — no writes, no state changes.

def rbac_scope_diagnostics(
  db : DB::Connection,
  action : String,
  domain : String,
  doc_type : String,
  doc_id : String,
  auth_context : Facet::RBAC::AuthContext,
) : String
  lines = [] of String
  lines << "action=#{action} on=#{domain}.#{doc_type} doc=#{doc_id}"

  # Layer 1 — the permission gate over the active role.
  gate = Facet::RBAC::EnforcerSupport.dispatch_action(action, domain, doc_type, auth_context)
  lines << "gate=#{gate.gate}"
  gate.permissions.each_with_index do |perm, i|
    lines << "gate_perm[#{i}]=#{perm.to_h.to_json}"
  end

  unless auth_context.system?
    principal = auth_context.principal
    if principal.is_a?(Facet::RBAC::Principal::Real)
      role = principal.active_role
      lines << "role_id=#{role.role_id.inspect} role_permissions=#{role.permissions.size}"
      role.permissions.each_with_index do |perm, i|
        lines << "role_perm[#{i}]=#{perm.to_h.to_json}"
      end
    end
  end

  # Layer 2 — the row this test reads (the enforcer reads it by primary key,
  # without a deleted_at filter; the state is reported verbatim).
  doc_content = nil
  doc_deleted_at = nil
  db.query_one?(
    "SELECT content, deleted_at FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
    domain, doc_type, doc_id,
  ) do |rs|
    doc_content = rs.read(::JSON::Any)
    doc_deleted_at = rs.read(Time?)
  end
  lines << "doc_present=#{!doc_content.nil?} deleted_at=#{doc_deleted_at.inspect}"
  lines << "doc_content=#{doc_content.inspect}"

  # Layer 3 — the doctype definition the aliases expand against.
  definition = Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{doc_type}")
  lines << "definition_present=#{!definition.nil?}"
  unless definition.nil?
    lines << "definition_scopes=#{definition.scopes.keys.inspect}"
  end

  # Layer 4 — the per-alias expansion and the row match.
  return lines.join("\n") if auth_context.system?

  lines << "ctx.account_id=#{auth_context.account_id.inspect}"
  # `$self` predicates match both stored principal forms — print the pair
  # so a denial diagnostic shows every value a scope comparison accepts.
  lines << "principal_forms=#{Facet::RBAC.principal_forms(auth_context.account_id).inspect}"

  scope_context = Facet::RBAC::ScopeContext.load(db, auth_context.account_id)
  lines << "scope_context_ou=#{scope_context.organizational_unit.inspect}"

  context_results = Facet::RBAC::ContextResolver.resolve_for_domain(db, domain, scope_context)
  lines << "context_sets=#{context_results.keys.inspect}"

  gate.permissions.each_with_index do |perm, i|
    expanded = Facet::RBAC::ScopeExpander.expand_all(perm, definition)
    if expanded.nil?
      lines << "perm[#{i}] expand=nil (unknown alias or definition missing)"
      next
    end

    expanded.each_with_index do |predicates, ai|
      lines << "perm[#{i}] alias[#{ai}] predicates=#{predicates.inspect}"
    end
  end

  # Layer 4 — the shared single-row gate: the row satisfies the compiled
  # scope clauses (same `ScopePredicateSql` engine as the list path).
  matched = Facet::RBAC::EnforcerSupport.row_authorized?(db, action, domain, doc_type, doc_id, auth_context)
  lines << "row_gate=#{matched}"

  lines.join("\n")
end

# Asserts that `ReadEnforcer.authorized?` allows the read. On a denial, fails
# with the layer-by-layer diagnostics instead of a bare boolean.
def expect_rbac_authorized(
  db : DB::Connection,
  domain : String,
  doc_type : String,
  doc_id : String,
  auth_context : Facet::RBAC::AuthContext,
) : Nil
  result = Facet::RBAC::ReadEnforcer.authorized?(db, domain, doc_type, doc_id, auth_context)
  unless result
    fail("ReadEnforcer.authorized? denied — " \
         "#{rbac_scope_diagnostics(db, "read", domain, doc_type, doc_id, auth_context)}")
  end
end

# Asserts that `ReadEnforcer.authorized?` denies the read. On an unexpected
# allow, fails with the layer-by-layer diagnostics.
def expect_rbac_denied(
  db : DB::Connection,
  domain : String,
  doc_type : String,
  doc_id : String,
  auth_context : Facet::RBAC::AuthContext,
) : Nil
  result = Facet::RBAC::ReadEnforcer.authorized?(db, domain, doc_type, doc_id, auth_context)
  if result
    fail("ReadEnforcer.authorized? unexpectedly allowed — " \
         "#{rbac_scope_diagnostics(db, "read", domain, doc_type, doc_id, auth_context)}")
  end
end
