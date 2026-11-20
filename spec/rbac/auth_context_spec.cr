# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

module Facet::RBAC
  describe AuthContext do
    # ── Principal::System ─────────────────────────────────────────────────

    describe "AuthContext.system" do
      it "creates a system principal" do
        ctx = AuthContext.system
        ctx.system?.should be_true
        ctx.account_id.should eq("system")
        ctx.principal.should be_a(Principal::System)
      end

      it "accepts a custom account_id" do
        ctx = AuthContext.system("system:assistant")
        ctx.system?.should be_true
        ctx.account_id.should eq("system:assistant")
        ctx.principal.should be_a(Principal::System)
      end

      it "can? returns All for any action and path" do
        ctx = AuthContext.system

        result = ctx.can?("read", "crm", ["Project"])
        result.should be_a(CanResult::All)

        result = ctx.can?("create", "crm", ["Project"])
        result.should be_a(CanResult::All)

        result = ctx.can?("delete", "hr", ["Employee"])
        result.should be_a(CanResult::All)

        result = ctx.can?("promote", "crm", ["Project"])
        result.should be_a(CanResult::All)
      end

      it "can? with dot-path returns All" do
        ctx = AuthContext.system
        result = ctx.can?("read", "crm.Project")
        result.should be_a(CanResult::All)
      end
    end

    # ── Principal::Real ──────────────────────────────────────────────────

    describe "AuthContext.authenticated" do
      it "creates a real principal with an active role" do
        role = ActiveRole.new(
          role_id: "admin",
          visible_tags: Set{"*"},
          permissions: [] of Permission
        )
        ctx = AuthContext.authenticated("account_123", role)
        ctx.system?.should be_false
        ctx.account_id.should eq("account_123")
        ctx.principal.should be_a(Principal::Real)
      end

      it "raises ArgumentError when account_id is 'system'" do
        role = ActiveRole.new(role_id: "admin", visible_tags: Set{"*"}, permissions: [] of Permission)
        expect_raises(ArgumentError, /reserved/) do
          AuthContext.authenticated("system", role)
        end
      end

      it "raises ArgumentError when account_id is 'anonymous'" do
        role = ActiveRole.new(role_id: "admin", visible_tags: Set{"*"}, permissions: [] of Permission)
        expect_raises(ArgumentError, /reserved/) do
          AuthContext.authenticated("anonymous", role)
        end
      end
    end

    # ── can? return variants ──────────────────────────────────────────────

    describe "#can?" do
      it "returns Denied when no permission matches" do
        role = ActiveRole.new(
          role_id: "reader",
          visible_tags: Set{"default"},
          permissions: [] of Permission
        )
        ctx = AuthContext.authenticated("account_1", role)

        result = ctx.can?("read", "crm", ["Project"])
        result.should be_a(CanResult::Denied)
      end

      it "returns All when a matching permission has an empty scope" do
        perm = Permission.new(
          action: "read",
          domain: "crm",
          path: ["Project"],
          scope: nil
        )
        role = ActiveRole.new(
          role_id: "reader",
          visible_tags: Set{"default"},
          permissions: [perm]
        )
        ctx = AuthContext.authenticated("account_1", role)

        result = ctx.can?("read", "crm", ["Project"])
        result.should be_a(CanResult::All)
      end

      it "returns All when a matching permission has the wildcard action '*'" do
        perm = Permission.new(
          action: "*",
          domain: "crm",
          path: ["Project"],
          scope: nil
        )
        role = ActiveRole.new(
          role_id: "admin",
          visible_tags: Set{"*"},
          permissions: [perm]
        )
        ctx = AuthContext.authenticated("admin_1", role)

        result = ctx.can?("update", "crm", ["Project"])
        result.should be_a(CanResult::All)
      end

      it "returns All when a matching permission has the wildcard path '*.*'" do
        perm = Permission.new(
          action: "read",
          domain: "*",
          path: ["*"],
          scope: nil
        )
        role = ActiveRole.new(
          role_id: "god",
          visible_tags: Set{"*"},
          permissions: [perm]
        )
        ctx = AuthContext.authenticated("god_1", role)

        result = ctx.can?("read", "any", ["Thing"])
        result.should be_a(CanResult::All)
      end

      it "returns Scoped when matching permissions have scope constraints" do
        perm = Permission.new(
          action: "read",
          domain: "crm",
          path: ["Project"],
          scope: "$mine"
        )
        role = ActiveRole.new(
          role_id: "reader",
          visible_tags: Set{"default"},
          permissions: [perm]
        )
        ctx = AuthContext.authenticated("account_1", role)

        result = ctx.can?("read", "crm", ["Project"])
        result.should be_a(CanResult::Scoped)
        result.as(CanResult::Scoped).permissions.size.should eq(1)
        result.as(CanResult::Scoped).permissions.first.unrestricted?.should be_false
      end

      it "returns Scoped with all matching permissions (not just first)" do
        perm1 = Permission.new(
          action: "read",
          domain: "crm",
          path: ["Project"],
          scope: "$mine"
        )
        perm2 = Permission.new(
          action: "read",
          domain: "crm",
          path: ["Project"],
          scope: "$my_teams"
        )
        role = ActiveRole.new(
          role_id: "reader",
          visible_tags: Set{"default"},
          permissions: [perm1, perm2]
        )
        ctx = AuthContext.authenticated("account_1", role)

        result = ctx.can?("read", "crm", ["Project"])
        result.should be_a(CanResult::Scoped)
        result.as(CanResult::Scoped).permissions.size.should eq(2)
      end

      it "matches nested child paths via prefix matching" do
        # Permission on "Project" should match "Project.Comment"
        perm = Permission.new(
          action: "read",
          domain: "crm",
          path: ["Project"],
          scope: nil
        )
        role = ActiveRole.new(
          role_id: "reader",
          visible_tags: Set{"default"},
          permissions: [perm]
        )
        ctx = AuthContext.authenticated("account_1", role)

        result = ctx.can?("read", "crm", ["Project", "Comment"])
        result.should be_a(CanResult::All)
      end
    end

    # ── dot-path overload ─────────────────────────────────────────────────

    describe "#can? with dot-path" do
      it "parses 'crm.Project' into domain='crm', path=['Project']" do
        perm = Permission.new(
          action: "read",
          domain: "crm",
          path: ["Project"],
          scope: nil
        )
        role = ActiveRole.new(
          role_id: "reader",
          visible_tags: Set{"default"},
          permissions: [perm]
        )
        ctx = AuthContext.authenticated("account_1", role)
        ctx.can?("read", "crm.Project").should be_a(CanResult::All)
      end

      it "parses 'crm.Project.Comment' into domain='crm', path=['Project','Comment']" do
        perm = Permission.new(
          action: "read",
          domain: "crm",
          path: ["Project"],
          scope: nil
        )
        role = ActiveRole.new(
          role_id: "reader",
          visible_tags: Set{"default"},
          permissions: [perm]
        )
        ctx = AuthContext.authenticated("account_1", role)
        ctx.can?("read", "crm.Project.Comment").should be_a(CanResult::All)
      end

      it "raises ArgumentError on a bare domain without doctype" do
        role = ActiveRole.new(
          role_id: "reader",
          visible_tags: Set{"default"},
          permissions: [] of Permission
        )
        ctx = AuthContext.authenticated("account_1", role)
        expect_raises(ArgumentError, /must include at least/) do
          ctx.can?("read", "crm")
        end
      end
    end

    # ── CanResult type hierarchy ──────────────────────────────────────────

    describe CanResult do
      it "Denied is a CanResult" do
        CanResult::Denied.new.should be_a(CanResult)
      end

      it "All is a CanResult" do
        CanResult::All.new.should be_a(CanResult)
      end

      it "Scoped is a CanResult carrying permissions" do
        perm = Permission.new(
          action: "read", domain: "crm", path: ["Project"],
          scope: nil
        )
        scoped = CanResult::Scoped.new([perm])
        scoped.should be_a(CanResult)
        scoped.permissions.size.should eq(1)
        scoped.permissions.first.action.should eq("read")
      end

      it "is_a? works for all three variants" do
        CanResult::Denied.new.should be_a(CanResult::Denied)
        CanResult::All.new.should be_a(CanResult::All)
        CanResult::Scoped.new([] of Permission).should be_a(CanResult::Scoped)
      end
    end

    # ── Principal types ──────────────────────────────────────────────────

    describe Principal do
      it "System#account_id is 'system'" do
        Principal::System.new.account_id.should eq("system")
      end

      it "Real#account_id and #active_role are accessible" do
        role = ActiveRole.new(
          role_id: "tester",
          visible_tags: Set{"default"},
          permissions: [] of Permission
        )
        p = Principal::Real.new("tester_1", role)
        p.account_id.should eq("tester_1")
        p.active_role.role_id.should eq("tester")
      end

      it "System is not a Real" do
        Principal::System.new.should_not be_a(Principal::Real)
      end

      it "Preview stores account_id and preview_domain" do
        p = Principal::Preview.new("account_1", "_abc")
        p.account_id.should eq("account_1")
        p.preview_domain.should eq("_abc")
      end
    end

    # ── AuthContext.preview ─────────────────────────────────────────────

    describe "AuthContext.preview" do
      it "creates a preview principal bound to a draft domain" do
        ctx = AuthContext.preview("account_1", "_abc")
        ctx.system?.should be_false
        ctx.preview?.should be_true
        ctx.account_id.should eq("account_1")
        ctx.preview_domain.should eq("_abc")
        ctx.principal.should be_a(Principal::Preview)
      end

      it "raises ArgumentError when account_id is 'system'" do
        expect_raises(ArgumentError, /reserved/) do
          AuthContext.preview("system", "_abc")
        end
      end

      it "raises ArgumentError when account_id is 'anonymous'" do
        expect_raises(ArgumentError, /reserved/) do
          AuthContext.preview("anonymous", "_abc")
        end
      end

      it "raises ArgumentError when preview_domain is empty" do
        expect_raises(ArgumentError, /preview_domain/) do
          AuthContext.preview("account_1", "")
        end
      end

      it "carries no app grant or app id" do
        ctx = AuthContext.preview("account_1", "_abc")
        ctx.app_grant.should be_nil
        ctx.app_id.should be_nil
      end

      it "#can? raises — preview does not consult the role/permission system" do
        ctx = AuthContext.preview("account_1", "_abc")
        expect_raises(ArgumentError, /preview principal/) do
          ctx.can?("read", "_abc", ["Widget"])
        end
      end
    end

    # ── AuthContext.anonymous ──────────────────────────────────────────

    describe "AuthContext.anonymous" do
      anonymous_role = ActiveRole.new(
        role_id: "anonymous",
        visible_tags: Set{"default"},
        permissions: [Permission.new(action: "read", domain: "core", path: ["Currency"], scope: nil)],
      )

      it "creates a real principal carrying the reserved anonymous identity" do
        ctx = AuthContext.anonymous(anonymous_role)
        ctx.system?.should be_false
        ctx.preview?.should be_false
        ctx.account_id.should eq("anonymous")
        ctx.principal.should be_a(Principal::Real)
        ctx.principal.as(Principal::Real).active_role.role_id.should eq("anonymous")
      end

      it "carries no app grant, app id, acting role, or api key id" do
        ctx = AuthContext.anonymous(anonymous_role)
        ctx.app_grant.should be_nil
        ctx.app_id.should be_nil
        ctx.acting_role.should be_nil
        ctx.api_key_id.should be_nil
      end

      it "can? follows the anonymous role's permissions" do
        ctx = AuthContext.anonymous(anonymous_role)
        ctx.can?("read", "core", ["Currency"]).should be_a(CanResult::All)
        ctx.can?("read", "crm", ["Company"]).should be_a(CanResult::Denied)
        ctx.can?("create", "core", ["Currency"]).should be_a(CanResult::Denied)
        ctx.can?("delete", "core", ["Currency"]).should be_a(CanResult::Denied)
      end

      it "an empty anonymous role denies every action (fail closed)" do
        empty_role = ActiveRole.new(
          role_id: "anonymous",
          visible_tags: Set{"default"},
          permissions: [] of Permission,
        )
        ctx = AuthContext.anonymous(empty_role)
        ctx.can?("read", "core", ["Currency"]).should be_a(CanResult::Denied)
      end
    end
  end
end
