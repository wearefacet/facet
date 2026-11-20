# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"
require "../../src/audit/list"
require "../../src/audit/rollback"
require "../../src/document/create"
require "../../src/document/update"
require "../../src/secrets/staging"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "json"

HTTPTest.init

# Audit redaction (execution plan Phase 6): a tagged-down Real reader never
# sees invisible field values in the mutation log; the removed content
# paths land in the out-of-band `redacted` metadata.
private def redact_seed(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

private def redact_ctx(tags : Array(String))
  role = Facet::RBAC::ActiveRole.new(
    role_id: "redact_role",
    visible_tags: Set.new(tags),
    permissions: [Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "read", "on": "*.*"})))],
  )
  Facet::RBAC::AuthContext.authenticated("redact-caller", role)
end

private def redact_doctype(db, domain : String, doctype : String)
  ensure_domain(db, domain)
  fields = %({
    "name": {"type": "string"},
    "salary": {"type": "integer", "tags": ["confidential"]},
    "profile": {"type": "object", "properties": {
      "bio": {"type": "string"},
      "grade": {"type": "string", "tags": ["confidential"]}
    }},
    "note": {"type": "longtext"}
  })
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
  Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
end

# A doctype with the object-valued scalar kinds and dictionaries. The
# two dictionary flavors pin both fail directions: `hidden_attrs` is a
# visible root with a tagged value descriptor, `sealed_attrs` is a
# tagged root with a visible value descriptor.
private def redact_value_doctype(db, domain : String, doctype : String)
  ensure_domain(db, domain)
  fields = %({
    "name": {"type": "string"},
    "fee": {"type": "money", "currency": "EUR"},
    "days": {"type": "dateperiod"},
    "span": {"type": "period"},
    "attrs": {"type": "dictionary", "values": {"type": "string"}},
    "hidden_attrs": {"type": "dictionary", "values": {"type": "string", "tags": ["confidential"]}},
    "sealed_attrs": {"type": "dictionary", "tags": ["confidential"], "values": {"type": "string"}},
    "free": {"type": "object"},
    "extra": {"type": "any"},
    "api_key": {"type": "secret", "mode": "hash"},
    "salary": {"type": "integer", "tags": ["confidential"]}
  })
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
  Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
end

# A caller that may create and update the doctype. Its account id is
# the staging `created_by` the secret adoption flow checks.
private def redact_writer_ctx(domain : String, doctype : String)
  role = Facet::RBAC::ActiveRole.new(
    role_id: "redact_writer",
    visible_tags: Set.new(["default"]),
    permissions: [
      Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"}))),
      Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "update", "on": "#{domain}.#{doctype}"}))),
    ],
  )
  Facet::RBAC::AuthContext.authenticated("redact-caller", role)
end

# Finds one `diff.set` entry by its dotted path in a mutation row.
private def redact_set_entry(row : Facet::Audit::List::MutationRecord, dotted : String) : JSON::Any
  entries = row.arguments.as_h["diff"].as_h["set"].as_a
  found = entries.find do |entry|
    entry.as_h["path"].as_a.map(&.as_s).join(".") == dotted
  end
  found.should_not be_nil
  found.not_nil!
end

describe "Audit::Redact" do
  it "never exposes create values to a tagged-down caller; paths land in redacted" do
    with_temp_doctype("redc") do |db, domain, doctype|
      redact_seed(db)
      redact_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 777, "profile": {"bio": "b", "grade": "G"}}), sys)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)
      create_row = list.items.find { |m| m.action == "create" }.should_not be_nil

      raw = create_row.arguments.as_h["content"].as_h
      raw["name"].as_s.should eq("a")
      raw["salary"]?.should be_nil
      raw["profile"].as_h["bio"].as_s.should eq("b")
      raw["profile"].as_h["grade"]?.should be_nil

      paths = create_row.redacted.map(&.join("."))
      paths.should contain("salary")
      paths.should contain("profile.grade")
    end
  end

  it "removes update diff values and long-text patch contents at invisible paths" do
    with_temp_doctype("redu") do |db, domain, doctype|
      redact_seed(db)
      redact_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      # A visible long-text edit and an invisible scalar edit.
      long_note = "word " * 80
      Facet::Document::Update.call(db, domain, doctype, doc_id,
        %({"salary": 5}), sys)
      Facet::Document::Update.call(db, domain, doctype, doc_id,
        %({"note": "#{long_note}"}), sys)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)

      salary_row = list.items.find { |m| m.action == "update" && !m.arguments.as_h["diff"].as_h["set"].as_a.empty? && m.arguments.as_h["diff"].as_h["set"].as_a.first["path"].as_a == ["salary"] }.should_not be_nil
      entry = salary_row.arguments.as_h["diff"].as_h["set"].as_a.first.as_h
      entry["path"].as_a.should eq([JSON::Any.new("salary")])
      entry["value"]?.should be_nil
      entry["patch"]?.should be_nil
      salary_row.redacted.map(&.join(".")).should contain("salary")

      # The visible long-text row keeps its patch (visible field).
      note_row = list.items.find { |m| m.action == "update" && m.arguments.as_h["diff"].as_h["set"].as_a.first["path"].as_a == ["note"] }.should_not be_nil
      note_entry = note_row.arguments.as_h["diff"].as_h["set"].as_a.first.as_h
      note_row.redacted.should eq([] of Array(String))
      (note_entry["value"]? || note_entry["patch"]?).should_not be_nil
    end
  end

  it "keeps unset paths visible without duplicate redaction entries" do
    with_temp_doctype("redx") do |db, domain, doctype|
      redact_seed(db)
      redact_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id
      Facet::Document::Update.call(db, domain, doctype, doc_id, %({"name": null}), sys)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)
      update_row = list.items.find { |m| m.action == "update" }.should_not be_nil
      update_row.arguments.as_h["diff"].as_h["unset"].as_a.should eq([JSON::Any.new([JSON::Any.new("name")])])
      update_row.redacted.should eq([] of Array(String))
    end
  end

  it "redacts a visible parent set with hidden nested values recursively" do
    with_temp_doctype("redp") do |db, domain, doctype|
      redact_seed(db)
      redact_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id
      Facet::Document::Update.call(db, domain, doctype, doc_id,
        %({"profile": {"bio": "b2", "grade": "TOP"}}), sys)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)
      update_row = list.items.find { |m| m.action == "update" }.should_not be_nil

      entry = update_row.arguments.as_h["diff"].as_h["set"].as_a.first.as_h
      entry["path"].as_a.should eq([JSON::Any.new("profile")])
      value = entry["value"].as_h
      value["bio"].as_s.should eq("b2")
      value["grade"]?.should be_nil

      paths = update_row.redacted.map(&.join("."))
      paths.should contain("profile.grade")
    end
  end

  it "gives wildcard-tag and System callers raw arguments and empty redacted arrays" do
    with_temp_doctype("redw") do |db, domain, doctype|
      redact_seed(db)
      redact_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 55}), sys)

      wide = Facet::Audit::List.call(db, domain: domain, doc_type: doctype,
        auth_context: redact_ctx(["*"])).as(Facet::Audit::List::Result)
      wide_row = wide.items.find { |m| m.action == "create" }.should_not be_nil
      wide_row.arguments.as_h["content"].as_h["salary"].as_i.should eq(55)
      wide_row.redacted.should eq([] of Array(String))

      syslist = Facet::Audit::List.call(db, domain: domain, doc_type: doctype,
        auth_context: sys).as(Facet::Audit::List::Result)
      sys_row = syslist.items.find { |m| m.action == "create" }.should_not be_nil
      sys_row.arguments.as_h["content"].as_h["salary"].as_i.should eq(55)
      sys_row.redacted.should eq([] of Array(String))
    end
  end

  it "fails closed on missing definitions and unknown historical fields" do
    with_temp_doctype("redm") do |db, domain, doctype|
      redact_seed(db)
      redact_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 9}), sys)

      # Unknown historical field: inject a content junk field directly
      # into a historical mutation row (models a removed field) while the
      # definition still resolves.
      db.exec(<<-SQL, domain, doctype)
        UPDATE mutations
        SET arguments = jsonb_set(arguments, '{content,junk_secret}', '"boom"')
        WHERE domain = $1 AND doc_type = $2 AND action = 'create'
      SQL

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)
      create_row = list.items.find { |m| m.action == "create" }.should_not be_nil

      content = create_row.arguments.as_h["content"].as_h
      content["junk_secret"]?.should be_nil
      content["name"].as_s.should eq("a")
      create_row.redacted.map(&.join(".")).should contain("junk_secret")

      # Missing definition: drop the core.DocType projection row and clear
      # the definition caches — no raw content value survives, the root
      # path marks whole-content redaction.
      db.exec("DELETE FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1", "#{domain}.#{doctype}")
      Facet::Doctype::DefinitionStore.cache.clear

      list2 = Facet::Audit::List.call(db, domain: domain, doc_type: doctype,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)
      row2 = list2.items.find { |m| m.action == "create" }.should_not be_nil
      row2.arguments.as_h["content"].as_h.should eq({} of String => JSON::Any)
      row2.redacted.should contain([] of String)
    end
  end

  it "keeps money, period, dateperiod, and dictionary diff values visible to an entitled role" do
    with_temp_doctype("redv") do |db, domain, doctype|
      redact_seed(db)
      redact_value_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype, %({
        "name": "a",
        "fee": {"value": "1.00", "currency": "EUR"},
        "days": {"start": "2026-02-01", "end": "2026-02-28"},
        "span": {"start": "2026-02-01T00:00:00Z", "end": "2026-02-20T00:00:00Z"},
        "attrs": {"k": "v"}
      }), sys).as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      Facet::Document::Update.call(db, domain, doctype, doc_id, %({
        "fee": {"value": "2.00", "currency": "USD"},
        "days": {"start": "2026-02-03", "end": "2026-02-27"},
        "span": {"start": "2026-02-01T00:00:00Z", "end": "2026-02-25T00:00:00Z"},
        "attrs": {"k": "v2"}
      }), sys)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)

      # The create row keeps every structured value.
      create_row = list.items.find { |m| m.action == "create" }.should_not be_nil
      content = create_row.arguments.as_h["content"].as_h
      content["fee"].as_h["value"].as_s.should eq("1.00")
      content["days"].as_h["end"].as_s.should eq("2026-02-28")
      content["attrs"].as_h["k"].as_s.should eq("v")
      create_row.redacted.should eq([] of Array(String))

      # Every value-shaped diff entry keeps its value.
      update_row = list.items.find { |m| m.action == "update" }.should_not be_nil
      update_row.redacted.should eq([] of Array(String))
      redact_set_entry(update_row, "fee.value")["value"].as_s.should eq("2.00")
      redact_set_entry(update_row, "fee.currency")["value"].as_s.should eq("USD")
      redact_set_entry(update_row, "days.start")["value"].as_s.should eq("2026-02-03")
      redact_set_entry(update_row, "days.end")["value"].as_s.should eq("2026-02-27")
      redact_set_entry(update_row, "span.end")["value"].as_s.should contain("2026-02-25")
      redact_set_entry(update_row, "attrs.k")["value"].as_s.should eq("v2")

      # A wildcard-tag role sees the same rows raw.
      wide = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["*"])).as(Facet::Audit::List::Result)
      wide_row = wide.items.find { |m| m.action == "update" }.should_not be_nil
      redact_set_entry(wide_row, "fee.value")["value"].as_s.should eq("2.00")
      redact_set_entry(wide_row, "attrs.k")["value"].as_s.should eq("v2")
      wide_row.redacted.should eq([] of Array(String))
    end
  end

  it "redacts dictionary diff paths for a tagged root or a tagged value descriptor" do
    with_temp_doctype("redt") do |db, domain, doctype|
      redact_seed(db)
      redact_value_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype, %({
        "name": "a",
        "hidden_attrs": {"k": "s1"},
        "sealed_attrs": {"k": "t1"}
      }), sys).as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      Facet::Document::Update.call(db, domain, doctype, doc_id, %({
        "hidden_attrs": {"k": "s2"},
        "sealed_attrs": {"k": "t2"}
      }), sys)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)

      # Content rows: the tagged root drops whole; the visible root with
      # a tagged value descriptor drops per key.
      create_row = list.items.find { |m| m.action == "create" }.should_not be_nil
      content = create_row.arguments.as_h["content"].as_h
      content["sealed_attrs"]?.should be_nil
      content["hidden_attrs"].as_h["k"]?.should be_nil
      create_paths = create_row.redacted.map(&.join("."))
      create_paths.should contain("sealed_attrs")
      create_paths.should contain("hidden_attrs.k")

      # Diff rows: both dictionary sub-paths lose their values.
      update_row = list.items.find { |m| m.action == "update" }.should_not be_nil
      redact_set_entry(update_row, "hidden_attrs.k")["value"]?.should be_nil
      redact_set_entry(update_row, "sealed_attrs.k")["value"]?.should be_nil
      update_paths = update_row.redacted.map(&.join("."))
      update_paths.should contain("hidden_attrs.k")
      update_paths.should contain("sealed_attrs.k")
    end
  end

  it "keeps free-form object and any diff sub-paths visible to an entitled role" do
    with_temp_doctype("redf") do |db, domain, doctype|
      redact_seed(db)
      redact_value_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "free": {"k": "v"}, "extra": {"k": "v"}}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      Facet::Document::Update.call(db, domain, doctype, doc_id,
        %({"free": {"k": "v2"}, "extra": {"k": "v2"}}), sys)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)

      # The create row keeps the whole free-form values.
      create_row = list.items.find { |m| m.action == "create" }.should_not be_nil
      create_row.arguments.as_h["content"].as_h["free"].as_h["k"].as_s.should eq("v")
      create_row.redacted.should eq([] of Array(String))

      # The member sub-paths of the free-form shapes keep their values.
      update_row = list.items.find { |m| m.action == "update" }.should_not be_nil
      redact_set_entry(update_row, "free.k")["value"].as_s.should eq("v2")
      redact_set_entry(update_row, "extra.k")["value"].as_s.should eq("v2")
      update_row.redacted.should eq([] of Array(String))
    end
  end

  it "keeps secret marker rotation sub-paths visible to an entitled role" do
    with_temp_doctype("redk") do |db, domain, doctype|
      redact_seed(db)
      redact_value_doctype(db, domain, doctype)

      # The write pipeline adopts each stage handle into a marker
      # {mode, version, set_at}; the rotation rewrites the marker, so
      # the diff lands as member sub-paths.
      writer = redact_writer_ctx(domain, doctype)
      h1 = Facet::Secrets::Staging.insert(db, "hash", "hash-one", domain, doctype, "api_key", "redact-caller")
      doc = Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "api_key": "#{h1}"}), writer).as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      h2 = Facet::Secrets::Staging.insert(db, "hash", "hash-two", domain, doctype, "api_key", "redact-caller")
      Facet::Document::Update.call(db, domain, doctype, doc_id, %({"api_key": "#{h2}"}), writer)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)

      # The create row carries the first marker in full.
      create_row = list.items.find { |m| m.action == "create" }.should_not be_nil
      marker = create_row.arguments.as_h["content"].as_h["api_key"].as_h
      marker["mode"].as_s.should eq("hash")
      marker["version"].as_i.should eq(1)

      # The rotation sub-paths keep their values.
      update_row = list.items.find { |m| m.action == "update" }.should_not be_nil
      redact_set_entry(update_row, "api_key.version")["value"].as_i.should eq(2)
      update_row.redacted.should eq([] of Array(String))
    end
  end

  it "fails closed on unknown historical diff paths" do
    with_temp_doctype("redn") do |db, domain, doctype|
      redact_seed(db)
      redact_value_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id
      Facet::Document::Update.call(db, domain, doctype, doc_id, %({"name": "b"}), sys)

      # Inject unknown historical paths into the update row: a removed
      # root field and a descent under a scalar field. Both model
      # history that the current definition cannot vouch for.
      db.exec(<<-SQL, domain, doctype)
        UPDATE mutations
        SET arguments = jsonb_set(
          arguments,
          '{diff,set}',
          (arguments->'diff'->'set') ||
          '[{"path": ["ghost"], "value": "boom"}, {"path": ["name", "sub"], "value": "deep-boom"}]'::jsonb
        )
        WHERE domain = $1 AND doc_type = $2 AND action = 'update'
      SQL

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)
      update_row = list.items.find { |m| m.action == "update" }.should_not be_nil

      # The legit entry keeps its value; the unknown ones keep only
      # their path.
      redact_set_entry(update_row, "name")["value"].as_s.should eq("b")
      redact_set_entry(update_row, "ghost")["value"]?.should be_nil
      redact_set_entry(update_row, "name.sub")["value"]?.should be_nil

      paths = update_row.redacted.map(&.join("."))
      paths.should contain("ghost")
      paths.should contain("name.sub")
    end
  end

  it "keeps snapshot rows on the content-shape rules" do
    with_temp_doctype("redq") do |db, domain, doctype|
      redact_seed(db)
      redact_value_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 5, "fee": {"value": "9.00", "currency": "EUR"}}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      pre = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: sys).as(Facet::Audit::List::Result)
      create_id = pre.items.find! { |m| m.action == "create" }.id

      Facet::Audit::Rollback.call(db, mutation_id: create_id, auth_context: sys)

      list = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id,
        auth_context: redact_ctx(["default"])).as(Facet::Audit::List::Result)
      snapshot_row = list.items.find { |m| m.action == "snapshot" }.should_not be_nil

      content = snapshot_row.arguments.as_h["content"].as_h
      content["name"].as_s.should eq("a")
      content["fee"].as_h["value"].as_s.should eq("9.00")
      content["salary"]?.should be_nil
      snapshot_row.redacted.map(&.join(".")).should contain("salary")
    end
  end

  it "shares the contract across HTTP history, global audit, and MCP list_mutations" do
    with_temp_doctype("redh") do |db, domain, doctype|
      redact_seed(db)
      redact_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 31}), sys).as(Facet::Document::Create::Result)

      ctx = redact_ctx(["default"])

      # Document history (service level).
      history = Facet::Audit::List.call(db, domain: domain, doc_type: doctype,
        doc_id: doc.projection.id, auth_context: ctx).as(Facet::Audit::List::Result)
      svc_row = history.items.find { |m| m.action == "create" }.should_not be_nil
      svc_row.arguments.as_h["content"].as_h["salary"]?.should be_nil

      # Global audit over HTTP. The bracket form is the GET filter
      # transport — a bare `doc_type` key answers 422 (strict admission).
      resp = call_api_as(HTTP::Request.new("GET", "/Api/Audit?filters[doc_type__eq]=#{doctype}"), ctx)
      resp.status_code.should eq(200)
      payload = JSON.parse(resp.body)
      row = payload["data"].as_a.find { |r| r["action"].as_s == "create" }.should_not be_nil
      row["arguments"]["content"]["salary"]?.should be_nil
      row["redacted"].as_a.should_not be_nil

      # MCP list_mutations — the doctype pins as top-level arguments, not
      # filters.
      result = Facet::AgentTools::Registry.execute(ctx, "list_mutations",
        JSON.parse(%({"doctype": "#{doctype}"})))
      mcp_row = result["data"].as_a.find { |r| r["action"].as_s == "create" }.should_not be_nil
      mcp_row["arguments"]["content"]["salary"]?.should be_nil
      mcp_paths = mcp_row["redacted"].as_a.map(&.as_a.map(&.as_s).join("."))
      mcp_paths.should contain("salary")
    end
  end

  it "does not leak the original values into the serialized HTTP response" do
    with_temp_doctype("redj") do |db, domain, doctype|
      redact_seed(db)
      redact_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 12345, "profile": {"grade": "TOPSECRET"}}), sys)

      resp = call_api_as(HTTP::Request.new("GET", "/Api/Audit?filters[doc_type__eq]=#{doctype}"),
        redact_ctx(["default"]))
      resp.status_code.should eq(200)
      resp.body.should_not contain("12345")
      resp.body.should_not contain("TOPSECRET")
    end
  end
end
