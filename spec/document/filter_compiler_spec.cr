# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "db"
require "../../src/doctype/replicate_config"
require "../../src/doctype/field_type"
require "../../src/doctype/field_types/string_type"
require "../../src/doctype/field_types/integer_type"
require "../../src/doctype/field_types/duration_type"
require "../../src/doctype/field_types/boolean_type"
require "../../src/doctype/field_types/money_type"
require "../../src/doctype/field_types/array_type"
require "../../src/doctype/field_types/period_type"
require "../../src/doctype/field_types/datetime_type"
require "../../src/doctype/field_types/enum_type"
require "../../src/doctype/doctype_definition"
require "../../src/util/money"
require "../../src/rbac"
require "../../src/document/filter_compiler"

# Direct spec for `Document::FilterCompiler` — the shared compile step for
# the document filter grammar. Pure logic: no database, no HTTP.
#
# Each operator family must land in its clause family with the expected SQL
# shape and bound parameters, placeholder numbering must respect the caller's
# `offset`, datetime values must normalize to UTC RFC-3339, and unknown
# fields must drop silently.

alias FC = Facet::Document::FilterCompiler
alias DoctypeDef = Facet::Doctype::DoctypeDefinition
alias FieldDef = Facet::Doctype::FieldDefinition

# Top-level fixture helpers (Crystal forbids `def` inside `describe`).

def jv(raw) : JSON::Any
  JSON::Any.new(raw)
end

def jarr(items : Array(JSON::Any)) : JSON::Any
  JSON::Any.new(items)
end

def filter_doctype : DoctypeDef
  fields = {
    "name"   => FieldDef.new(type: Facet::Doctype::StringType.new, filters: [Facet::Doctype::FilterCapability::Comparison, Facet::Doctype::FilterCapability::TextSearch]),
    "age"    => FieldDef.new(type: Facet::Doctype::IntegerType.new, filters: [Facet::Doctype::FilterCapability::Comparison]),
    "score"  => FieldDef.new(type: Facet::Doctype::IntegerType.new, filters: [Facet::Doctype::FilterCapability::Equality]),
    "serial" => FieldDef.new(type: Facet::Doctype::IntegerType.new, unique: true),
    "delay"  => FieldDef.new(type: Facet::Doctype::DurationType.new, filters: [Facet::Doctype::FilterCapability::Equality]),
    "active" => FieldDef.new(type: Facet::Doctype::BooleanType.new, filters: [Facet::Doctype::FilterCapability::Equality]),
    "price"  => FieldDef.new(type: Facet::Doctype::MoneyType.new, filters: [Facet::Doctype::FilterCapability::Comparison, Facet::Doctype::FilterCapability::Currency]),
    "tags"   => FieldDef.new(type: Facet::Doctype::ArrayType.new, filters: [Facet::Doctype::FilterCapability::Membership]),
    "window" => FieldDef.new(type: Facet::Doctype::PeriodType.new, filters: [Facet::Doctype::FilterCapability::Interval]),
    "starts" => FieldDef.new(type: Facet::Doctype::DatetimeType.new, filters: [Facet::Doctype::FilterCapability::Comparison]),
    "status" => FieldDef.new(type: Facet::Doctype::EnumType.new, filters: [Facet::Doctype::FilterCapability::Equality]),
  } of String => FieldDef
  DoctypeDef.new(doctype: "Invoice", domain: "core", fields: fields)
end

def compile_one(definition, filters, offset = 0)
  clauses, params = FC.compile(definition, filters, offset: offset)
  {clauses, params}
end

# A definition carrying one tagged `salary` field next to a default-tagged
# `name` field — the field-visibility fixture for the S4 specs.
def filter_doctype_with_hidden_salary : DoctypeDef
  fields = {
    "name"   => FieldDef.new(type: Facet::Doctype::StringType.new, filters: [Facet::Doctype::FilterCapability::Comparison]),
    "salary" => FieldDef.new(type: Facet::Doctype::IntegerType.new, filters: [Facet::Doctype::FilterCapability::Comparison], tags: ["payroll"]),
  } of String => FieldDef
  DoctypeDef.new(doctype: "Payslip", domain: "core", fields: fields)
end

# A Real principal whose role holds the given visible tags and no
# permission ceiling — the visibility gate under test is pure tag
# arithmetic, so no read grant is needed.
def field_tag_caller(visible : Array(String)) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "field_tag_role",
    visible_tags: Set.new(visible),
    permissions: [] of Facet::RBAC::Permission,
  )
  Facet::RBAC::AuthContext.authenticated("field_tag_account", role)
end

describe Facet::Document::FilterCompiler do
  # Money filters validate tickers against the currency registry, which
  # `Currency::Registry` populates from `core.Currency` projections. Pure
  # specs run without it, so a USD ticker is registered here.
  Facet::Util::Currency.register({"USD" => Facet::Util::Currency.new(ticker: "USD", symbol: "$", name: "US Dollar", digits: 2)})

  definition = filter_doctype

  # ── Scalar family (text-based, via FilterSet) ──────────────────────

  it "compiles a scalar __eq filter through the text-extract LHS" do
    clauses, params = compile_one(definition, {"name__eq" => jv("Alice")})
    clauses.should eq(["content->>'name' = $1"])
    params.should eq(["Alice"])
  end

  it "compiles a bare filter key as scalar equality" do
    clauses, params = compile_one(definition, {"name" => jv("Alice")})
    clauses.should eq(["content->>'name' = $1"])
    params.should eq(["Alice"])
  end

  it "compiles __match as an escaped ILIKE pattern" do
    clauses, params = compile_one(definition, {"name__match" => jv("li_ce")})
    clauses.should eq(["content->>'name' ILIKE '%' || $1 || '%' ESCAPE '\\'"])
    # `%` and `_` must not act as wildcards — LIKE-escaped before binding.
    params.should eq(["li\\_ce"])
  end

  # ── Typed comparison family ─────────────────────────────────────────

  it "routes integer __gt through the numeric cast LHS with a string value" do
    clauses, params = compile_one(definition, {"age__gt" => jv("20")})
    clauses.should eq(["jsonb_as_numeric(content->'age') > $1::numeric"])
    params.should eq(["20"])
  end

  it "routes integer __between through the numeric cast LHS" do
    clauses, _params = compile_one(definition, {"age__between" => jarr([jv(10_i64), jv(20_i64)])})
    clauses.should eq(["jsonb_as_numeric(content->'age') BETWEEN $1::numeric AND $2::numeric"])
  end

  it "routes integer __eq / __ne through the numeric cast LHS when btree_numeric exists" do
    # `score` declares `filters: [equality]`, so the planner creates
    # `btree_numeric` on `jsonb_as_numeric(content->'score')`; text
    # equality would not use it.
    clauses, params = compile_one(definition, {"score__eq" => jv("20")})
    clauses.should eq(["jsonb_as_numeric(content->'score') = $1::numeric"])
    params.should eq(["20"])

    clauses, params = compile_one(definition, {"score__ne" => jv("20")})
    clauses.should eq(["jsonb_as_numeric(content->'score') IS DISTINCT FROM $1::numeric"])
    params.should eq(["20"])
  end

  it "routes duration __eq / __ne through the numeric cast LHS when btree_numeric exists" do
    clauses, params = compile_one(definition, {"delay__eq" => jv("30")})
    clauses.should eq(["jsonb_as_numeric(content->'delay') = $1::numeric"])
    params.should eq(["30"])

    clauses, params = compile_one(definition, {"delay__ne" => jv("30")})
    clauses.should eq(["jsonb_as_numeric(content->'delay') IS DISTINCT FROM $1::numeric"])
    params.should eq(["30"])
  end

  it "rejects filters on a field that declares no filters capability" do
    # `serial` is unique but declares no `filters`, so it has no queryable
    # operator set — the unique index is for enforcement, not user filters.
    {"eq", "ne", "gt"}.each do |suffix|
      ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /not served for field 'serial'/) do
        compile_one(definition, {"serial__#{suffix}" => jv("20")})
      end
      ex.reason.should eq("unsupported_filter_operator")
    end
  end

  it "names the remedy when the field declares no filters capability" do
    # An empty allowed set used to render as `(allowed: )`, which names no
    # fix. The message must name the missing `filters:` capability.
    ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /not served for field 'serial'/) do
      compile_one(definition, {"serial__eq" => jv("20")})
    end
    message = ex.message.not_nil!
    message.should contain("declares no filter capability")
    message.should contain("filters:")
    message.should_not contain("allowed:")
  end

  it "rejects a bare key on a field that declares no filters capability" do
    ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /not served for field 'serial'/) do
      compile_one(definition, {"serial" => jv("20")})
    end
    ex.reason.should eq("unsupported_filter_operator")
  end

  it "serves only eq and ne on a boolean field" do
    # A boolean is a two-state field: the comparison family is legal PG
    # (`false < true`) but meaningless as a filter, so the grammar serves
    # the same family as a reference.
    allowed = FC.allowed_operators(definition, "active").not_nil!
    allowed.should eq(Set{"eq", "ne"})
  end

  it "compiles boolean eq/ne through the scalar text-extract LHS" do
    clauses, params = compile_one(definition, {"active__eq" => jv("true")})
    clauses.should eq(["content->>'active' = $1"])
    params.should eq(["true"])

    clauses, params = compile_one(definition, {"active__ne" => jv("true")})
    clauses.should eq(["content->>'active' IS DISTINCT FROM $1"])
    params.should eq(["true"])
  end

  it "raises on a comparison operator on a boolean field (B-20)" do
    # `false < true` is legal PG but no filter a user means to send — the
    # grammar rejects the suffix instead of compiling it.
    {"gt", "gte", "lt", "lte", "between", "in", "match", "starts_with"}.each do |suffix|
      value = suffix == "between" || suffix == "in" ? jarr([jv("true")]) : jv("true")
      ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter operator '#{suffix}' is not served for field 'active'/) do
        compile_one(definition, {"active__#{suffix}" => value})
      end
      ex.reason.should eq("unsupported_filter_operator")
    end
  end

  # ── Money family ────────────────────────────────────────────────────

  it "compiles a money __gt with a currency prefix into a numeric + currency predicate" do
    clauses, params = compile_one(definition, {"price__gt" => jv("USD 100.00")})
    clauses.should eq([
      "facet_money_value_as_numeric(content->'price') > $1::numeric AND content#>>'{price,currency}' = $2",
    ])
    # The parsed amount is the canonical decimal string, not the raw input.
    params.should eq(["100.0", "USD"])
  end

  it "compiles a bare-amount money filter against any currency" do
    clauses, params = compile_one(definition, {"price__gte" => jv("5.5")})
    clauses.should eq(["facet_money_value_as_numeric(content->'price') >= $1::numeric"])
    params.should eq(["5.5"])
  end

  it "compiles the __currency operator as text equality on the stored ticker" do
    clauses, params = compile_one(definition, {"price__currency" => jv("USD")})
    clauses.should eq(["content#>>'{price,currency}' = $1"])
    params.should eq(["USD"])
  end

  it "compiles a money filter with an inactive registered ticker" do
    # Stored values of a deactivated currency stay queryable — the filter
    # grammar requires the ticker to be registered, not active.
    Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false)})

    clauses, params = compile_one(definition, {"price__gt" => jv("OLD 100.00")})
    clauses.should eq([
      "facet_money_value_as_numeric(content->'price') > $1::numeric AND content#>>'{price,currency}' = $2",
    ])
    params.should eq(["100.0", "OLD"])
  end

  it "raises MoneyFilterError for an unregistered ticker" do
    expect_raises(Facet::Util::FilterClauses::MoneyFilterError) do
      FC.compile(definition, {"price__eq" => jv("XYZ 1.0")})
    end
  end

  it "raises MoneyFilterError for a non-decimal amount" do
    expect_raises(Facet::Util::FilterClauses::MoneyFilterError) do
      FC.compile(definition, {"price__eq" => jv("USD abc")})
    end
  end

  # ── Range family (period / dateperiod) ─────────────────────────────

  it "compiles a period __contains point filter through the GiST LHS" do
    clauses, params = compile_one(definition, {"window__contains" => jv("2026-01-01T00:00:00Z")})
    clauses.should eq(["facet_tstzrange(content#>>'{window,start}', content#>>'{window,end}') @> $1::timestamptz"])
    params.should eq(["2026-01-01T00:00:00Z"])
  end

  it "compiles a period __overlaps interval filter" do
    clauses, params = compile_one(definition, {"window__overlaps" => jarr([jv("2026-01-01T00:00:00Z"), jv("2026-02-01T00:00:00Z")])})
    clauses.should eq([
      "facet_tstzrange(content#>>'{window,start}', content#>>'{window,end}') && tstzrange($1::timestamptz, $2::timestamptz, '[)')",
    ])
    params.should eq(["2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z"])
  end

  it "raises on a period field with a non-range operator (B-20)" do
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /'gte' is not served for field 'window'/) do
      compile_one(definition, {"window__gte" => jv("2026-01-01T00:00:00Z")})
    end
  end

  # ── Container family (array membership) ────────────────────────────

  it "compiles an array __contains scalar as JSONB containment" do
    clauses, params = compile_one(definition, {"tags__contains" => jv("foo")})
    clauses.should eq(["content->'tags' @> $1::jsonb"])
    params.should eq(["[\"foo\"]"])
  end

  it "compiles an array __overlaps filter as JSONB overlap" do
    clauses, params = compile_one(definition, {"tags__overlaps" => jarr([jv("a"), jv("b")])})
    clauses.should eq(["content->'tags' && $1::jsonb"])
    params.should eq(["[\"a\",\"b\"]"])
  end

  # ── System-column family ────────────────────────────────────────────

  it "compiles an id __eq filter against the projection column" do
    clauses, params = compile_one(definition, {"id__eq" => jv("abc")})
    clauses.should eq(["id = $1"])
    params.should eq(["abc"])
  end

  it "compiles an id __between filter with two bound values" do
    clauses, params = compile_one(definition, {"id__between" => jarr([jv("a"), jv("z")])})
    clauses.should eq(["id BETWEEN $1 AND $2"])
    params.should eq(["a", "z"])
  end

  it "compiles an id __in filter as an ANY(ARRAY) membership" do
    clauses, params = compile_one(definition, {"id__in" => jarr([jv("a"), jv("b")])})
    clauses.should eq(["id = ANY(ARRAY[$1, $2])"])
    params.should eq(["a", "b"])
  end

  it "raises on an id __in filter with a non-array value (B-41)" do
    ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'id__in' requires a JSON array value/) do
      compile_one(definition, {"id__in" => jv("a")})
    end
    ex.reason.should eq("malformed_filter_value")
    ex.filter_key.should eq("id__in")
  end

  it "degrades an id __in filter over the value bound to FALSE" do
    over = Array.new(Facet::Util::FilterSet::MAX_IN_VALUES + 1) { |i| jv("id-#{i}") }
    clauses, params = compile_one(definition, {"id__in" => jarr(over)})
    clauses.should eq(["FALSE"])
    params.should eq([] of ::DB::Any)
  end

  it "raises on __match against a system timestamp column (B-20)" do
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /'match' is not served for field 'created_at'/) do
      compile_one(definition, {"created_at__match" => jv("2026")})
    end
  end

  # ── Search family ───────────────────────────────────────────────────

  it "compiles the search filter as an escaped trigram ILIKE" do
    clauses, params = compile_one(definition, {"search" => jv("50%_off")})
    clauses.should eq(["search ILIKE '%' || $1 || '%' ESCAPE '\\'"])
    # `%` and `_` must match literally, not as wildcards.
    params.should eq(["50\\%\\_off"])
  end

  it "folds the search term before escaping — an unaccented term matches an accented corpus" do
    clauses, params = compile_one(definition, {"search" => jv("García")})
    clauses.should eq(["search ILIKE '%' || $1 || '%' ESCAPE '\\'"])
    params.should eq(["garcia"])
  end

  it "raises on suffixed search keys — `search` takes no operator suffix (B-20)" do
    {"search__match", "search__eq", "search__starts_with"}.each do |key|
      expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /not served for field 'search'/) do
        compile_one(definition, {key => jv("garcia")})
      end
    end
  end

  it "ignores a null search value" do
    clauses, params = compile_one(definition, {"search" => jv(nil)})
    clauses.should eq([] of String)
    params.should eq([] of ::DB::Any)
  end

  # ── Datetime UTC normalization ──────────────────────────────────────

  it "normalizes a tz-offset value on a datetime field to UTC RFC-3339" do
    clauses, params = compile_one(definition, {"starts__eq" => jv("2026-01-01T02:00:00+02:00")})
    clauses.should eq(["content->>'starts' = $1"])
    params.should eq(["2026-01-01T00:00:00Z"])
  end

  it "normalizes tz-offset bounds on a datetime __between filter" do
    clauses, params = compile_one(definition, {"starts__between" => jarr([jv("2026-01-01T02:00:00+02:00"), jv("2026-01-02T02:00:00+02:00")])})
    clauses.should eq(["content->>'starts' BETWEEN $1 AND $2"])
    params.should eq(["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"])
  end

  it "normalizes a tz-offset value on the created_at system column" do
    clauses, params = compile_one(definition, {"created_at__gt" => jv("2026-01-01T02:00:00+02:00")})
    clauses.should eq(["created_at > $1::timestamp"])
    params.should eq(["2026-01-01T00:00:00Z"])
  end

  it "compiles a UTC instant with milliseconds on the created_at system column" do
    # The calendar window bounds send `toISOString()` instants — the client
    # contract for system timestamp filters is a full RFC-3339 datetime.
    clauses, params = compile_one(definition, {"created_at__gte" => jv("2026-10-25T00:00:00.000Z")})
    clauses.should eq(["created_at >= $1::timestamp"])
    params.should eq(["2026-10-25T00:00:00Z"])
  end

  it "degrades a date-only value on the created_at system column to FALSE" do
    # `Time.parse_iso8601` rejects date-only strings (no offset), so the
    # clause matches nothing rather than guessing a midnight bound — the
    # caller must send a full RFC-3339 datetime.
    clauses, params = compile_one(definition, {"created_at__gte" => jv("2026-10-25")})
    clauses.should eq(["FALSE"])
    params.should eq([] of ::DB::Any)
  end

  # ── Unknown fields ──────────────────────────────────────────────────

  # ── Value-shape validation (B-41) ──────────────────────────────────

  # A malformed value on an array-valued operator must raise a 422 —
  # never degrade to a FALSE clause that reads as "nothing matches".

  it "raises on a comma-text value on a scalar __between (B-41)" do
    ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'name__between' requires a JSON array value \(got a string\)/) do
      compile_one(definition, {"name__between" => jv("a,z")})
    end
    ex.reason.should eq("malformed_filter_value")
  end

  it "raises on a scalar value on a scalar __in (B-41)" do
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'name__in' requires a JSON array value/) do
      compile_one(definition, {"name__in" => jv("INV-1")})
    end
  end

  # ── Enum set membership (`__in`) ─────────────────────────────

  # An enum field routes through the scalar family (`Util::FilterSet`),
  # whose `__in` compiles an `ANY` set match over the stored enum key.
  it "compiles an enum __in array to the ANY set match" do
    clauses, params = compile_one(definition, {"status__in" => jarr([jv("open"), jv("won")])})
    clauses.should eq(["content->>'status' = ANY(ARRAY[$1, $2])"])
    params.should eq(["open", "won"])
  end

  it "raises on a scalar value on an enum __in (B-41)" do
    ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'status__in' requires a JSON array value \(got a string\)/) do
      compile_one(definition, {"status__in" => jv("open")})
    end
    ex.reason.should eq("malformed_filter_value")
  end

  it "serves in on an enum field that declares equality" do
    allowed = FC.allowed_operators(definition, "status").not_nil!
    allowed.should contain("in")
  end

  it "raises on a scalar value on a typed __in and __between (B-41)" do
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'age__in' requires a JSON array value/) do
      compile_one(definition, {"age__in" => jv(10_i64)})
    end
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'age__between' requires a JSON array value/) do
      compile_one(definition, {"age__between" => jv("10,20")})
    end
  end

  it "raises on a scalar value on a money __between (B-41)" do
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'price__between' requires a JSON array value/) do
      compile_one(definition, {"price__between" => jv("USD 100")})
    end
  end

  it "raises on a scalar value on a period interval operator (B-41)" do
    {"window__eq", "window__overlaps", "window__within"}.each do |key|
      expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /requires a JSON array value/) do
        compile_one(definition, {key => jv("2026-01-01T00:00:00Z")})
      end
    end
  end

  it "raises on a non-point value on a period __contains (B-41)" do
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'window__contains' requires an ISO-8601 string or a JSON array value \(got null\)/) do
      compile_one(definition, {"window__contains" => jv(nil)})
    end
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'window__contains' requires an ISO-8601 string or a JSON array value \(got an object\)/) do
      compile_one(definition, {"window__contains" => JSON.parse("{\"start\":\"2026-01-01\"}")})
    end
  end

  it "raises on an object value on an array-field membership operator (B-41)" do
    {"tags__eq", "tags__contains", "tags__overlaps"}.each do |key|
      expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /requires a scalar or a JSON array value \(got an object\)/) do
        compile_one(definition, {key => JSON.parse("{\"a\":1}")})
      end
    end
  end

  it "raises on id and system timestamp __between with a scalar value (B-41)" do
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'id__between' requires a JSON array value/) do
      compile_one(definition, {"id__between" => jv("a,z")})
    end
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Filter 'created_at__between' requires a JSON array value/) do
      compile_one(definition, {"created_at__between" => jv("2026-01-01,2026-02-01")})
    end
  end

  it "keeps serving the documented scalar forms of dual-form operators" do
    # A range __contains point and an array-field single-element filter
    # are productions of the grammar — the shape check must not reject them.
    clauses, _ = compile_one(definition, {"window__contains" => jv("2026-01-01T00:00:00Z")})
    clauses.should eq(["facet_tstzrange(content#>>'{window,start}', content#>>'{window,end}') @> $1::timestamptz"])
    clauses, _ = compile_one(definition, {"tags__contains" => jv("foo")})
    clauses.should eq(["content->'tags' @> $1::jsonb"])
  end

  it "raises on filters naming unknown fields — suffixed and bare (B-20)" do
    ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Unknown filter field 'ghost'/) do
      compile_one(definition, {"ghost__eq" => jv("x")})
    end
    ex.reason.should eq("unknown_filter_field")
    ex.filter_key.should eq("ghost__eq")

    ex2 = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /Unknown filter field 'nonsense'/) do
      compile_one(definition, {"nonsense" => jv("y")})
    end
    ex2.reason.should eq("unknown_filter_field")
  end

  it "lists the filterable fields in the unknown-field message (B-20)" do
    expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /filterable: active, age, created_at, delay, deleted_at, id, name, price, score, search, starts, status, tags, updated_at, window/) do
      compile_one(definition, {"ghost" => jv("x")})
    end
  end

  # ── Field visibility (S4) ──────────────────────────────────────────

  it "answers 403 for a filter on a field the active role cannot see (S4)" do
    tagged = filter_doctype_with_hidden_salary
    ctx = field_tag_caller(["default"])

    ex = expect_raises(Facet::Util::FilterClauses::FilterGrammarError, /field 'salary' is not visible to the active role/) do
      FC.compile(tagged, {"salary__gt" => jv("10")}, auth_context: ctx)
    end
    # The refusal names the field and the visibility rule only — never the
    # operator set or the type contract of the hidden field.
    ex.reason.should eq("invisible_filter_field")
    ex.filter_key.should eq("salary")
  end

  it "keeps a visible field filterable and a wildcard role sees every field (S4)" do
    tagged = filter_doctype_with_hidden_salary

    clauses, params = FC.compile(tagged, {"salary__gt" => jv("10")}, auth_context: field_tag_caller(["default", "payroll"]))
    clauses.should eq(["jsonb_as_numeric(content->'salary') > $1::numeric"])
    params.should eq(["10"])

    wildcard = FC.compile(tagged, {"salary__gt" => jv("10")}, auth_context: field_tag_caller(["*"]))
    wildcard[0].should eq(["jsonb_as_numeric(content->'salary') > $1::numeric"])
  end

  it "exempts an internal integrity filter from the visibility gate (S4)" do
    tagged = filter_doctype_with_hidden_salary
    clauses, _params = FC.compile(tagged, {"salary__eq" => jv("10")},
      skip_capability_check: true, auth_context: field_tag_caller(["default"]), skip_visibility_check: true)
    clauses.should eq(["jsonb_as_numeric(content->'salary') = $1::numeric"])
  end

  # ── Placeholder offset contract ────────────────────────────────────

  it "numbers placeholders from offset + 1" do
    clauses, _params = compile_one(definition, {"name__eq" => jv("Alice")}, offset: 3)
    clauses.should eq(["content->>'name' = $4"])
  end

  it "numbers the search placeholder from offset + 1" do
    clauses, _params = compile_one(definition, {"search" => jv("inv")}, offset: 2)
    clauses.should eq(["search ILIKE '%' || $3 || '%' ESCAPE '\\'"])
  end

  # ── Combined compile: family order + placeholder numbering ─────────

  it "AND-composes every family in compile order with continuous placeholders" do
    filters = {
      "window__contains" => jv("2026-01-01T00:00:00Z"), # range    → $1
      "id__eq"           => jv("doc1"),                 # system   → $2
      "age__gte"         => jv("18"),                   # typed    → $3
      "price__currency"  => jv("USD"),                  # money    → $4
      "tags__contains"   => jv("foo"),                  # container→ $5
      "name"             => jv("Alice"),                # scalar   → $6
      "search"           => jv("inv"),                  # search   → $7
    }
    clauses, params = FC.compile(definition, filters)

    clauses.should eq([
      "facet_tstzrange(content#>>'{window,start}', content#>>'{window,end}') @> $1::timestamptz",
      "id = $2",
      "jsonb_as_numeric(content->'age') >= $3::numeric",
      "content#>>'{price,currency}' = $4",
      "content->'tags' @> $5::jsonb",
      "content->>'name' = $6",
      "search ILIKE '%' || $7 || '%' ESCAPE '\\'",
    ])
    params.should eq([
      "2026-01-01T00:00:00Z",
      "doc1",
      "18",
      "USD",
      "[\"foo\"]",
      "Alice",
      "inv",
    ])
  end

  it "returns empty clauses and params for an empty filter hash" do
    clauses, params = FC.compile(definition, {} of String => JSON::Any)
    clauses.should eq([] of String)
    params.should eq([] of ::DB::Any)
  end
end
