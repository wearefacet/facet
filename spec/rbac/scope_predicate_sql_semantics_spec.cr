# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

# Builds an in-memory doctype definition exercising the field-driven
# dispatch of `ScopePredicateSql`'s type-aware clause builders:
# - `price`  — money  → routes to `money_clauses`
# - `level`  — integer → routes to `typed_clauses`
# - `name`   — string → text ordering fallback
# - `window` — period → routes to `range_clauses`
def dispatch_definition : Facet::Doctype::DoctypeDefinition
  money_type = Facet::Doctype::FieldType.parse("money")
  int_type = Facet::Doctype::FieldType.parse("integer")
  string_type = Facet::Doctype::FieldType.parse("string")
  period_type = Facet::Doctype::FieldType.parse("period")
  Facet::Doctype::DoctypeDefinition.new(
    doctype: "Thing",
    domain: "crm",
    fields: {
      "price"  => Facet::Doctype::FieldDefinition.new(type: money_type, filters: [] of Facet::Doctype::FilterCapability),
      "level"  => Facet::Doctype::FieldDefinition.new(type: int_type, filters: [] of Facet::Doctype::FilterCapability),
      "name"   => Facet::Doctype::FieldDefinition.new(type: string_type, filters: [] of Facet::Doctype::FilterCapability),
      "window" => Facet::Doctype::FieldDefinition.new(type: period_type, filters: [] of Facet::Doctype::FilterCapability),
    } of String => Facet::Doctype::FieldDefinition,
    actions: {} of String => Facet::Doctype::ActionDefinition,
    scopes: {} of String => Facet::Doctype::NamedScope,
  )
end

module Facet::RBAC
  describe ScopePredicateSql do
    describe "Ne against a context set (fail closed)" do
      it "emits FALSE for an empty resolved set (no rows, never vacuous-true)" do
        predicates = ScopePredicateParser.parse_where({"team__ne" => "$my_teams"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {"my_teams" => [] of String}, 1, nil,
        )
        clause.should eq("FALSE")
        params.should be_empty
        idx.should eq(1)
      end

      it "treats a missing set name as an empty set and emits FALSE" do
        predicates = ScopePredicateParser.parse_where({"team__ne" => "$my_teams"})
        clause, _params, _idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, nil,
        )
        clause.should eq("FALSE")
      end

      it "emits NOT (... = ANY(...)) for a non-empty resolved set" do
        predicates = ScopePredicateParser.parse_where({"team__ne" => "$my_teams"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {"my_teams" => ["eng", "design"] of String}, 1, nil,
        )
        clause.should eq("NOT (content->>'team' = ANY(string_to_array($1, ',')))")
        params.should eq(["eng,design"] of ::DB::Any)
        idx.should eq(2)
      end
    end

    describe "Eq and pattern clauses through the unified compiler" do
      it "emits membership for Eq against a non-empty resolved set" do
        predicates = ScopePredicateParser.parse_where({"team" => "$my_teams"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {"my_teams" => ["eng", "design"] of String}, 1, nil,
        )
        clause.should eq("content->>'team' = ANY(string_to_array($1, ','))")
        params.should eq(["eng,design"] of ::DB::Any)
        idx.should eq(2)
      end

      it "emits 1=0 for Eq against an empty resolved set" do
        predicates = ScopePredicateParser.parse_where({"team" => "$my_teams"})
        clause, params, _idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {"my_teams" => [] of String}, 1, nil,
        )
        clause.should eq("1=0")
        params.should be_empty
      end

      it "emits an EXISTS pattern clause for Match against a non-empty set" do
        predicates = ScopePredicateParser.parse_where({"team__match" => "$my_teams"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {"my_teams" => ["eng"] of String}, 1, nil,
        )
        # One bound parameter serves both the unnested membership list and
        # the pattern value (pre-refactor `ContextResolver.emit_pattern`
        # behaviour, preserved verbatim).
        clause.should eq(
          "EXISTS (SELECT 1 FROM unnest(string_to_array($1, ',')) AS v " \
          "WHERE content->>'team' ILIKE '%' || $1 || '%' ESCAPE '\\')"
        )
        params.should eq(["eng"] of ::DB::Any)
        idx.should eq(2)
      end

      it "emits FALSE for Match against an empty resolved set" do
        predicates = ScopePredicateParser.parse_where({"team__match" => "$my_teams"})
        clause, params, _idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {"my_teams" => [] of String}, 1, nil,
        )
        clause.should eq("FALSE")
        params.should be_empty
      end
    end

    describe "$self across both stored principal forms" do
      it "binds the bare id and the qualified reference for Eq" do
        predicates = ScopePredicateParser.parse_where({"owner_id" => "$self"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, nil,
        )
        clause.should eq("(content->>'owner_id' = $1 OR content->>'owner_id' = $2)")
        params.should eq(["account_1", "iam.Account.account_1"] of ::DB::Any)
        idx.should eq(3)
      end

      it "keeps IS DISTINCT FROM for Ne across both forms" do
        predicates = ScopePredicateParser.parse_where({"owner_id__ne" => "$self"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, nil,
        )
        clause.should eq(
          "(content->>'owner_id' IS DISTINCT FROM $1 AND content->>'owner_id' IS DISTINCT FROM $2)"
        )
        params.should eq(["account_1", "iam.Account.account_1"] of ::DB::Any)
        idx.should eq(3)
      end

      it "ORs the StartsWith pattern across both forms" do
        predicates = ScopePredicateParser.parse_where({"owner_id__starts_with" => "$self"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, nil,
        )
        clause.should eq(
          "(content->>'owner_id' ILIKE $1 || '%' ESCAPE '\\' OR " \
          "content->>'owner_id' ILIKE $2 || '%' ESCAPE '\\')"
        )
        # Pattern bounds are LIKE-escaped (the `_` in `account_1` becomes
        # `\_`), the same contract as the literal pattern clause.
        params.should eq(["account\\_1", "iam.Account.account\\_1"] of ::DB::Any)
        idx.should eq(3)
      end

      it "matches both stored forms against real rows (regression pair)" do
        with_db do |db|
          ensure_domain(db, "crm")
          create_rbac_project_doctype(db)

          # The pair: a bare-id string field (what the documented
          # `ctx.root.owner_id = ctx.actor.id` recipe stores) and the
          # qualified reference form (what a reference-typed owner field
          # stores). Both must match their owner's `$self` predicate.
          bare_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "account_1"})
          qualified_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "iam.Account.account_1"})
          create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "someone_else"})

          predicates = ScopePredicateParser.parse_where({"owner_id" => "$self"})
          clause, params, _idx = ScopePredicateSql.build_clauses(
            predicates, ScopeContext.root("account_1"),
            {} of String => Array(String), 1, nil,
          )
          ids = db.query_all(
            "SELECT id FROM projections WHERE domain = 'crm' AND doc_type = 'Project' AND deleted_at IS NULL AND #{clause}",
            args: params, as: String,
          )
          ids.size.should eq(2)
          ids.should contain(bare_id)
          ids.should contain(qualified_id)
        end
      end
    end

    describe "money / range dispatch (field-driven)" do
      it "routes gt on a money field to the numeric money value clause" do
        predicates = ScopePredicateParser.parse_where({"price__gt" => "5"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, dispatch_definition,
        )
        clause.should eq("facet_money_value_as_numeric(content->'price') > $1::numeric")
        params.size.should eq(1)
        idx.should eq(2)
      end

      it "never falls back to a text comparison on a money field" do
        predicates = ScopePredicateParser.parse_where({"price__lte" => "5"})
        clause, _params, _idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, dispatch_definition,
        )
        clause.should_not be_nil
        clause.to_s.should contain("facet_money_value_as_numeric")
        clause.to_s.should_not contain("content->>'price'")
      end

      it "routes the currency operator on a money field to the ticker clause" do
        predicates = ScopePredicateParser.parse_where({"price__currency" => "USD"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, dispatch_definition,
        )
        clause.should eq("content#>>'{price,currency}' = $1")
        params.should eq(["USD"] of ::DB::Any)
        idx.should eq(2)
      end

      it "fails closed for between on a money field (single-string RHS cannot express two bounds)" do
        predicates = ScopePredicateParser.parse_where({"price__between" => "5"})
        clause, params, _idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, dispatch_definition,
        )
        clause.should eq("FALSE")
        params.should be_empty
      end

      it "fails closed for the currency operator on a non-money field" do
        predicates = ScopePredicateParser.parse_where({"name__currency" => "USD"})
        clause, params, _idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, dispatch_definition,
        )
        clause.should eq("FALSE")
        params.should be_empty
      end

      it "routes gte on a typed field to the numeric cast clause" do
        predicates = ScopePredicateParser.parse_where({"level__gte" => "5"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, dispatch_definition,
        )
        clause.should eq("jsonb_as_numeric(content->'level') >= $1::numeric")
        params.should eq(["5"] of ::DB::Any)
        idx.should eq(2)
      end

      it "falls back to a text comparison for gt on a text field" do
        predicates = ScopePredicateParser.parse_where({"name__gt" => "b"})
        clause, params, idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, dispatch_definition,
        )
        clause.should eq("content->>'name' > $1")
        params.should eq(["b"] of ::DB::Any)
        idx.should eq(2)
      end

      it "routes contains on a period field to the tstzrange clause" do
        predicates = ScopePredicateParser.parse_where({"window__contains" => "2026-01-01T00:00:00Z"})
        clause, params, _idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, dispatch_definition,
        )
        clause.should_not be_nil
        clause.to_s.should contain("facet_tstzrange")
        clause.to_s.should contain("@>")
        params.should eq(["2026-01-01T00:00:00Z"] of ::DB::Any)
      end

      it "fails closed for a range operator without a definition" do
        predicates = ScopePredicateParser.parse_where({"window__contains" => "2026-01-01T00:00:00Z"})
        clause, _params, _idx = ScopePredicateSql.build_clauses(
          predicates, ScopeContext.new("account_1", "/engineering/"),
          {} of String => Array(String), 1, nil,
        )
        clause.should eq("FALSE")
      end
    end
  end
end
