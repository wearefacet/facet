# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "json"
require "../../src/rbac"

# Builds a Real principal whose role can read the doctype and sees the
# given tags — the sum field-tag guard under test is orthogonal to the
# read permission, so the 403 must be the only gate that fires.
def sum_tagged_caller(domain : String, doctype : String, visible : Array(String))
  role = Facet::RBAC::ActiveRole.new(
    role_id: "sum_tag_role",
    visible_tags: Set.new(visible),
    permissions: [Facet::RBAC::Permission.new(action: "read", domain: domain, path: [doctype])],
  )
  Facet::RBAC::AuthContext.authenticated("sum_tag_account", role)
end

# Builds a Real principal whose role holds no read permission on the
# target doctype at all — the same gate state that makes their list answer
# the non-disclosing empty set. The role keeps the default visible_tags so
# the field-tag guard would fire on a tagged field if the aggregate path
# ran it.
private def agg_no_grant_caller
  role = Facet::RBAC::ActiveRole.new(
    role_id: "agg_no_grant_role",
    visible_tags: Set.new(["default"]),
    permissions: [] of Facet::RBAC::Permission,
  )
  Facet::RBAC::AuthContext.authenticated("agg_no_grant_account", role)
end

# Seeds an aggregate-root parent and an owned child (`member_of`) doctype
# pair for the reserved `parent_id__eq` filter examples.
private def parent_filter_seed_pair(db : DB::Connection, domain : String, parent_dt : String, child_dt : String)
  ensure_domain(db, domain)
  parent_defn = %({"doctype": "#{parent_dt}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"parts": {"doctype": "#{child_dt}", "collection": true}}})
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system))
  child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string"}}})
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system))
end

private def parent_filter_create_parent(db : DB::Connection, domain : String, parent_dt : String, name : String) : Facet::Mutation::Client::Projection
  expect_create_success(Facet::Document::Create.call(db, domain, parent_dt, %({"name": "#{name}"}), Facet::RBAC::AuthContext.system)).projection
end

private def parent_filter_create_child(db : DB::Connection, domain : String, child_dt : String, parent_id : String, label : String) : Facet::Mutation::Client::Projection
  expect_create_success(Facet::Document::Create.call(
    db, domain, child_dt, %({"label": "#{label}"}), Facet::RBAC::AuthContext.system,
    meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
  )).projection
end

describe Facet::Document::List do
  # ── aggregate: count ────────────────────────────────────────────────
  #
  # Count mode returns the same `Result` shape with an empty `items` array
  # and `total` reflecting the capped-at-1000 row count. Replicates the
  # normal-list cap semantics so the caller always learns the inclusive
  # upper bound of what matches, irrespective of the page/items supplied.

  it "aggregate:count returns an empty items array with the capped total" do
    with_temp_doctype("listcountbasic") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}, "status": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      3.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "u#{i}", "status": "active"}), Facet::RBAC::AuthContext.system))
      end
      2.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "d#{i}", "status": "inactive"}), Facet::RBAC::AuthContext.system))
      end

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "count")
      result.should be_a(Facet::Document::List::Result)
      r = result.as(Facet::Document::List::Result)
      r.items.should be_empty
      r.total.should eq(5)
      r.more.should be_false
    end
  end

  it "aggregate:count applies filters the same as a normal list" do
    with_temp_doctype("listcountfilter") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}, "status": {"type": "string", "filters": ["equality"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      3.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "u#{i}", "status": "active"}), Facet::RBAC::AuthContext.system))
      end
      2.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "d#{i}", "status": "inactive"}), Facet::RBAC::AuthContext.system))
      end

      filtered = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"status__eq" => JSON::Any.new("active")},
        auth_context: Facet::RBAC::AuthContext.system,
        aggregate: "count",
      )
      filtered.should be_a(Facet::Document::List::Result)
      r = filtered.as(Facet::Document::List::Result)
      r.items.should be_empty
      r.total.should eq(3)
    end
  end

  it "aggregate:count ignores page and items — reports the full capped total" do
    with_temp_doctype("listcountpage") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      4.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "u#{i}"}), Facet::RBAC::AuthContext.system))
      end

      # page=2, items=2 would normally yield total=3 (capped offset+items).
      # In count mode the caller learns the full total of what matches,
      # irrespective of page/items — that is the whole reason count mode
      # exists.
      result = Facet::Document::List.call(db, domain, doctype, page: 2, items_per_page: 2, auth_context: Facet::RBAC::AuthContext.system, aggregate: "count")
      r = result.as(Facet::Document::List::Result)
      r.total.should eq(4)
    end
  end

  it "aggregate:count caps at 1000 and reports more=true at the HTTP layer (total > 1000)" do
    with_temp_doctype("listcountcap") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      # 1001 rows: the COUNT subquery wraps with LIMIT 1001, so the count
      # subquery returns 1001. The `Result` carries more=true when the cap
      # is reached (`total > COUNT_CAP`); the HTTP layer turns this into
      # count=1000, more=true. At the List layer we assert the raw cap:
      # `total` is 1001 — the cap protects PostgreSQL from full-table scans
      # but still signals "max reached" to callers.
      1001.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "u#{i}"}), Facet::RBAC::AuthContext.system))
      end

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "count")
      r = result.as(Facet::Document::List::Result)
      r.items.should be_empty
      r.total.should eq(1001)
      r.more.should be_true
    end
  end

  it "aggregate:count returns 422 for unknown aggregate values" do
    with_temp_doctype("listcountbadagg") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "median")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Unknown aggregate")
    end
  end

  it "aggregate:count answers 403 for a caller with no read access" do
    with_temp_doctype("listcountscoped") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      3.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "u#{i}"}), Facet::RBAC::AuthContext.system))
      end

      # A caller with no read permission on the doctype at all is denied
      # the resource class — the same gate state the write side answers
      # 403 for. The class-level check runs before any SQL, so the count
      # never leaks the row total. A caller that holds a read grant gets
      # the scope-narrowed count instead (see the scoped specs above).
      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.denied, aggregate: "count")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
    end
  end

  it "lists documents of a given doctype" do
    with_temp_doctype("listbasic") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      r1 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Alice"}), Facet::RBAC::AuthContext.system)
      r2 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Bob"}), Facet::RBAC::AuthContext.system)
      expect_create_success(r1)
      expect_create_success(r2)

      list_result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system)
      list_result.should be_a(Facet::Document::List::Result)
      result = list_result.as(Facet::Document::List::Result)
      result.items.size.should be >= 2
      result.total.should be >= 2
    end
  end

  it "returns error for unknown doctype" do
    with_db do |db|
      result = Facet::Document::List.call(db, "nonexistent", "Unknown", auth_context: Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      error = result.as(Facet::ServiceError)
      error.status.should eq(404)
      error.message.should contain("Unknown doctype")
    end
  end

  it "answers 422 for a filter key naming an unknown field (B-20)" do
    with_temp_doctype("listfilterignore") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Alice"}), Facet::RBAC::AuthContext.system))

      # A typo in a filter key must surface, never degrade to an
      # unfiltered result. The message names the key and the filterable
      # fields; the structured detail carries the code.
      list_result = Facet::Document::List.call(db, domain, doctype, filters: {"nonexistent__eq" => JSON::Any.new("x")}, auth_context: Facet::RBAC::AuthContext.system)
      list_result.should be_a(Facet::ServiceError)
      error = list_result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("nonexistent")
      error.message.should contain("filterable")
      detail = error.details.try(&.first?)
      detail.should_not be_nil
      detail.try(&.code).should eq("unknown_filter_field")
      detail.try(&.field).should eq("nonexistent__eq")
    end
  end

  it "supports pagination" do
    with_temp_doctype("listpagination") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      3.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "User#{i}"}), Facet::RBAC::AuthContext.system))
      end

      page1 = Facet::Document::List.call(db, domain, doctype, page: 1, items_per_page: 2, auth_context: Facet::RBAC::AuthContext.system)
      page1.should be_a(Facet::Document::List::Result)
      p1 = page1.as(Facet::Document::List::Result)
      p1.items.size.should be <= 2

      page2 = Facet::Document::List.call(db, domain, doctype, page: 2, items_per_page: 2, auth_context: Facet::RBAC::AuthContext.system)
      page2.should be_a(Facet::Document::List::Result)
      p2 = page2.as(Facet::Document::List::Result)
      p2.items.size.should be >= 1
    end
  end

  it "normal mode counts the real total from the page offset" do
    with_temp_doctype("listmoretrue") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      5.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "u#{i}"}), Facet::RBAC::AuthContext.system))
      end

      # Page 1: the count reads every matching row from this offset, so
      # `total` is the real number (5), not the page size plus a probe.
      page1 = Facet::Document::List.call(db, domain, doctype, page: 1, items_per_page: 2, auth_context: Facet::RBAC::AuthContext.system)
      p1 = page1.as(Facet::Document::List::Result)
      p1.items.size.should eq(2)
      p1.total.should eq(5)
      p1.more.should be_false

      # Middle page: the count is offset-relative, so it reports what
      # remains from here (3).
      page2 = Facet::Document::List.call(db, domain, doctype, page: 2, items_per_page: 2, auth_context: Facet::RBAC::AuthContext.system)
      p2 = page2.as(Facet::Document::List::Result)
      p2.items.size.should eq(2)
      p2.total.should eq(3)
      p2.more.should be_false

      # Last page: nothing remains after it, even though the page is not full.
      page3 = Facet::Document::List.call(db, domain, doctype, page: 3, items_per_page: 2, auth_context: Facet::RBAC::AuthContext.system)
      p3 = page3.as(Facet::Document::List::Result)
      p3.items.size.should eq(1)
      p3.total.should eq(1)
      p3.more.should be_false
    end
  end

  it "normal mode sets more=false when the result set fits the page exactly" do
    with_temp_doctype("listmoreexact") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      4.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "u#{i}"}), Facet::RBAC::AuthContext.system))
      end

      # Page 1 of 2: the count sees all four rows, so `more` stays false —
      # it means "counting was truncated", not "a next page exists".
      page1 = Facet::Document::List.call(db, domain, doctype, page: 1, items_per_page: 2, auth_context: Facet::RBAC::AuthContext.system)
      p1 = page1.as(Facet::Document::List::Result)
      p1.items.size.should eq(2)
      p1.total.should eq(4)
      p1.more.should be_false

      # Page 2: a full page with nothing behind it — the exact-fit case.
      page2 = Facet::Document::List.call(db, domain, doctype, page: 2, items_per_page: 2, auth_context: Facet::RBAC::AuthContext.system)
      p2 = page2.as(Facet::Document::List::Result)
      p2.items.size.should eq(2)
      p2.total.should eq(2)
      p2.more.should be_false
    end
  end

  it "normal mode caps the count at COUNT_CAP and flags more=true" do
    with_temp_doctype("listcountcapnormal") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      # COUNT_CAP + 2 rows: the count subquery reads COUNT_CAP + 1 of them,
      # which is enough to know the cap was hit.
      (Facet::Document::List::COUNT_CAP + 2).times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "u#{i}"}), Facet::RBAC::AuthContext.system))
      end

      page1 = Facet::Document::List.call(db, domain, doctype, page: 1, items_per_page: 10, auth_context: Facet::RBAC::AuthContext.system)
      p1 = page1.as(Facet::Document::List::Result)
      p1.items.size.should eq(10)
      p1.total.should eq(Facet::Document::List::COUNT_CAP + 1)
      p1.more.should be_true

      # Offset-relative: page 2 starts 10 rows in, so the window holds the
      # 992 rows still ahead of it — the cap was not hit from here.
      page2 = Facet::Document::List.call(db, domain, doctype, page: 2, items_per_page: 10, auth_context: Facet::RBAC::AuthContext.system)
      p2 = page2.as(Facet::Document::List::Result)
      p2.total.should eq(Facet::Document::List::COUNT_CAP + 2 - 10)
      p2.more.should be_false
    end
  end

  it "lazily migrates a stale document in the list result" do
    with_temp_doctype("listmig") do |db, domain, dt|
      ensure_domain(db, domain)
      # Create a v1 doctype with a migration script
      script = <<-LUA
      local export = {}
      function export.create(ctx) end
      function export.migrate_from_1(ctx)
        ctx.root.priority = ctx.root.priority or 'normal'
      end
      return export
      LUA
      fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
      body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
      defn = Facet::Doctype::DoctypeDefinition.from_json(body)
      Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Create::Result)

      # Create a document at v1
      doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}), Facet::RBAC::AuthContext.system)
      proj = doc_result.as(Facet::Document::Create::Result).projection

      # Verify it's at v1
      proj.meta["schema_version"].as_i.should eq(1)

      # Update the doctype to v2
      doctype_id = "#{domain}.#{dt}"
      v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
      Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

      # List — should trigger lazy migration
      list_result = Facet::Document::List.call(db, domain, dt, auth_context: Facet::RBAC::AuthContext.system)
      list_result.should be_a(Facet::Document::List::Result)
      result = list_result.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items[0].content["priority"].should eq(JSON.parse(%("normal")))
      result.items[0].meta["schema_version"].as_i.should eq(2)

      # Verify it was persisted
      stored = Facet::Mutation::Client.fetch_projection(db, domain, dt, proj.id)
      stored.meta["schema_version"].as_i.should eq(2)
    end
  end

  it "does not migrate a document that is already at the current schema version" do
    with_temp_doctype("listmig2") do |db, domain, dt|
      ensure_domain(db, domain)
      script = <<-LUA
      local export = {}
      function export.create(ctx) end
      function export.migrate_from_1(ctx)
        ctx.root.priority = 'normal'
      end
      return export
      LUA
      fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
      body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
      defn = Facet::Doctype::DoctypeDefinition.from_json(body)
      Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Create::Result)

      doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}), Facet::RBAC::AuthContext.system)
      doc_result.should be_a(Facet::Document::Create::Result)

      # Update doctype to v2
      doctype_id = "#{domain}.#{dt}"
      v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
      Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

      # First list triggers migration
      list1 = Facet::Document::List.call(db, domain, dt, auth_context: Facet::RBAC::AuthContext.system)
      list1.should be_a(Facet::Document::List::Result)
      list1.as(Facet::Document::List::Result).items[0].meta["schema_version"].as_i.should eq(2)

      # Second list should not migrate again
      list2 = Facet::Document::List.call(db, domain, dt, auth_context: Facet::RBAC::AuthContext.system)
      list2.should be_a(Facet::Document::List::Result)
      list2.as(Facet::Document::List::Result).items[0].meta["schema_version"].as_i.should eq(2)
    end
  end

  it "migrates a mix of stale and already-migrated documents" do
    with_temp_doctype("listmig3") do |db, domain, dt|
      ensure_domain(db, domain)
      script = <<-LUA
      local export = {}
      function export.create(ctx) end
      function export.migrate_from_1(ctx)
        ctx.root.priority = ctx.root.priority or 'normal'
      end
      return export
      LUA
      fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
      body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
      defn = Facet::Doctype::DoctypeDefinition.from_json(body)
      Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Create::Result)

      # Create two documents at v1
      doc1 = Facet::Document::Create.call(db, domain, dt, %({"title": "doc one"}), Facet::RBAC::AuthContext.system)
      doc2 = Facet::Document::Create.call(db, domain, dt, %({"title": "doc two"}), Facet::RBAC::AuthContext.system)
      proj1 = doc1.as(Facet::Document::Create::Result).projection
      _proj2 = doc2.as(Facet::Document::Create::Result).projection

      # Update doctype to v2
      doctype_id = "#{domain}.#{dt}"
      v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
      Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

      # Migrate doc1 individually via Read first
      Facet::Document::Read.call(db, domain, dt, proj1.id, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Read::Result)

      # List should migrate doc2 (stale) and leave doc1 (already migrated) alone
      list_result = Facet::Document::List.call(db, domain, dt, auth_context: Facet::RBAC::AuthContext.system)
      list_result.should be_a(Facet::Document::List::Result)
      result = list_result.as(Facet::Document::List::Result)
      result.items.size.should eq(2)
      result.items.all? { |item| item.meta["schema_version"].as_i == 2 }.should be_true
      result.items.all? { |item| item.content["priority"]? == JSON.parse(%("normal")) }.should be_true
    end
  end

  it "marks a document with migration_error when migration fails in list" do
    with_temp_doctype("listmig4") do |db, domain, dt|
      ensure_domain(db, domain)
      script = <<-LUA
      local export = {}
      function export.create(ctx) end
      function export.migrate_from_1(ctx)
        ctx.error('migration failed')
      end
      return export
      LUA
      fields_json = %({"title": {"type": "string", "required": true}})
      body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
      defn = Facet::Doctype::DoctypeDefinition.from_json(body)
      Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Create::Result)

      doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}), Facet::RBAC::AuthContext.system)
      doc_result.should be_a(Facet::Document::Create::Result)

      doctype_id = "#{domain}.#{dt}"
      v2_fields = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
      v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{v2_fields}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
      Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

      # List — migration fails, document gets migration_error marker in meta
      list_result = Facet::Document::List.call(db, domain, dt, auth_context: Facet::RBAC::AuthContext.system)
      list_result.should be_a(Facet::Document::List::Result)
      result = list_result.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      # The marker preserves the Lua `ctx.error` text so operators can see why.
      result.items[0].meta["migration_error"].as_s.should contain("migration failed")

      # Second list — should not retry migration
      list2 = Facet::Document::List.call(db, domain, dt, auth_context: Facet::RBAC::AuthContext.system)
      list2.should be_a(Facet::Document::List::Result)
      result2 = list2.as(Facet::Document::List::Result)
      # The persisted marker still carries the Lua reason after retry-blocking.
      result2.items[0].meta["migration_error"].as_s.should contain("migration failed")
    end
  end

  # ── Period / dateperiod range filters ──────────────────────────────────

  it "filters period fields by point containment via __contains" do
    with_temp_doctype("listperiodcontains") do |db, domain, doctype|
      ensure_domain(db, domain)
      schema = %({"doctype":"#{doctype}","domain":"#{domain}","fields":{"tenure":{"type":"period","filters":["interval"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system))

      # Period covering 2026-01-01 to 2026-02-01 (exclusive upper)
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"tenure":{"start":"2026-01-01T00:00:00Z","end":"2026-02-01T00:00:00Z"}}), Facet::RBAC::AuthContext.system))
      # Period covering 2025-06-01 to 2025-09-01
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"tenure":{"start":"2025-06-01T00:00:00Z","end":"2025-09-01T00:00:00Z"}}), Facet::RBAC::AuthContext.system))

      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"tenure__contains" => JSON::Any.new("2026-01-15T00:00:00Z")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      # Only the 2026 period contains 2026-01-15.
      result.items.size.should eq(1)
      (result.items[0].content["tenure"]["start"].as_s).should eq("2026-01-01T00:00:00Z")
    end
  end

  it "filters period fields by overlap via __overlaps" do
    with_temp_doctype("listperiodoverlaps") do |db, domain, doctype|
      ensure_domain(db, domain)
      schema = %({"doctype":"#{doctype}","domain":"#{domain}","fields":{"tenure":{"type":"period","filters":["interval"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"tenure":{"start":"2026-01-01T00:00:00Z","end":"2026-02-01T00:00:00Z"}}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"tenure":{"start":"2025-06-01T00:00:00Z","end":"2025-09-01T00:00:00Z"}}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"tenure":{"start":"2026-03-01T00:00:00Z","end":"2026-04-01T00:00:00Z"}}), Facet::RBAC::AuthContext.system))

      # Query overlap with [2026-01-15, 2026-03-15) → two periods overlap:
      # the Jan-Feb one and the Mar-Apr one. The mid-2025 one does not.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"tenure__overlaps" => JSON.parse(%(["2026-01-15T00:00:00Z","2026-03-15T00:00:00Z"]))},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(2)
      starts = result.items.map(&.content.["tenure"].["start"].as_s).sort!
      starts.should eq(["2026-01-01T00:00:00Z", "2026-03-01T00:00:00Z"])
    end
  end

  it "filters dateperiod fields by point containment" do
    with_temp_doctype("listdateperiod") do |db, domain, doctype|
      ensure_domain(db, domain)
      schema = %({"doctype":"#{doctype}","domain":"#{domain}","fields":{"calendar":{"type":"dateperiod","filters":["interval"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system))

      # Inclusive bounds — Jan 1..Jan 31 includes Jan 31.
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"calendar":{"start":"2026-01-01","end":"2026-01-31"}}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"calendar":{"start":"2026-03-01","end":"2026-03-31"}}), Facet::RBAC::AuthContext.system))

      # Query on 2026-01-31 — should match the Jan range only (inclusive).
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"calendar__contains" => JSON::Any.new("2026-01-31")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items[0].content["calendar"]["start"].as_s.should eq("2026-01-01")
    end
  end

  # ── System-column filters (id, created_at, updated_at) ────────────────
  #
  # Unlike doctype `fields` filters (which go through `FilterSet` against
  # `content->>'field'`), these target the `projections` table columns
  # directly. They are useful for listing UIs that expose the table's
  # `created_at`/`updated_at` columns and let users filter on them.

  it "filters by id equality via __eq" do
    with_temp_doctype("listidfilter") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      r1 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Alice"}), Facet::RBAC::AuthContext.system)
      r2 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Bob"}), Facet::RBAC::AuthContext.system)
      expect_create_success(r1)
      expect_create_success(r2)
      id1 = r1.as(Facet::Document::Create::Result).projection.id

      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"id__eq" => JSON::Any.new(id1)},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items[0].id.should eq(id1)
    end
  end

  it "supports id__between (inclusive ULID range)" do
    with_temp_doctype("listidbetween") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      r1 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Alice"}), Facet::RBAC::AuthContext.system)
      r2 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Bob"}), Facet::RBAC::AuthContext.system)
      r3 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Carol"}), Facet::RBAC::AuthContext.system)
      # ULIDs embed a 48-bit ms timestamp plus a 10-bit sub-ms field (~0.98 µs),
      # so back-to-back `Create` calls (each taking ms) produce strictly
      # increasing id prefixes.
      expect_create_success(r1); expect_create_success(r2); expect_create_success(r3)
      id1 = r1.as(Facet::Document::Create::Result).projection.id
      id3 = r3.as(Facet::Document::Create::Result).projection.id

      # Inclusive range from id1 to id3 captures all three documents.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"id__between" => JSON.parse(%(["#{id1}", "#{id3}"]))},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(3)
    end
  end

  it "filters by created_at with tz-offset normalization to UTC" do
    with_temp_doctype("listcreatedat") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      alice_result = Facet::Document::Create.call(db, domain, doctype, %({"name": "Alice"}), Facet::RBAC::AuthContext.system)
      expect_create_success(alice_result)
      alice_id = alice_result.as(Facet::Document::Create::Result).projection.id
      # Backdate Alice so her created_at is strictly before Bob's. Never
      # rely on write ordering: two writes in the same millisecond can get
      # the same ULID timestamp.
      db.exec("UPDATE projections SET created_at = now() - interval '1 hour' WHERE id = $1", alice_id)
      r2 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Bob"}), Facet::RBAC::AuthContext.system)
      expect_create_success(r2)
      bob = r2.as(Facet::Document::Create::Result).projection
      bob_created = bob.created_at.to_rfc3339

      # Filter `created_at__gte` with a tz-offset value that normalizes to
      # UTC exactly at Bob's `created_at`. Only Bob should match.
      list = Facet::Document::List.call(
        db, domain, doctype,
        # Append a +00:00 offset to prove the path goes through
        # `normalize_datetime_filter_value` (a bare tz-naive string would
        # be rejected by `Time.parse_iso8601`).
        filters: {"created_at__gte" => JSON::Any.new("#{bob_created}+00:00")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      # Alice is backdated an hour, so the result set is fully determined:
      # only Bob matches.
      result.items.map(&.id).should eq([bob.id])
    end
  end

  it "filters by created_at with a relative date" do
    with_temp_doctype("listrelativedt") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      alice = Facet::Document::Create.call(db, domain, doctype, %({"name": "Alice"}), Facet::RBAC::AuthContext.system)
      expect_create_success(alice)
      alice_id = alice.as(Facet::Document::Create::Result).projection.id
      db.exec("UPDATE projections SET created_at = now() - interval '2 days' WHERE id = $1", alice_id)
      bob = Facet::Document::Create.call(db, domain, doctype, %({"name": "Bob"}), Facet::RBAC::AuthContext.system)
      expect_create_success(bob)

      # `-1d` covers the last 24 hours: only Bob, created now.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"created_at__gte" => JSON::Any.new("-1d")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.as(Facet::Document::List::Result).items.map(&.content["name"].as_s).should eq(["Bob"])

      # `-3d` covers both rows.
      wide = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"created_at__gte" => JSON::Any.new("-3d")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      wide.as(Facet::Document::List::Result).items.size.should eq(2)
    end
  end

  it "filters a date field with a relative date truncated to the day" do
    with_temp_doctype("listrelativedate") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}, "due": {"type": "date", "filters": ["comparison"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      yesterday = (Time.utc - 1.day).to_s("%F")
      last_year = (Time.utc - 1.year).to_s("%F")
      [{"Alice", last_year}, {"Bob", yesterday}].each do |(name, due)|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "#{name}", "due": "#{due}"}), Facet::RBAC::AuthContext.system))
      end

      # `-1d` truncates to yesterday's calendar day: only Bob.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"due__gte" => JSON::Any.new("-1d")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.as(Facet::Document::List::Result).items.map(&.content["name"].as_s).should eq(["Bob"])
    end
  end

  it "refuses a relative time unit on a date field with a 422" do
    with_temp_doctype("listrelativedateunit") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"due": {"type": "date", "filters": ["comparison"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"due__gte" => JSON::Any.new("-2h")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("carries a time unit")
    end
  end

  it "filters by updated_at__between with an ISO-8601 array" do
    with_temp_doctype("listupdatedatbetween") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      r1 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Alice"}), Facet::RBAC::AuthContext.system)
      expect_create_success(r1)
      alice = r1.as(Facet::Document::Create::Result).projection
      # A wide `between` window: from 1 minute before alice's updated_at to
      # 1 minute after. Avoids sub-second precision issues from RFC-3339
      # truncating to seconds (alice.updated_at may carry microseconds).
      lower = (alice.updated_at - 1.minute).to_rfc3339
      upper = (alice.updated_at + 1.minute).to_rfc3339

      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"updated_at__between" => JSON.parse(%(["#{lower}", "#{upper}"]))},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.any?(&.id.==(alice.id)).should be_true
    end
  end

  it "answers 422 for an unserved operator on a system column (B-20)" do
    with_temp_doctype("listcreatedatmatch") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      # `match` has no useful semantics on a `timestamp` column — the
      # strict grammar refuses the key instead of degrading to FALSE.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"created_at__match" => JSON::Any.new("2025-")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::ServiceError)
      error = list.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("'match'")
      error.details.try(&.first?).try(&.code).should eq("unsupported_filter_operator")
    end
  end

  # ── Type-aware ORDER BY on JSONB fields ───────────────────────────────
  #
  # Sorting on a doctype field must respect the field's declared type so
  # that `integer` / `money` fields sort numerically (0, 10, 20, 100)
  # rather than lexicographically ('0', '10', '100', '20'). Cast failures
  # on a malformed stored value must degrade to NULL rather than 500-ing
  # the whole list call.

  it "sorts integer fields numerically rather than lexicographically" do
    with_temp_doctype("listsortint") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"age": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      [0, 10, 100, 20].each do |n|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"age": #{n}}), Facet::RBAC::AuthContext.system))
      end

      list = Facet::Document::List.call(
        db, domain, doctype,
        sort: ["age"],
        items_per_page: 50,
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      ages = result.items.map(&.content["age"].as_i)
      ages.should eq([0, 10, 20, 100])
    end
  end

  it "sorts integer fields descending numerically" do
    with_temp_doctype("listsortintdesc") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"age": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      [0, 10, 100, 20].each do |n|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"age": #{n}}), Facet::RBAC::AuthContext.system))
      end

      list = Facet::Document::List.call(
        db, domain, doctype,
        sort: ["-age"],
        items_per_page: 50,
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      ages = result.items.map(&.content["age"].as_i)
      ages.should eq([100, 20, 10, 0])
    end
  end

  it "does not 500 when an integer field holds a non-numeric value in some document" do
    with_temp_doctype("listsortintbad") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"age": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      # Two well-formed documents
      r10 = Facet::Document::Create.call(db, domain, doctype, %({"age": 10}), Facet::RBAC::AuthContext.system)
      r20 = Facet::Document::Create.call(db, domain, doctype, %({"age": 20}), Facet::RBAC::AuthContext.system)
      expect_create_success(r10)
      expect_create_success(r20)

      # Inject a document whose `age` violates the doctype type. Bypasses
      # validation by writing a snapshot mutation directly.
      bad_id = "bad#{unique_suffix}"
      Facet::Mutation::Client.snapshot_mutation(
        db, domain, doctype, bad_id,
        content: %({"age": "not-a-number"}),
        meta: %({"schema_version": 1}),
        version: 1
      )

      # Listing sorted by age must not raise; the bad row degrades to NULL
      # and sorts consistently with the column default (NULLS LAST for ASC).
      list = Facet::Document::List.call(
        db, domain, doctype,
        sort: ["age"],
        items_per_page: 50,
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      ids = result.items.map(&.id)
      r10.as(Facet::Document::Create::Result).projection.id.tap do |expected_first|
        ids.should contain(expected_first)
      end
      # Bad row is present (not silently dropped) since it is a valid projection.
      ids.should contain(bad_id)
    end
  end

  it "sorts money fields numerically rather than lexicographically" do
    with_temp_doctype("listsortmoney") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"price": {"type": "money", "currency": "USD"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      # Numeric values: 5, 12, 100, 25 — lexicographically these would
      # sort as 100, 12, 25, 5.
      [5, 12, 100, 25].each do |n|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"price": #{money_json(n.to_s, "USD")}}), Facet::RBAC::AuthContext.system))
      end

      list = Facet::Document::List.call(
        db, domain, doctype,
        sort: ["price"],
        items_per_page: 50,
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      prices = result.items.map(&.content.["price"].["value"].as_s.to_f)
      prices.should eq([5.0, 12.0, 25.0, 100.0])
    end
  end

  it "answers 422 unsortable_field for a non-scalar field (object)" do
    with_temp_doctype("listsortobj") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"profile": {"type": "object"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      2.times do |i|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"profile": {"k": #{i}}}), Facet::RBAC::AuthContext.system))
      end

      # Sorting by an `object` field is meaningless; the request is refused
      # instead of silently dropping the column (B-158).
      list = Facet::Document::List.call(
        db, domain, doctype,
        sort: ["profile"],
        items_per_page: 50,
        auth_context: Facet::RBAC::AuthContext.system
      )
      err = list.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("Field 'profile' of type 'object' is not sortable")
      detail = err.details.not_nil!.first
      detail.code.should eq("unsortable_field")
      detail.field.should eq("profile")
    end
  end

  it "answers 422 unknown_sort_field for `-created` — neither a system column nor a doctype field" do
    with_temp_doctype("listsortunk") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), Facet::RBAC::AuthContext.system))

      list = Facet::Document::List.call(
        db, domain, doctype,
        sort: ["-created"],
        auth_context: Facet::RBAC::AuthContext.system
      )
      err = list.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("Unknown sort field 'created'")
      detail = err.details.not_nil!.first
      detail.code.should eq("unknown_sort_field")
      detail.field.should eq("created")
    end
  end

  it "answers 422 when a sort mixes a valid entry with an unknown field" do
    with_temp_doctype("listsortmix") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), Facet::RBAC::AuthContext.system))

      list = Facet::Document::List.call(
        db, domain, doctype,
        sort: ["id", "nope"],
        auth_context: Facet::RBAC::AuthContext.system
      )
      err = list.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("'nope'")
    end
  end

  it "sorts on the system columns id, created_at, and updated_at" do
    with_temp_doctype("listsortsys") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      created = ["a", "b", "c"].map do |name|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "#{name}"}), Facet::RBAC::AuthContext.system)).projection.id
      end

      # `id` sorts by creation order (the ULID contract).
      list = Facet::Document::List.call(
        db, domain, doctype,
        sort: ["id"],
        items_per_page: 50,
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      list.as(Facet::Document::List::Result).items.map(&.id).should eq(created)

      # `created_at` ascending matches the creation order; `-updated_at`
      # reverses it. The timestamp columns carry microsecond precision, so
      # sequentially created rows never tie.
      ["created_at", "-updated_at"].each do |column|
        list = Facet::Document::List.call(
          db, domain, doctype,
          sort: [column],
          items_per_page: 50,
          auth_context: Facet::RBAC::AuthContext.system
        )
        list.should be_a(Facet::Document::List::Result)
        result = list.as(Facet::Document::List::Result)
        expected = column.starts_with?("-") ? created.reverse : created
        result.items.map(&.id).should eq(expected)
      end
    end
  end

  it "answers 422 for a bad sort in aggregate count mode" do
    with_temp_doctype("listsortcount") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), Facet::RBAC::AuthContext.system))

      # The order clause compiles before the count runs, so a bad sort
      # answers 422 in count mode too.
      list = Facet::Document::List.call(
        db, domain, doctype,
        aggregate: "count",
        sort: ["-created"],
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.as(Facet::ServiceError).status.should eq(422)
    end
  end

  # ── Search filter (search % → ILIKE) ──────────────────────────────────

  it "matches by search on a doctype with an explicit search template (bare search key; suffixed keys answer 422)" do
    with_temp_doctype("listsearcharr") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({
        "doctype": "#{doctype}", "domain": "#{domain}",
        "search": "{{ name }} {{ domain_name }}",
        "fields": {"name": {"type": "string"}, "domain_name": {"type": "string"}}
      })
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Acme Corp", "domain_name": "acme.com"})))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Globex Inc", "domain_name": "globex.com"})))

      # Contains semantics via ILIKE (case-insensitive).
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("acm")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items.first.content["name"].as_s.should eq("Acme Corp")

      # `search` is bare-only: every suffixed form is refused by the
      # strict filter grammar (B-20), not silently compiled to FALSE.
      suffixed = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search__eq" => JSON::Any.new("acm")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      suffixed.should be_a(Facet::ServiceError)
      suffixed.as(Facet::ServiceError).status.should eq(422)
    end
  end

  it "falls back to id and display_name matching on a doctype with no search template (B-115)" do
    with_temp_doctype("listsearchfallback") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({
        "doctype": "#{doctype}", "domain": "#{domain}",
        "display_name": "{{ name }}",
        "fields": {"name": {"type": "string"}}
      })
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      r1 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Acme Corp"}), Facet::RBAC::AuthContext.system)
      expect_create_success(r1)
      doc_id = r1.as(Facet::Document::Create::Result).projection.id

      # No template → the corpus column is NULL, so the bare search filter
      # falls back to a contains match on the row id and the display_name
      # (B-115) instead of matching nothing.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("acm")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items.first.id.should eq(doc_id)

      id_frag = doc_id[-8..]
      list2 = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new(id_frag)},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list2.should be_a(Facet::Document::List::Result)
      result2 = list2.as(Facet::Document::List::Result)
      result2.items.size.should eq(1)
      result2.items.first.id.should eq(doc_id)

      # A term that matches neither the id nor the display_name still finds
      # nothing.
      list3 = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("initech")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list3.should be_a(Facet::Document::List::Result)
      list3.as(Facet::Document::List::Result).items.size.should eq(0)

      # By-id lookup keeps the dedicated system filter.
      list4 = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"id__match" => JSON::Any.new(id_frag)},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list4.should be_a(Facet::Document::List::Result)
      result4 = list4.as(Facet::Document::List::Result)
      result4.items.size.should eq(1)
      result4.items.first.id.should eq(doc_id)
    end
  end

  it "matches accented display names on a doctype with no search template (B-115)" do
    # The write path stages the folded display_name as the fallback corpus,
    # so an unaccented term matches an accented label — the same contract a
    # templated corpus already has. The raw display_name arm additionally
    # lets an accented term match, and covers rows with no staged corpus.
    with_temp_doctype("listsearchaccent") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({
        "doctype": "#{doctype}", "domain": "#{domain}",
        "display_name": "{{ name }}",
        "fields": {"name": {"type": "string"}}
      })
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      r1 = Facet::Document::Create.call(db, domain, doctype, %({"name": "Crème café"}), Facet::RBAC::AuthContext.system)
      expect_create_success(r1)
      doc_id = r1.as(Facet::Document::Create::Result).projection.id

      # Unaccented terms ride the folded corpus arm.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("creme")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items.first.id.should eq(doc_id)

      list2 = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("cafe")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list2.should be_a(Facet::Document::List::Result)
      result2 = list2.as(Facet::Document::List::Result)
      result2.items.size.should eq(1)
      result2.items.first.id.should eq(doc_id)

      # The accented term rides the raw display_name arm.
      list3 = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("café")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list3.should be_a(Facet::Document::List::Result)
      result3 = list3.as(Facet::Document::List::Result)
      result3.items.size.should eq(1)
      result3.items.first.id.should eq(doc_id)

      # The id fragment still matches through the id arm.
      id_frag = doc_id[-8..]
      list4 = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new(id_frag)},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list4.should be_a(Facet::Document::List::Result)
      result4 = list4.as(Facet::Document::List::Result)
      result4.items.size.should eq(1)
      result4.items.first.id.should eq(doc_id)
    end
  end

  it "matches sub-3-character search terms" do
    with_temp_doctype("listsearchshort") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({
        "doctype": "#{doctype}", "domain": "#{domain}",
        "search": "{{ name }}",
        "fields": {"name": {"type": "string"}}
      })
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Acme Corp"})))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Bob"})))

      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("ac")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items.first.content["name"].as_s.should eq("Acme Corp")
    end
  end

  it "matches a full domain value (e.g. acme.com) via the search column" do
    with_temp_doctype("listsearchdomain") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({
        "doctype": "#{doctype}", "domain": "#{domain}",
        "search": "{{ name }} {{ domain_name }}",
        "fields": {"name": {"type": "string"}, "domain_name": {"type": "string"}}
      })
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Acme Corp", "domain_name": "acme.com"})))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Globex Inc", "domain_name": "globex.com"})))

      # The full domain value (with a literal dot) must match the company
      # whose domain_name is acme.com — the dot in the term is a literal
      # character, not a wildcard.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("acme.com")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items.first.content["name"].as_s.should eq("Acme Corp")

      # Same search via the suffixed `search__match` key: not a production
      # of the filter grammar (`search` is an operator-keyword, not a
      # column) — the strict grammar refuses the key instead of silently
      # widening to a contains match (B-20).
      list2 = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search__match" => JSON::Any.new("acme.com")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list2.should be_a(Facet::ServiceError)
      list2.as(Facet::ServiceError).status.should eq(422)
    end
  end

  it "folds the search term — an unaccented term finds an accented document" do
    with_temp_doctype("listsearchaccent") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({
        "doctype": "#{doctype}", "domain": "#{domain}",
        "search": "{{ name }}",
        "fields": {"name": {"type": "string"}}
      })
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "García"})))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Globex Inc"})))

      # The corpus folds at write time and the term folds at query time,
      # so the unaccented term finds the accented document — and the
      # accented term keeps working too.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("garcia")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items.first.content["name"].as_s.should eq("García")

      list2 = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("García")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list2.should be_a(Facet::Document::List::Result)
      result2 = list2.as(Facet::Document::List::Result)
      result2.items.size.should eq(1)
      result2.items.first.content["name"].as_s.should eq("García")
    end
  end

  it "answers 422 for suffixed search filter keys (search__eq, search__starts_with)" do
    with_temp_doctype("listsearchsuffix") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({
        "doctype": "#{doctype}", "domain": "#{domain}",
        "search": "{{ name }}",
        "fields": {"name": {"type": "string"}}
      })
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "García"})))

      {"search__eq", "search__starts_with"}.each do |key|
        list = Facet::Document::List.call(
          db, domain, doctype,
          filters: {key => JSON::Any.new("garcia")},
          auth_context: Facet::RBAC::AuthContext.system
        )
        list.should be_a(Facet::ServiceError)
        error = list.as(Facet::ServiceError)
        error.status.should eq(422)
        error.details.try(&.first?).try(&.code).should eq("unsupported_filter_operator")
      end
    end
  end

  it "escapes LIKE wildcards in search terms" do
    with_temp_doctype("listsearchescape") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({
        "doctype": "#{doctype}", "domain": "#{domain}",
        "search": "{{ name }}",
        "fields": {"name": {"type": "string"}}
      })
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "100% funded"})))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "Acme Corp"})))

      # A literal `%` in the term must not act as a wildcard (would match
      # everything). `%` is escaped to `\%` so only the literal row matches.
      list = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"search" => JSON::Any.new("100%")},
        auth_context: Facet::RBAC::AuthContext.system
      )
      list.should be_a(Facet::Document::List::Result)
      result = list.as(Facet::Document::List::Result)
      result.items.size.should eq(1)
      result.items.first.content["name"].as_s.should eq("100% funded")
    end
  end

  # ── aggregate: field aggregates (sum / avg / min / max) ────────
  #
  # A field aggregate computes over the FULL filtered set — no page cap,
  # no ORDER BY (unlike `aggregate=count`, which caps at 1000 for UI
  # paging UX). The response is an `AggregateResult`: `value` is the
  # aggregate payload (JSON number for `integer` / `duration`, a
  # `{ticker => decimal-string}` bag for `money`) and `count` is the
  # contributing-row count from the same statement. Validation failures
  # surface as 422 before any SQL runs; a hidden field surfaces as 403.

  it "aggregate:sum totals an integer field and emits the value as a JSON number" do
    with_temp_doctype("suminteger") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}, "name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 10, "name": "a"}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 25, "name": "b"}), Facet::RBAC::AuthContext.system))
      # A row without the field matches the filter set but contributes
      # nothing to the SUM; COUNT(*) still includes it.
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "no-qty"}), Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "qty")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(35)
      r.count.should eq(3)
    end
  end

  it "aggregate:sum totals a duration field as integer seconds" do
    with_temp_doctype("sumduration") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"elapsed": {"type": "duration"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"elapsed": 90}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"elapsed": 30}), Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "elapsed")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(120)
      r.count.should eq(2)
    end
  end

  it "aggregate:sum over a money field returns one bag entry per currency, never a cross-currency total" do
    with_temp_doctype("summoney") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"price": {"type": "money"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"price": {"value": "10.50", "currency": "USD"}}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"price": {"value": "100.00", "currency": "USD"}}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"price": {"value": "99.95", "currency": "EUR"}}), Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "price")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      bag = r.value.as_h
      bag.size.should eq(2)
      bag["USD"].as_s.should eq("110.50")
      bag["EUR"].as_s.should eq("99.95")
      r.count.should eq(3)
    end
  end

  it "aggregate:sum honours the total — page and items are ignored and there is no 1000-row cap" do
    with_temp_doctype("sumnocap") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      # 1001 rows × 2 = 2002 — beyond the count cap. The sum must cover
      # every matching row; runaway cost is bounded by the global
      # statement_timeout, not a row cap.
      1001.times do
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 2}), Facet::RBAC::AuthContext.system))
      end

      result = Facet::Document::List.call(db, domain, doctype, page: 3, items_per_page: 5, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "qty")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(2002)
      r.count.should eq(1001)
    end
  end

  it "aggregate:sum applies filters the same as a normal list" do
    with_temp_doctype("sumfilter") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}, "status": {"type": "string", "filters": ["equality"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      2.times do
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 5, "status": "active"}), Facet::RBAC::AuthContext.system))
      end
      2.times do
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 7, "status": "inactive"}), Facet::RBAC::AuthContext.system))
      end

      result = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"status__eq" => JSON::Any.new("active")},
        auth_context: Facet::RBAC::AuthContext.system,
        aggregate: "sum", field: "qty",
      )
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(10)
      r.count.should eq(2)
    end
  end

  it "aggregate:sum over an empty numeric result set returns value 0, not null" do
    with_temp_doctype("sumemptynum") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "qty")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(0)
      r.count.should eq(0)
    end
  end

  it "aggregate:sum over an empty money result set returns an empty bag" do
    with_temp_doctype("sumemptymoney") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"price": {"type": "money"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "price")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_h.should be_empty
      r.count.should eq(0)
    end
  end

  it "aggregate:sum requires a field parameter" do
    with_temp_doctype("sumnofield") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("field")
    end
  end

  it "aggregate:sum returns 422 for an unknown field" do
    with_temp_doctype("sumunknown") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "nope")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Unknown field")
    end
  end

  it "aggregate:sum rejects dotted field paths — top-level fields only" do
    with_temp_doctype("sumdotted") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"price": {"type": "money"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "price.value")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("top-level")
    end
  end

  it "aggregate:sum rejects non-numeric field types" do
    with_temp_doctype("sumbadtype") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}, "active": {"type": "boolean"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      # A `string` field is not numeric even when every stored value looks
      # like a number — the declared type decides, not the runtime JSON.
      {"name", "active"}.each do |field|
        result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: field)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("not a numeric field")
      end
    end
  end

  it "aggregate:sum answers 403 for a caller with no read access" do
    with_temp_doctype("sumscoped") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      3.times do
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 10}), Facet::RBAC::AuthContext.system))
      end

      # A caller with no read permission on the doctype at all is denied
      # the resource class before any SQL runs — the same gate state the
      # write side answers 403 for. A caller that holds a read grant gets
      # the scope-narrowed sum instead.
      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.denied, aggregate: "sum", field: "qty")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
    end
  end

  it "aggregate:avg returns a JSON number for an integral average" do
    with_temp_doctype("avgintegral") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 10}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 20}), Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "avg", field: "qty")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(15)
      r.count.should eq(2)
    end
  end

  it "aggregate:avg emits the exact PG decimal for a fractional average" do
    with_temp_doctype("avgfraction") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 10}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 25}), Facet::RBAC::AuthContext.system))

      # PG's avg(numeric) scale pads to 16 decimal digits; the string form
      # is exact and the spec pins it verbatim — no client-side rounding or
      # trimming ever enters the payload.
      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "avg", field: "qty")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_s.should eq("17.5000000000000000")
      r.count.should eq(2)
    end
  end

  it "aggregate:min and aggregate:max return the boundary values as JSON numbers" do
    with_temp_doctype("minmaxnum") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      {10, 25, 17}.each do |qty|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": #{qty}}), Facet::RBAC::AuthContext.system))
      end

      min_result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "min", field: "qty")
      min_result.should be_a(Facet::Document::List::AggregateResult)
      min_r = min_result.as(Facet::Document::List::AggregateResult)
      min_r.value.as_i64?.should eq(10)
      min_r.count.should eq(3)

      max_result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "max", field: "qty")
      max_result.should be_a(Facet::Document::List::AggregateResult)
      max_r = max_result.as(Facet::Document::List::AggregateResult)
      max_r.value.as_i64?.should eq(25)
      max_r.count.should eq(3)
    end
  end

  it "aggregate:avg/min/max over an empty result set return value null" do
    with_temp_doctype("aggemptynull") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      # sum stays 0 over nothing; avg/min/max have no meaningful value and
      # report JSON null — both with count 0.
      sum_result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "qty")
      sum_result.as(Facet::Document::List::AggregateResult).value.as_i64?.should eq(0)

      {"avg", "min", "max"}.each do |aggregate|
        result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: aggregate, field: "qty")
        result.should be_a(Facet::Document::List::AggregateResult)
        r = result.as(Facet::Document::List::AggregateResult)
        r.value.raw.should be_nil
        r.count.should eq(0)
      end
    end
  end

  it "aggregate:max over a money field returns the per-currency maximum bag" do
    with_temp_doctype("aggmaxmoney") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"price": {"type": "money"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"price": {"value": "10.50", "currency": "USD"}}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"price": {"value": "100.00", "currency": "USD"}}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"price": {"value": "99.95", "currency": "EUR"}}), Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "max", field: "price")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      bag = r.value.as_h
      bag.size.should eq(2)
      bag["USD"].as_s.should eq("100.00")
      bag["EUR"].as_s.should eq("99.95")
      r.count.should eq(3)
    end
  end

  it "field aggregates require a field parameter with the aggregate named in the error" do
    with_temp_doctype("aggmfield") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      {"sum", "avg", "min", "max"}.each do |aggregate|
        result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: aggregate)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("aggregate=#{aggregate} requires a field parameter")
      end
    end
  end

  # The mirror gate (B-358): `field` is only the target of the field
  # aggregates. With no aggregate — or with the field-free `count` — a
  # present `field` would be silently ignored, so the request fails.
  it "field without a field aggregate answers 422" do
    with_temp_doctype("aggorphanfield") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      [nil, "count"].each do |aggregate|
        result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: aggregate, field: "qty")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("field=qty requires an aggregate parameter")
      end
    end
  end

  # ── field aggregates — RBAC field-tag guard ───────────────
  #
  # An aggregate returns no rows, so the read mask cannot protect a field
  # tagged with `view`. The guard fails closed at validation time: a
  # `field` whose view tags are not covered by the caller's
  # `visible_tags` gets 403 before any SQL runs. System / preview
  # principals and wildcard-tag roles bypass, mirroring the read mask
  # (`RBAC::ReadEnforcer.field_visible?` — one predicate serves both
  # paths).

  # Field visibility runs before the pair-consistency check: a field the
  # caller cannot see answers 403 even when the request also omits the
  # aggregate, so a 422 never names a role-invisible field.
  it "orphan field answers 403, not 422, when the field is not visible" do
    with_temp_doctype("aggorphantag") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"salary": {"type": "integer", "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      ctx = sum_tagged_caller(domain, doctype, ["default"])
      [nil, "count"].each do |aggregate|
        result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx, aggregate: aggregate, field: "salary")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(403)
        err.message.should contain("not visible")
        err.message.should_not contain("requires an aggregate parameter")
      end
    end
  end

  it "aggregate:sum returns 403 when the field's view tags are not covered by the caller" do
    with_temp_doctype("sumtag403") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"salary": {"type": "integer", "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      2.times do
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 100}), Facet::RBAC::AuthContext.system))
      end

      ctx = sum_tagged_caller(domain, doctype, ["default"])
      result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx, aggregate: "sum", field: "salary")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should contain("not visible")
      # Fail closed on information too: the denial must not leak the
      # hidden field's type (the visibility check runs before the type
      # gate).
      err.message.should_not contain("integer")
    end
  end

  # ── Field visibility on filters and sorts (S4) ──────────────────────
  #
  # The read mask hides a tagged field, but a filter or a sort on it still
  # answers questions about its values (row count, pagination total, row
  # order). Both gates answer the same 403 as the aggregate field gate.

  it "answers 403 for a filter on a field the active role cannot see (S4)" do
    with_temp_doctype("listfiltvis") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}, "salary": {"type": "integer", "filters": ["comparison"], "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "salary": 10}), Facet::RBAC::AuthContext.system))

      ctx = sum_tagged_caller(domain, doctype, ["default"])
      result = Facet::Document::List.call(db, domain, doctype,
        filters: {"salary__gt" => JSON::Any.new("5")}, auth_context: ctx)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should contain("not visible")
      err.message.should eq("field 'salary' is not visible to the active role")
    end
  end

  it "answers 403 for a sort on a field the active role cannot see (S4)" do
    with_temp_doctype("listsortvis") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}, "salary": {"type": "integer", "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "salary": 10}), Facet::RBAC::AuthContext.system))

      ctx = sum_tagged_caller(domain, doctype, ["default"])
      result = Facet::Document::List.call(db, domain, doctype, sort: ["-salary"], auth_context: ctx)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should eq("field 'salary' is not visible to the active role")
      # The type contract never leaks through the denial.
      err.message.should_not contain("sortable")
    end
  end

  it "keeps filtering and sorting a field the active role can see (S4)" do
    with_temp_doctype("listsortvisok") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"salary": {"type": "integer", "filters": ["comparison"], "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))
      [10, 30, 20].each do |n|
        expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": #{n}}), Facet::RBAC::AuthContext.system))
      end

      ctx = sum_tagged_caller(domain, doctype, ["default", "confidential"])
      result = Facet::Document::List.call(db, domain, doctype,
        filters: {"salary__gt" => JSON::Any.new("15")}, sort: ["salary"], auth_context: ctx)
      result.should be_a(Facet::Document::List::Result)
      values = result.as(Facet::Document::List::Result).items.map(&.content.["salary"].as_i64)
      values.should eq([20_i64, 30_i64])
    end
  end

  it "aggregate:count answers 403 for a filter on a hidden field (S4)" do
    with_temp_doctype("listcountvis") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"salary": {"type": "integer", "filters": ["comparison"], "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 99}), Facet::RBAC::AuthContext.system))

      ctx = sum_tagged_caller(domain, doctype, ["default"])
      result = Facet::Document::List.call(db, domain, doctype,
        filters: {"salary__gt" => JSON::Any.new("5")}, auth_context: ctx, aggregate: "count")
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should contain("not visible")
    end
  end

  it "aggregate:sum lets the system principal sum a view-tagged field" do
    with_temp_doctype("sumtagsys") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"salary": {"type": "integer", "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 40}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 60}), Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, aggregate: "sum", field: "salary")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(100)
      r.count.should eq(2)
    end
  end

  it "aggregate:sum lets a wildcard-tag role sum a view-tagged field" do
    with_temp_doctype("sumtagwild") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"salary": {"type": "integer", "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 40}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 60}), Facet::RBAC::AuthContext.system))

      ctx = sum_tagged_caller(domain, doctype, ["*"])
      result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx, aggregate: "sum", field: "salary")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(100)
      r.count.should eq(2)
    end
  end

  it "aggregate:sum lets a caller whose tags cover the field's view sum it" do
    with_temp_doctype("sumtagcover") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"salary": {"type": "integer", "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 40}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 60}), Facet::RBAC::AuthContext.system))

      ctx = sum_tagged_caller(domain, doctype, ["default", "confidential"])
      result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx, aggregate: "sum", field: "salary")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(100)
      r.count.should eq(2)
    end
  end

  it "aggregate:sum treats a field with no view declaration as visible to the default tags" do
    with_temp_doctype("sumtagnone") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 7}), Facet::RBAC::AuthContext.system))

      ctx = sum_tagged_caller(domain, doctype, ["default"])
      result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx, aggregate: "sum", field: "qty")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(7)
      r.count.should eq(1)
    end
  end

  it "aggregate:sum lets a preview principal sum a view-tagged field" do
    with_temp_doctype("sumtagprev") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"salary": {"type": "integer", "tags": ["confidential"]}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 40}), Facet::RBAC::AuthContext.system))
      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"salary": 60}), Facet::RBAC::AuthContext.system))

      # The preview capability is domain-scoped and sees every field of
      # the draft — same as the read mask.
      ctx = Facet::RBAC::AuthContext.preview("preview_account", domain)
      result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx, aggregate: "sum", field: "salary")
      result.should be_a(Facet::Document::List::AggregateResult)
      r = result.as(Facet::Document::List::AggregateResult)
      r.value.as_i64?.should eq(100)
      r.count.should eq(2)
    end
  end

  # ── field aggregates — no-grant caller ──────────────
  #
  # A caller with no read permission on the doctype at all is denied the
  # resource class: the list and every aggregate answer 403 before any
  # field inspection (`ReadEnforcer.list_denied?`). One uniform answer
  # per caller keeps the schema enumeration channel closed — no field
  # ever produces a distinguishing 403 (tagged) / 422 (unknown) / 200
  # (visible) triple, because no field-level code runs at all.

  it "aggregate over a no-grant caller answers 403 for every field alike" do
    with_temp_doctype("aggnogrant") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"qty": {"type": "integer"}, "secret_qty": {"type": "integer", "tags": ["confidential"]}, "price": {"type": "money"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"qty": 5, "secret_qty": 9, "price": {"value": "1.00", "currency": "USD"}}), Facet::RBAC::AuthContext.system))

      ctx = agg_no_grant_caller

      # Parity with the plain list: the same caller is denied the class.
      list_result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx)
      list_result.should be_a(Facet::ServiceError)
      list_result.as(Facet::ServiceError).status.should eq(403)

      # Declared untagged, declared tagged, undeclared, and money — every
      # `sum` answers the identical 403. Never a 422, and never the money
      # bag: the class-level check runs before any field validation or
      # field-definition read.
      {"qty", "secret_qty", "ghost", "price"}.each do |field|
        result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx, aggregate: "sum", field: field)
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(403)
      end

      # `avg` / `min` / `max` answer the same uniform 403 for every field
      # name alike.
      {"avg", "min", "max"}.each do |aggregate|
        {"qty", "secret_qty", "ghost", "price"}.each do |field|
          result = Facet::Document::List.call(db, domain, doctype, auth_context: ctx, aggregate: aggregate, field: field)
          result.should be_a(Facet::ServiceError)
          result.as(Facet::ServiceError).status.should eq(403)
        end
      end
    end
  end

  # ── include_deleted (trash listing) ─────────────────────────────────

  it "include_deleted:false returns only live rows" do
    with_temp_doctype("deletedoff") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "live"}), Facet::RBAC::AuthContext.system))
      gone = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "gone"}), Facet::RBAC::AuthContext.system))
      Facet::Document::Delete.call(db, domain, doctype, gone.projection.id, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Delete::Result)

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, include_deleted: false)
      result.should be_a(Facet::Document::List::Result)
      r = result.as(Facet::Document::List::Result)
      r.total.should eq(1)
    end
  end

  it "include_deleted:true returns tombstones with their retained payload" do
    with_temp_doctype("deletedon") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "live"}), Facet::RBAC::AuthContext.system))
      gone = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "gone"}), Facet::RBAC::AuthContext.system))
      Facet::Document::Delete.call(db, domain, doctype, gone.projection.id, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Delete::Result)

      result = Facet::Document::List.call(db, domain, doctype, auth_context: Facet::RBAC::AuthContext.system, include_deleted: true)
      result.should be_a(Facet::Document::List::Result)
      r = result.as(Facet::Document::List::Result)
      r.total.should eq(1)
      r.items.size.should eq(1)
      # Tombstones keep their pre-delete payload until pruned.
      r.items.first.content["name"].as_s.should eq("gone")
      r.items.first.deleted_at.should_not be_nil
    end
  end

  it "include_deleted honours the deleted_at timestamp filter with UTC normalization" do
    with_temp_doctype("deletedts") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      gone = expect_create_success(Facet::Document::Create.call(db, domain, doctype, %({"name": "gone"}), Facet::RBAC::AuthContext.system))
      Facet::Document::Delete.call(db, domain, doctype, gone.projection.id, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Delete::Result)

      upper = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"deleted_at__lte" => JSON::Any.new("2000-01-01T00:00:00Z")},
        auth_context: Facet::RBAC::AuthContext.system,
        include_deleted: true,
      )
      upper.should be_a(Facet::Document::List::Result)
      upper.as(Facet::Document::List::Result).total.should eq(0)

      lower = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"deleted_at__gte" => JSON::Any.new("2000-01-01T02:00:00+02:00")},
        auth_context: Facet::RBAC::AuthContext.system,
        include_deleted: true,
      )
      lower.should be_a(Facet::Document::List::Result)
      lower.as(Facet::Document::List::Result).total.should eq(1)
    end
  end

  # ── reserved parent_id__eq filter ─────────────────────────────────
  #
  # The flat list route's answer to the composition link: an owned
  # child (`member_of`) has no back-reference field, so the parent
  # narrows through the reserved `parent_id__eq` key — the same
  # `meta->>'parent_id'` clause the nested child route drives.

  it "parent_id__eq narrows a child doctype's flat list to one parent's children" do
    with_temp_doctype("pfchild") do |db, domain, doctype|
      parent_dt = "#{doctype}Box"
      parent_filter_seed_pair(db, domain, parent_dt, doctype)

      p1 = parent_filter_create_parent(db, domain, parent_dt, "M1")
      p2 = parent_filter_create_parent(db, domain, parent_dt, "M2")
      parent_filter_create_child(db, domain, doctype, p1.id, "a")
      parent_filter_create_child(db, domain, doctype, p1.id, "b")
      parent_filter_create_child(db, domain, doctype, p2.id, "c")

      result = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"parent_id__eq" => JSON::Any.new(p1.id)},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::Document::List::Result)
      r = result.as(Facet::Document::List::Result)
      r.total.should eq(2)
      r.items.all? { |i| i.meta["parent_id"].as_s == p1.id }.should be_true
    end
  end

  it "parent_id__eq accepts a fully qualified reference token" do
    with_temp_doctype("pfqual") do |db, domain, doctype|
      parent_dt = "#{doctype}Box"
      parent_filter_seed_pair(db, domain, parent_dt, doctype)

      p1 = parent_filter_create_parent(db, domain, parent_dt, "M1")
      parent_filter_create_child(db, domain, doctype, p1.id, "a")
      parent_filter_create_child(db, domain, doctype, p1.id, "b")

      result = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"parent_id__eq" => JSON::Any.new("#{domain}.#{parent_dt}.#{p1.id}")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::Document::List::Result)
      result.as(Facet::Document::List::Result).total.should eq(2)
    end
  end

  it "parent_id__eq applies to aggregate:count" do
    with_temp_doctype("pfcount") do |db, domain, doctype|
      parent_dt = "#{doctype}Box"
      parent_filter_seed_pair(db, domain, parent_dt, doctype)

      p1 = parent_filter_create_parent(db, domain, parent_dt, "M1")
      p2 = parent_filter_create_parent(db, domain, parent_dt, "M2")
      parent_filter_create_child(db, domain, doctype, p1.id, "a")
      parent_filter_create_child(db, domain, doctype, p2.id, "b")

      result = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"parent_id__eq" => JSON::Any.new(p1.id)},
        auth_context: Facet::RBAC::AuthContext.system,
        aggregate: "count",
      )
      result.should be_a(Facet::Document::List::Result)
      result.as(Facet::Document::List::Result).total.should eq(1)
    end
  end

  it "parent_id__eq folds into a matching nested parent scope and rejects a conflicting one" do
    with_temp_doctype("pfnested") do |db, domain, doctype|
      parent_dt = "#{doctype}Box"
      parent_filter_seed_pair(db, domain, parent_dt, doctype)

      p1 = parent_filter_create_parent(db, domain, parent_dt, "M1")
      p2 = parent_filter_create_parent(db, domain, parent_dt, "M2")
      parent_filter_create_child(db, domain, doctype, p1.id, "a")

      agree = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"parent_id__eq" => JSON::Any.new(p1.id)},
        auth_context: Facet::RBAC::AuthContext.system,
        parent_id: p1.id,
      )
      agree.should be_a(Facet::Document::List::Result)
      agree.as(Facet::Document::List::Result).total.should eq(1)

      conflict = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"parent_id__eq" => JSON::Any.new(p2.id)},
        auth_context: Facet::RBAC::AuthContext.system,
        parent_id: p1.id,
      )
      conflict.should be_a(Facet::ServiceError)
      conflict.as(Facet::ServiceError).status.should eq(422)
    end
  end

  it "parent_id__eq rejects a doctype that is not an owned child" do
    with_temp_doctype("pfroot") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      expect_create_success(Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system))

      result = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"parent_id__eq" => JSON::Any.new("01HX")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("member_of")
    end
  end

  it "parent_id__eq rejects a non-string value" do
    with_temp_doctype("pftype") do |db, domain, doctype|
      parent_dt = "#{doctype}Box"
      parent_filter_seed_pair(db, domain, parent_dt, doctype)

      result = Facet::Document::List.call(
        db, domain, doctype,
        filters: {"parent_id__eq" => JSON::Any.new(42)},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(422)
    end
  end
end
