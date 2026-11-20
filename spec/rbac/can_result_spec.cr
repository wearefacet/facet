# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

module Facet::RBAC
  describe CanResult do
    # ── Denied ─────────────────────────────────────────────────────────────

    describe CanResult::Denied do
      it "is a CanResult" do
        CanResult::Denied.new.should be_a(CanResult)
      end

      it "is_a? returns true for Denied" do
        CanResult::Denied.new.should be_a(CanResult::Denied)
      end

      it "is not All or Scoped" do
        d = CanResult::Denied.new
        d.should_not be_a(CanResult::All)
        d.should_not be_a(CanResult::Scoped)
      end
    end

    # ── All ────────────────────────────────────────────────────────────────

    describe CanResult::All do
      it "is a CanResult" do
        CanResult::All.new.should be_a(CanResult)
      end

      it "is_a? returns true for All" do
        CanResult::All.new.should be_a(CanResult::All)
      end

      it "is not Denied or Scoped" do
        a = CanResult::All.new
        a.should_not be_a(CanResult::Denied)
        a.should_not be_a(CanResult::Scoped)
      end
    end

    # ── Scoped ─────────────────────────────────────────────────────────────

    describe CanResult::Scoped do
      it "is a CanResult carrying permissions" do
        perm = Permission.new(
          action: "read", domain: "crm", path: ["Project"],
          scope: nil
        )
        scoped = CanResult::Scoped.new([perm])
        scoped.should be_a(CanResult)
        scoped.permissions.size.should eq(1)
        scoped.permissions.first.action.should eq("read")
      end

      it "is_a? returns true for Scoped" do
        CanResult::Scoped.new([] of Permission).should be_a(CanResult::Scoped)
      end

      it "is not Denied or All" do
        s = CanResult::Scoped.new([] of Permission)
        s.should_not be_a(CanResult::Denied)
        s.should_not be_a(CanResult::All)
      end

      it "carries multiple permissions" do
        perms = [
          Permission.new(action: "read", domain: "crm", path: ["Project"], scope: nil),
          Permission.new(action: "update", domain: "crm", path: ["Project"], scope: nil),
        ]
        scoped = CanResult::Scoped.new(perms)
        scoped.permissions.size.should eq(2)
      end
    end
  end
end
