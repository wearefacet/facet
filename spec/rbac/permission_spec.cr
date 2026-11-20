# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

module Facet::RBAC
  describe Permission do
    # ── from_json ──────────────────────────────────────────────────────────

    describe ".from_json" do
      it "parses a minimal permission with no scope (unrestricted)" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project"}))
        perm = Permission.from_json(raw)
        perm.action.should eq("read")
        perm.domain.should eq("crm")
        perm.path.should eq(["Project"])
        perm.scope.should eq([] of String)
        perm.unrestricted?.should be_true
      end

      it "parses a permission with the $all scope (string form, unrestricted)" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": "$all"}))
        perm = Permission.from_json(raw)
        perm.scope.should eq([] of String)
        perm.unrestricted?.should be_true
      end

      it "parses a permission with a single named scope alias (legacy string form)" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": "$mine"}))
        perm = Permission.from_json(raw)
        perm.scope.should eq(["$mine"])
        perm.unrestricted?.should be_false
        perm.scope_aliases.should eq(["mine"])
      end

      it "parses a permission with a single-element scope array (canonical form)" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": ["$mine"]}))
        perm = Permission.from_json(raw)
        perm.scope.should eq(["$mine"])
        perm.scope_aliases.should eq(["mine"])
      end

      it "parses a permission with multiple scope aliases (OR semantics)" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": ["$mine", "$global"]}))
        perm = Permission.from_json(raw)
        perm.scope.should eq(["$mine", "$global"])
        perm.unrestricted?.should be_false
        perm.scope_aliases.should eq(["mine", "global"])
      end

      it "collapses to unrestricted when $all appears in an array scope" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": ["$all", "$mine"]}))
        perm = Permission.from_json(raw)
        perm.scope.should eq([] of String)
        perm.unrestricted?.should be_true
      end

      it "keeps an unaliased scope (without $ prefix) verbatim in scope_aliases" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": ["mine"]}))
        perm = Permission.from_json(raw)
        perm.scope_aliases.should eq(["mine"])
      end

      it "parses a nested path (domain.Root.Child)" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project.Comment"}))
        perm = Permission.from_json(raw)
        perm.domain.should eq("crm")
        perm.path.should eq(["Project", "Comment"])
      end

      it "parses a hyphenated domain" do
        raw = JSON.parse(%({"action": "read", "on": "qa-final.WorkItem"}))
        perm = Permission.from_json(raw)
        perm.domain.should eq("qa-final")
        perm.path.should eq(["WorkItem"])
      end

      it "parses a wildcard permission" do
        raw = JSON.parse(%({"action": "*", "on": "*.*"}))
        perm = Permission.from_json(raw)
        perm.action.should eq("*")
        perm.domain.should eq("*")
        perm.path.should eq(["*"])
      end

      it "raises ArgumentError when 'action' is missing" do
        raw = JSON.parse(%({"on": "crm.Project"}))
        expect_raises(ArgumentError, /action/) do
          Permission.from_json(raw)
        end
      end

      it "raises ArgumentError when 'on' is missing" do
        raw = JSON.parse(%({"action": "read"}))
        expect_raises(ArgumentError, /on/) do
          Permission.from_json(raw)
        end
      end

      it "raises ArgumentError when scope is a non-string scalar" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": 5}))
        expect_raises(ArgumentError, /string or an array of strings/) do
          Permission.from_json(raw)
        end
      end

      it "raises ArgumentError when scope array contains a non-string" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": ["$mine", 5]}))
        expect_raises(ArgumentError, /entries must be strings/) do
          Permission.from_json(raw)
        end
      end
    end

    # ── matches_action? ────────────────────────────────────────────────────

    describe "#matches_action?" do
      it "matches exact action" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.matches_action?("read").should be_true
      end

      it "matches wildcard action" do
        perm = Permission.new(action: "*", domain: "crm", path: ["Project"])
        perm.matches_action?("update").should be_true
      end

      it "does not match a different action" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.matches_action?("delete").should be_false
      end
    end

    # ── matches_path? ──────────────────────────────────────────────────────

    describe "#matches_path?" do
      it "matches exact domain and path" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.matches_path?("crm", ["Project"]).should be_true
      end

      it "matches prefix path (parent matches child)" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.matches_path?("crm", ["Project", "Comment"]).should be_true
      end

      it "does not match different domain" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.matches_path?("hr", ["Project"]).should be_false
      end

      it "does not match different path" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.matches_path?("crm", ["Task"]).should be_false
      end

      it "wildcard domain matches everything" do
        perm = Permission.new(action: "read", domain: "*", path: ["*"])
        perm.matches_path?("any", ["Thing"]).should be_true
      end

      it "does not match when target path is shorter than permission path" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project", "Comment"])
        perm.matches_path?("crm", ["Project"]).should be_false
      end
    end

    # ── covers_create? ─────────────────────────────────────────────────────

    describe "#covers_create?" do
      it "returns true when action is create and path matches" do
        perm = Permission.new(action: "create", domain: "crm", path: ["Project"])
        perm.covers_create?("crm", ["Project"]).should be_true
      end

      it "returns false when action is not create" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.covers_create?("crm", ["Project"]).should be_false
      end

      it "returns false when path does not match" do
        perm = Permission.new(action: "create", domain: "crm", path: ["Project"])
        perm.covers_create?("hr", ["Project"]).should be_false
      end
    end

    # ── wildcard? ──────────────────────────────────────────────────────────

    describe "#wildcard?" do
      it "returns true for *.* with * action" do
        perm = Permission.new(action: "*", domain: "*", path: ["*"])
        perm.wildcard?.should be_true
      end

      it "returns false for non-wildcard domain" do
        perm = Permission.new(action: "*", domain: "crm", path: ["*"])
        perm.wildcard?.should be_false
      end

      it "returns false for non-wildcard action" do
        perm = Permission.new(action: "read", domain: "*", path: ["*"])
        perm.wildcard?.should be_false
      end
    end

    # ── unrestricted? / scope_aliases ─────────────────────────────────────

    describe "#unrestricted? / #scope_aliases" do
      it "treats absent scope as unrestricted" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.unrestricted?.should be_true
        perm.scope_aliases.should eq([] of String)
      end

      it "treats $all as unrestricted" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"], scope: ["$all"])
        perm.unrestricted?.should be_true
        perm.scope_aliases.should eq([] of String)
      end

      it "strips $ from each named scope alias" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"], scope: ["$mine", "$global"])
        perm.unrestricted?.should be_false
        perm.scope_aliases.should eq(["mine", "global"])
      end

      it "defaults scope to an empty array when omitted in initializer" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        perm.scope.should eq([] of String)
      end
    end

    # ── to_h ───────────────────────────────────────────────────────────────

    describe "#to_h" do
      it "round-trips a single-scope permission as an array" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": "$mine"}))
        perm = Permission.from_json(raw)
        h = perm.to_h
        h["action"].should eq(JSON::Any.new("read"))
        h["on"].should eq(JSON::Any.new("crm.Project"))
        h["scope"].should eq(JSON::Any.new([JSON::Any.new("$mine")]))
      end

      it "round-trips a multi-scope permission as an array, preserving order" do
        raw = JSON.parse(%({"action": "read", "on": "crm.Project", "scope": ["$mine", "$global"]}))
        perm = Permission.from_json(raw)
        h = perm.to_h
        h["scope"].should eq(JSON::Any.new([JSON::Any.new("$mine"), JSON::Any.new("$global")]))
      end

      it "omits scope key for unrestricted permissions" do
        perm = Permission.new(action: "read", domain: "crm", path: ["Project"])
        h = perm.to_h
        h["action"]?.should_not be_nil
        h["scope"]?.should be_nil
      end
    end
  end
end
