# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "../../src/http/list_request"
require "json"
require "../../src/rbac"

# Type-aware filter and sort behaviour for `Document::List`.
#
# These specs assert that filters and sorts honour the doctype field's
# *declared* type, not the runtime JSON type of the filter value. The HTTP
# query-string path (`filters[field__op]=value`) delivers scalar values as
# `JSON::Any(String)` (see `HTTP::ListRequest.from_query`; array values
# arrive JSON-decoded), and a JSON body
# may also send a string where a number was intended. For comparison
# operators (`__gt`, `__gte`, `__lt`, `__lte`, `__between`) on `integer`
# and `duration` fields, the cast must be selected from the doctype
# definition — otherwise PostgreSQL falls back to text comparison and sorts
# numbers lexicographically (`"100"` between `"10"` and `"20"`). Boolean
# fields serve eq/ne only (a two-state field has no ordering), through the
# text-extract LHS.
#
# These operators route through IMMUTABLE jsonb-direct cast helpers
# (`jsonb_as_numeric`) backed by `content->'field'`
# rather than the `content->>'field'` text round-trip. Money uses its own
# builder (`build_money_clauses`) and the `facet_money_value_as_numeric`
# helper that reads the object's `value` member.
# ── Shared fixture helpers ───────────────────────────────────────────
# Top-level methods (Crystal forbids `def` inside `describe`).

def make_typed_doctype(db, domain, doctype)
  ensure_domain(db, domain)
  schema = %({
    "doctype": "#{doctype}",
    "domain": "#{domain}",
    "fields": {
      "age":    {"type": "integer", "filters": ["comparison"]},
      "price":  {"type": "money", "filters": ["comparison", "currency"]},
      "name":   {"type": "string", "filters": ["comparison", "text_search"]},
      "active": {"type": "boolean", "filters": ["equality"]}
    }
  })
  expect_create_success(
    Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system),
  )
end

def create_typed_doc(db, domain, doctype, content : String)
  expect_create_success(
    Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system),
  )
end

def list_typed(db, domain, doctype,
               filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
               sort : Array(String) = ["id"],
               items_per_page : Int32 = 100)
  Facet::Document::List.call(db, domain, doctype,
    filters: filters, sort: sort, items_per_page: items_per_page,
    auth_context: Facet::RBAC::AuthContext.system)
end

def list_result(result)
  result.should be_a(Facet::Document::List::Result)
  result.as(Facet::Document::List::Result)
end

describe Facet::Document::List do
  # ── Numeric (integer) comparison operators with string values ──────
  #
  # The query-string path delivers values as JSON strings. Each test
  # expects *numeric* comparison semantics; the current text-based path
  # fails because, e.g., `"5" > "20"` is true in text ordering.

  it "filters integer field by __gt with a string value, numerically" do
    with_temp_doctype("typedgt") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [5, 10, 20, 100, 200].each do |n|
        create_typed_doc(db, domain, doctype, %({"age":#{n},"name":"u#{n}"}))
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"age__gt" => JSON::Any.new("20")}))
      r.items.map(&.content["age"].as_i).sort!.should eq([100, 200])
    end
  end

  it "filters integer field by __gte with a string value, numerically" do
    with_temp_doctype("typedgte") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [5, 10, 20, 100, 200].each do |n|
        create_typed_doc(db, domain, doctype, %({"age":#{n},"name":"u#{n}"}))
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"age__gte" => JSON::Any.new("20")}))
      r.items.map(&.content["age"].as_i).sort!.should eq([20, 100, 200])
    end
  end

  it "filters integer field by __lt with a string value, numerically" do
    with_temp_doctype("typedlt") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [5, 10, 20, 100, 200].each do |n|
        create_typed_doc(db, domain, doctype, %({"age":#{n},"name":"u#{n}"}))
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"age__lt" => JSON::Any.new("100")}))
      r.items.map(&.content["age"].as_i).sort!.should eq([5, 10, 20])
    end
  end

  it "filters integer field by __lte with a string value, numerically" do
    with_temp_doctype("typedlte") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [5, 10, 20, 100, 200].each do |n|
        create_typed_doc(db, domain, doctype, %({"age":#{n},"name":"u#{n}"}))
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"age__lte" => JSON::Any.new("100")}))
      r.items.map(&.content["age"].as_i).sort!.should eq([5, 10, 20, 100])
    end
  end

  it "filters integer field by __between with string bounds, numerically" do
    with_temp_doctype("typedbetween") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [5, 10, 20, 100, 200].each do |n|
        create_typed_doc(db, domain, doctype, %({"age":#{n},"name":"u#{n}"}))
      end

      bounds = JSON::Any.new([JSON::Any.new("20"), JSON::Any.new("100")])
      r = list_result(list_typed(db, domain, doctype, filters: {"age__between" => bounds}))
      r.items.map(&.content["age"].as_i).sort!.should eq([20, 100])
    end
  end

  # ── Numeric (money) comparison operators with string values ─────────
  #
  # Money fields store `{"value":"...","currency":"..."}` and route through
  # `facet_money_value_as_numeric(content->'field')` (NOT `jsonb_as_numeric`).
  # The filter grammar accepts `"<CCY> <amount>"` (currency-prefixed) or
  # `"<amount>"` (currency-agnostic) per the money revamp filter grammar.

  it "filters money field by __gt with a currency-agnostic value, numerically" do
    with_temp_doctype("typedmoneygt") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("9.99", "USD"), "name": "a"},
       {"price": money("100", "USD"), "name": "b"},
       {"price": money("199.99", "USD"), "name": "c"},
       {"price": money("1000", "USD"), "name": "d"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"price__gt" => JSON::Any.new("100")}))
      r.items.map(&.content.["price"].["value"].as_s.to_f).sort!.should eq([199.99, 1000.0])
    end
  end

  it "filters money field by __gte with a currency-prefixed value" do
    with_temp_doctype("typedmoneygte") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("9.99", "USD"), "name": "a"},
       {"price": money("100", "USD"), "name": "b"},
       {"price": money("199.99", "USD"), "name": "c"},
       {"price": money("1000", "USD"), "name": "d"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"price__gte" => JSON::Any.new("USD 100")}))
      r.items.map(&.content.["price"].["value"].as_s.to_f).sort!.should eq([100.0, 199.99, 1000.0])
    end
  end

  it "filters money field by __lt with a currency-prefixed value, ignoring other currencies" do
    with_temp_doctype("typedmoneylt") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("9.99", "USD"), "name": "a"},
       {"price": money("50", "EUR"), "name": "b"},
       {"price": money("199.99", "EUR"), "name": "c"},
       {"price": money("1000", "USD"), "name": "d"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"price__lt" => JSON::Any.new("EUR 500")}))
      names = r.items.map(&.content.["name"].as_s).sort!
      names.should eq(["b", "c"])
    end
  end

  it "filters money field by __lte with a currency-prefixed value inclusive" do
    with_temp_doctype("typedmoneylte") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("9.99", "USD"), "name": "a"},
       {"price": money("100", "USD"), "name": "b"},
       {"price": money("199.99", "USD"), "name": "c"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"price__lte" => JSON::Any.new("USD 100")}))
      names = r.items.map(&.content.["name"].as_s).sort!
      names.should eq(["a", "b"])
    end
  end

  it "filters money field by __between with shared-currency currency-prefixed bounds" do
    with_temp_doctype("typedmoneybetween") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("9.99", "USD"), "name": "a"},
       {"price": money("100", "USD"), "name": "b"},
       {"price": money("199.99", "USD"), "name": "c"},
       {"price": money("1000", "USD"), "name": "d"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      bounds = JSON::Any.new([JSON::Any.new("USD 100"), JSON::Any.new("USD 500")])
      r = list_result(list_typed(db, domain, doctype, filters: {"price__between" => bounds}))
      names = r.items.map(&.content.["name"].as_s).sort!
      names.should eq(["b", "c"])
    end
  end

  it "decodes a JSON-array __between from the HTTP query string" do
    # The full query-string chain: the frontend DataSource JSON-encodes an
    # array filter value and from_query must decode it back, so the money
    # __between matches both middle rows. A value left as a string would
    # degrade to FALSE and empty the lane.
    with_temp_doctype("typedqsbetween") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("45000", "USD"), "name": "small"},
       {"price": money("80000", "USD"), "name": "mid"},
       {"price": money("120000", "USD"), "name": "large"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      payload = ["USD 25000", "USD 100000"].to_json
      params = URI::Params.parse("filters[price__between]=#{payload}")
      req = Facet::HTTP::ListRequest.from_query(params).as(Facet::HTTP::ListRequest)

      r = list_result(list_typed(db, domain, doctype, filters: req.filters))
      names = r.items.map(&.content.["name"].as_s).sort!
      names.should eq(["mid", "small"])
    end
  end

  it "rejects money __between with mixed-currency bounds (422)" do
    with_temp_doctype("typedmoneybetweencross") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"price": #{money_json("100", "USD")}, "name": "a"}))

      bounds = JSON::Any.new([JSON::Any.new("USD 100"), JSON::Any.new("EUR 500")])
      result = list_typed(db, domain, doctype, filters: {"price__between" => bounds})
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("same currency")
    end
  end

  # ── Malformed array-valued filter values (B-41) ──────────────────
  #
  # A comma-text value (or any scalar) on an array-valued operator must
  # answer 422 naming the filter key — never degrade to a FALSE clause
  # that reads as "nothing matches".

  it "rejects a comma-text integer __between value with 422 (B-41)" do
    with_temp_doctype("typedbetweencommatext") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"age": 100, "name": "a"}))

      result = list_typed(db, domain, doctype, filters: {"age__between" => JSON::Any.new("60,3600")})
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("'age__between'")
      err.message.should contain("JSON array")
    end
  end

  it "rejects a scalar text __in value with 422 (B-41)" do
    with_temp_doctype("typedinscalar") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"age": 1, "name": "INV-1"}))

      result = list_typed(db, domain, doctype, filters: {"name__in" => JSON::Any.new("INV-1")})
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("'name__in'")
      err.message.should contain("JSON array")
    end
  end

  it "rejects a comma-text __between that arrived on the query string with 422 (B-41)" do
    # The full B-41 chain: `filters[age__between]=60,3600` keeps the raw
    # string in `from_query` (only `[`-prefixed text decodes as JSON), and
    # the compiler must reject the scalar instead of matching nothing.
    with_temp_doctype("typedqscommatext") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"age": 100, "name": "a"}))

      params = URI::Params.parse("filters[age__between]=60,3600")
      req = Facet::HTTP::ListRequest.from_query(params).as(Facet::HTTP::ListRequest)
      result = list_typed(db, domain, doctype, filters: req.filters)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("'age__between'")
    end
  end

  it "filters a text field by __in with a JSON array value" do
    with_temp_doctype("typedinarray") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      ["INV-1", "INV-3", "INV-9"].each do |n|
        create_typed_doc(db, domain, doctype, %({"age": 1, "name": "#{n}"}))
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"name__in" => JSON::Any.new([JSON::Any.new("INV-1"), JSON::Any.new("INV-3")])}))
      names = r.items.map(&.content["name"].as_s).sort!
      names.should eq(["INV-1", "INV-3"])
    end
  end

  it "filters money field by __currency" do
    with_temp_doctype("typedmoneycurrency") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("9.99", "USD"), "name": "a"},
       {"price": money("50", "EUR"), "name": "b"},
       {"price": money("100", "USD"), "name": "c"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"price__currency" => JSON::Any.new("USD")}))
      names = r.items.map(&.content.["name"].as_s).sort!
      names.should eq(["a", "c"])
    end
  end

  it "rejects __currency with an unregistered ticker (422)" do
    with_temp_doctype("typedmoneycurrencyunknown") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"price": #{money_json("100", "USD")}, "name": "a"}))

      result = list_typed(db, domain, doctype, filters: {"price__currency" => JSON::Any.new("XYZ")})
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("XYZ")
    end
  end

  it "filters money field by __eq with a currency-prefixed value" do
    with_temp_doctype("typedmoneyeq") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("100", "USD"), "name": "a"},
       {"price": money("100", "EUR"), "name": "b"},
       {"price": money("200", "USD"), "name": "c"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"price__eq" => JSON::Any.new("USD 100")}))
      names = r.items.map(&.content.["name"].as_s)
      names.should eq(["a"])
    end
  end

  it "filters money field by __eq with a currency-agnostic value (matches across currencies)" do
    with_temp_doctype("typedmoneyeqnoccy") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("100", "USD"), "name": "a"},
       {"price": money("100", "EUR"), "name": "b"},
       {"price": money("200", "USD"), "name": "c"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"price__eq" => JSON::Any.new("100")}))
      names = r.items.map(&.content.["name"].as_s).sort!
      names.should eq(["a", "b"])
    end
  end

  it "rejects __gte with an unregistered currency prefix (422)" do
    with_temp_doctype("typedmoneyunknownccy") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"price": #{money_json("100", "USD")}, "name": "a"}))

      result = list_typed(db, domain, doctype, filters: {"price__gte" => JSON::Any.new("XYZ 100")})
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
    end
  end

  # ── Boolean comparison/equality ─────────────────────────────────
  #
  # The grammar serves eq/ne on a boolean field; the clauses ride the
  # text-extract LHS (`content->>'active' = 'true'`). These specs lock
  # that contract.

  it "filters boolean field by __eq with a string value" do
    with_temp_doctype("typedbooleq") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"active":true,"name":"on"}))
      create_typed_doc(db, domain, doctype, %({"active":false,"name":"off"}))
      create_typed_doc(db, domain, doctype, %({"active":false,"name":"off2"}))

      r = list_result(list_typed(db, domain, doctype, filters: {"active__eq" => JSON::Any.new("true")}))
      r.items.map(&.content["name"].as_s).sort!.should eq(["on"])
    end
  end

  it "filters boolean field by __ne with a string value (includes null rows)" do
    with_temp_doctype("typedboolne") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"active":true,"name":"on"}))
      create_typed_doc(db, domain, doctype, %({"active":false,"name":"off"}))
      create_typed_doc(db, domain, doctype, %({"name":"unset"})) # active omitted → null

      r = list_result(list_typed(db, domain, doctype, filters: {"active__ne" => JSON::Any.new("true")}))
      r.items.map(&.content["name"].as_s).sort!.should eq(["off", "unset"])
    end
  end

  # ── String field: text comparison is correct (regression guard) ──────

  it "filters string field by __eq" do
    with_temp_doctype("typedstreq") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"name":"Alice"}))
      create_typed_doc(db, domain, doctype, %({"name":"Bob"}))

      r = list_result(list_typed(db, domain, doctype, filters: {"name__eq" => JSON::Any.new("Alice")}))
      r.items.map(&.content["name"].as_s).should eq(["Alice"])
    end
  end

  it "filters string field by __match (escaped substring ILIKE)" do
    with_temp_doctype("typedstrmatch") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"name":"Alice"}))
      create_typed_doc(db, domain, doctype, %({"name":"Charlie"}))
      create_typed_doc(db, domain, doctype, %({"name":"Dave"}))

      r = list_result(list_typed(db, domain, doctype, filters: {"name__match" => JSON::Any.new("li")}))
      r.items.map(&.content["name"].as_s).sort!.should eq(["Alice", "Charlie"])
    end
  end

  it "filters string field by __starts_with (escaped prefix ILIKE)" do
    with_temp_doctype("typedstrstarts") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"name":"Alice"}))
      create_typed_doc(db, domain, doctype, %({"name":"Charlie"}))
      create_typed_doc(db, domain, doctype, %({"name":"Dave"}))

      r = list_result(list_typed(db, domain, doctype, filters: {"name__starts_with" => JSON::Any.new("Al")}))
      r.items.map(&.content["name"].as_s).should eq(["Alice"])
    end
  end

  it "treats a literal % in a __match value as a literal, not a wildcard" do
    with_temp_doctype("typedstrpct") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"name":"50%off"}))
      create_typed_doc(db, domain, doctype, %({"name":"Alice"}))
      create_typed_doc(db, domain, doctype, %({"name":"Bob"}))

      r = list_result(list_typed(db, domain, doctype, filters: {"name__match" => JSON::Any.new("%")}))
      r.items.map(&.content["name"].as_s).should eq(["50%off"])
    end
  end

  it "filters string field by __ne" do
    with_temp_doctype("typedstrne") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"name":"Alice"}))
      create_typed_doc(db, domain, doctype, %({"name":"Bob"}))

      r = list_result(list_typed(db, domain, doctype, filters: {"name__ne" => JSON::Any.new("Alice")}))
      r.items.map(&.content["name"].as_s).should eq(["Bob"])
    end
  end

  # ── Numeric: Int64 value (JSON body numeric path) ─────────────────
  #
  # The JSON body path delivers numbers as `JSON::Any(Int64)`. The value
  # still binds correctly; the LHS cast is selected from the doctype.

  it "filters integer field by __gt with an Int64 value" do
    with_temp_doctype("typedgtint") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [5, 10, 20, 100, 200].each do |n|
        create_typed_doc(db, domain, doctype, %({"age":#{n},"name":"u#{n}"}))
      end

      r = list_result(list_typed(db, domain, doctype, filters: {"age__gt" => JSON::Any.new(20_i64)}))
      r.items.map(&.content["age"].as_i).sort!.should eq([100, 200])
    end
  end

  # ── Type-aware ORDER BY (regression guards) ────────────────────────
  #
  # Sort routes numerics through the IMMUTABLE `jsonb_as_numeric` helper
  # (reading `content->'field'` directly). These specs lock the numeric sort
  # contract so future refactors of the cast strategy don't regress to
  # lexicographic text ordering.

  it "sorts integer fields ascending numerically" do
    with_temp_doctype("typedsortintasc") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [5, 200, 10, 20, 100].each do |n|
        create_typed_doc(db, domain, doctype, %({"age":#{n},"name":"u#{n}"}))
      end

      r = list_result(list_typed(db, domain, doctype, sort: ["age"], items_per_page: 50))
      r.items.map(&.content["age"].as_i).should eq([5, 10, 20, 100, 200])
    end
  end

  it "sorts integer fields descending numerically" do
    with_temp_doctype("typedsortintdesc") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [5, 200, 10, 20, 100].each do |n|
        create_typed_doc(db, domain, doctype, %({"age":#{n},"name":"u#{n}"}))
      end

      r = list_result(list_typed(db, domain, doctype, sort: ["-age"], items_per_page: 50))
      r.items.map(&.content["age"].as_i).should eq([200, 100, 20, 10, 5])
    end
  end

  it "sorts money fields ascending numerically" do
    with_temp_doctype("typedsortmoneyasc") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("1000", "USD"), "name": "a"},
       {"price": money("9.99", "USD"), "name": "b"},
       {"price": money("100", "USD"), "name": "c"},
       {"price": money("199.99", "USD"), "name": "d"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, sort: ["price"], items_per_page: 50))
      r.items.map(&.content.["price"].["value"].as_s.to_f).should eq([9.99, 100.0, 199.99, 1000.0])
    end
  end

  it "sorts money fields descending numerically" do
    with_temp_doctype("typedsortmoneydesc") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      [{"price": money("1000", "USD"), "name": "a"},
       {"price": money("9.99", "USD"), "name": "b"},
       {"price": money("100", "USD"), "name": "c"},
       {"price": money("199.99", "USD"), "name": "d"}].each do |h|
        create_typed_doc(db, domain, doctype, h.to_json)
      end

      r = list_result(list_typed(db, domain, doctype, sort: ["-price"], items_per_page: 50))
      r.items.map(&.content.["price"].["value"].as_s.to_f).should eq([1000.0, 199.99, 100.0, 9.99])
    end
  end

  # ── Defensive: malformed stored value does not 500 the request ──────
  #
  # If a stored JSON value is typologically invalid for its declared field
  # type (e.g. a JSON string where an integer was expected — possible only
  # via a direct snapshot mutation, since the validator rejects such inputs
  # at create/update time), the query layer must degrade to NULL rather than
  # raise `invalid input syntax for type bigint`. This matches sort's
  # existing NULL-tolerance and unifies filter behaviour with it.

  it "does not 500 when an integer field holds a non-numeric value and a __gt filter is applied" do
    with_temp_doctype("typedmalformedgt") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"age":10,"name":"ok1"}))
      create_typed_doc(db, domain, doctype, %({"age":100,"name":"ok2"}))

      # Inject a document whose `age` violates the doctype type. Bypasses
      # validation by writing a snapshot mutation directly.
      bad_id = "bad#{unique_suffix}"
      Facet::Mutation::Client.snapshot_mutation(
        db, domain, doctype, bad_id,
        content: %({"age":"not-a-number"}),
        meta: %({"schema_version":1}),
        version: 1,
      )

      r = list_result(list_typed(db, domain, doctype,
        filters: {"age__gt" => JSON::Any.new("20")},
        items_per_page: 50))
      # Bad row excluded (NULL), correctly-typed rows filtered numerically.
      r.items.map(&.content["age"].as_i).sort!.should eq([100])
    end
  end

  # ── Defensive: malformed money stored value does not 500 the request ────
  #
  # `facet_money_value_as_numeric` returns NULL for any non-object / non-
  # string-`value` JSON shape so a directly-mutated row (the validator rejects
  # these at write time, so they only exist via raw snapshot writes) degrades
  # to no-match on filter and NULLS LAST on sort instead of raising
  # `invalid input syntax for type numeric`.

  it "does not 500 when a money field is missing its value member" do
    with_temp_doctype("typedmalformedmoney1") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"price": #{money_json("100", "USD")}, "name": "ok1"}))
      create_typed_doc(db, domain, doctype, %({"price": #{money_json("250", "USD")}, "name": "ok2"}))

      bad_id = "bad#{unique_suffix}"
      Facet::Mutation::Client.snapshot_mutation(
        db, domain, doctype, bad_id,
        content: %({"price":{"currency":"USD"},"name":"bad"}),
        meta: %({"schema_version":1}),
        version: 1,
      )

      r = list_result(list_typed(db, domain, doctype,
        filters: {"price__gte" => JSON::Any.new("100")},
        items_per_page: 50))
      names = r.items.map(&.content["name"].as_s).sort!
      names.should eq(["ok1", "ok2"])
    end
  end

  it "does not 500 when a money field holds a blank value string" do
    with_temp_doctype("typedmalformedmoney2") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"price": #{money_json("100", "USD")}, "name": "ok1"}))

      bad_id = "bad#{unique_suffix}"
      Facet::Mutation::Client.snapshot_mutation(
        db, domain, doctype, bad_id,
        content: %({"price":{"value":"","currency":"USD"},"name":"bad"}),
        meta: %({"schema_version":1}),
        version: 1,
      )

      r = list_result(list_typed(db, domain, doctype,
        filters: {"price__gte" => JSON::Any.new("100")},
        items_per_page: 50))
      names = r.items.map(&.content["name"].as_s)
      names.should eq(["ok1"])
    end
  end

  it "does not 500 when a money field holds a non-numeric value string" do
    with_temp_doctype("typedmalformedmoney3") do |db, domain, doctype|
      make_typed_doctype(db, domain, doctype)
      create_typed_doc(db, domain, doctype, %({"price": #{money_json("100", "USD")}, "name": "ok1"}))

      bad_id = "bad#{unique_suffix}"
      Facet::Mutation::Client.snapshot_mutation(
        db, domain, doctype, bad_id,
        content: %({"price":{"value":"abc","currency":"USD"},"name":"bad"}),
        meta: %({"schema_version":1}),
        version: 1,
      )

      r = list_result(list_typed(db, domain, doctype,
        sort: ["price"],
        items_per_page: 50))
      # Bad row degrades to NULLS LAST → sorted after the ok row.
      names = r.items.map(&.content["name"].as_s)
      names.should eq(["ok1", "bad"])
    end
  end
end
