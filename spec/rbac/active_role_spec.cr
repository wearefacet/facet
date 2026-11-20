# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

module Facet::RBAC
  describe ActiveRole do
    # ── from_projection_content ────────────────────────────────────────────

    describe ".from_projection_content" do
      it "parses name, visible_tags, and permissions from JSON" do
        content = JSON.parse(%({
          "name": "editor",
          "visible_tags": ["default", "internal"],
          "permissions": [
            {"action": "read", "on": "crm.Project"},
            {"action": "update", "on": "crm.Project"}
          ]
        }))
        role = ActiveRole.from_projection_content(content)
        role.role_id.should eq("editor")
        role.visible_tags.should eq(Set{"default", "internal"})
        role.permissions.size.should eq(2)
        role.permissions[0].action.should eq("read")
        role.permissions[1].action.should eq("update")
      end

      it "defaults visible_tags to DEFAULT_VISIBLE_TAGS when missing" do
        content = JSON.parse(%({"name": "minimal", "permissions": []}))
        role = ActiveRole.from_projection_content(content)
        role.visible_tags.should eq(ActiveRole::DEFAULT_VISIBLE_TAGS)
      end

      it "defaults permissions to empty when missing" do
        content = JSON.parse(%({"name": "no_perms"}))
        role = ActiveRole.from_projection_content(content)
        role.permissions.should be_empty
      end

      it "raises ArgumentError when name is missing" do
        content = JSON.parse(%({"permissions": []}))
        expect_raises(ArgumentError, /name/) do
          ActiveRole.from_projection_content(content)
        end
      end
    end

    # ── wildcard_tags? ─────────────────────────────────────────────────────

    describe "#wildcard_tags?" do
      it "returns true when visible_tags contains '*'" do
        role = ActiveRole.new(role_id: "admin", visible_tags: Set{"*"}, permissions: [] of Permission)
        role.wildcard_tags?.should be_true
      end

      it "returns false when visible_tags does not contain '*'" do
        role = ActiveRole.new(role_id: "editor", visible_tags: Set{"default"}, permissions: [] of Permission)
        role.wildcard_tags?.should be_false
      end
    end

    # ── matching_permissions ───────────────────────────────────────────────

    describe "#matching_permissions" do
      it "returns permissions matching action and path" do
        perms = [
          Permission.new(action: "read", domain: "crm", path: ["Project"], scope: nil),
          Permission.new(action: "update", domain: "crm", path: ["Project"], scope: nil),
          Permission.new(action: "read", domain: "hr", path: ["Employee"], scope: nil),
        ]
        role = ActiveRole.new(role_id: "multi", visible_tags: Set{"default"}, permissions: perms)
        matching = role.matching_permissions("read", "crm", ["Project"])
        matching.size.should eq(1)
        matching.first.action.should eq("read")
      end

      it "returns multiple permissions when several match" do
        perms = [
          Permission.new(action: "read", domain: "crm", path: ["Project"], scope: ["$mine"]),
          Permission.new(action: "read", domain: "crm", path: ["Project"], scope: nil),
        ]
        role = ActiveRole.new(role_id: "multi", visible_tags: Set{"default"}, permissions: perms)
        matching = role.matching_permissions("read", "crm", ["Project"])
        matching.size.should eq(2)
      end

      it "returns empty when nothing matches" do
        role = ActiveRole.new(role_id: "empty", visible_tags: Set{"default"}, permissions: [] of Permission)
        role.matching_permissions("read", "crm", ["Project"]).should be_empty
      end
    end

    # ── grants? ────────────────────────────────────────────────────────────

    describe "#grants?" do
      it "returns true when at least one permission matches" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"], scope: nil)
        role = ActiveRole.new(role_id: "reader", visible_tags: Set{"default"}, permissions: [perm])
        role.grants?("read", "crm", ["Project"]).should be_true
      end

      it "returns false when no permission matches" do
        role = ActiveRole.new(role_id: "empty", visible_tags: Set{"default"}, permissions: [] of Permission)
        role.grants?("read", "crm", ["Project"]).should be_false
      end
    end

    # ── DEFAULT_VISIBLE_TAGS ───────────────────────────────────────────────

    describe "DEFAULT_VISIBLE_TAGS" do
      it "is ['default']" do
        ActiveRole::DEFAULT_VISIBLE_TAGS.should eq(Set{"default"})
      end
    end
  end
end
