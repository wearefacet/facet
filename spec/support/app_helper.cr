# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── App test helpers ─────────────────────────────────────────────────────────
#
# Re-registers the doctype definitions that the `app.App` integration
# specs rely on. The global per-example TRUNCATE in spec_helper.cr wipes
# `projections`, so the seeded `core.DocType`, `core.Domain`, and `app.App`
# definitions are gone before each example. Re-running the full
# `Doctype::Seed.seed` per example is wasteful; this helper restores only
# the meta rows and the `app.*` definitions each example touches.

require "../../src/doctype"
require "../../src/doctype/seed"
require "../../src/mutation/client"
require "../../src/document/create"

# Reads the doctype seed definitions (and their co-located scripts when
# present) and persists the `core.DocType` rows. Shared seed loop used by
# the helpers below.
private def seed_doctype_rows(db : DB::Connection, qualified_list : Array(String)) : Nil
  qualified_list.uniq.each do |qualified|
    next if doctype_row_exists?(db, qualified)

    domain = qualified.split('.', 2)[0]
    path = File.join(__DIR__, "..", "..", "data", "seeds", qualified, "definition.yml")
    next unless File.exists?(path)

    yaml = YAML.parse(File.read(path))
    json_any = Facet::Doctype::YamlHelper.to_json_any(yaml)

    # Inject an optional co-located script.lua exactly like Doctype::Seed.
    script_path = File.join(__DIR__, "..", "..", "data", "seeds", qualified, "script.lua")
    if File.exists?(script_path)
      hash = json_any.as_h
      hash["script"] = JSON::Any.new(File.read(script_path))
      json_any = JSON::Any.new(hash)
    end

    # Stamp the derived per-field `operators` member — the helper mirrors
    # `Doctype::Seed.seed_definition`'s raw create, which stamps the same
    # member (the frontend filter bar reads it; a definition without it is
    # silently non-filterable in the UI).
    json_any = Facet::Doctype::DerivedOperators.apply(json_any)

    meta = %({"parent_id": #{domain.to_json}})
    Facet::Mutation::Client.create(
      db, "core", "DocType",
      doc_id: qualified,
      content: json_any.to_json,
      meta: meta,
      actioner_id: "system",
    )
    Facet::Doctype::DefinitionStore.invalidate(qualified)
  end
end

# Re-registers the meta doctype definitions (`core.DocType`, `core.Domain`)
# and the `app` domain row + `app.App` doctype definition, wiped by the
# per-example TRUNCATE. Idempotent: a row that already exists is skipped.
def seed_app_doctypes(db : DB::Connection) : Nil
  seed_doctype_rows(db, ["core.DocType", "core.Domain", "app.App", "app.Deployment"])

  # The `app` core.Domain document (id="app") is created separately
  # because it lives in domain `core`, doctype `Domain`, not in
  # `core.DocType` like the definitions above.
  seed_app_domain_row(db)
end

# Seeds the four doctypes OAuth specs touch that are wiped by the per-example
# TRUNCATE: `iam.Account`, `iam.Roles`, `iam.LoginEvent` (auth audit), and
# `app.App`. Idempotent — a row that already exists is skipped. Use this in
# conjunction with `seed_app_doctypes` (which restores `core.DocType`, `core.Domain`,
# and the `app` domain row) to bring the OAuth integration spec up to the
# baseline the `db_reset` template already establishes.
def seed_iam_doctypes(db : DB::Connection) : Nil
  seed_doctype_rows(db, ["iam.Account", "iam.Roles", "iam.LoginEvent"])

  # Ensure the `iam` domain row exists — same shape as the `app` row.
  seed_iam_domain_row(db)
end

# Returns true if the `core.DocType` row for the given qualified id
# already exists and is not deleted. Mirrors Doctype::Seed.doctype_exists?.
private def doctype_row_exists?(db : DB::Connection, qualified : String) : Bool
  result = db.query_one?(
    "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1 AND deleted_at IS NULL",
    qualified,
    as: Int32,
  )
  !result.nil?
end

# Creates the `app` row on `core.Domain` (id="app"), idempotently.
private def seed_app_domain_row(db : DB::Connection) : Nil
  existing = db.query_one?(
    "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'app' AND deleted_at IS NULL",
    as: Int32,
  )
  return unless existing.nil?

  # Match the seed values in data/seeds/core.Domain/documents.yml so the
  # database (template or worker) stays consistent regardless of which
  # path loaded the app domain row first.
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: "app",
    content: %({"color": "#7B1FA2"}),
    actioner_id: "system",
  )
end

# Creates the `iam` row on `core.Domain` (id="iam"), idempotently.
private def seed_iam_domain_row(db : DB::Connection) : Nil
  existing = db.query_one?(
    "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'iam' AND deleted_at IS NULL",
    as: Int32,
  )
  return unless existing.nil?

  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: "iam",
    content: %({"color": "#009688"}),
    actioner_id: "system",
  )
end

# Seeds the `facet-cli` app document from `data/seeds/app.App/documents.yml`
# through the real document pipeline — the same path `Doctype::Seed` uses —
# so the row matches a fresh seed exactly (hook-assigned `client_id`
# included). Call it after `seed_app_doctypes` (the `app.App` definition).
def seed_facet_cli_app(db : DB::Connection) : Facet::Mutation::Client::Projection
  path = File.join(__DIR__, "..", "..", "data", "seeds", "app.App", "documents.yml")
  docs = YAML.parse(File.read(path))
  entry = docs.as_a.find { |d| d["id"].as_s == "facet-cli" }
  raise "facet-cli entry missing in data/seeds/app.App/documents.yml" if entry.nil?
  content = Facet::Doctype::YamlHelper.to_json_any(entry["content"]).to_json

  result = Facet::Document::Create.call(
    db, "app", "App", content, Facet::RBAC::AuthContext.system, doc_id: "facet-cli")
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection
end
