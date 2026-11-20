# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

# Builds an in-memory doctype definition with three fields exercising the
# operator-union rule:
# - `owner` — string with only the `equality` filter declared,
# - `title` — string with only `text_search`,
# - `level` — enum with `equality` + `comparison`.
def build_named_scope_definition(scopes : Hash(String, Hash(String, String))) : Facet::Doctype::DoctypeDefinition
  string_type = Facet::Doctype::FieldType.parse("string")
  enum_type = Facet::Doctype::FieldType.parse("enum")
  Facet::Doctype::DoctypeDefinition.new(
    doctype: "Thing",
    domain: "crm",
    fields: {
      "owner" => Facet::Doctype::FieldDefinition.new(type: string_type, filters: [Facet::Doctype::FilterCapability::Equality]),
      "title" => Facet::Doctype::FieldDefinition.new(type: string_type, filters: [Facet::Doctype::FilterCapability::TextSearch]),
      "level" => Facet::Doctype::FieldDefinition.new(type: enum_type, filters: [Facet::Doctype::FilterCapability::Equality, Facet::Doctype::FilterCapability::Comparison]),
    } of String => Facet::Doctype::FieldDefinition,
    actions: {} of String => Facet::Doctype::ActionDefinition,
    scopes: scopes.each_with_object({} of String => Facet::Doctype::NamedScope) do |(name, where), acc|
      acc[name] = Facet::Doctype::NamedScope.new(name: name, where: where)
    end,
  )
end

module Facet::RBAC
  describe Validator do
    # ── validate_permissions ───────────────────────────────────────────────

    describe ".validate_permissions" do
      it "passes valid permissions without scopes" do
        perms = [
          JSON.parse(%({"action": "read", "on": "crm.Project"})),
          JSON.parse(%({"action": "update", "on": "crm.Project.Comment"})),
        ]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.should be_empty
      end

      it "collects error when permission is missing action" do
        perms = [JSON.parse(%({"on": "crm.Project"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.size.should eq(1)
        errors.first.message.should contain("Permission #0")
        errors.first.message.should contain("action")
      end

      it "collects error when permission is missing on" do
        perms = [JSON.parse(%({"action": "read"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.size.should eq(1)
        errors.first.message.should contain("Permission #0")
        errors.first.message.should contain("on")
      end

      it "collects error for invalid domain format" do
        perms = [JSON.parse(%({"action": "read", "on": "Crm.Project"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.any? { |e| e.message.includes?("domain") && e.message.includes?("Crm") }.should be_true
      end

      it "allows a hyphenated domain" do
        perms = [JSON.parse(%({"action": "read", "on": "qa-final.WorkItem"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.should be_empty
      end

      it "collects error for an underscored domain" do
        perms = [JSON.parse(%({"action": "read", "on": "foo_bar.Project"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.any? { |e| e.message.includes?("domain") && e.message.includes?("foo_bar") }.should be_true
      end

      it "collects error for invalid path segment" do
        perms = [JSON.parse(%({"action": "read", "on": "crm.project"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.any? { |e| e.message.includes?("path segment") && e.message.includes?("project") }.should be_true
        errors.any?(&.message.includes?("bare domain")).should be_true
      end

      it "allows the bare domain form (domain-wide scope)" do
        perms = [JSON.parse(%({"action": "read", "on": "crm"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.should be_empty
      end

      it "collects error for wildcard domain without wildcard path" do
        perms = [JSON.parse(%({"action": "read", "on": "*.Project"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.any?(&.message.includes?("wildcard domain")).should be_true
      end

      it "allows wildcard domain with wildcard path" do
        perms = [JSON.parse(%({"action": "read", "on": "*.*"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.should be_empty
      end

      it "rejects the grant-only 'write' action and names the fix" do
        perms = [JSON.parse(%({"action": "write", "on": "crm.Project"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.size.should eq(1)
        errors.first.message.should contain("Permission #0")
        errors.first.message.should contain("'write' is not a role action")
        errors.first.message.should contain("read, create, update, delete")
        errors.first.message.should contain("use 'create/update'")
      end

      it "allows a named action on a role line" do
        perms = [JSON.parse(%({"action": "approve", "on": "crm.Project"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.should be_empty
      end

      it "allows the $all scope unconditionally (no doctype lookup)" do
        perms = [JSON.parse(%({"action": "read", "on": "crm.Project", "scope": "$all"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.should be_empty
      end

      it "rejects a named scope alias when the doctype is not registered" do
        perms = [JSON.parse(%({"action": "read", "on": "crm.Project", "scope": "$mine"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          Validator.validate_permissions(perms, db, errors)
        end
        errors.any?(&.message.includes?("not registered")).should be_true
      end

      it "rejects a named scope alias when the doctype declares no scopes" do
        perms = [JSON.parse(%({"action": "read", "on": "crm.Project", "scope": "$mine"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          ensure_domain(db, "crm")
          # Register a `crm.Project` doctype with no `scopes:` block.
          defn_json = %({"doctype": "Project", "domain": "crm", "fields": {"name": {"type": "string"}}})
          Facet::Document::Create.call(
            db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system
          )
          Validator.validate_permissions(perms, db, errors)
        end
        errors.any? { |e| e.message.includes?("$mine") && e.message.includes?("not declared") }.should be_true
      end

      it "accepts a named scope alias when the doctype declares it" do
        perms = [JSON.parse(%({"action": "read", "on": "crm.Project", "scope": "$mine"}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          ensure_domain(db, "crm")
          defn_json = %({
            "doctype": "Project",
            "domain": "crm",
            "fields": {"owner_id": {"type": "string"}},
            "scopes": {"mine": {"where": {"owner_id": "$self"}}}
          })
          Facet::Document::Create.call(
            db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system
          )
          Validator.validate_permissions(perms, db, errors)
        end
        errors.should be_empty
      end

      it "accepts every alias in a multi-scope array permission when declared" do
        perms = [JSON.parse(%({"action": "read", "on": "crm.Project", "scope": ["$mine", "$global"]}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          ensure_domain(db, "crm")
          defn_json = %({
            "doctype": "Project",
            "domain": "crm",
            "fields": {"owner_id": {"type": "string"}},
            "scopes": {
              "mine":   {"where": {"owner_id": "$self"}},
              "global": {"where": {"owner_id": "$null"}}
            }
          })
          Facet::Document::Create.call(
            db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system
          )
          Validator.validate_permissions(perms, db, errors)
        end
        errors.should be_empty
      end

      it "rejects a multi-scope permission when one alias is undeclared" do
        perms = [JSON.parse(%({"action": "read", "on": "crm.Project", "scope": ["$mine", "$ghost"]}))]
        errors = [] of Facet::ValidationError
        with_db do |db|
          ensure_domain(db, "crm")
          defn_json = %({
            "doctype": "Project",
            "domain": "crm",
            "fields": {"owner_id": {"type": "string"}},
            "scopes": {"mine": {"where": {"owner_id": "$self"}}}
          })
          Facet::Document::Create.call(
            db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system
          )
          Validator.validate_permissions(perms, db, errors)
        end
        errors.any? { |e| e.message.includes?("$ghost") && e.message.includes?("not declared") }.should be_true
        errors.none? { |e| e.message.includes?("$mine") && e.message.includes?("not declared") }.should be_true
      end
    end

    # ── scoped_create_warnings (the scoped-create lint) ────────────────

    describe ".scoped_create_warnings_for" do
      it "warns for a scoped create permission" do
        perms = [JSON.parse(%({"action": "create", "on": "core.Domain", "scope": ["$domain_editor"]}))]
        warnings = Validator.scoped_create_warnings_for(perms)
        warnings.size.should eq(1)
        warnings.first.message.should contain("Permission #0")
        warnings.first.message.should contain("create core.Domain")
        warnings.first.message.should contain("not enforced")
        warnings.first.message.should contain("ctx.actor.scope")
        warnings.first.code.should eq("rbac")
      end

      it "warns for the legacy single-string scope form" do
        perms = [JSON.parse(%({"action": "create", "on": "core.DocumentView", "scope": "$domain_editor"}))]
        warnings = Validator.scoped_create_warnings_for(perms)
        warnings.size.should eq(1)
      end

      it "does not warn for an unrestricted create permission" do
        perms = [
          JSON.parse(%({"action": "create", "on": "core.Domain"})),
        ]
        Validator.scoped_create_warnings_for(perms).should be_empty
      end

      it "does not warn for an explicit $all create permission" do
        perms = [
          JSON.parse(%({"action": "create", "on": "core.Domain", "scope": "$all"})),
          JSON.parse(%({"action": "create", "on": "core.Domain", "scope": ["$all", "$mine"]})),
        ]
        Validator.scoped_create_warnings_for(perms).should be_empty
      end

      it "does not warn for scoped read or update permissions" do
        perms = [
          JSON.parse(%({"action": "read", "on": "core.Comment", "scope": ["$mine"]})),
          JSON.parse(%({"action": "update", "on": "core.Comment", "scope": ["$mine"]})),
        ]
        Validator.scoped_create_warnings_for(perms).should be_empty
      end

      it "does not warn for a wildcard action with a scope" do
        perms = [JSON.parse(%({"action": "*", "on": "crm.Project", "scope": ["$mine"]}))]
        Validator.scoped_create_warnings_for(perms).should be_empty
      end

      it "skips malformed lines and warns on the valid scoped create" do
        perms = [
          JSON.parse(%({"on": "core.Domain"})),
          JSON.parse(%({"action": "create", "on": "core.SchematicLayout", "scope": ["$domain_editor"]})),
        ]
        warnings = Validator.scoped_create_warnings_for(perms)
        warnings.size.should eq(1)
        warnings.first.message.should contain("Permission #1")
      end
    end

    # ── validate_named_scopes (operator / value grammar) ───────────────

    describe ".validate_named_scopes" do
      it "accepts an operator valid for the field's declared filters" do
        defn = build_named_scope_definition({"by_title" => {"title__starts_with" => "Eng"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "rejects an operator outside the field's declared filters" do
        defn = build_named_scope_definition({"by_owner" => {"owner__gt" => "a"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.any? { |e| e.message.includes?("__gt") && e.message.includes?("owner") }.should be_true
      end

      it "rejects an unknown operator suffix" do
        defn = build_named_scope_definition({"bad" => {"owner__frobnicate" => "a"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.size.should eq(1)
        errors[0].message.includes?("not a valid predicate").should be_true
      end

      it "rejects a field that does not exist after suffix stripping" do
        defn = build_named_scope_definition({"ghost" => {"missing__eq" => "a"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.any?(&.message.includes?("missing")).should be_true
      end

      it "accepts $organizational_unit as a value" do
        defn = build_named_scope_definition({"my_ou" => {"owner" => "$organizational_unit"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "rejects $null combined with ne" do
        defn = build_named_scope_definition({"unassigned" => {"owner__ne" => "$null"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.any? { |e| e.message.includes?("$null") && e.message.includes?("eq") }.should be_true
      end

      it "accepts $null combined with eq" do
        defn = build_named_scope_definition({"unassigned" => {"owner" => "$null"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "rejects a context-set value under a comparison operator" do
        sets = {"my_teams" => ContextSet.new(name: "my_teams", from: "T", where: {"account" => "$self"}, select_field: "id")}
        defn = build_named_scope_definition({"by_team" => {"owner__gt" => "$my_teams"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, sets, errors)
        errors.any? { |e| e.message.includes?("eq/ne/match/starts_with") }.should be_true
      end

      it "accepts a context-set value under match" do
        sets = {"my_teams" => ContextSet.new(name: "my_teams", from: "T", where: {"account" => "$self"}, select_field: "name")}
        defn = build_named_scope_definition({"by_team" => {"title__match" => "$my_teams"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, sets, errors)
        errors.should be_empty
      end

      it "rejects an undeclared context-set reference" do
        defn = build_named_scope_definition({"by_team" => {"owner" => "$ghost"}})
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.any?(&.message.includes?("$ghost")).should be_true
      end
    end

    # ── validate_context_set_definitions ───────────────────────────────

    describe ".validate_context_set_definitions" do
      it "passes when there are no context sets" do
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(nil, "crm", {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "passes for acyclic context sets" do
        cs_a = ContextSet.new(name: "my_teams", from: "TeamMembership", where: {"account" => "$self"}, select_field: "team")
        cs_b = ContextSet.new(name: "my_projects", from: "Project", where: {"team" => "$my_teams"}, select_field: "id")
        parsed = {"my_teams" => cs_a, "my_projects" => cs_b}
        raw = JSON.parse(%({"my_teams": {"from": "TeamMembership", "select": "team", "where": {"account": "$self"}}, "my_projects": {"from": "Project", "select": "id", "where": {"team": "$my_teams"}}}))
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(raw, "crm", parsed, errors)
        errors.should be_empty
      end

      it "detects a direct cycle" do
        cs = ContextSet.new(name: "self_ref", from: "Thing", where: {"ref" => "$self_ref"}, select_field: "id")
        parsed = {"self_ref" => cs}
        raw = JSON.parse(%({"self_ref": {"from": "Thing", "select": "id", "where": {"ref": "$self_ref"}}}))
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(raw, "crm", parsed, errors)
        errors.any? { |e| e.message.includes?("cycle") && e.message.includes?("self_ref") }.should be_true
      end

      it "detects an indirect cycle" do
        cs_a = ContextSet.new(name: "a", from: "A", where: {"b" => "$b"}, select_field: "id")
        cs_b = ContextSet.new(name: "b", from: "B", where: {"a" => "$a"}, select_field: "id")
        parsed = {"a" => cs_a, "b" => cs_b}
        raw = JSON.parse(%({"a": {"from": "A", "select": "id", "where": {"b": "$b"}}, "b": {"from": "B", "select": "id", "where": {"a": "$a"}}}))
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(raw, "crm", parsed, errors)
        errors.any?(&.message.includes?("cycle")).should be_true
      end

      it "rejects a SQL injection attempt in the select field" do
        cs = ContextSet.new(name: "mine", from: "Thing", where: {"account" => "$self"}, select_field: "x' UNION SELECT password_hash FROM auth_secrets --")
        parsed = {"mine" => cs}
        raw = JSON.parse(%({"mine": {"from": "Thing", "select": "x' UNION SELECT password_hash FROM auth_secrets --", "where": {"account": "$self"}}}))
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(raw, "crm", parsed, errors)
        errors.any? { |e| e.code == "context_set" && e.message.includes?("select") && e.message.includes?("mine") }.should be_true
      end

      it "rejects a SQL injection attempt in a where field" do
        cs = ContextSet.new(name: "mine", from: "Thing", where: {"x' UNION SELECT 1 --" => "$self"}, select_field: "id")
        parsed = {"mine" => cs}
        raw = JSON.parse(%({"mine": {"from": "Thing", "select": "id", "where": {"x' UNION SELECT 1 --": "$self"}}}))
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(raw, "crm", parsed, errors)
        errors.any? { |e| e.code == "context_set" && e.message.includes?("where") && e.message.includes?("mine") }.should be_true
      end

      it "accepts the $parent_id token in select and where" do
        cs = ContextSet.new(name: "mine", from: "Thing", where: {"$parent_id" => "$self"}, select_field: "$parent_id")
        parsed = {"mine" => cs}
        raw = JSON.parse(%({"mine": {"from": "Thing", "select": "$parent_id", "where": {"$parent_id": "$self"}}}))
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(raw, "crm", parsed, errors)
        errors.should be_empty
      end

      it "accepts camelCase field names" do
        cs = ContextSet.new(name: "mine", from: "Thing", where: {"accountId" => "$self"}, select_field: "teamId")
        parsed = {"mine" => cs}
        raw = JSON.parse(%({"mine": {"from": "Thing", "select": "teamId", "where": {"accountId": "$self"}}}))
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(raw, "crm", parsed, errors)
        errors.should be_empty
      end

      it "rejects a field name with a space" do
        cs = ContextSet.new(name: "mine", from: "Thing", where: {"account" => "$self"}, select_field: "bad field")
        parsed = {"mine" => cs}
        raw = JSON.parse(%({"mine": {"from": "Thing", "select": "bad field", "where": {"account": "$self"}}}))
        errors = [] of Facet::ValidationError
        Validator.validate_context_set_definitions(raw, "crm", parsed, errors)
        errors.any? { |e| e.message.includes?("select") && e.message.includes?("bad field") }.should be_true
      end
    end

    # ── validate_named_scopes ──────────────────────────────────────────────

    describe ".validate_named_scopes" do
      it "passes when no scopes are declared" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Project", domain: "crm",
          fields: {"name" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"))},
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
        )
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "passes for a literal scope over an existing field" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Project", domain: "crm",
          fields: {"status" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("enum"), values: [Doctype::EnumValue.new(key: "active")])},
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
          scopes: {
            "active_only" => Doctype::NamedScope.new(
              name: "active_only",
              where: {"status" => "active"},
            ),
          },
        )
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "passes for a $self scope referencing any field" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Project", domain: "crm",
          fields: {"owner_id" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("reference"))},
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
          scopes: {
            "mine" => Doctype::NamedScope.new(
              name: "mine",
              where: {"owner_id" => "$self"},
            ),
          },
        )
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "passes for a $parent_id field reference" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Task", domain: "crm",
          fields: {"title" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"))},
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
          scopes: {
            "all_parents" => Doctype::NamedScope.new(
              name: "all_parents",
              where: {"$parent_id" => "$self"},
            ),
          },
        )
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "passes for a $<context_set> value when the context set is declared" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Project", domain: "crm",
          fields: {"team" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("reference"))},
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
          scopes: {
            "mine_or_my_teams" => Doctype::NamedScope.new(
              name: "mine_or_my_teams",
              where: {"team" => "$my_teams"},
            ),
          },
        )
        ctx = ContextSet.new(name: "my_teams", from: "TeamMembership", where: {"account" => "$self"}, select_field: "team")
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {"my_teams" => ctx}, errors)
        errors.should be_empty
      end

      it "passes for a $null value (IS NULL predicate)" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Project", domain: "crm",
          fields: {"owner_id" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"))},
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
          scopes: {
            "global" => Doctype::NamedScope.new(
              name: "global",
              where: {"owner_id" => "$null"},
            ),
          },
        )
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.should be_empty
      end

      it "rejects where field that does not exist on the doctype" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Project", domain: "crm",
          fields: {"name" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"))},
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
          scopes: {
            "broken" => Doctype::NamedScope.new(
              name: "broken",
              where: {"nonexistent_field" => "x"},
            ),
          },
        )
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.any? { |e| e.message.includes?("broken") && e.message.includes?("nonexistent_field") }.should be_true
      end

      it "rejects $<context_set> value when the context set is not declared" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Project", domain: "crm",
          fields: {"team" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("reference"))},
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
          scopes: {
            "broken" => Doctype::NamedScope.new(
              name: "broken",
              where: {"team" => "$unknown_set"},
            ),
          },
        )
        errors = [] of Facet::ValidationError
        Validator.validate_named_scopes(defn, {} of String => ContextSet, errors)
        errors.any? { |e| e.message.includes?("broken") && e.message.includes?("unknown_set") }.should be_true
      end
    end

    # ── validate_tags ──────────────────────────────────────────────────────

    describe ".validate_tags" do
      it "passes when visible_tags is nil" do
        warnings = [] of String
        Validator.validate_tags(nil, Set{"default", "confidential"}, warnings)
        warnings.should be_empty
      end

      it "passes for known tags" do
        warnings = [] of String
        Validator.validate_tags(["default", "confidential"], Set{"default", "confidential"}, warnings)
        warnings.should be_empty
      end

      it "skips '*' and 'default' tags" do
        warnings = [] of String
        Validator.validate_tags(["*", "default"], Set{"confidential"}, warnings)
        warnings.should be_empty
      end

      it "warns for unknown tags" do
        warnings = [] of String
        Validator.validate_tags(["unknown_tag"], Set{"default"}, warnings)
        warnings.any?(&.includes?("unknown_tag")).should be_true
      end
    end

    # ── known_tags_from_definition ─────────────────────────────────────────

    describe ".known_tags_from_definition" do
      it "includes 'default' even when no fields have tags" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Person", domain: "hr", schema_version: 1,
          fields: {
            "name" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          },
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
        )
        tags = Validator.known_tags_from_definition(defn)
        tags.should eq(Set{"default"})
      end

      it "collects tags from all fields" do
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Person", domain: "hr", schema_version: 1,
          fields: {
            "name" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
            "ssn"  => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"), tags: ["confidential"]),
            "role" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"), tags: ["internal", "confidential"]),
          },
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
        )
        tags = Validator.known_tags_from_definition(defn)
        tags.should eq(Set{"default", "confidential", "internal"})
      end
    end
  end
end
