# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

# Wraps a raw `where` value into a predicate for the `owner_id` field
# with the given operator (default: equality).
def predicate_for(raw : String, op : Facet::Doctype::Operator = Facet::Doctype::Operator::Eq) : Facet::RBAC::ScopePredicate
  Facet::RBAC::ScopePredicate.new("owner_id", op, Facet::RBAC::ScopeValue.parse(raw))
end

def ctx : Facet::RBAC::ScopeContext
  Facet::RBAC::ScopeContext.root("account_1")
end

def no_context_results : Hash(String, Array(String))
  {} of String => Array(String)
end

module Facet::RBAC
  describe ScopeMatcher do
    # ── match? ────────────────────────────────────────────────────────────

    describe ".match?" do
      it "matches a literal value" do
        actual = JSON::Any.new("engineering")
        ScopeMatcher.match?(predicate_for("engineering"), actual, ctx, no_context_results).should be_true
      end

      it "does not match a different literal value" do
        actual = JSON::Any.new("marketing")
        ScopeMatcher.match?(predicate_for("engineering"), actual, ctx, no_context_results).should be_false
      end

      it "matches $self when actual equals the qualified account reference" do
        actual = JSON::Any.new("iam.Account.account_1")
        ScopeMatcher.match?(predicate_for("$self"), actual, ctx, no_context_results).should be_true
      end

      it "matches $self when actual equals the bare account id" do
        # A plain string owner field stores the bare id (the documented
        # `ctx.root.owner_id = ctx.actor.id` create-hook recipe).
        actual = JSON::Any.new("account_1")
        ScopeMatcher.match?(predicate_for("$self"), actual, ctx, no_context_results).should be_true
      end

      it "does not match $self when actual differs from account_id" do
        actual = JSON::Any.new("other_account")
        ScopeMatcher.match?(predicate_for("$self"), actual, ctx, no_context_results).should be_false
      end

      it "does not match $self when actual is another account in qualified form" do
        actual = JSON::Any.new("iam.Account.other_account")
        ScopeMatcher.match?(predicate_for("$self"), actual, ctx, no_context_results).should be_false
      end

      # ── Ne against $self (both principal forms) ─────────────────────────

      it "does not match Ne $self when actual is the bare account id" do
        actual = JSON::Any.new("account_1")
        ScopeMatcher.match?(predicate_for("$self", Facet::Doctype::Operator::Ne), actual, ctx, no_context_results).should be_false
      end

      it "does not match Ne $self when actual is the qualified reference" do
        actual = JSON::Any.new("iam.Account.account_1")
        ScopeMatcher.match?(predicate_for("$self", Facet::Doctype::Operator::Ne), actual, ctx, no_context_results).should be_false
      end

      it "matches Ne $self for another account" do
        actual = JSON::Any.new("iam.Account.other_account")
        ScopeMatcher.match?(predicate_for("$self", Facet::Doctype::Operator::Ne), actual, ctx, no_context_results).should be_true
      end

      # ── Match / StartsWith against $self (both principal forms) ─────────

      it "matches Match $self against the bare account id" do
        actual = JSON::Any.new("account_1")
        ScopeMatcher.match?(predicate_for("$self", Facet::Doctype::Operator::Match), actual, ctx, no_context_results).should be_true
      end

      it "matches Match $self against the qualified reference" do
        actual = JSON::Any.new("iam.Account.account_1")
        ScopeMatcher.match?(predicate_for("$self", Facet::Doctype::Operator::Match), actual, ctx, no_context_results).should be_true
      end

      it "matches StartsWith $self against both principal forms" do
        pred = predicate_for("$self", Facet::Doctype::Operator::StartsWith)
        ScopeMatcher.match?(pred, JSON::Any.new("account_1"), ctx, no_context_results).should be_true
        ScopeMatcher.match?(pred, JSON::Any.new("iam.Account.account_1"), ctx, no_context_results).should be_true
      end

      it "does not match StartsWith $self for another account" do
        actual = JSON::Any.new("iam.Account.other_account")
        ScopeMatcher.match?(predicate_for("$self", Facet::Doctype::Operator::StartsWith), actual, ctx, no_context_results).should be_false
      end

      it "matches a context set value when actual is in resolved results" do
        actual = JSON::Any.new("team_a")
        context_results = {"my_teams" => ["team_a", "team_b"]}
        ScopeMatcher.match?(predicate_for("$my_teams"), actual, ctx, context_results).should be_true
      end

      it "does not match a context set value when actual is not in resolved results" do
        actual = JSON::Any.new("team_c")
        context_results = {"my_teams" => ["team_a", "team_b"]}
        ScopeMatcher.match?(predicate_for("$my_teams"), actual, ctx, context_results).should be_false
      end

      it "returns false when context set is not found in results" do
        actual = JSON::Any.new("anything")
        ScopeMatcher.match?(predicate_for("$unknown"), actual, ctx, no_context_results).should be_false
      end

      # ── $organizational_unit ────────────────────────────────────────────

      it "matches $organizational_unit when actual equals the actioner OU" do
        actual = JSON::Any.new("/engineering/")
        scope_context = ScopeContext.new("account_1", "/engineering/")
        ScopeMatcher.match?(predicate_for("$organizational_unit"), actual, scope_context, no_context_results).should be_true
      end

      it "does not match $organizational_unit when actual differs from the actioner OU" do
        actual = JSON::Any.new("/marketing/")
        scope_context = ScopeContext.new("account_1", "/engineering/")
        ScopeMatcher.match?(predicate_for("$organizational_unit"), actual, scope_context, no_context_results).should be_false
      end

      # ── Ne ──────────────────────────────────────────────────────────────

      it "matches Ne when actual differs from the literal" do
        actual = JSON::Any.new("marketing")
        ScopeMatcher.match?(predicate_for("engineering", Facet::Doctype::Operator::Ne), actual, ctx, no_context_results).should be_true
      end

      it "does not match Ne when actual equals the literal" do
        actual = JSON::Any.new("engineering")
        ScopeMatcher.match?(predicate_for("engineering", Facet::Doctype::Operator::Ne), actual, ctx, no_context_results).should be_false
      end

      # ── Match / StartsWith ──────────────────────────────────────────────

      it "matches Match as a case-insensitive substring" do
        actual = JSON::Any.new("Platform Engineering")
        ScopeMatcher.match?(predicate_for("engineering", Facet::Doctype::Operator::Match), actual, ctx, no_context_results).should be_true
      end

      it "treats % as a literal in Match (never a wildcard)" do
        actual = JSON::Any.new("Platform Engineering")
        ScopeMatcher.match?(predicate_for("%", Facet::Doctype::Operator::Match), actual, ctx, no_context_results).should be_false
      end

      it "matches StartsWith as a case-insensitive prefix" do
        actual = JSON::Any.new("/Engineering/Backend/")
        ScopeMatcher.match?(predicate_for("/engineering", Facet::Doctype::Operator::StartsWith), actual, ctx, no_context_results).should be_true
      end

      it "does not match StartsWith when the prefix differs" do
        actual = JSON::Any.new("/Marketing/")
        ScopeMatcher.match?(predicate_for("/engineering", Facet::Doctype::Operator::StartsWith), actual, ctx, no_context_results).should be_false
      end

      # ── Comparison operators ────────────────────────────────────────────

      it "compares numerically for Gt" do
        actual = JSON::Any.new(20_i64)
        ScopeMatcher.match?(predicate_for("9", Facet::Doctype::Operator::Gt), actual, ctx, no_context_results).should be_true
      end

      it "compares lexicographically for a string literal that is not numeric" do
        actual = JSON::Any.new("b")
        ScopeMatcher.match?(predicate_for("a", Facet::Doctype::Operator::Gt), actual, ctx, no_context_results).should be_true
      end

      it "falls back to lexicographic comparison when neither side parses as numeric or datetime" do
        actual = JSON::Any.new("not-a-number")
        ScopeMatcher.match?(predicate_for("zzz", Facet::Doctype::Operator::Gt), actual, ctx, no_context_results).should be_false
      end

      # ── Contains / Currency ─────────────────────────────────────────────

      it "matches Contains on an array member" do
        actual = JSON.parse(%(["alpha", "beta"]))
        ScopeMatcher.match?(predicate_for("beta", Facet::Doctype::Operator::Contains), actual, ctx, no_context_results).should be_true
      end

      it "does not match Contains when the array lacks the literal" do
        actual = JSON.parse(%(["alpha"]))
        ScopeMatcher.match?(predicate_for("beta", Facet::Doctype::Operator::Contains), actual, ctx, no_context_results).should be_false
      end

      it "matches Currency on the money object's currency member" do
        actual = JSON.parse(%({"value": "12.00", "currency": "USD"}))
        ScopeMatcher.match?(predicate_for("USD", Facet::Doctype::Operator::Currency), actual, ctx, no_context_results).should be_true
      end

      it "does not match Currency on a different ticker" do
        actual = JSON.parse(%({"value": "12.00", "currency": "EUR"}))
        ScopeMatcher.match?(predicate_for("USD", Facet::Doctype::Operator::Currency), actual, ctx, no_context_results).should be_false
      end

      # ── $null and unsupported operators ─────────────────────────────────

      it "matches $null with Eq against an explicit JSON null" do
        actual = JSON::Any.new(nil)
        ScopeMatcher.match?(predicate_for("$null"), actual, ctx, no_context_results).should be_true
      end

      it "does not match $null with Eq against a present value" do
        actual = JSON::Any.new("assigned")
        ScopeMatcher.match?(predicate_for("$null"), actual, ctx, no_context_results).should be_false
      end

      it "degrades Between to false (no two-bound grammar in `where`)" do
        actual = JSON::Any.new(5_i64)
        ScopeMatcher.match?(predicate_for("1", Facet::Doctype::Operator::Between), actual, ctx, no_context_results).should be_false
      end
    end
  end
end
