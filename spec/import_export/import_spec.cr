# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/rbac"
require "../../src/document"
require "../../src/import_export/import"

# ── Spec helpers ─────────────────────────────────────────────────────────────

private def create_import_doctype(
  db : DB::Connection,
  domain : String,
  doctype : String,
  fields : String,
  script : String? = nil,
  identifier : String? = nil,
) : Nil
  ensure_domain(db, domain)
  script_field = script ? %Q(, "script": #{script.to_json}) : ""
  id_field = identifier ? %Q(, "identifier": #{identifier}) : ""
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}#{script_field}#{id_field}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
    .should be_a(Facet::Document::Create::Result)
end

private def create_import_doc(db : DB::Connection, domain : String, doctype : String, content : String) : String
  result = Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection.id
end

private def import_doc_exists(db : DB::Connection, domain : String, doctype : String, id : String) : Bool
  !db.query_one?("SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
    domain, doctype, id, as: Int32).nil?
end

private def import_doc_content(db : DB::Connection, domain : String, doctype : String, id : String) : JSON::Any
  db.query_one(
    "SELECT content FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
    domain, doctype, id, as: JSON::Any)
end

private def import_doc_tombstoned?(db : DB::Connection, domain : String, doctype : String, id : String) : Bool?
  db.query_one?(
    "SELECT deleted_at IS NOT NULL FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
    domain, doctype, id, as: Bool)
end

private def create_import_role(db, role_id : String, permissions : Array(JSON::Any)) : Nil
  content = JSON::Any.new({
    "name"         => JSON::Any.new(role_id),
    "level"        => JSON::Any.new(20_i64),
    "permissions"  => JSON::Any.new(permissions),
    "visible_tags" => JSON::Any.new(["default"].map { |t| JSON::Any.new(t) }),
  })
  Facet::Mutation::Client.create(db, "iam", "Roles",
    doc_id: role_id, content: content.to_json, actioner_id: "system")
end

private def import_auth_context(db : DB::Connection, role_id : String?) : Facet::RBAC::AuthContext
  return Facet::RBAC::AuthContext.system if role_id.nil?
  ensure_iam_account(db, "import_caller")
  role_content = Facet::IAM::Helpers.find_role_content(db, role_id).not_nil!
  Facet::RBAC::AuthContext.authenticated("import_caller", Facet::RBAC::ActiveRole.from_projection_content(role_content))
end

describe Facet::Document::Import do
  before_each do
    # Money decode validates tickers against the in-memory currency registry,
    # which `register_seed_currencies` fills from the core.Currency seeds.
    Facet::Config.reset!
    Facet::Config.instance
    register_seed_currencies
    # A fresh in-process event manager so event assertions are hermetic.
    Facet::Event::Publisher.manager = Facet::Event::InProcessManager.new
  end

  describe "happy path" do
    it "creates N rows and reports correct counts" do
      with_temp_doctype("impok", "Contact") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        a = Facet::Util::ScriptHelpers.ulid
        b = Facet::Util::ScriptHelpers.ulid
        file = %([
          {"id": "#{a}", "content": {"name": "a"}},
          {"id": "#{b}", "content": {"name": "b"}}
        ])

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [a, b], [true, true], Facet::RBAC::AuthContext.system)

        result.should be_a(Facet::Document::Import::Result)
        r = result.as(Facet::Document::Import::Result)
        r.row_count.should eq(2)
        r.created.should eq(2)
        r.updated.should eq(0)
        r.skipped.should eq(0)
        import_doc_exists(db, domain, dt, a).should be_true
        import_doc_exists(db, domain, dt, b).should be_true
      end
    end
  end

  describe "CSV decode drives the same upsert" do
    it "imports through the cell codec (money prefix required, empty cell is null)" do
      with_temp_doctype("impcsv", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt,
          %({"label": {"type": "string"}, "price": {"type": "money"}, "note": {"type": "string"}}))

        a = Facet::Util::ScriptHelpers.ulid
        file = "id,label,price,note\n#{a},First row,USD 1.5,hello\n"

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "csv", file, [a], [true], Facet::RBAC::AuthContext.system)

        r = result.as(Facet::Document::Import::Result)
        r.created.should eq(1)

        content = import_doc_content(db, domain, dt, a)
        content["price"]["value"].as_s.should eq("1.5")
        content["price"]["currency"].as_s.should eq("USD")
        content["note"].as_s.should eq("hello")
      end
    end

    it "fails a row whose money cell lacks the currency prefix, naming the field" do
      with_temp_doctype("impmoney", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"price": {"type": "money"}}))
        a = Facet::Util::ScriptHelpers.ulid
        file = "id,price\n#{a},1.5\n"

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "csv", file, [a], [true], Facet::RBAC::AuthContext.system)

        failure = result.as(Facet::Document::Import::RowFailure)
        failure.row.should eq(1)
        failure.field.should eq("price")
        failure.message.should contain("currency prefix")
      end
    end
  end

  describe "currency lifecycle" do
    it "imports a row carrying an inactive registered ticker" do
      with_temp_doctype("impon", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt,
          %({"label": {"type": "string"}, "price": {"type": "money"}}))
        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false)})

        a = Facet::Util::ScriptHelpers.ulid
        file = %([{"id": "#{a}", "content": {"label": "kept", "price": {"value": "9.50", "currency": "OLD"}}}])

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [a], [true], Facet::RBAC::AuthContext.system)

        result.should be_a(Facet::Document::Import::Result)
        import_doc_content(db, domain, dt, a)["price"]["currency"].as_s.should eq("OLD")
      end
    end

    it "imports a CSV cell with an inactive registered ticker" do
      with_temp_doctype("impcsvon", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"price": {"type": "money"}}))
        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false)})

        a = Facet::Util::ScriptHelpers.ulid
        file = "id,price\n#{a},OLD 4.20\n"

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "csv", file, [a], [true], Facet::RBAC::AuthContext.system)

        result.should be_a(Facet::Document::Import::Result)
        import_doc_content(db, domain, dt, a)["price"]["currency"].as_s.should eq("OLD")
      end
    end

    it "fails loudly at decode on an unknown (deleted) ticker" do
      with_temp_doctype("impdel", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"price": {"type": "money"}}))

        a = Facet::Util::ScriptHelpers.ulid
        file = "id,price\n#{a},XYZ 1.00\n"

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "csv", file, [a], [true], Facet::RBAC::AuthContext.system)

        failure = result.as(Facet::Document::Import::RowFailure)
        failure.field.should eq("price")
        failure.message.should contain("unknown currency")
      end
    end

    it "upserts a stored inactive ticker unchanged (update path)" do
      with_temp_doctype("impupold", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"price": {"type": "money"}}))

        # OLD starts active so the create may store it, then it turns
        # inactive — the import replay keeps the stored ticker.
        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2)})
        existing = create_import_doc(db, domain, dt, %({"price": {"value": "10.00", "currency": "OLD"}}))
        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false)})

        file = %([{"id": "#{existing}", "content": {"price": {"value": "10.00", "currency": "OLD"}}}])
        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [existing], [true], Facet::RBAC::AuthContext.system)

        r = result.as(Facet::Document::Import::Result)
        r.updated.should eq(1)
        import_doc_content(db, domain, dt, existing)["price"]["currency"].as_s.should eq("OLD")
      end
    end
  end

  describe "upsert matrix" do
    it "creates absent ids, updates live ids, and counts a no-op row as updated" do
      with_temp_doctype("impupsert", "Contact") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        existing = create_import_doc(db, domain, dt, %({"name": "original"}))

        new_id = Facet::Util::ScriptHelpers.ulid
        file = %([
          {"id": "#{existing}", "content": {"name": "original"}},
          {"id": "#{existing}", "content": {"name": "changed"}},
          {"id": "#{new_id}", "content": {"name": "new"}}
        ])

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [existing, existing, new_id], [true, true, true], Facet::RBAC::AuthContext.system)

        r = result.as(Facet::Document::Import::Result)
        r.row_count.should eq(3)
        r.created.should eq(1)
        r.updated.should eq(2) # one no-op (same content), one real change
        r.skipped.should eq(0)

        import_doc_content(db, domain, dt, existing)["name"].as_s.should eq("changed")
        import_doc_content(db, domain, dt, new_id)["name"].as_s.should eq("new")
      end
    end

    it "skips a tombstoned id and never resurrects it" do
      with_temp_doctype("imptomb", "Contact") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        deleted_id = create_import_doc(db, domain, dt, %({"name": "doomed"}))
        Facet::Document::Delete.call(db, domain, dt, deleted_id, Facet::RBAC::AuthContext.system)
        import_doc_tombstoned?(db, domain, dt, deleted_id).should be_true

        file = %([{"id": "#{deleted_id}", "content": {"name": "resurrect?"}}])
        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [deleted_id], [true], Facet::RBAC::AuthContext.system)

        r = result.as(Facet::Document::Import::Result)
        r.skipped.should eq(1)
        r.created.should eq(0)
        r.updated.should eq(0)
        import_doc_tombstoned?(db, domain, dt, deleted_id).should be_true
      end
    end
  end

  describe "first-failure rollback" do
    it "leaves zero rows, nothing in mutations, and no events when a later row fails" do
      with_temp_doctype("improb", "Contact") do |db, domain, dt|
        create_import_doctype(db, domain, dt,
          %({"name": {"type": "string"}, "price": {"type": "money"}}))
        updated_id = create_import_doc(db, domain, dt, %({"name": "before"}))

        new_id = Facet::Util::ScriptHelpers.ulid
        bad_id = Facet::Util::ScriptHelpers.ulid
        file = %([
          {"id": "#{new_id}", "content": {"name": "good create"}},
          {"id": "#{updated_id}", "content": {"name": "good update"}},
          {"id": "#{bad_id}", "content": {"price": {"value": "1.5", "currency": "XXX"}}}
        ])

        Facet::Event::Publisher.flush
        event_manager.clear!
        mutations_before = db.query_one("SELECT COUNT(*) FROM mutations", as: Int64)

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [new_id, updated_id, bad_id], [true, true, true], Facet::RBAC::AuthContext.system)

        failure = result.as(Facet::Document::Import::RowFailure)
        failure.row.should eq(3)

        import_doc_exists(db, domain, dt, new_id).should be_false
        import_doc_content(db, domain, dt, updated_id)["name"].as_s.should eq("before")
        db.query_one("SELECT COUNT(*) FROM mutations", as: Int64).should eq(mutations_before)
        event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}").size.should eq(0)
      end
    end
  end

  describe "update-permission failure" do
    it "fails the file with the row named when the caller may not update" do
      with_temp_doctype("imppermiss", "Contact") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        existing = create_import_doc(db, domain, dt, %({"name": "original"}))
        create_import_role(db, "import_create_only_role",
          [permission_json("create", "#{domain}.#{dt}")])

        file = %([{"id": "#{existing}", "content": {"name": "changed"}}])
        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [existing], [true], import_auth_context(db, "import_create_only_role"))

        failure = result.as(Facet::Document::Import::RowFailure)
        failure.row.should eq(1)
        import_doc_content(db, domain, dt, existing)["name"].as_s.should eq("original")
      end
    end
  end

  describe "Lua hooks" do
    it "runs the create hook on created rows and the update hook on updated rows, both as the import actor" do
      with_temp_doctype("imphook", "Contact") do |db, domain, dt|
        script = <<-LUA
          local import_hook = {}
          function import_hook.create(ctx)
            ctx.root.actor_seen = ctx.actor_id
            ctx.root.touched_by = "create_hook"
          end
          function import_hook.update(ctx)
            ctx.root.actor_seen = ctx.actor_id
            ctx.root.touched_by = "update_hook"
          end
          return import_hook
        LUA
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}), script)

        new_id = Facet::Util::ScriptHelpers.ulid
        existing = create_import_doc(db, domain, dt, %({"name": "before"}))

        file = %([
          {"id": "#{new_id}", "content": {"name": "new"}},
          {"id": "#{existing}", "content": {"name": "after"}}
        ])
        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [new_id, existing], [true, true], Facet::RBAC::AuthContext.system)

        r = result.as(Facet::Document::Import::Result)
        r.created.should eq(1)
        r.updated.should eq(1)

        created_content = import_doc_content(db, domain, dt, new_id)
        created_content["touched_by"].as_s.should eq("create_hook")
        created_content["actor_seen"].as_s.should eq("import")

        updated_content = import_doc_content(db, domain, dt, existing)
        updated_content["touched_by"].as_s.should eq("update_hook")
        updated_content["actor_seen"].as_s.should eq("import")
      end
    end
  end

  describe "events" do
    it "publishes nothing before the commit and one ordered burst after" do
      with_temp_doctype("impevent", "Contact") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}))

        a = Facet::Util::ScriptHelpers.ulid
        b = Facet::Util::ScriptHelpers.ulid
        file = %([
          {"id": "#{a}", "content": {"name": "a"}},
          {"id": "#{b}", "content": {"name": "b"}}
        ])

        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [a, b], [true, true], Facet::RBAC::AuthContext.system)

        result.should be_a(Facet::Document::Import::Result)

        events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
        events.size.should eq(2)
        events[0].headers["event"].as_s.should eq("created")
        events[1].headers["event"].as_s.should eq("created")
        events[0].content["id"].as_s.should eq(a)
        events[1].content["id"].as_s.should eq(b)
      end
    end

    it "mixes created and updated events in file order" do
      with_temp_doctype("impevent2", "Contact") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        existing = create_import_doc(db, domain, dt, %({"name": "before"}))
        new_id = Facet::Util::ScriptHelpers.ulid

        # The seeding buffers its own fiber-local event; publish and clear
        # so the assertions below see only the import's burst.
        Facet::Event::Publisher.flush
        event_manager.clear!

        file = %([
          {"id": "#{existing}", "content": {"name": "after"}},
          {"id": "#{new_id}", "content": {"name": "new"}}
        ])
        Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [existing, new_id], [true, true], Facet::RBAC::AuthContext.system)
          .should be_a(Facet::Document::Import::Result)

        events = event_manager.events_for("FACET:RESOURCE:#{domain}:#{dt}")
        events.size.should eq(2)
        events[0].headers["event"].as_s.should eq("updated")
        events[0].content["id"].as_s.should eq(existing)
        events[1].headers["event"].as_s.should eq("created")
        events[1].content["id"].as_s.should eq(new_id)
      end
    end
  end

  describe "re-execution" do
    it "absorbs a committed attempt — no duplicates" do
      with_temp_doctype("impre", "Contact") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}))
        defn = Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!

        a = Facet::Util::ScriptHelpers.ulid
        b = Facet::Util::ScriptHelpers.ulid
        file = %([
          {"id": "#{a}", "content": {"name": "a"}},
          {"id": "#{b}", "content": {"name": "b"}}
        ])

        Facet::Document::Import.call(db, domain, dt, defn, "json", file, [a, b], [true, true], Facet::RBAC::AuthContext.system)
          .should be_a(Facet::Document::Import::Result)

        # Simulate the crash-window re-execution: the same manifest ids run
        # again after the first attempt committed and its outcome was lost.
        second = Facet::Document::Import.call(db, domain, dt, defn, "json", file, [a, b], [true, true], Facet::RBAC::AuthContext.system)
        r2 = second.as(Facet::Document::Import::Result)
        r2.created.should eq(0)
        r2.updated.should eq(2) # both rows re-run as no-op updates
        r2.skipped.should eq(0)

        dc = db.query_one("SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = $2", domain, dt, as: Int64)
        dc.should eq(2)
      end
    end
  end

  describe "genonly identifier" do
    it "fails a caller-supplied id instead of creating the document" do
      with_temp_doctype("impgo", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}),
          identifier: %({"template": "INV-{year}-####", "genonly": true}))

        file = "id,name\nMY-IMP-1,First row\n"
        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "csv", file, ["MY-IMP-1"], [true], Facet::RBAC::AuthContext.system)

        failure = result.as(Facet::Document::Import::RowFailure)
        failure.row.should eq(1)
        failure.field.should eq("id")
        failure.message.should contain("genonly")
        import_doc_exists(db, domain, dt, "MY-IMP-1").should be_false
      end
    end

    it "accepts a caller-supplied id when genonly is false" do
      with_temp_doctype("impgnf", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}),
          identifier: %({"template": "INV-{year}-####", "genonly": false}))

        file = "id,name\nMY-IMP-2,Primeira linha\n"
        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "csv", file, ["MY-IMP-2"], [true], Facet::RBAC::AuthContext.system)

        r = result.as(Facet::Document::Import::Result)
        r.created.should eq(1)
        import_doc_exists(db, domain, dt, "MY-IMP-2").should be_true
      end
    end

    it "imports id-less rows under the manifest-generated id" do
      with_temp_doctype("impgi", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}),
          identifier: %({"template": "INV-{year}-####", "genonly": true}))

        pinned = Facet::Util::ScriptHelpers.ulid
        file = %([{"content": {"name": "First row"}}])
        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [pinned], [false], Facet::RBAC::AuthContext.system)

        r = result.as(Facet::Document::Import::Result)
        r.created.should eq(1)
        import_doc_exists(db, domain, dt, pinned).should be_true
      end
    end

    it "updates an existing id — the guard covers creation only" do
      with_temp_doctype("impge", "Invoice") do |db, domain, dt|
        create_import_doctype(db, domain, dt, %({"name": {"type": "string"}}),
          identifier: %({"template": "INV-{year}-####", "genonly": true}))
        existing = create_import_doc(db, domain, dt, %({"name": "original"}))

        file = %([{"id": "#{existing}", "content": {"name": "changed"}}])
        result = Facet::Document::Import.call(db, domain, dt,
          Facet::Doctype::DefinitionStore.fetch(db, "#{domain}.#{dt}").not_nil!,
          "json", file, [existing], [true], Facet::RBAC::AuthContext.system)

        r = result.as(Facet::Document::Import::Result)
        r.updated.should eq(1)
        import_doc_content(db, domain, dt, existing).as_h["name"].as_s.should eq("changed")
      end
    end
  end
end
