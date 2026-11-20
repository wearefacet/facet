# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

# Builds a permission from the wire hash — the same parse path role
# authoring uses, so the tests exercise the stored grammar. Top-level
# `private def`: file-scoped (see doc/backend/workflow.md → Testing).
private def implication_perm(raw : String) : Facet::RBAC::Permission
  Facet::RBAC::Permission.from_json(JSON.parse(raw))
end

module Facet::RBAC
  describe "Permission#implied_by?" do
    # ── action ───────────────────────────────────────────────────────────

    it "implies an exact action match" do
      new_line = implication_perm(%({"action": "update", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "update", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_true
    end

    it "implies any action through the holder wildcard action" do
      new_line = implication_perm(%({"action": "promote", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "*", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_true
    end

    it "refuses a wildcard action not covered by a concrete holder action" do
      new_line = implication_perm(%({"action": "*", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "update", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_false
    end

    it "refuses a named action the holder does not carry" do
      new_line = implication_perm(%({"action": "promote", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "archive", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_false
    end

    # ── reach ────────────────────────────────────────────────────────────

    it "implies an exact path" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_true
    end

    it "implies a child path under a parent holder path" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project.Comment"}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_true
    end

    it "refuses a parent path under a child holder path" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project.Comment"}))
      new_line.implied_by?(holder).should be_false
    end

    it "refuses a sibling path" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Task"}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_false
    end

    it "refuses a different domain" do
      new_line = implication_perm(%({"action": "read", "on": "hr.Employee"}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_false
    end

    it "implies any domain through the wildcard holder domain" do
      new_line = implication_perm(%({"action": "read", "on": "hr.Employee"}))
      holder = implication_perm(%({"action": "read", "on": "*.*"}))
      new_line.implied_by?(holder).should be_true
    end

    it "refuses the wildcard reach not carried by the holder" do
      new_line = implication_perm(%({"action": "read", "on": "*.*"}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_false
    end

    it "implies the wildcard reach through the wildcard holder reach" do
      new_line = implication_perm(%({"action": "read", "on": "*.*"}))
      holder = implication_perm(%({"action": "read", "on": "*.*"}))
      new_line.implied_by?(holder).should be_true
    end

    # ── except carve-outs ───────────────────────────────────────────────

    it "implies when the holder exception sits outside the new reach" do
      new_line = implication_perm(%({"action": "update", "on": "crm.Task"}))
      holder = implication_perm(%({"action": "update", "on": "crm.Project", "except": ["core.DocType"]}))
      new_line.implied_by?(holder).should be_false
    end

    it "refuses when the holder exception fully covers the new reach and the new line does not exclude it" do
      new_line = implication_perm(%({"action": "update", "on": "crm.Project.Comment"}))
      holder = implication_perm(%({"action": "update", "on": "crm.Project", "except": ["crm.Project.Comment"]}))
      new_line.implied_by?(holder).should be_false
    end

    it "implies when the new line carries the same covering exception" do
      new_line = implication_perm(%({"action": "update", "on": "crm.Project.Comment", "except": ["crm.Project.Comment"]}))
      holder = implication_perm(%({"action": "update", "on": "crm.Project", "except": ["crm.Project.Comment"]}))
      new_line.implied_by?(holder).should be_true
    end

    it "refuses when the holder exception partially intersects and the new line does not exclude it" do
      new_line = implication_perm(%({"action": "update", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "update", "on": "crm.Project", "except": ["crm.Project.Comment"]}))
      new_line.implied_by?(holder).should be_false
    end

    it "implies when the new exception narrows the intersecting holder carve-out" do
      new_line = implication_perm(%({"action": "update", "on": "crm.Project", "except": ["crm.Project.Comment"]}))
      holder = implication_perm(%({"action": "update", "on": "crm.Project", "except": ["crm.Project.Comment"]}))
      new_line.implied_by?(holder).should be_true
    end

    it "allows extra new exceptions (narrowing only)" do
      new_line = implication_perm(%({"action": "update", "on": "crm.Project", "except": ["crm.Project.Comment", "crm.Project.Log"]}))
      holder = implication_perm(%({"action": "update", "on": "crm.Project", "except": ["crm.Project.Comment"]}))
      new_line.implied_by?(holder).should be_true
    end

    it "requires the wildcard line to carry every holder carve-out" do
      new_line = implication_perm(%({"action": "read", "on": "*.*"}))
      holder = implication_perm(%({"action": "read", "on": "*.*", "except": ["core.SystemSettings"]}))
      new_line.implied_by?(holder).should be_false
    end

    it "implies the wildcard line when it repeats the holder carve-out" do
      new_line = implication_perm(%({"action": "read", "on": "*.*", "except": ["core.SystemSettings"]}))
      holder = implication_perm(%({"action": "read", "on": "*.*", "except": ["core.SystemSettings"]}))
      new_line.implied_by?(holder).should be_true
    end

    # ── scope ────────────────────────────────────────────────────────────

    it "implies any scope through an unrestricted holder" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_true
    end

    it "implies an identical named scope" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
      new_line.implied_by?(holder).should be_true
    end

    it "implies a scope subset of the holder aliases" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine", "$global"]}))
      new_line.implied_by?(holder).should be_true
    end

    it "refuses a scope superset of the holder aliases" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine", "$global"]}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
      new_line.implied_by?(holder).should be_false
    end

    it "refuses an unrestricted new line under a scoped holder" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
      new_line.implied_by?(holder).should be_false
    end

    it "refuses an empty scope array under a scoped holder" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project", "scope": []}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
      new_line.implied_by?(holder).should be_false
    end

    it "collapses an explicit $all on the holder to unrestricted" do
      new_line = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project", "scope": ["$all"]}))
      new_line.implied_by?(holder).should be_true
    end

    # ── combined shapes ──────────────────────────────────────────────────

    it "does not imply the run-19 god-role line from editor CRUD lines" do
      god_line = implication_perm(%({"action": "*", "on": "*.*"}))
      editor_create = implication_perm(%({"action": "create", "on": "*.*", "except": ["core.DocType", "core.DocumentView", "core.DomainEditor", "core.SystemSettings", "iam.OIDCProvider"]}))
      editor_update = implication_perm(%({"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType", "core.DocumentView", "core.DomainEditor", "core.SystemSettings", "iam.OIDCProvider"]}))
      editor_delete = implication_perm(%({"action": "delete", "on": "*.*", "except": ["core.Domain", "core.DocType", "core.DocumentView", "core.DomainEditor", "core.SystemSettings", "iam.OIDCProvider"]}))
      editor_read = implication_perm(%({"action": "read", "on": "*.*", "except": ["core.SystemSettings", "iam.OIDCProvider"]}))

      god_line.implied_by?(editor_create).should be_false
      god_line.implied_by?(editor_update).should be_false
      god_line.implied_by?(editor_delete).should be_false
      god_line.implied_by?(editor_read).should be_false
    end

    it "implies a narrowed editor line from the admin god-role" do
      editor_create = implication_perm(%({"action": "create", "on": "*.*", "except": ["core.DocType", "core.DocumentView", "core.DomainEditor", "core.SystemSettings", "iam.OIDCProvider"]}))
      admin = implication_perm(%({"action": "*", "on": "*.*"}))
      editor_create.implied_by?(admin).should be_true
    end

    it "does not imply a line from an unrelated holder" do
      new_line = implication_perm(%({"action": "update", "on": "crm.Project"}))
      holder = implication_perm(%({"action": "read", "on": "crm.Project"}))
      new_line.implied_by?(holder).should be_false
    end
  end
end
