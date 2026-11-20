# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-172. The core.SchematicLayout seed — the doctype that carries the
# saved node positions of a domain schematic (one document per target
# domain). Pins the declaration shape the frontend and the retention
# override depend on, then exercises the document pipeline end to end:
# the create/update round-trip, the one-row-per-domain guard, and the
# domain-editor gate the seed's Lua hook enforces.

require "spec"
require "json"
require "yaml"
require "pg"
require "../spec_helper"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "../support/iam_helper"

SEED_DIR = File.join(__DIR__, "..", "..", "data", "seeds", "core.SchematicLayout")

# Loads the definition with the script injected — the same normalization
# the seed loader applies (YamlHelper, then `script` into the content).
private def load_seed_definition : Facet::Doctype::DoctypeDefinition
  defn_raw = File.read(File.join(SEED_DIR, "definition.yml"))
  yaml = YAML.parse(defn_raw)
  content = Facet::Doctype::YamlHelper.to_json_any(yaml).to_json
  script_path = File.join(SEED_DIR, "script.lua")
  if File.exists?(script_path)
    parsed = JSON.parse(content)
    parsed.as_h["script"] = JSON::Any.new(File.read(script_path))
    content = parsed.to_json
  end
  Facet::Doctype::DoctypeDefinition.from_json(content)
end

private def seed_layout_doctype(db : DB::Connection) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "SchematicLayout")
end

# A live target domain with a unique name, so hook lookups resolve.
private def seed_target_domain(db : DB::Connection, name : String) : Nil
  Facet::Mutation::Client.create(db, "core", "Domain", doc_id: name, content: %({}), actioner_id: "system")
end

private def create_layout(db : DB::Connection, domain : String, auth = Facet::RBAC::AuthContext.system)
  Facet::Document::Create.call(
    db, "core", "SchematicLayout",
    %({"domain": "#{domain}", "positions": {"#{domain}.Widget": {"x": 120, "y": 80}}}),
    auth,
  )
end

describe "core.SchematicLayout seed" do
  it "parses as a DoctypeDefinition with the script injected" do
    defn = load_seed_definition
    defn.doctype.should eq("SchematicLayout")
    defn.domain.should eq("core")
    defn.aggregate_root.should be_true
    defn.script.should_not be_nil
  end

  it "declares the domain field: required string, equality filter, slug pattern" do
    field = load_seed_definition.fields["domain"]?
    field.should_not be_nil
    f = field.not_nil!
    f.required.should be_true
    f.type.not_nil!.type_name.should eq("string")
    f.filters.not_nil!.should contain(Facet::Doctype::FilterCapability::Equality)
    f.pattern.should_not be_nil
  end

  it "declares the positions dictionary of {x, y} objects" do
    positions = load_seed_definition.fields["positions"]?
    positions.should_not be_nil
    p = positions.not_nil!
    p.type.not_nil!.type_name.should eq("dictionary")

    value = p.dictionary_value
    value.should_not be_nil
    v = value.not_nil!
    v.type.not_nil!.type_name.should eq("object")
    x = v.properties.not_nil!["x"]?
    y = v.properties.not_nil!["y"]?
    x.should_not be_nil
    y.should_not be_nil
    x.not_nil!.type.not_nil!.type_name.should eq("integer")
    y.not_nil!.type.not_nil!.type_name.should eq("integer")
  end

  it "scopes writes through the domain_editor named scope" do
    defn = load_seed_definition
    scope = defn.scopes["domain_editor"]?
    scope.should_not be_nil
    scope.not_nil!.where.should eq({"domain" => "$editor_domains"})
  end

  it "ships a script.lua with create and update hooks" do
    script = File.read(File.join(SEED_DIR, "script.lua"))
    script.should contain("export.create")
    script.should contain("export.update")
    script.should contain("editor_domains")
  end
end

describe "core.SchematicLayout document pipeline" do
  it "round-trips: create, read back, patch the full positions map" do
    with_db do |db|
      seed_layout_doctype(db)
      domain = "schem#{unique_suffix}"
      seed_target_domain(db, domain)

      created = create_layout(db, domain)
      created.should be_a(Facet::Document::Create::Result)
      doc_id = created.as(Facet::Document::Create::Result).projection.id

      # Read back: the row carries the domain and the positions map.
      projection = Facet::Mutation::Client.fetch_projection(db, "core", "SchematicLayout", doc_id)
      projection.content["domain"].as_s.should eq(domain)
      projection.content["positions"].as_h["#{domain}.Widget"].as_h["x"].as_i.should eq(120)

      # Patch: the frontend writes the full map; a new doctype key lands.
      patch = Facet::Document::Update.call(
        db, "core", "SchematicLayout", doc_id,
        %({"positions": {"#{domain}.Widget": {"x": 200, "y": 60}, "#{domain}.Other": {"x": 1, "y": 2}}}),
        Facet::RBAC::AuthContext.system,
      )
      patch.should be_a(Facet::Document::Update::Result)
      updated = Facet::Mutation::Client.fetch_projection(db, "core", "SchematicLayout", doc_id)
      updated.content["positions"].as_h.size.should eq(2)
      updated.content["positions"].as_h["#{domain}.Widget"].as_h["x"].as_i.should eq(200)
    end
  end

  it "refuses a second layout row for the same domain (create hook)" do
    with_db do |db|
      seed_layout_doctype(db)
      domain = "schem#{unique_suffix}"
      seed_target_domain(db, domain)

      create_layout(db, domain).should be_a(Facet::Document::Create::Result)

      duplicate = create_layout(db, domain)
      duplicate.should be_a(Facet::ServiceError)
      err = duplicate.as(Facet::ServiceError)
      err.status.should eq(422)
      details = err.details.try(&.map(&.message).join("; ")) || ""
      details.should contain("exactly one layout")
    end
  end

  it "refuses a layout naming a domain that does not exist" do
    with_db do |db|
      seed_layout_doctype(db)
      ghost = create_layout(db, "no_such_domain#{unique_suffix}")
      ghost.should be_a(Facet::ServiceError)
      ghost.as(Facet::ServiceError).status.should eq(422)
    end
  end

  it "denies a scoped domain editor outside their domains and admits a member" do
    with_db do |db|
      restore_seeded_baseline(db)
      member_domain = "schem#{unique_suffix}"
      other_domain = "schem#{unique_suffix}"
      seed_target_domain(db, member_domain)
      seed_target_domain(db, other_domain)

      ensure_iam_account(db, "acc_schem_member")
      ensure_iam_account(db, "acc_schem_outsider")
      Facet::Document::Create.call(
        db, "core", "DomainEditor",
        %({"account": "iam.Account.acc_schem_member", "domain": "#{member_domain}"}),
        Facet::RBAC::AuthContext.system,
      )

      role = Facet::RBAC::ActiveRole.from_projection_content(
        Facet::Mutation::Client.fetch_content(db, "iam", "Roles", "iam.Roles.editor")
      )
      member = Facet::RBAC::AuthContext.authenticated("acc_schem_member", role)
      outsider = Facet::RBAC::AuthContext.authenticated("acc_schem_outsider", role)

      # A member editor lays out their own domain…
      own = create_layout(db, member_domain, member)
      own.should be_a(Facet::Document::Create::Result)

      # …and cannot retarget the row at (or create a row for) a domain
      # they do not edit. The update gate reads the merged content.
      doc_id = own.as(Facet::Document::Create::Result).projection.id
      retarget = Facet::Document::Update.call(
        db, "core", "SchematicLayout", doc_id,
        %({"domain": "#{other_domain}"}),
        member,
      )
      retarget.should be_a(Facet::ServiceError)
      retarget.as(Facet::ServiceError).status.should eq(422)

      # A non-member editor is denied outright (fail closed).
      denied = create_layout(db, other_domain, outsider)
      denied.should be_a(Facet::ServiceError)
      denied.as(Facet::ServiceError).status.should eq(422)
    end
  end
end
