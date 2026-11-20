# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/index"

describe Facet::Index::Naming do
  describe ".index_name" do
    it "generates a deterministic name starting with idx_env_" do
      name = Facet::Index::Naming.index_name("hr", "Employee", "email", "btree")
      name.should match(/^idx_env_hr_[a-f0-9]+$/)
    end

    it "generates different names for different field/type combos" do
      name1 = Facet::Index::Naming.index_name("hr", "Employee", "email", "btree")
      name2 = Facet::Index::Naming.index_name("hr", "Employee", "email", "gin_trgm")
      name1.should_not eq(name2)
    end

    it "generates different names for different fields" do
      name1 = Facet::Index::Naming.index_name("hr", "Employee", "email", "btree")
      name2 = Facet::Index::Naming.index_name("hr", "Employee", "name", "btree")
      name1.should_not eq(name2)
    end

    it "generates different names for different domains" do
      name1 = Facet::Index::Naming.index_name("hr", "Employee", "email", "btree")
      name2 = Facet::Index::Naming.index_name("crm", "Employee", "email", "btree")
      name1.should_not eq(name2)
    end

    it "respects the NAMEDATALEN limit of 63 characters" do
      long_domain = "a-very-long-domain-name-that-exceeds-normal-limits-for-testing"
      name = Facet::Index::Naming.index_name(long_domain, "TestDoctype", "a_really_long_field_name_that_goes_on_and_on", "gin_trgm")
      name.bytesize.should be <= 63
    end

    it "is deterministic (same inputs → same output)" do
      name1 = Facet::Index::Naming.index_name("hr", "Employee", "email", "btree")
      name2 = Facet::Index::Naming.index_name("hr", "Employee", "email", "btree")
      name1.should eq(name2)
    end

    # Domain names containing characters that are not valid in a
    # PostgreSQL unquoted identifier (e.g. `new-crm`, `core.hr`, mixed case)
    # must be sanitised. The generated SQL embeds the identifier unquoted,
    # so a stray `-` or `.` produces `syntax error at or near "-"` from
    # `CREATE INDEX` / `DROP INDEX CONCURRENTLY`. See index_name.
    it "produces only identifier-safe characters in the slug" do
      samples = ["hr", "new-crm", "core.hr", "a.b-c", "MixedCase", "under_score"]
      samples.each do |domain|
        name = Facet::Index::Naming.index_name(domain, "Employee", "email", "btree")
        name.should match(/^idx_env_[a-z0-9_]+_[a-f0-9]+$/),
          "expected identifier-safe index name for domain=#{domain.inspect}, got #{name.inspect}"
      end
    end

    it "sanitises hyphenated domain names (regression for new-crm)" do
      name = Facet::Index::Naming.index_name("new-crm", "Deal", "expected_close_date", "btree")
      name.should match(/^idx_env_new_crm_[a-f0-9]+$/)
      name.should_not match(/-/)
    end

    it "preserves uniqueness across domains that share a sanitised slug" do
      # `new-crm` and `new.crm` both sanitise to `new_crm`; the hash suffix
      # must still disambiguate them because the hash input retains the
      # original domain string.
      name1 = Facet::Index::Naming.index_name("new-crm", "Deal", "amount", "btree")
      name2 = Facet::Index::Naming.index_name("new.crm", "Deal", "amount", "btree")
      name1.should_not eq(name2)
    end
  end

  describe ".access_expression" do
    it "returns content->>'field' for simple btree fields" do
      expr = Facet::Index::Naming.access_expression("email", "btree")
      expr.should eq("content->>'email'")
    end

    it "returns content->'field' for simple gin_jsonb fields" do
      expr = Facet::Index::Naming.access_expression("tags", "gin_jsonb")
      expr.should eq("content->'tags'")
    end

    it "returns content#>>'{parent,child}' for nested btree fields" do
      expr = Facet::Index::Naming.access_expression("address.city", "btree")
      expr.should eq("content#>>'{address,city}'")
    end

    it "returns content#>'{parent,child}' for nested gin_jsonb fields" do
      expr = Facet::Index::Naming.access_expression("metadata.tags", "gin_jsonb")
      expr.should eq("content#>'{metadata,tags}'")
    end

    it "returns jsonb_as_numeric(content->'field') for simple btree_numeric fields" do
      expr = Facet::Index::Naming.access_expression("age", "btree_numeric")
      expr.should eq("jsonb_as_numeric(content->'age')")
    end

    it "returns jsonb_as_numeric(content#>'{parent,child}') for nested btree_numeric fields" do
      expr = Facet::Index::Naming.access_expression("profile.age", "btree_numeric")
      expr.should eq("jsonb_as_numeric(content#>'{profile,age}')")
    end

    it "returns a composite (numeric_value, currency_text) for simple btree_money fields" do
      expr = Facet::Index::Naming.access_expression("price", "btree_money")
      expr.should eq("facet_money_value_as_numeric(content->'price'), content#>>'{price,currency}'")
    end

    it "returns a composite access expression for nested btree_money fields" do
      expr = Facet::Index::Naming.access_expression("profile.price", "btree_money")
      expr.should eq("facet_money_value_as_numeric(content#>'{profile,price}'), content#>>'{profile,price,currency}'")
    end

    it "returns the currency text extract for simple btree_money_currency fields" do
      expr = Facet::Index::Naming.access_expression("price", "btree_money_currency")
      expr.should eq("content#>>'{price,currency}'")
    end

    it "returns the currency text extract for nested btree_money_currency fields" do
      expr = Facet::Index::Naming.access_expression("profile.price", "btree_money_currency")
      expr.should eq("content#>>'{profile,price,currency}'")
    end

    it "builds an facet_tstzrange() expression for gist_tstzrange fields" do
      expr = Facet::Index::Naming.access_expression("tenure", "gist_tstzrange")
      expr.should eq("facet_tstzrange(content#>>'{tenure,start}', content#>>'{tenure,end}')")
    end

    it "builds a nested facet_tstzrange() expression for nested period fields" do
      expr = Facet::Index::Naming.access_expression("address.tenure", "gist_tstzrange")
      expr.should eq("facet_tstzrange(content#>>'{address,tenure,start}', content#>>'{address,tenure,end}')")
    end

    it "builds an facet_daterange() expression for gist_daterange fields" do
      expr = Facet::Index::Naming.access_expression("calendar", "gist_daterange")
      expr.should eq("facet_daterange(content#>>'{calendar,start}', content#>>'{calendar,end}')")
    end

    it "raises for unknown index type" do
      expect_raises(ArgumentError, "Unknown index type") do
        Facet::Index::Naming.access_expression("field", "unknown_type")
      end
    end
  end

  describe ".where_clause" do
    it "filters by domain, doctype, and non-deleted" do
      clause = Facet::Index::Naming.where_clause("hr", "Employee")
      clause.should eq("domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL")
    end
  end

  describe ".create_index_sql" do
    it "generates CREATE INDEX CONCURRENTLY for btree" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "email", "btree")
      sql.should match(/^CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_env_hr_[a-f0-9]+ ON projections USING btree \(\(content->>'email'\)\)/)
      sql.should match(/WHERE domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL$/)
    end

    it "generates CREATE INDEX CONCURRENTLY with jsonb_as_numeric for btree_numeric" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "age", "btree_numeric")
      sql.should match(/^CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_env_hr_[a-f0-9]+ ON projections USING btree \(\(jsonb_as_numeric\(content->'age'\)\)\)/)
      sql.should match(/WHERE domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL$/)
    end

    it "generates CREATE UNIQUE INDEX CONCURRENTLY for unique_btree" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "email", "unique_btree")
      sql.should match(/^CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS/)
      sql.should contain("USING btree ((content->>'email'))")
    end

    it "generates CREATE INDEX CONCURRENTLY with gin_trgm_ops for gin_trgm" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "name", "gin_trgm")
      sql.should contain("USING gin ((content->>'name') gin_trgm_ops)")
    end

    it "generates a composite CREATE INDEX for btree_money" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "salary", "btree_money")
      sql.should match(/^CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_env_hr_[a-f0-9]+ ON projections USING btree /)
      sql.should contain("((facet_money_value_as_numeric(content->'salary')), (content#>>'{salary,currency}'))")
      sql.should match(/WHERE domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL$/)
    end

    it "generates CREATE INDEX for btree_money_currency" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "salary", "btree_money_currency")
      sql.should match(/^CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_env_hr_[a-f0-9]+ ON projections USING btree /)
      sql.should contain("(content#>>'{salary,currency}')")
      sql.should match(/WHERE domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL$/)
    end

    it "generates a composite CREATE INDEX for a nested btree_money field" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "profile.salary", "btree_money")
      sql.should contain("((facet_money_value_as_numeric(content#>'{profile,salary}')), (content#>>'{profile,salary,currency}'))")
    end

    it "generates CREATE INDEX CONCURRENTLY with jsonb_ops for gin_jsonb" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "tags", "gin_jsonb")
      sql.should contain("USING gin ((content->'tags') jsonb_ops)")
    end

    it "generates CREATE INDEX CONCURRENTLY USING gist for gist_tstzrange" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "tenure", "gist_tstzrange")
      sql.should match(/^CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_env_hr_/)
      sql.should contain("USING gist ((facet_tstzrange(content#>>'{tenure,start}', content#>>'{tenure,end}')))")
      sql.should contain("WHERE domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL")
    end

    it "generates CREATE INDEX CONCURRENTLY USING gist for gist_daterange" do
      sql = Facet::Index::Naming.create_index_sql("hr", "Employee", "calendar", "gist_daterange")
      sql.should contain("USING gist ((facet_daterange(content#>>'{calendar,start}', content#>>'{calendar,end}')))")
    end

    it "raises for unknown index type" do
      expect_raises(ArgumentError, "Unknown index type") do
        Facet::Index::Naming.create_index_sql("hr", "Employee", "field", "unknown")
      end
    end

    # A hyphenated domain name must produce a valid unquoted PostgreSQL
    # identifier — `CREATE INDEX` with a `-` in the index name raises a
    # syntax error. See the drop_index_sql spec for the cleanup path.
    it "sanitises hyphenated domains in CREATE INDEX SQL" do
      sql = Facet::Index::Naming.create_index_sql("new-crm", "Deal", "expected_close_date", "btree")
      sql.should match(/^CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_env_new_crm_[a-f0-9]+ ON projections/)
      # No stray hyphens in the identifier portion.
      sql[/(?:IF NOT EXISTS ).+ ON projections/].should_not match(/-/)
    end
  end

  describe ".drop_index_sql" do
    it "generates DROP INDEX CONCURRENTLY IF EXISTS" do
      sql = Facet::Index::Naming.drop_index_sql("hr", "Employee", "email", "btree")
      sql.should match(/^DROP INDEX CONCURRENTLY IF EXISTS idx_env_hr_[a-f0-9]+$/)
    end

    # A domain with a hyphen must produce a usable identifier — PG parses
    # `idx_env_new-crm_<hex>` as the identifier `idx_env_new` followed by
    # the stray token `-crm_<hex>`, raising a syntax error.
    it "sanitises hyphenated domains in DROP INDEX SQL" do
      sql = Facet::Index::Naming.drop_index_sql("new-crm", "Deal", "expected_close_date", "btree")
      sql.should match(/^DROP INDEX CONCURRENTLY IF EXISTS idx_env_new_crm_[a-f0-9]+$/)
      # No stray hyphens in the identifier (the SQL keyword prefix is separate).
      sql[/(?:IF EXISTS ).+$/].should_not match(/-/)
    end
  end
end
