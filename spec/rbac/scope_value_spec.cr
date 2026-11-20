# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

module Facet::RBAC
  describe ScopeValue do
    # ── parse ──────────────────────────────────────────────────────────────

    describe ".parse" do
      it "parses $self as Self type" do
        sv = ScopeValue.parse("$self")
        sv.type.should eq(ScopeValueType::Self)
        sv.raw.should eq("$self")
      end

      it "parses $set_name as ContextSet type" do
        sv = ScopeValue.parse("$my_teams")
        sv.type.should eq(ScopeValueType::ContextSet)
        sv.raw.should eq("$my_teams")
      end

      it "parses a literal string as Literal type" do
        sv = ScopeValue.parse("engineering")
        sv.type.should eq(ScopeValueType::Literal)
        sv.raw.should eq("engineering")
      end

      it "parses a numeric string as Literal type" do
        sv = ScopeValue.parse("42")
        sv.type.should eq(ScopeValueType::Literal)
        sv.raw.should eq("42")
      end

      it "parses a boolean literal string as Literal type" do
        sv = ScopeValue.parse("true")
        sv.type.should eq(ScopeValueType::Literal)
        sv.raw.should eq("true")
      end

      it "parses $null as Null type" do
        sv = ScopeValue.parse("$null")
        sv.type.should eq(ScopeValueType::Null)
        sv.raw.should eq("$null")
      end

      it "does not parse $null as a context set" do
        ScopeValue.parse("$null").context_set?.should be_false
        ScopeValue.parse("$null").context_set_name.should be_nil
      end

      it "parses $organizational_unit as OrganizationalUnit type" do
        sv = ScopeValue.parse("$organizational_unit")
        sv.type.should eq(ScopeValueType::OrganizationalUnit)
        sv.raw.should eq("$organizational_unit")
      end

      it "does not parse $organizational_unit as a context set" do
        ScopeValue.parse("$organizational_unit").context_set?.should be_false
        ScopeValue.parse("$organizational_unit").context_set_name.should be_nil
      end
    end

    # ── context_set? ───────────────────────────────────────────────────────

    describe "#context_set?" do
      it "returns true for a context set value" do
        ScopeValue.parse("$my_teams").context_set?.should be_true
      end

      it "returns false for $self" do
        ScopeValue.parse("$self").context_set?.should be_false
      end

      it "returns false for a literal" do
        ScopeValue.parse("engineering").context_set?.should be_false
      end
    end

    # ── context_set_name ───────────────────────────────────────────────────

    describe "#context_set_name" do
      it "returns the name without $ prefix" do
        ScopeValue.parse("$my_teams").context_set_name.should eq("my_teams")
      end

      it "returns nil for $self" do
        ScopeValue.parse("$self").context_set_name.should be_nil
      end

      it "returns nil for a literal" do
        ScopeValue.parse("engineering").context_set_name.should be_nil
      end
    end

    # ── equality ───────────────────────────────────────────────────────────

    describe "#==" do
      it "is equal when type and raw match" do
        ScopeValue.parse("$self").should eq(ScopeValue.parse("$self"))
      end

      it "is not equal when type differs" do
        ScopeValue.parse("$self").should_not eq(ScopeValue.parse("$team"))
      end

      it "is not equal when raw differs" do
        ScopeValue.parse("$team_a").should_not eq(ScopeValue.parse("$team_b"))
      end
    end
  end
end
