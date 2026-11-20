# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# Parent recompute on child mutation (B-110 part 2).
#
# A computed field whose `compute_when` names a child relationship re-runs
# when the children change. The walk starts at the mutated child, recomputes
# the parent, writes the result as a partial-patch update carrying a
# `recompute` cause, and continues upward until no parent remains, no
# relationship matches, the parent content stops changing, or the depth cap
# is reached.
describe Facet::Document::Recompute do
  it "converges the parent total inside a compound create and carries the child create as cause" do
    with_db do |db|
      domain = "recomp-test"
      ensure_domain(db, domain)
      parent_dt = "RcOrder#{unique_suffix[0..3]}"
      child_dt = "#{parent_dt}Line"
      seed_order_pair!(db, domain, parent_dt, child_dt, script: TOTAL_ONLY_SCRIPT)

      body = %({
        "$content": {"name": "Order 1"},
        "$children": {"lines": [
          {"label": "a", "qty": 2, "price": 5},
          {"label": "b", "qty": 1, "price": 9},
          {"label": "c", "qty": 3, "price": 4}
        ]}
      })
      result = Facet::Document::CreateWithChildren.call(db, domain, parent_dt, body, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::CreateWithChildren::Result)
      cwc = result.as(Facet::Document::CreateWithChildren::Result)

      # The wire response carries the converged content: 2*5 + 1*9 + 3*4 = 31.
      cwc.projection.content["total"].as_i64.should eq(31)

      # Every child create triggered one recompute write whose cause names
      # that child's create mutation (one hop per row).
      child_mut_ids = cwc.children["lines"].map(&.mut_id).to_set
      recompute_rows = recompute_mutations(db, domain, parent_dt, cwc.projection.id)
      recompute_rows.size.should eq(3)
      recompute_rows.all? { |row| child_mut_ids.includes?(row["parent"].as(String)) }.should be_true
    end
  end

  it "updates the parent total when a line qty is patched and records the recompute mutation in the audit log" do
    with_db do |db|
      domain = "recomp-test"
      ensure_domain(db, domain)
      parent_dt = "RcOrder#{unique_suffix[0..3]}"
      child_dt = "#{parent_dt}Line"
      seed_order_pair!(db, domain, parent_dt, child_dt, script: TOTAL_ONLY_SCRIPT)

      cwc = compound_create_order!(db, domain, parent_dt, child_dt, [{2, 5}, {1, 9}])
      parent_id = cwc.projection.id

      patch = Facet::Document::Update.call(db, domain, child_dt, cwc.children["lines"][0].id,
        %({"qty": 100}), Facet::RBAC::AuthContext.system)
      patch.should be_a(Facet::Document::Update::Result)
      patch_mut_id = patch.as(Facet::Document::Update::Result).mutation_id

      parent = Facet::Mutation::Client.fetch_projection(db, domain, parent_dt, parent_id)
      parent.content["total"].as_i64.should eq(509)

      # The audit log shows the recompute mutation, caused by the line patch.
      latest = latest_parent_mutation(db, domain, parent_dt, parent_id)
      latest["name"].as(String).should eq("recompute")
      latest["parent"].as(String).should eq(patch_mut_id)
    end
  end

  it "drops the parent total when a line is deleted" do
    with_db do |db|
      domain = "recomp-test"
      ensure_domain(db, domain)
      parent_dt = "RcOrder#{unique_suffix[0..3]}"
      child_dt = "#{parent_dt}Line"
      seed_order_pair!(db, domain, parent_dt, child_dt, script: TOTAL_ONLY_SCRIPT)

      cwc = compound_create_order!(db, domain, parent_dt, child_dt, [{2, 5}, {1, 9}, {3, 4}])
      parent_id = cwc.projection.id
      victim = cwc.children["lines"][2]

      deleted = Facet::Document::Delete.call(db, domain, child_dt, victim.id, Facet::RBAC::AuthContext.system)
      deleted.should be_a(Facet::Document::Delete::Result)

      parent = Facet::Mutation::Client.fetch_projection(db, domain, parent_dt, parent_id)
      parent.content["total"].as_i64.should eq(19)

      latest = latest_parent_mutation(db, domain, parent_dt, parent_id)
      latest["name"].as(String).should eq("recompute")
      latest["parent"].as(String).should eq(deleted.as(Facet::Document::Delete::Result).mutation_id)
    end
  end

  it "does not recompute when no field's compute_when names the relationship" do
    with_db do |db|
      domain = "recomp-test"
      ensure_domain(db, domain)
      parent_dt = "RcPlain#{unique_suffix[0..3]}"
      child_dt = "#{parent_dt}Line"
      # No computed field at all — nothing names the relationship.
      seed_order_pair!(db, domain, parent_dt, child_dt, script: TOTAL_ONLY_SCRIPT, computed_field: nil)

      cwc = compound_create_order!(db, domain, parent_dt, child_dt, [{1, 1}])
      parent_id = cwc.projection.id
      before = parent_mutation_count(db, domain, parent_dt, parent_id)

      patch = Facet::Document::Update.call(db, domain, child_dt, cwc.children["lines"][0].id,
        %({"qty": 50}), Facet::RBAC::AuthContext.system)
      patch.should be_a(Facet::Document::Update::Result)

      parent_mutation_count(db, domain, parent_dt, parent_id).should eq(before)
    end
  end

  it "cascades the recompute up to the grandparent" do
    with_db do |db|
      domain = "recomp-test"
      ensure_domain(db, domain)
      region_dt = "RcRegion#{unique_suffix[0..3]}"
      order_dt = "#{region_dt}Order"
      line_dt = "#{order_dt}Line"
      seed_region_chain!(db, domain, region_dt, order_dt, line_dt)

      # Region ← Order (member_of Region) ← Line (member_of Order).
      region = Facet::Document::Create.call(db, domain, region_dt,
        %({"name": "west"}), Facet::RBAC::AuthContext.system)
      region.should be_a(Facet::Document::Create::Result)
      region_id = region.as(Facet::Document::Create::Result).projection.id

      order = Facet::Document::Create.call(db, domain, order_dt,
        %({"name": "o1"}), Facet::RBAC::AuthContext.system,
        meta_overrides: {"parent_id" => JSON::Any.new(region_id)})
      order.should be_a(Facet::Document::Create::Result)
      order_id = order.as(Facet::Document::Create::Result).projection.id

      line = Facet::Document::Create.call(db, domain, line_dt,
        %({"label": "l1", "qty": 2, "price": 10}), Facet::RBAC::AuthContext.system,
        meta_overrides: {"parent_id" => JSON::Any.new(order_id)})
      line.should be_a(Facet::Document::Create::Result)

      # The line create recomputed the order's total (20), which recomputed
      # the region's grand_total over its live orders.
      region_proj = Facet::Mutation::Client.fetch_projection(db, domain, region_dt, region_id)
      region_proj.content["grand_total"].as_i64.should eq(20)

      # Patch the line: both levels move.
      Facet::Document::Update.call(db, domain, line_dt,
        line.as(Facet::Document::Create::Result).projection.id,
        %({"qty": 5}), Facet::RBAC::AuthContext.system)
      region_proj = Facet::Mutation::Client.fetch_projection(db, domain, region_dt, region_id)
      region_proj.content["grand_total"].as_i64.should eq(50)
    end
  end

  it "does not loop when the parent's update hook writes a child" do
    with_db do |db|
      domain = "recomp-test"
      ensure_domain(db, domain)
      parent_dt = "RcHook#{unique_suffix[0..3]}"
      child_dt = "#{parent_dt}Line"
      hook_script = <<-LUA
        local export = {}
        function export.compute_order_total(ctx)
          local total = 0
          for _, line in ipairs((ctx.children or {}).lines or {}) do
            total = total + (line.qty or 0) * (line.price or 0)
          end
          return total
        end
        function export.update(ctx)
          local last = ctx.root.last_line_id
          if last ~= nil and last ~= "" then
            document.update("#{child_dt}", last, { label = "touched" })
          end
        end
        return export
      LUA
      seed_order_pair!(db, domain, parent_dt, child_dt, script: hook_script,
        extra_fields: %({"last_line_id": {"type": "string"}}))

      cwc = compound_create_order!(db, domain, parent_dt, child_dt, [{2, 5}, {1, 9}],
        content: %("name": "Order 1", "last_line_id": ""))
      parent_id = cwc.projection.id
      line_id = cwc.children["lines"][0].id

      # Point the hook at the OTHER line (the second one), then patch the
      # first: recompute → parent update hook → child write → the guard
      # skips that walk. Without the guard this spec hangs.
      other = cwc.children["lines"][1].id
      Facet::Document::Update.call(db, domain, parent_dt, parent_id,
        %({"last_line_id": "#{other}"}), Facet::RBAC::AuthContext.system)

      Facet::Document::Update.call(db, domain, child_dt, line_id,
        %({"qty": 100}), Facet::RBAC::AuthContext.system)

      parent = Facet::Mutation::Client.fetch_projection(db, domain, parent_dt, parent_id)
      parent.content["total"].as_i64.should eq(509)

      # The hook's write landed exactly once on the other line.
      other_line = Facet::Mutation::Client.fetch_projection(db, domain, child_dt, other)
      other_line.content["label"].as_s.should eq("touched")
    end
  end

  it "fires a field whose compute_when mixes a field name and a relationship name in both passes" do
    with_db do |db|
      domain = "recomp-test"
      ensure_domain(db, domain)
      parent_dt = "RcMix#{unique_suffix[0..3]}"
      child_dt = "#{parent_dt}Line"
      mix_script = <<-LUA
        local export = {}
        function export.compute_order_total(ctx)
          local total = 0
          for _, line in ipairs((ctx.children or {}).lines or {}) do
            total = total + (line.qty or 0) * (line.price or 0)
          end
          return total
        end
        function export.compute_summary(ctx)
          local count = 0
          for _ in ipairs((ctx.children or {}).lines or {}) do
            count = count + 1
          end
          return (ctx.root.name or "?") .. "/" .. tostring(count)
        end
        return export
      LUA
      seed_order_pair!(db, domain, parent_dt, child_dt, script: mix_script,
        extra_computed: %({"summary": {"type": "data", "compute": "summary", "compute_when": ["name", "lines"]}}))

      cwc = compound_create_order!(db, domain, parent_dt, child_dt, [{2, 5}, {1, 9}])
      parent_id = cwc.projection.id

      # After the compound create both fields fired (relationship pass).
      parent = Facet::Mutation::Client.fetch_projection(db, domain, parent_dt, parent_id)
      parent.content["total"].as_i64.should eq(19)
      parent.content["summary"].as_s.should eq("Order 1/2")

      # Value pass: a parent field change fires the mixed field alone.
      Facet::Document::Update.call(db, domain, parent_dt, parent_id,
        %({"name": "Renamed"}), Facet::RBAC::AuthContext.system)
      parent = Facet::Mutation::Client.fetch_projection(db, domain, parent_dt, parent_id)
      parent.content["summary"].as_s.should eq("Renamed/2")

      # Relationship pass: a child mutation fires the mixed field again.
      Facet::Document::Update.call(db, domain, child_dt, cwc.children["lines"][0].id,
        %({"qty": 3}), Facet::RBAC::AuthContext.system)
      parent = Facet::Mutation::Client.fetch_projection(db, domain, parent_dt, parent_id)
      parent.content["total"].as_i64.should eq(24)
      parent.content["summary"].as_s.should eq("Renamed/2")
    end
  end

  it "scopes a compute document.list filter to the computed document through ctx.doc_id" do
    with_db do |db|
      domain = "recomp-test"
      ensure_domain(db, domain)
      parent_dt = "RcDocId#{unique_suffix[0..3]}"
      child_dt = "#{parent_dt}Line"
      list_script = <<-LUA
        local export = {}
        function export.compute_order_total(ctx)
          local total = 0
          local res = document.list("#{child_dt}", { parent_id__eq = ctx.doc_id })
          for _, row in ipairs(res.items) do
            total = total + (util.json_decode(row.content).price or 0)
          end
          return total
        end
        return export
      LUA
      seed_order_pair!(db, domain, parent_dt, child_dt, script: list_script)

      # Two live parents before any line exists: both create passes see an
      # empty table, so both store 0.
      created_a = Facet::Document::Create.call(db, domain, parent_dt,
        %({"name": "A"}), Facet::RBAC::AuthContext.system)
      created_a.should be_a(Facet::Document::Create::Result)
      a_id = created_a.as(Facet::Document::Create::Result).projection.id
      created_b = Facet::Document::Create.call(db, domain, parent_dt,
        %({"name": "B"}), Facet::RBAC::AuthContext.system)
      created_b.should be_a(Facet::Document::Create::Result)
      b_id = created_b.as(Facet::Document::Create::Result).projection.id

      # One line (price 7) under A. The child create triggers the parent
      # recompute walk, which supplies ctx.doc_id.
      line = Facet::Document::Create.call(db, domain, child_dt,
        %({"label": "l", "qty": 1, "price": 7}), Facet::RBAC::AuthContext.system,
        meta_overrides: {"parent_id" => JSON::Any.new(a_id)})
      line.should be_a(Facet::Document::Create::Result)

      # A's stored total converged to its own line only; B owns no lines.
      parent_a = Facet::Mutation::Client.fetch_projection(db, domain, parent_dt, a_id)
      parent_a.content["total"].as_i64.should eq(7)
      parent_b = Facet::Mutation::Client.fetch_projection(db, domain, parent_dt, b_id)
      parent_b.content["total"].as_i64.should eq(0)

      # The same call the walk makes, once per parent: the filter must
      # scope to ctx.doc_id — A sums its line, B sums nothing (not the
      # whole table).
      defn = Facet::Doctype::DefinitionStore.fetch!(db, "#{domain}.#{parent_dt}").as(Facet::Doctype::DoctypeDefinition)
      result_a, errors_a = Facet::Document::Compute.call(
        list_script, defn, parent_a.content,
        changed_fields: Set{"lines"},
        actioner_id: "test",
        db: db,
        domain: domain,
        doc_id: a_id,
      )
      errors_a.should be_empty
      result_a["total"].as_i64.should eq(7)

      result_b, errors_b = Facet::Document::Compute.call(
        list_script, defn, parent_b.content,
        changed_fields: Set{"lines"},
        actioner_id: "test",
        db: db,
        domain: domain,
        doc_id: b_id,
      )
      errors_b.should be_empty
      result_b["total"].as_i64.should eq(0)
    end
  end
end

# ── Fixtures ──────────────────────────────────────────────────────────────

private TOTAL_ONLY_SCRIPT = <<-LUA
  local export = {}
  function export.compute_order_total(ctx)
    local total = 0
    for _, line in ipairs((ctx.children or {}).lines or {}) do
      total = total + (line.qty or 0) * (line.price or 0)
    end
    return total
  end
  return export
LUA

# Creates the parent (aggregate root, `total` computed over `lines`) and the
# child (member_of the parent) doctypes through the authoring path.
private def seed_order_pair!(
  db : DB::Connection,
  domain : String,
  parent_dt : String,
  child_dt : String,
  script : String,
  computed_field : String? = "total",
  extra_fields : String = "",
  extra_computed : String = "",
) : Nil
  parent_fields = {"name" => JSON.parse(%({"type": "string"}))} of String => JSON::Any
  unless extra_fields.empty?
    JSON.parse(extra_fields).as_h.each { |name, raw| parent_fields[name] = raw }
  end
  if f = computed_field
    parent_fields[f] = JSON.parse(%({"type": "data", "compute": "order_total", "compute_when": ["lines"]}))
  end
  unless extra_computed.empty?
    JSON.parse(extra_computed).as_h.each { |name, raw| parent_fields[name] = raw }
  end
  parent_body = {
    "doctype" => parent_dt,
    "domain" => domain,
    "aggregate_root" => true, "search" => "{{ display_name }}",
    "fields" => JSON::Any.new(parent_fields),
    "children" => JSON.parse(%({"lines": {"doctype": "#{child_dt}", "collection": true}})),
    "script" => script,
  }.to_json
  parent = Facet::Document::Create.call(db, "core", "DocType", parent_body, Facet::RBAC::AuthContext.system)
  parent.should be_a(Facet::Document::Create::Result)

  child_body = {
    "doctype"   => child_dt,
    "domain"    => domain,
    "member_of" => parent_dt,
    "fields"    => JSON.parse(%({"label": {"type": "string"}, "qty": {"type": "integer"}, "price": {"type": "integer"}})),
  }.to_json
  child = Facet::Document::Create.call(db, "core", "DocType", child_body, Facet::RBAC::AuthContext.system)
  child.should be_a(Facet::Document::Create::Result)
end

# Creates the Region ← Order ← Line three-level chain definitions.
private def seed_region_chain!(
  db : DB::Connection,
  domain : String,
  region_dt : String,
  order_dt : String,
  line_dt : String,
) : Nil
  order_script = <<-LUA
    local export = {}
    function export.compute_order_total(ctx)
      local total = 0
      for _, line in ipairs((ctx.children or {}).lines or {}) do
        total = total + (line.qty or 0) * (line.price or 0)
      end
      return total
    end
    return export
  LUA
  region_script = <<-LUA
    local export = {}
    function export.compute_region_total(ctx)
      local total = 0
      for _, order in ipairs((ctx.children or {}).orders or {}) do
        total = total + (order.total or 0)
      end
      return total
    end
    return export
  LUA

  line_body = {
    "doctype"   => line_dt,
    "domain"    => domain,
    "member_of" => order_dt,
    "fields"    => JSON.parse(%({"label": {"type": "string"}, "qty": {"type": "integer"}, "price": {"type": "integer"}})),
  }.to_json
  Facet::Document::Create.call(db, "core", "DocType", line_body, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)

  order_body = {
    "doctype"   => order_dt,
    "domain"    => domain,
    "member_of" => region_dt,
    "fields"    => JSON.parse(%({"name": {"type": "string"}, "total": {"type": "data", "compute": "order_total", "compute_when": ["lines"]}})),
    "children"  => JSON.parse(%({"lines": {"doctype": "#{line_dt}", "collection": true}})),
    "script"    => order_script,
  }.to_json
  Facet::Document::Create.call(db, "core", "DocType", order_body, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)

  region_body = {
    "doctype" => region_dt,
    "domain" => domain,
    "aggregate_root" => true, "search" => "{{ display_name }}",
    "fields" => JSON.parse(%({"name": {"type": "string"}, "grand_total": {"type": "data", "compute": "region_total", "compute_when": ["orders"]}})),
    "children" => JSON.parse(%({"orders": {"doctype": "#{order_dt}", "collection": true}})),
    "script" => region_script,
  }.to_json
  Facet::Document::Create.call(db, "core", "DocType", region_body, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)
end

# Compound-creates one parent with the given (qty, price) lines.
private def compound_create_order!(
  db : DB::Connection,
  domain : String,
  parent_dt : String,
  child_dt : String,
  lines : Array(Tuple(Int32, Int32)),
  content : String = %("name": "Order 1"),
) : Facet::Document::CreateWithChildren::Result
  lines_json = lines.map do |qty, price|
    %({"label": "l", "qty": #{qty}, "price": #{price}})
  end.join(", ")
  body = %({
    "$content": {#{content}},
    "$children": {"lines": [#{lines_json}]}
  })
  result = Facet::Document::CreateWithChildren.call(db, domain, parent_dt, body, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::CreateWithChildren::Result)
  result.as(Facet::Document::CreateWithChildren::Result)
end

# The recompute mutations recorded for one parent document.
private def recompute_mutations(db : DB::Connection, domain : String, doc_type : String, doc_id : String) : Array(Hash(String, String?))
  rows = [] of Hash(String, String?)
  db.query_each(
    "SELECT cause_name, cause_parent FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND cause_name = 'recompute' ORDER BY idx",
    domain, doc_type, doc_id,
  ) do |rs|
    rows << {"name" => rs.read(String?), "parent" => rs.read(String?)}
  end
  rows
end

# The latest mutation row of one parent document.
private def latest_parent_mutation(db : DB::Connection, domain : String, doc_type : String, doc_id : String) : Hash(String, String?)
  db.query_one(
    "SELECT cause_name, cause_parent FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 ORDER BY idx DESC LIMIT 1",
    domain, doc_type, doc_id,
  ) do |rs|
    {"name" => rs.read(String?), "parent" => rs.read(String?)}
  end
end

private def parent_mutation_count(db : DB::Connection, domain : String, doc_type : String, doc_id : String) : Int64
  db.query_one(
    "SELECT count(*) FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3",
    domain, doc_type, doc_id, as: Int64
  )
end
