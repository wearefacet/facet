# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"
require "../../src/document/create"
require "../../src/document/update"
require "../../src/document/action"
require "../../src/audit/rollback"
require "../../src/audit/list"

# Shared recursive field visibility and write refusal (execution plan
# Phase 4). Pure-logic coverage for the walker, then pipeline coverage
# through the document services.

# A doctype with tagged fields at every structural level.
private def fv_definition
  string = Facet::Doctype::FieldType.parse("string")
  integer = Facet::Doctype::FieldType.parse("integer")
  object = Facet::Doctype::FieldType.parse("object")
  array = Facet::Doctype::FieldType.parse("array")
  dictionary = Facet::Doctype::FieldType.parse("dictionary")
  money = Facet::Doctype::FieldType.parse("money")
  dateperiod = Facet::Doctype::FieldType.parse("dateperiod")
  any = Facet::Doctype::FieldType.parse("any")
  secret = Facet::Doctype::FieldType.parse("secret")

  fields = {
    "name"    => Facet::Doctype::FieldDefinition.new(type: string),
    "ssn"     => Facet::Doctype::FieldDefinition.new(type: string, tags: ["confidential"]),
    "profile" => Facet::Doctype::FieldDefinition.new(
      type: object,
      properties: {
        "bio"    => Facet::Doctype::FieldDefinition.new(type: string),
        "salary" => Facet::Doctype::FieldDefinition.new(type: integer, tags: ["confidential"]),
        "deep"   => Facet::Doctype::FieldDefinition.new(
          type: object,
          properties: {
            "secret" => Facet::Doctype::FieldDefinition.new(type: string, tags: ["confidential"]),
            "note"   => Facet::Doctype::FieldDefinition.new(type: string),
          },
        ),
      },
    ),
    "attachments" => Facet::Doctype::FieldDefinition.new(
      type: array,
      items: Facet::Doctype::FieldDefinition.new(
        type: object,
        properties: {
          "url"   => Facet::Doctype::FieldDefinition.new(type: string),
          "token" => Facet::Doctype::FieldDefinition.new(type: string, tags: ["confidential"]),
        },
      ),
    ),
    "tagged_items" => Facet::Doctype::FieldDefinition.new(
      type: array,
      items: Facet::Doctype::FieldDefinition.new(type: string, tags: ["confidential"]),
    ),
    "metadata" => Facet::Doctype::FieldDefinition.new(
      type: dictionary,
      dictionary_value: Facet::Doctype::FieldDefinition.new(type: string, tags: ["confidential"]),
    ),
    "open_metadata" => Facet::Doctype::FieldDefinition.new(
      type: dictionary,
      dictionary_value: Facet::Doctype::FieldDefinition.new(type: string),
    ),
    "sealed" => Facet::Doctype::FieldDefinition.new(
      type: dictionary,
      tags: ["confidential"],
      dictionary_value: Facet::Doctype::FieldDefinition.new(type: string),
    ),
    "fee"         => Facet::Doctype::FieldDefinition.new(type: money, tags: ["confidential"]),
    "public_fee"  => Facet::Doctype::FieldDefinition.new(type: money),
    "days"        => Facet::Doctype::FieldDefinition.new(type: dateperiod),
    "tagged_days" => Facet::Doctype::FieldDefinition.new(type: dateperiod, tags: ["confidential"]),
    "free"        => Facet::Doctype::FieldDefinition.new(type: object),
    "tagged_free" => Facet::Doctype::FieldDefinition.new(type: object, tags: ["confidential"]),
    "extra"       => Facet::Doctype::FieldDefinition.new(type: any),
    "api_key"     => Facet::Doctype::FieldDefinition.new(type: secret, tags: ["confidential"]),
    "visible_key" => Facet::Doctype::FieldDefinition.new(type: secret),
  } of String => Facet::Doctype::FieldDefinition

  Facet::Doctype::DoctypeDefinition.new(
    doctype: "Person", domain: "hr", schema_version: 1,
    fields: fields,
    children: {} of String => Facet::Doctype::ChildrenDefinition,
    actions: {} of String => Facet::Doctype::ActionDefinition,
  )
end

private def fv_ctx(tags : Array(String))
  role = Facet::RBAC::ActiveRole.new(
    role_id: "fv_role",
    visible_tags: Set.new(tags),
    permissions: [] of Facet::RBAC::Permission,
  )
  Facet::RBAC::AuthContext.authenticated("fv-caller", role)
end

describe "RBAC::FieldVisibility" do
  # ── Read masking ────────────────────────────────────────────────────

  it "masks nested invisible values on reads" do
    content = JSON.parse(%({
      "name": "alice",
      "ssn": "123-45-6789",
      "profile": {"bio": "hi", "salary": 99000, "deep": {"secret": "x", "note": "n"}},
      "attachments": [{"url": "u1", "token": "t1"}, {"url": "u2", "token": "t2"}],
      "tagged_items": ["a", "b"],
      "metadata": {"k": "v"}
    }))
    masked = Facet::RBAC::FieldVisibility.mask_content(content, fv_ctx(["default"]), fv_definition)

    masked["name"]?.should eq(JSON.parse(%("alice")))
    masked["ssn"]?.should be_nil
    masked["profile"].as_h["bio"].as_s.should eq("hi")
    masked["profile"].as_h["salary"]?.should be_nil
    masked["profile"].as_h["deep"].as_h["note"].as_s.should eq("n")
    masked["profile"].as_h["deep"].as_h["secret"]?.should be_nil
    masked["attachments"].as_a[0].as_h["url"].as_s.should eq("u1")
    masked["attachments"].as_a[0].as_h["token"]?.should be_nil
    masked["tagged_items"].as_a.should eq([] of JSON::Any)
    masked["metadata"].as_h.should eq({} of String => JSON::Any)
  end

  it "keeps an invisible parent's whole subtree invisible" do
    content = JSON.parse(%({"profile": {"bio": "hi", "deep": {"note": "n"}}}))
    defn = fv_definition
    # A caller that cannot see `profile` at all.
    role = Facet::RBAC::ActiveRole.new(
      role_id: "r", visible_tags: Set{"none_such"},
      permissions: [] of Facet::RBAC::Permission,
    )
    ctx = Facet::RBAC::AuthContext.authenticated("fv", role)
    masked = Facet::RBAC::FieldVisibility.mask_content(content, ctx, defn)
    masked["profile"]?.should be_nil
  end

  it "omits unknown content keys for Real principals and keeps them for System and Preview" do
    content = JSON.parse(%({"name": "alice", "junk_field": "x"}))
    defn = fv_definition

    masked = Facet::RBAC::FieldVisibility.mask_content(content, fv_ctx(["default"]), defn)
    masked["junk_field"]?.should be_nil
    masked["name"]?.should_not be_nil

    sys_masked = Facet::RBAC::FieldVisibility.mask_content(content, Facet::RBAC::AuthContext.system, defn)
    sys_masked.should eq(content)

    preview = Facet::RBAC::AuthContext.preview("pv", "_draft_domain")
    pv_masked = Facet::RBAC::FieldVisibility.mask_content(content, preview, defn)
    pv_masked.should eq(content)
  end

  it "shows wildcard-tag callers everything at every level" do
    content = JSON.parse(%({
      "ssn": "x",
      "profile": {"salary": 1, "deep": {"secret": "s"}},
      "tagged_items": ["a"],
      "metadata": {"k": "v"}
    }))
    masked = Facet::RBAC::FieldVisibility.mask_content(content, fv_ctx(["*"]), fv_definition)
    masked.should eq(content)
  end

  # ── Write guard ─────────────────────────────────────────────────────

  it "names invisible paths on submitted writes, explicit null included" do
    submitted = JSON.parse(%({
      "name": "alice",
      "ssn": null,
      "profile": {"salary": 5},
      "metadata": {"k": "v"}
    }))
    violations = Facet::RBAC::FieldVisibility.write_violations(fv_ctx(["default"]), fv_definition, submitted)
    paths = violations.map(&.join("."))
    paths.should contain("ssn")
    paths.should contain("profile.salary")
    paths.should contain("metadata.k")
    paths.size.should eq(3)
  end

  it "passes visible-only writes and stays silent for System and Preview" do
    submitted = JSON.parse(%({"name": "alice", "profile": {"bio": "hi", "deep": {"note": "n"}}}))
    Facet::RBAC::FieldVisibility.write_violations(fv_ctx(["default"]), fv_definition, submitted)
      .should eq([] of Array(String))

    secret = JSON.parse(%({"ssn": "x"}))
    Facet::RBAC::FieldVisibility.write_violations(Facet::RBAC::AuthContext.system, fv_definition, secret)
      .should eq([] of Array(String))
    preview = Facet::RBAC::AuthContext.preview("pv", "_draft_domain")
    Facet::RBAC::FieldVisibility.write_violations(preview, fv_definition, secret)
      .should eq([] of Array(String))
  end

  it "flags invisible array items and tagged array element writes" do
    submitted = JSON.parse(%({
      "attachments": [{"url": "u", "token": "t"}],
      "tagged_items": ["a"]
    }))
    violations = Facet::RBAC::FieldVisibility.write_violations(fv_ctx(["default"]), fv_definition, submitted)
    paths = violations.map(&.join("."))
    paths.should contain("attachments.token")
    paths.should contain("tagged_items")
  end

  # ── Changed-path guard ──────────────────────────────────────────────

  it "flags changed paths that land in invisible fields" do
    before = JSON.parse(%({"name": "a", "profile": {"bio": "b", "deep": {"secret": "s", "note": "n"}}}))
    after = JSON.parse(%({"name": "a2", "profile": {"bio": "b2", "deep": {"secret": "s2", "note": "n2"}}}))
    violations = Facet::RBAC::FieldVisibility.changed_violations(fv_ctx(["default"]), fv_definition, before, after)
    paths = violations.map(&.join("."))
    paths.should contain("profile.deep.secret")
    paths.should_not contain("name")
    paths.should_not contain("profile.bio")
    paths.should_not contain("profile.deep.note")
  end

  it "passes a transition with unchanged invisible content and a visible-only actual diff" do
    before = JSON.parse(%({"name": "a", "profile": {"bio": "b", "deep": {"secret": "same", "note": "same"}}}))
    after = JSON.parse(%({"name": "a2", "profile": {"bio": "b", "deep": {"secret": "same", "note": "same"}}}))
    violations = Facet::RBAC::FieldVisibility.changed_violations(fv_ctx(["default"]), fv_definition, before, after)
    violations.should eq([] of Array(String))
  end

  it "flags member sub-path changes under invisible fields and descriptors" do
    before = JSON.parse(%({
      "fee": {"value": "1.00", "currency": "EUR"},
      "tagged_days": {"start": "2026-01-01", "end": "2026-01-31"},
      "metadata": {"k": "v"},
      "sealed": {"k": "v"},
      "api_key": {"mode": "hash", "version": 1, "set_at": "2026-01-01T00:00:00Z"},
      "tagged_free": {"k": "v"}
    }))
    after = JSON.parse(%({
      "fee": {"value": "2.00", "currency": "EUR"},
      "tagged_days": {"start": "2026-01-05", "end": "2026-01-31"},
      "metadata": {"k": "v2"},
      "sealed": {"k": "v2"},
      "api_key": {"mode": "hash", "version": 2, "set_at": "2026-01-01T00:00:00Z"},
      "tagged_free": {"k": "v2"}
    }))
    violations = Facet::RBAC::FieldVisibility.changed_violations(fv_ctx(["default"]), fv_definition, before, after)
    paths = violations.map(&.join("."))
    paths.should contain("fee.value")
    paths.should contain("tagged_days.start")
    paths.should contain("metadata.k")
    paths.should contain("sealed.k")
    paths.should contain("api_key.version")
    paths.should contain("tagged_free.k")
    paths.size.should eq(6)
  end

  it "passes member sub-path changes under visible fields" do
    before = JSON.parse(%({
      "public_fee": {"value": "1.00", "currency": "EUR"},
      "days": {"start": "2026-01-01", "end": "2026-01-31"},
      "open_metadata": {"k": "v"},
      "free": {"k": "v"},
      "extra": {"k": "v"},
      "visible_key": {"mode": "hash", "version": 1, "set_at": "2026-01-01T00:00:00Z"}
    }))
    after = JSON.parse(%({
      "public_fee": {"value": "2.00", "currency": "EUR"},
      "days": {"start": "2026-01-05", "end": "2026-01-31"},
      "open_metadata": {"k": "v2"},
      "free": {"k": "v2"},
      "extra": {"k": "v2"},
      "visible_key": {"mode": "hash", "version": 2, "set_at": "2026-01-01T00:00:00Z"}
    }))
    violations = Facet::RBAC::FieldVisibility.changed_violations(fv_ctx(["default"]), fv_definition, before, after)
    violations.should eq([] of Array(String))
  end

  it "flags an unset dictionary key under a tagged value descriptor" do
    before = JSON.parse(%({"metadata": {"k": "v"}, "open_metadata": {"k": "v"}}))
    after = JSON.parse(%({"metadata": {}, "open_metadata": {}}))
    violations = Facet::RBAC::FieldVisibility.changed_violations(fv_ctx(["default"]), fv_definition, before, after)
    paths = violations.map(&.join("."))
    paths.should eq(["metadata.k"])
  end

  it "stays silent for unresolvable historical paths" do
    before = JSON.parse(%({"name": {"sub": "a"}, "gone": {"x": "1"}}))
    after = JSON.parse(%({"name": {"sub": "b"}, "gone": {"x": "2"}}))
    violations = Facet::RBAC::FieldVisibility.changed_violations(fv_ctx(["default"]), fv_definition, before, after)
    violations.should eq([] of Array(String))
  end

  # ── Pipeline: create / update ───────────────────────────────────────

  it "refuses an invisible create write with 403 naming the path" do
    with_temp_doctype("fvcr") do |db, domain, doctype|
      ensure_domain(db, domain)
      fields = %({
        "name": {"type": "string"},
        "ssn": {"type": "string", "tags": ["confidential"]}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"})))],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)

      result = Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "ssn": "x"}), ctx)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
      detail = err.details.try(&.first?)
      detail.should_not be_nil
      detail.as(Facet::ValidationError).message.should contain("ssn")
    end
  end

  # B-325: format validation runs after the field-write guard, so a caller
  # whose role cannot see a field never learns the field's type contract
  # from a 422 — a bad value on an invisible field answers the same 403 as
  # any other write into it, on create and update alike.
  it "answers 403, not a format 422, for a bad value on an invisible secret field (B-325)" do
    with_temp_doctype("fvsec") do |db, domain, doctype|
      ensure_domain(db, domain)
      fields = %({
        "name": {"type": "string"},
        "salary": {"type": "secret", "mode": "hash", "tags": ["confidential"]}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"}))),
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "update", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)

      # Create: the plaintext value on the invisible field answers 403
      # before secret format validation could answer 422.
      created = Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "salary": "120000"}), ctx)
      created.should be_a(Facet::ServiceError)
      err = created.as(Facet::ServiceError)
      err.status.should eq(403)
      err.message.should contain("invisible field")

      # Update: the same ordering on the patch path.
      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), Facet::RBAC::AuthContext.system)
        .as(Facet::Document::Create::Result)
      denied = Facet::Document::Update.call(db, domain, doctype, doc.projection.id, %({"salary": "120000"}), ctx)
      denied.should be_a(Facet::ServiceError)
      denied.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "refuses an invisible update write, explicit null included, and allows visible edits" do
    with_temp_doctype("fvup") do |db, domain, doctype|
      ensure_domain(db, domain)
      fields = %({
        "name": {"type": "string"},
        "salary": {"type": "integer", "tags": ["confidential"]}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"}))),
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "update", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)

      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "salary": 1}), Facet::RBAC::AuthContext.system)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      # A write into the invisible field refuses (403), value or null.
      denied = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"salary": 5}), ctx)
      denied.should be_a(Facet::ServiceError)
      denied.as(Facet::ServiceError).status.should eq(403)

      nulled = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"salary": null}), ctx)
      nulled.should be_a(Facet::ServiceError)
      nulled.as(Facet::ServiceError).status.should eq(403)

      # A visible-only edit passes.
      ok = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"name": "b"}), ctx)
      ok.should be_a(Facet::Document::Update::Result)
    end
  end

  it "keeps the GET → edit → PUT round trip safe" do
    with_temp_doctype("fvrt") do |db, domain, doctype|
      ensure_domain(db, domain)
      fields = %({
        "name": {"type": "string"},
        "salary": {"type": "integer", "tags": ["confidential"]}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"}))),
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "read", "on": "#{domain}.#{doctype}"}))),
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "update", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)

      Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "salary": 1}), Facet::RBAC::AuthContext.system)

      # GET (masked) omits the invisible field.
      list = Facet::Document::List.call(db, domain, doctype, auth_context: ctx).as(Facet::Document::List::Result)
      list.items.size.should eq(1)
      masked = list.items.first.content.as_h
      masked["salary"]?.should be_nil
      masked["name"]?.should_not be_nil

      # The masked shape PUTs back cleanly: the write guard only refuses
      # keys the caller submits, and the masked GET never submits the
      # invisible one.
      doc_id = list.items.first.id
      patch = {"name" => masked["name"]}.to_json
      result = Facet::Document::Update.call(db, domain, doctype, doc_id, patch, ctx)
      result.should be_a(Facet::Document::Update::Result)
    end
  end

  # ── Pipeline: action / rollback ─────────────────────────────────────

  it "refuses an action that changes an invisible field and allows a visible-only action" do
    with_temp_doctype("fvact") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.touch_secret(ctx) ctx.root.salary = 42 end
        function export.touch_visible(ctx) ctx.root.name = 'renamed' end
        return export
      LUA
      fields = %({
        "name": {"type": "string"},
        "salary": {"type": "integer", "tags": ["confidential"]}
      })
      actions = %({"touch_secret": {"args": {}}, "touch_visible": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"}))),
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "touch_secret", "on": "#{domain}.#{doctype}"}))),
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "touch_visible", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)

      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "salary": 1}), Facet::RBAC::AuthContext.system)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      denied = Facet::Document::Action.call(db, domain, doctype, doc_id, "touch_secret", "{}", ctx)
      denied.should be_a(Facet::ServiceError)
      denied.as(Facet::ServiceError).status.should eq(403)

      ok = Facet::Document::Action.call(db, domain, doctype, doc_id, "touch_visible", "{}", ctx)
      ok.should be_a(Facet::Document::Action::Result)
    end
  end

  it "refuses a rollback that rewinds an invisible value even when the target mutation touched only a visible field" do
    with_temp_doctype("fvrb") do |db, domain, doctype|
      ensure_domain(db, domain)
      fields = %({
        "name": {"type": "string"},
        "salary": {"type": "integer", "tags": ["confidential"]}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "update", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "salary": 1}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      # System: rename first (visible), then change the invisible salary.
      # Rolling back to the rename rewinds salary 99 → 1 — an invisible
      # value — even though the selected mutation's own diff touched only
      # the visible name.
      Facet::Document::Update.call(db, domain, doctype, doc_id, %({"name": "b"}), sys)
        .as(Facet::Document::Update::Result)
      Facet::Document::Update.call(db, domain, doctype, doc_id, %({"salary": 99}), sys)
        .as(Facet::Document::Update::Result)

      # Newest first — the rename is the OLDEST update.
      history = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id, auth_context: sys).as(Facet::Audit::List::Result)
      name_update = history.items.reverse_each.find { |m| m.action == "update" }.should_not be_nil

      result = Facet::Audit::Rollback.call(db, name_update.id, ctx)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "allows a rollback with unchanged invisible content and a visible-only actual diff" do
    with_temp_doctype("fvrb2") do |db, domain, doctype|
      ensure_domain(db, domain)
      fields = %({
        "name": {"type": "string"},
        "salary": {"type": "integer", "tags": ["confidential"]}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "update", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype, %({"name": "a", "salary": 1}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      # Two visible renames; the invisible salary never changes.
      Facet::Document::Update.call(db, domain, doctype, doc_id, %({"name": "b"}), sys)
        .as(Facet::Document::Update::Result)
      Facet::Document::Update.call(db, domain, doctype, doc_id, %({"name": "c"}), sys)
        .as(Facet::Document::Update::Result)

      history = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id, auth_context: sys).as(Facet::Audit::List::Result)
      first_rename = history.items.reverse_each.find { |m| m.action == "update" }.should_not be_nil

      result = Facet::Audit::Rollback.call(db, first_rename.id, ctx)
      result.should be_a(Facet::Audit::Rollback::Result)
    end
  end

  it "refuses an action that changes an invisible money member and allows a visible one" do
    with_temp_doctype("fvmoney") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) end
        function export.bump_hidden(ctx) ctx.root.fee.value = '9.99' end
        function export.bump_visible(ctx) ctx.root.public_fee.value = '9.99' end
        return export
      LUA
      fields = %({
        "name": {"type": "string"},
        "fee": {"type": "money", "currency": "EUR", "tags": ["confidential"]},
        "public_fee": {"type": "money", "currency": "EUR"}
      })
      actions = %({"bump_hidden": {"args": {}}, "bump_visible": {"args": {}}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "actions": #{actions}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"}))),
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "bump_hidden", "on": "#{domain}.#{doctype}"}))),
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "bump_visible", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)

      doc = Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "fee": {"value": "1.00", "currency": "EUR"}, "public_fee": {"value": "1.00", "currency": "EUR"}}),
        Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      denied = Facet::Document::Action.call(db, domain, doctype, doc_id, "bump_hidden", "{}", ctx)
      denied.should be_a(Facet::ServiceError)
      denied.as(Facet::ServiceError).status.should eq(403)

      ok = Facet::Document::Action.call(db, domain, doctype, doc_id, "bump_visible", "{}", ctx)
      ok.should be_a(Facet::Document::Action::Result)
    end
  end

  it "refuses a rollback that rewinds an invisible money member and allows a visible one" do
    with_temp_doctype("fvrbs") do |db, domain, doctype|
      ensure_domain(db, domain)
      fields = %({
        "name": {"type": "string"},
        "fee": {"type": "money", "currency": "EUR", "tags": ["confidential"]},
        "public_fee": {"type": "money", "currency": "EUR"}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "update", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)
      sys = Facet::RBAC::AuthContext.system

      content = %({"name": "a", "fee": {"value": "1.00", "currency": "EUR"}, "public_fee": {"value": "1.00", "currency": "EUR"}})

      # A value-only change to the invisible money member lands as the
      # sub-path ["fee", "value"]. Rolling back past it rewinds that
      # member — the gate refuses on the actual current-versus-replayed
      # diff, even though the selected mutation touched only the name.
      doc = Facet::Document::Create.call(db, domain, doctype, content, sys).as(Facet::Document::Create::Result)
      hidden_doc = doc.projection.id
      Facet::Document::Update.call(db, domain, doctype, hidden_doc, %({"name": "b"}), sys)
        .as(Facet::Document::Update::Result)
      Facet::Document::Update.call(db, domain, doctype, hidden_doc,
        %({"fee": {"value": "2.00", "currency": "EUR"}}), sys)
        .as(Facet::Document::Update::Result)

      history = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: hidden_doc, auth_context: sys).as(Facet::Audit::List::Result)
      rename = history.items.reverse_each.find { |m| m.action == "update" }.should_not be_nil

      denied = Facet::Audit::Rollback.call(db, rename.id, ctx)
      denied.should be_a(Facet::ServiceError)
      denied.as(Facet::ServiceError).status.should eq(403)

      # The same rewind on the visible money member passes.
      doc2 = Facet::Document::Create.call(db, domain, doctype, content, sys).as(Facet::Document::Create::Result)
      visible_doc = doc2.projection.id
      Facet::Document::Update.call(db, domain, doctype, visible_doc, %({"name": "b"}), sys)
        .as(Facet::Document::Update::Result)
      Facet::Document::Update.call(db, domain, doctype, visible_doc,
        %({"public_fee": {"value": "2.00", "currency": "EUR"}}), sys)
        .as(Facet::Document::Update::Result)

      history2 = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: visible_doc, auth_context: sys).as(Facet::Audit::List::Result)
      rename2 = history2.items.reverse_each.find { |m| m.action == "update" }.should_not be_nil

      allowed = Facet::Audit::Rollback.call(db, rename2.id, ctx)
      allowed.should be_a(Facet::Audit::Rollback::Result)
    end
  end

  # ── Trusted lifecycle writes ────────────────────────────────────────

  it "lets defaults, computed values, replication, and hooks populate invisible fields" do
    with_temp_doctype("fvhook") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.create(ctx) ctx.root.salary = 777 end
        return export
      LUA
      fields = %({
        "name": {"type": "string"},
        "salary": {"type": "integer", "tags": ["confidential"], "default": 5}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      role = Facet::RBAC::ActiveRole.new(
        role_id: "fv", visible_tags: Set{"default"},
        permissions: [
          Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"}))),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("fv", role)

      # The caller submits only visible fields; the default and the create
      # hook both populate the invisible one — trusted lifecycle work.
      result = Facet::Document::Create.call(db, domain, doctype, %({"name": "a"}), ctx)
      result.should be_a(Facet::Document::Create::Result)
      content = result.as(Facet::Document::Create::Result).projection.content
      content["salary"].as_i.should eq(777)
    end
  end
end
