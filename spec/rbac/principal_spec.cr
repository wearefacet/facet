# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

module Facet::RBAC
  describe Principal do
    # ── Principal::System ──────────────────────────────────────────────────

    describe Principal::System do
      it "account_id is 'system'" do
        Principal::System.new.account_id.should eq("system")
      end

      it "accepts a custom account_id" do
        Principal::System.new("system:assistant").account_id.should eq("system:assistant")
      end

      it "is a Principal" do
        Principal::System.new.should be_a(Principal)
      end

      it "is not a Real" do
        Principal::System.new.should_not be_a(Principal::Real)
      end
    end

    # ── Principal::Real ────────────────────────────────────────────────────

    describe Principal::Real do
      it "stores account_id and active_role" do
        role = ActiveRole.new(role_id: "admin", visible_tags: Set{"*"}, permissions: [] of Permission)
        p = Principal::Real.new("account_1", role)
        p.account_id.should eq("account_1")
        p.active_role.role_id.should eq("admin")
      end

      it "is a Principal" do
        role = ActiveRole.new(role_id: "admin", visible_tags: Set{"*"}, permissions: [] of Permission)
        Principal::Real.new("account_1", role).should be_a(Principal)
      end

      it "is not a System" do
        role = ActiveRole.new(role_id: "admin", visible_tags: Set{"*"}, permissions: [] of Permission)
        Principal::Real.new("account_1", role).should_not be_a(Principal::System)
      end
    end

    # ── Principal::Preview ─────────────────────────────────────────────────

    describe Principal::Preview do
      it "stores account_id and preview_domain" do
        p = Principal::Preview.new("account_1", "_abc")
        p.account_id.should eq("account_1")
        p.preview_domain.should eq("_abc")
      end

      it "is a Principal" do
        Principal::Preview.new("account_1", "_abc").should be_a(Principal)
      end

      it "is neither System nor Real" do
        p = Principal::Preview.new("account_1", "_abc")
        p.should_not be_a(Principal::System)
        p.should_not be_a(Principal::Real)
      end
    end
  end
end
