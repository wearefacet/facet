# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "db"
require "../../src/util/filter_set"

alias FS = Facet::Util::FilterSet

describe Facet::Util::FilterSet do
  # ── Empty set ──────────────────────────────────────────────────────

  describe "#empty?" do
    it "is true when no filters given" do
      FS.new({} of String => JSON::Any).empty?.should be_true
    end

    it "is false when filters exist" do
      FS.new({"name__eq" => JSON::Any.new("foo")}).empty?.should be_false
    end
  end

  # ── SQL generation ─────────────────────────────────────────────────

  describe "#to_sql" do
    it "returns empty string when no filters" do
      FS.new({} of String => JSON::Any).to_sql.should eq("")
    end

    it "defaults to equality when no operator suffix" do
      set = FS.new({"name" => JSON::Any.new("Alice")})
      set.to_sql.should eq("content->>'name' = $1")
    end

    it "supports __eq" do
      set = FS.new({"name__eq" => JSON::Any.new("Bob")})
      set.to_sql.should eq("content->>'name' = $1")
    end

    it "supports __gt with integer values" do
      set = FS.new({"age__gt" => JSON::Any.new(25_i64)})
      set.to_sql.should eq("(content->>'age')::bigint > $1::bigint")
    end

    it "supports __gte with integer values" do
      set = FS.new({"age__gte" => JSON::Any.new(18_i64)})
      set.to_sql.should eq("(content->>'age')::bigint >= $1::bigint")
    end

    it "supports __lt with integer values" do
      set = FS.new({"age__lt" => JSON::Any.new(65_i64)})
      set.to_sql.should eq("(content->>'age')::bigint < $1::bigint")
    end

    it "supports __lte with integer values" do
      set = FS.new({"age__lte" => JSON::Any.new(100_i64)})
      set.to_sql.should eq("(content->>'age')::bigint <= $1::bigint")
    end

    it "supports __gt with float values" do
      set = FS.new({"price__gt" => JSON::Any.new(9.99_f64)})
      set.to_sql.should eq("(content->>'price')::numeric > $1::numeric")
    end

    it "supports __gt with string values (text comparison)" do
      set = FS.new({"name__gt" => JSON::Any.new("Alice")})
      set.to_sql.should eq("content->>'name' > $1")
    end

    it "supports __gte with boolean values" do
      set = FS.new({"active__gte" => JSON::Any.new(true)})
      set.to_sql.should eq("(content->>'active')::boolean >= $1::boolean")
    end

    it "supports __ne" do
      set = FS.new({"status__ne" => JSON::Any.new("archived")})
      set.to_sql.should eq("content->>'status' IS DISTINCT FROM $1")
    end

    it "supports __match (escaped substring ILIKE)" do
      set = FS.new({"name__match" => JSON::Any.new("smith")})
      set.to_sql.should eq("content->>'name' ILIKE '%' || $1 || '%' ESCAPE '\\'")
    end

    it "supports __starts_with (escaped prefix ILIKE)" do
      set = FS.new({"name__starts_with" => JSON::Any.new("Al")})
      set.to_sql.should eq("content->>'name' ILIKE $1 || '%' ESCAPE '\\'")
    end

    it "escapes LIKE special characters in the bound __match value" do
      set = FS.new({"name__match" => JSON::Any.new("%_")})
      set.values.should eq(["\\%\\_"] of ::DB::Any)
    end

    it "supports __between with two sequential placeholders" do
      set = FS.new({
        "age__between" => JSON::Any.new([JSON::Any.new(18_i64), JSON::Any.new(65_i64)]),
      })
      set.to_sql.should eq("(content->>'age')::bigint BETWEEN $1::bigint AND $2::bigint")
    end

    it "combines multiple filters with AND using sequential $N" do
      set = FS.new({
        "status__eq"  => JSON::Any.new("active"),
        "age__gte"    => JSON::Any.new(18_i64),
        "name__match" => JSON::Any.new("a"),
      })
      sql = set.to_sql
      sql.should contain("content->>'status' = $1")
      sql.should contain("(content->>'age')::bigint >= $2::bigint")
      sql.should contain("content->>'name' ILIKE '%' || $3 || '%' ESCAPE '\\'")
      sql.should match(/ AND /)
    end

    it "does not inline any user values (uses parameterised placeholders)" do
      set = FS.new({"name__eq" => JSON::Any.new("O'Brien")})
      set.to_sql.should eq("content->>'name' = $1")
    end
  end

  # ── Values ─────────────────────────────────────────────────────────

  describe "#values" do
    it "returns an empty array when no filters" do
      FS.new({} of String => JSON::Any).values.should eq([] of ::DB::Any)
    end

    it "returns the raw values in order" do
      set = FS.new({"name__eq" => JSON::Any.new("Alice")})
      set.values.should eq(["Alice"] of ::DB::Any)
    end

    it "includes non-string types" do
      set = FS.new({"age__gt" => JSON::Any.new(25_i64)})
      set.values.should eq([25_i64] of ::DB::Any)
    end

    it "preserves insertion order" do
      set = FS.new({
        "a__eq" => JSON::Any.new("first"),
        "b__eq" => JSON::Any.new(2_i64),
        "c__eq" => JSON::Any.new(true),
      })
      set.values.should eq(["first", 2_i64, true] of ::DB::Any)
    end
  end

  # ── Offset ─────────────────────────────────────────────────────────

  describe "offset constructor argument" do
    it "shifts $N numbering when offset is given" do
      set = FS.new({"name__eq" => JSON::Any.new("Alice")}, offset: 3)
      set.to_sql.should eq("content->>'name' = $4")
    end

    it "chain of offsets still uses sequential N" do
      set = FS.new({
        "a__eq" => JSON::Any.new("x"),
        "b__eq" => JSON::Any.new("y"),
      }, offset: 5)
      set.to_sql.should eq("content->>'a' = $6 AND content->>'b' = $7")
    end
  end

  # ── Composition ────────────────────────────────────────────────────

  describe "#+" do
    it "combines two filter sets with AND" do
      a = FS.new({"status__eq" => JSON::Any.new("active")})
      b = FS.new({"age__gte" => JSON::Any.new(18_i64)})
      combined = a + b
      combined.to_sql.should eq("content->>'status' = $1 AND (content->>'age')::bigint >= $1::bigint")
    end

    it "merges values from both sets" do
      a = FS.new({"a__eq" => JSON::Any.new("1")})
      b = FS.new({"b__eq" => JSON::Any.new("2")})
      combined = a + b
      combined.values.should eq(["1", "2"] of ::DB::Any)
    end

    it "returns a new FilterSet without mutating originals" do
      a = FS.new({"a__eq" => JSON::Any.new("1")})
      b = FS.new({"b__eq" => JSON::Any.new("2")})
      original_a_sql = a.to_sql
      _combined = a + b
      a.to_sql.should eq(original_a_sql)
    end

    it "handles combining with an empty set" do
      empty = FS.new({} of String => JSON::Any)
      set = FS.new({"name__eq" => JSON::Any.new("x")})
      (empty + set).to_sql.should eq(set.to_sql)
      (set + empty).to_sql.should eq(set.to_sql)
    end
  end

  # ── Clause generation (class-level) ─────────────────────────────────

  describe ".build_clause" do
    it "builds an equality clause with $1 placeholder" do
      clause, vals = FS.build_clause("field", JSON::Any.new("val"), 0)
      clause.should eq("content->>'field' = $1")
      vals.should eq(["val"] of ::DB::Any)
    end

    it "respects the idx parameter for $N numbering" do
      clause, _ = FS.build_clause("field", JSON::Any.new("val"), 5)
      clause.should eq("content->>'field' = $6")
    end

    it "builds a __gte clause with integer value" do
      clause, vals = FS.build_clause("n__gte", JSON::Any.new(5_i64), 0)
      clause.should eq("(content->>'n')::bigint >= $1::bigint")
      vals.should eq([5_i64] of ::DB::Any)
    end

    it "builds a __gte clause with string value (text comparison)" do
      clause, vals = FS.build_clause("n__gte", JSON::Any.new("hello"), 0)
      clause.should eq("content->>'n' >= $1")
      vals.should eq(["hello"] of ::DB::Any)
    end

    it "builds a __gt clause with float value" do
      clause, vals = FS.build_clause("p__gt", JSON::Any.new(9.99_f64), 0)
      clause.should eq("(content->>'p')::numeric > $1::numeric")
      vals.should eq([9.99_f64] of ::DB::Any)
    end

    it "builds a __between clause with integer bounds" do
      clause, vals = FS.build_clause(
        "age__between",
        JSON::Any.new([JSON::Any.new(18_i64), JSON::Any.new(65_i64)]),
        0
      )
      clause.should eq("(content->>'age')::bigint BETWEEN $1::bigint AND $2::bigint")
      vals.should eq([18_i64, 65_i64] of ::DB::Any)
    end

    it "builds a __between clause with string bounds (datetime text comparison)" do
      clause, vals = FS.build_clause(
        "due_at__between",
        JSON::Any.new([JSON::Any.new("2026-01-01"), JSON::Any.new("2026-12-31")]),
        3
      )
      clause.should eq("content->>'due_at' BETWEEN $4 AND $5")
      vals.should eq(["2026-01-01", "2026-12-31"] of ::DB::Any)
    end

    it "degrades to FALSE for malformed between value (non-array)" do
      clause, vals = FS.build_clause("age__between", JSON::Any.new("oops"), 0)
      clause.should eq("FALSE")
      vals.should eq([] of ::DB::Any)
    end

    it "degrades to FALSE for malformed between value (wrong length)" do
      clause, vals = FS.build_clause(
        "age__between",
        JSON::Any.new([JSON::Any.new(1_i64)]),
        0
      )
      clause.should eq("FALSE")
      vals.should eq([] of ::DB::Any)
    end

    it "builds an __in clause with one placeholder per entry" do
      clause, vals = FS.build_clause(
        "status__in",
        JSON::Any.new([JSON::Any.new("open"), JSON::Any.new("won")]),
        2
      )
      clause.should eq("content->>'status' = ANY(ARRAY[$3, $4])")
      vals.should eq(["open", "won"] of ::DB::Any)
    end

    it "degrades an __in clause to FALSE for a non-array value" do
      clause, vals = FS.build_clause("status__in", JSON::Any.new("open"), 0)
      clause.should eq("FALSE")
      vals.should eq([] of ::DB::Any)
    end

    it "degrades an __in clause to FALSE for an empty array" do
      clause, vals = FS.build_clause("status__in", JSON.parse("[]"), 0)
      clause.should eq("FALSE")
      vals.should eq([] of ::DB::Any)
    end

    it "degrades an __in clause to FALSE over the value bound" do
      over = Array.new(FS::MAX_IN_VALUES + 1) { |i| JSON::Any.new("v#{i}") }
      clause, vals = FS.build_clause("status__in", JSON::Any.new(over), 0)
      clause.should eq("FALSE")
      vals.should eq([] of ::DB::Any)
    end
  end

  describe ".parse_filter_key" do
    it "splits on double underscore" do
      FS.parse_filter_key("salary__gt").should eq({"salary", "gt"})
    end

    it "defaults op to eq when no separator" do
      FS.parse_filter_key("name").should eq({"name", "eq"})
    end

    it "splits on first double underscore only" do
      FS.parse_filter_key("a__b__c").should eq({"a", "b__c"})
    end
  end

  # ── SQL injection guards ─────────────────────────────────────────────

  describe "field name validation" do
    it "raises ArgumentError for a field name with a single quote" do
      expect_raises(ArgumentError, /FilterSet field/) do
        FS.build_clause("x' UNION SELECT 1 --", JSON::Any.new("val"), 0)
      end
    end

    it "raises ArgumentError for a field name with a space" do
      expect_raises(ArgumentError, /FilterSet field/) do
        FS.build_clause("bad field", JSON::Any.new("val"), 0)
      end
    end

    it "raises ArgumentError for a field name with a semicolon" do
      expect_raises(ArgumentError, /FilterSet field/) do
        FS.build_clause("field; DROP TABLE", JSON::Any.new("val"), 0)
      end
    end

    it "accepts snake_case field names" do
      clause, _ = FS.build_clause("my_field__eq", JSON::Any.new("x"), 0)
      clause.should eq("content->>'my_field' = $1")
    end

    it "accepts camelCase field names" do
      clause, _ = FS.build_clause("myField__eq", JSON::Any.new("x"), 0)
      clause.should eq("content->>'myField' = $1")
    end
  end
end
