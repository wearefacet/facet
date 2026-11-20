# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/doctype/definition_store"
require "../support/rbac_helper"

# The `except` carve-out on a permission line: parsing, serialisation,
# prefix exclusion, wildcard interplay, and authoring-time validation.
#
# `except` subtracts doctype paths from a permission's `on` reach. It
# exists because matching permissions OR together: a scoped
# `update core.Domain` line is dead weight while the role also holds
# unrestricted `update *.*`. The carve-out makes the re-grant meaningful.
private def parse_permission(json : String) : Facet::RBAC::Permission
  Facet::RBAC::Permission.from_json(JSON.parse(json))
end

module Facet::RBAC
  describe "Permission except carve-out" do
    describe "parsing" do
      it "defaults except to an empty array" do
        perm = parse_permission(%({"action": "update", "on": "*.*"}))
        perm.except_paths.should eq([] of String)
        perm.unrestricted?.should be_true
      end

      it "parses an except array" do
        perm = parse_permission(
          %({"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"]}),
        )
        perm.except_paths.should eq(["core.Domain", "core.DocType"])
      end

      it "rejects a non-array except" do
        expect_raises(ArgumentError, "except") do
          parse_permission(%({"action": "update", "on": "*.*", "except": "core.Domain"}))
        end
      end

      it "rejects non-string entries" do
        expect_raises(ArgumentError, "strings") do
          parse_permission(%({"action": "update", "on": "*.*", "except": [1]}))
        end
      end

      it "rejects wildcard entries" do
        expect_raises(ArgumentError, "wildcards") do
          parse_permission(%({"action": "update", "on": "*.*", "except": ["*.*"]}))
        end
      end

      it "rejects entries without a doctype segment" do
        expect_raises(ArgumentError, "domain.Doctype") do
          parse_permission(%({"action": "update", "on": "*.*", "except": ["core"]}))
        end
      end

      it "rejects entries with a malformed domain" do
        expect_raises(ArgumentError, "lowercase") do
          parse_permission(%({"action": "update", "on": "*.*", "except": ["Core.Domain"]}))
        end
      end

      it "accepts entries with a hyphenated domain" do
        perm = parse_permission(
          %({"action": "update", "on": "*.*", "except": ["qa-final.WorkItem"]}),
        )
        perm.except_paths.should eq(["qa-final.WorkItem"])
      end

      it "rejects entries with an underscored domain" do
        expect_raises(ArgumentError, "dashes") do
          parse_permission(%({"action": "update", "on": "*.*", "except": ["foo_bar.Domain"]}))
        end
      end

      it "rejects entries with a malformed path segment" do
        expect_raises(ArgumentError, "CamelCase") do
          parse_permission(%({"action": "update", "on": "*.*", "except": ["core.docType"]}))
        end
      end
    end

    describe "serialisation" do
      it "round-trips except through to_h" do
        perm = parse_permission(
          %({"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"], "scope": ["$mine"]}),
        )
        h = perm.to_h
        h["on"].as_s.should eq("*.*")
        h["scope"].as_a.map(&.as_s).should eq(["$mine"])
        h["except"].as_a.map(&.as_s).should eq(["core.Domain", "core.DocType"])
      end

      it "omits except when empty" do
        h = parse_permission(%({"action": "read", "on": "crm.Project"})).to_h
        h.has_key?("except").should be_false
      end
    end

    describe "path matching" do
      it "excludes an exact doctype match" do
        perm = parse_permission(%({"action": "update", "on": "*.*", "except": ["core.Domain"]}))
        perm.matches_path?("core", ["Domain"]).should be_false
        perm.matches_path?("core", ["Currency"]).should be_true
        perm.matches_path?("crm", ["Project"]).should be_true
      end

      it "prefix-matches entries: an entry on core.DocType also excludes core.DocType.Comment" do
        perm = parse_permission(%({"action": "create", "on": "*.*", "except": ["core.DocType"]}))
        perm.matches_path?("core", ["DocType"]).should be_false
        perm.matches_path?("core", ["DocType", "Comment"]).should be_false
        perm.matches_path?("core", ["DocumentView"]).should be_true
      end

      it "prefix-narrows a concrete entry on a wildcard line" do
        perm = parse_permission(%({"action": "update", "on": "*.*", "except": ["crm.Project"]}))
        perm.matches_path?("crm", ["Project"]).should be_false
        perm.matches_path?("crm", ["Project", "Comment"]).should be_false
        perm.matches_path?("crm", ["Task"]).should be_true
      end

      it "does not leak across domains" do
        perm = parse_permission(%({"action": "delete", "on": "*.*", "except": ["core.Domain"]}))
        perm.matches_path?("iam", ["Domain"]).should be_true
      end

      it "combines with scope evaluation (except bites first, at the gate)" do
        # A blanket line with the carve-out plus a scoped re-grant on the
        # same paths: matching_permissions must only see the scoped line.
        blanket = parse_permission(
          %({"action": "update", "on": "*.*", "except": ["core.Domain"]}),
        )
        scoped = parse_permission(
          %({"action": "update", "on": "core.Domain", "scope": ["$mine"]}),
        )
        role = ActiveRole.new(
          role_id: "carved_editor",
          visible_tags: ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [blanket, scoped],
        )

        # The carve-out removes the blanket line for core.Domain, so the
        # only matching permission is the scoped one — can? reports Scoped,
        # not All.
        result = AuthContext.authenticated("acc_1", role)
          .can?("update", "core", ["Domain"])
        result.should be_a(CanResult::Scoped)
      end

      it "keeps intra-role OR for doctypes the carve-out does not name" do
        blanket = parse_permission(
          %({"action": "update", "on": "*.*", "except": ["core.Domain"]}),
        )
        role = ActiveRole.new(
          role_id: "carved_editor",
          visible_tags: ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [blanket],
        )
        result = AuthContext.authenticated("acc_1", role)
          .can?("update", "crm", ["Project"])
        result.should be_a(CanResult::All)
      end
    end

    describe "authoring-time validation" do
      # The path grammar for `except` entries is enforced at parse time
      # (`Permission.from_json`); `validate_permissions` surfaces those
      # parse errors per line.
      it "rejects a wildcard except entry on iam.Roles documents" do
        with_db do |db|
          errors = Validator.validate_permissions_for(
            [JSON.parse(%({"action": "update", "on": "*.*", "except": ["*.*"]}))],
            db,
          )
          errors.should_not be_empty
          errors.first.message.should contain("wildcards")
        end
      end

      it "rejects a malformed except entry on iam.Roles documents" do
        with_db do |db|
          errors = Validator.validate_permissions_for(
            [JSON.parse(%({"action": "update", "on": "*.*", "except": ["core"]}))],
            db,
          )
          errors.should_not be_empty
          errors.first.message.should contain("domain.Doctype")
        end
      end

      it "accepts well-formed except entries" do
        with_db do |db|
          errors = Validator.validate_permissions_for(
            [JSON.parse(%({"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"]}))],
            db,
          )
          errors.should be_empty
        end
      end
    end
  end
end
