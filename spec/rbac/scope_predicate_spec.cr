# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

def scope_context : Facet::RBAC::ScopeContext
  Facet::RBAC::ScopeContext.new("account_1", "/engineering/")
end

module Facet::RBAC
  describe ScopePredicateParser do
    describe ".parse_where" do
      it "defaults to Eq when the key has no operator suffix" do
        predicates = ScopePredicateParser.parse_where({"status" => "active"})
        predicates.size.should eq(1)
        predicates[0].field.should eq("status")
        predicates[0].operator.eq?.should be_true
        predicates[0].value.type.should eq(ScopeValueType::Literal)
        predicates[0].value.raw.should eq("active")
      end

      it "parses an operator suffix into the Doctype operator" do
        predicates = ScopePredicateParser.parse_where({"ou__starts_with" => "/engineering"})
        predicates[0].field.should eq("ou")
        predicates[0].operator.starts_with?.should be_true
      end

      it "round-trips the reserved $parent_id field token" do
        # `$parent_id` contains no `__` separator, so it parses as a bare
        # field with the default Eq operator.
        predicates = ScopePredicateParser.parse_where({"$parent_id" => "$my_projects"})
        predicates[0].field.should eq("$parent_id")
        predicates[0].operator.eq?.should be_true
        predicates[0].value.type.should eq(ScopeValueType::ContextSet)
      end

      it "parses the $organizational_unit value token" do
        predicates = ScopePredicateParser.parse_where({"ou" => "$organizational_unit"})
        predicates[0].value.type.should eq(ScopeValueType::OrganizationalUnit)
      end

      it "raises on an unknown operator suffix" do
        expect_raises(ArgumentError) do
          ScopePredicateParser.parse_where({"status__frobnicate" => "x"})
        end
      end

      it "keeps every entry of a multi-predicate where map" do
        predicates = ScopePredicateParser.parse_where({
          "status"    => "active",
          "owner_id"  => "$self",
          "ou__match" => "engineering",
        })
        predicates.size.should eq(3)
      end
    end
  end

  describe ScopePredicateSql do
    describe ".build_clauses" do
      it "returns a nil clause for an empty predicate list" do
        clause, params, idx = ScopePredicateSql.build_clauses(
          [] of ScopePredicate, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should be_nil
        params.should be_empty
        idx.should eq(1)
      end

      it "emits an equality clause with the OU token resolved" do
        predicates = ScopePredicateParser.parse_where({"ou" => "$organizational_unit"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should eq("content->>'ou' = $1")
        params.should eq(["/engineering/"] of ::DB::Any)
        idx.should eq(2)
      end

      it "emits $self across both principal forms" do
        predicates = ScopePredicateParser.parse_where({"owner_id" => "$self"})
        clause, params, _idx = ScopePredicateSql.build_clauses(
          predicates, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should eq("(content->>'owner_id' = $1 OR content->>'owner_id' = $2)")
        params.should eq(["account_1", "iam.Account.account_1"] of ::DB::Any)
      end

      it "emits an escaped prefix clause for starts_with" do
        predicates = ScopePredicateParser.parse_where({"ou__starts_with" => "/eng%"})
        clause, params, _idx = ScopePredicateSql.build_clauses(
          predicates, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should eq("content->>'ou' ILIKE $1 || '%' ESCAPE '\\'")
        params.should eq(["/eng\\%"] of ::DB::Any)
      end

      it "emits IS NULL for $null with eq and IS NOT NULL for ne" do
        eq_predicates = ScopePredicateParser.parse_where({"owner_id" => "$null"})
        clause, _params, _idx = ScopePredicateSql.build_clauses(
          eq_predicates, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should eq("content->>'owner_id' IS NULL")

        ne_predicates = ScopePredicateParser.parse_where({"owner_id__ne" => "$null"})
        clause, _params, _idx = ScopePredicateSql.build_clauses(
          ne_predicates, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should eq("content->>'owner_id' IS NOT NULL")
      end

      it "resolves $parent_id to the meta linkage expression" do
        predicates = ScopePredicateParser.parse_where({"$parent_id" => "proj_1"})
        clause, _params, _idx = ScopePredicateSql.build_clauses(
          predicates, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should eq("meta->>'parent_id' = $1")
      end

      it "fails closed with FALSE for a comparison operator without a definition" do
        predicates = ScopePredicateParser.parse_where({"priority__gt" => "5"})
        clause, _params, _idx = ScopePredicateSql.build_clauses(
          predicates, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should eq("FALSE")
      end

      it "AND-combines multiple predicates with sequential placeholders" do
        predicates = ScopePredicateParser.parse_where({
          "status"  => "active",
          "owner"   => "$self",
          "ou__gte" => "5",
        })
        clause, params, _idx = ScopePredicateSql.build_clauses(
          predicates, scope_context, {} of String => Array(String), 1, nil
        )
        clause.should_not be_nil
        # status (1 param) + $self (both principal forms) + gte without a
        # definition (fails closed, no params).
        params.size.should eq(3)
      end
    end
  end
end
