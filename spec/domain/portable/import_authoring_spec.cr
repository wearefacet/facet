# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"

require "../../../src/domain"
require "../../../src/domain/portable"
require "../../../src/doctype"
require "../../../src/doctype/seed"
require "../../../src/document"
require "../../../src/mutation/client"
require "../../../src/rbac"

# Specs for the authoring gate on the portable-domain import door (B-277).
# A bundled row bypasses the document pipeline, so the authoring validation
# the API runs on `iam.Roles`, `core.DomainGrant`, `app.App`, and
# `core.Domain` never sees it. The import re-runs the same public
# validators and refuses the bundle with a 422 that names the offending
# row. Without this, an import can land a state the API refuses to re-save.
#
# Each example re-seeds the core doctypes (the global per-spec truncation
# wipes them) and builds its bundle in memory — no fixture files.

# Re-registers the core doctypes that the global truncation wiped.
private def authoring_reseed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# Wraps raw content/meta strings into a bundle entry.
private def authoring_entry(content : String, meta : String = "{}") : Facet::Domain::Portable::Archive::Entry
  Facet::Domain::Portable::Archive::Entry.new(JSON.parse(content), JSON.parse(meta))
end

# One bundled document row as the `documents` map entry: `qualified` is the
# bundle's doctype key, `id` the document id.
private def authoring_document(qualified : String, id : String, content : String, meta : String = "{}") : Hash(String, Array(Facet::Domain::Portable::Archive::DocumentEntry))
  {qualified => [Facet::Domain::Portable::Archive::DocumentEntry.new(id, authoring_entry(content, meta))]}
end

# An in-memory bundle for `domain` with the given document rows and no
# doctype entries — the gate under test fires on document rows and on the
# domain row, both of which the core seed makes importable.
private def authoring_bundle(
  domain : String,
  documents : Hash(String, Array(Facet::Domain::Portable::Archive::DocumentEntry)),
  domain_content : String = AUTHORING_DOMAIN_CONTENT,
) : Facet::Domain::Portable::Archive::Bundle
  Facet::Domain::Portable::Archive::Bundle.new(
    source_domain: domain,
    exported_at: "2026-01-01T00:00:00Z",
    facet_version: "test",
    domain: authoring_entry(domain_content),
    doctypes: [] of {doctype: String, entry: Facet::Domain::Portable::Archive::Entry},
    document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
    collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
    documents: documents,
  )
end

# Domain content that passes the gate: one well-formed context set (the
# `my_teams` shape the production fixture uses).
AUTHORING_DOMAIN_CONTENT = %({
  "description": "authoring gate bundle",
  "color": "#123456",
  "context_sets": {
    "my_teams": {"from": "TeamMember", "select": "$parent_id", "where": {"account": "$self"}}
  }
})

# A role whose permission rows all pass the gate. The first row is
# unrestricted; the second is the wildcard-with-carve-out form the
# permission spec pins as valid.
AUTHORING_VALID_ROLE = %({
  "level": 20,
  "name": "authoring_viewer",
  "permissions": [
    {"on": "iam.Account", "action": "read"},
    {"on": "*.*", "action": "read", "except": ["core.Domain", "core.DocType"]}
  ],
  "visible_tags": ["default"]
})

# The B-277 row shape: a permission line with no `on` (what YAML 1.1 makes
# of an unquoted `on:` key).
AUTHORING_ROLE_MISSING_ON = %({
  "level": 20,
  "name": "authoring_broken",
  "permissions": [
    {"on": "iam.Account", "action": "read"},
    {"action": "delete", "scope": ["$mine"]}
  ],
  "visible_tags": ["default"]
})

# A scoped row whose target doctype is not registered — the same
# forward-reference refusal the API enforces at authoring time.
AUTHORING_ROLE_UNKNOWN_SCOPE = %({
  "level": 20,
  "name": "authoring_scoped",
  "permissions": [
    {"on": "authcheck.Widget", "action": "read", "scope": ["$mine"]}
  ],
  "visible_tags": ["default"]
})

# An app whose grants all parse and name concrete targets.
AUTHORING_VALID_APP = %({
  "slug": "authoring-app",
  "name": "Authoring App",
  "grants": [
    {"target": "crm.Company", "actions": [{"name": "read", "required": true}]}
  ]
})

# The wildcard grant form the authoring gate refuses.
AUTHORING_APP_WILDCARD_GRANT = %({
  "slug": "authoring-wild-app",
  "name": "Authoring Wild App",
  "grants": [
    {"target": "crm.*", "actions": [{"name": "read", "required": true}]}
  ]
})

# A grant row that passes the gate: consumer differs from the parent
# (producer) domain, resources well-formed.
AUTHORING_VALID_GRANT = %({
  "consumer_domain": "otherdom",
  "resources": [
    {"doctype": "Thing", "tags": ["default"]}
  ]
})

# A self-grant — consumer equals the parent domain the grant is filed under.
AUTHORING_GRANT_SELF = %({
  "consumer_domain": "authcheck",
  "resources": [
    {"doctype": "Thing", "tags": ["default"]}
  ]
})

# A context set whose `select` field is not a SQL-safe identifier.
AUTHORING_DOMAIN_BAD_CONTEXT_SET = %({
  "description": "bad context set",
  "color": "#123456",
  "context_sets": {
    "leaky": {"from": "TeamMember", "select": "1; drop table projections", "where": {"account": "$self"}}
  }
})

# A context set missing its required `from` key — `extract_context_sets`
# raises on it, and the gate must turn that into an import error, not a
# crash.
AUTHORING_DOMAIN_INCOMPLETE_CONTEXT_SET = %({
  "description": "incomplete context set",
  "color": "#123456",
  "context_sets": {
    "incomplete": {"where": {"account": "$self"}}
  }
})

describe "Domain::Portable import authoring gate (B-277)" do
  it "refuses an iam.Roles row whose permission is missing 'on' (422, names the row)" do
    with_db do |db|
      authoring_reseed_core(db)

      bundle = authoring_bundle("authcheck",
        authoring_document("iam.Roles", "iam.Roles.broken_row", AUTHORING_ROLE_MISSING_ON))

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("iam.Roles")
      err.message.should contain("iam.Roles.broken_row")
      err.message.should contain("RBAC permission validation failed")
      err.message.should contain("Permission missing 'on'")

      # All-or-nothing: the domain row rolled back with the document.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'authcheck'",
        as: Int64
      ).should eq(0)
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.broken_row'",
        as: Int64
      ).should eq(0)
    end
  end

  it "refuses an iam.Roles row whose scope references an unregistered doctype (422)" do
    with_db do |db|
      authoring_reseed_core(db)

      bundle = authoring_bundle("authcheck",
        authoring_document("iam.Roles", "iam.Roles.scoped_row", AUTHORING_ROLE_UNKNOWN_SCOPE))

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("iam.Roles.scoped_row")
      err.message.should contain("not registered")
    end
  end

  it "refuses a bad iam.Roles row on a --merge import (the fixture-loader path)" do
    with_db do |db|
      authoring_reseed_core(db)

      clean = authoring_bundle("authcheck",
        authoring_document("iam.Roles", "iam.Roles.good_row", AUTHORING_VALID_ROLE))
      clean_result = Facet::Domain::Portable::Import.call(db, clean)
      clean_result.should be_a(Facet::Domain::Portable::Import::Result)
      clean_result.as(Facet::Domain::Portable::Import::Result).documents_created.should eq(1)

      bad = authoring_bundle("authcheck",
        authoring_document("iam.Roles", "iam.Roles.broken_row", AUTHORING_ROLE_MISSING_ON))
      result = Facet::Domain::Portable::Import.call(db, bad, merge: true)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("iam.Roles.broken_row")

      # The merge rolled back: the earlier clean row survives, the bad row
      # never landed.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.good_row'",
        as: Int64
      ).should eq(1)
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.broken_row'",
        as: Int64
      ).should eq(0)
    end
  end

  it "still imports valid iam.Roles, app.App, and core.DomainGrant rows (no false rejection)" do
    with_db do |db|
      authoring_reseed_core(db)

      documents = authoring_document("iam.Roles", "iam.Roles.authoring_viewer", AUTHORING_VALID_ROLE)
      documents.merge!(authoring_document("app.App", "authoring_app_row", AUTHORING_VALID_APP))
      documents.merge!(authoring_document("core.DomainGrant", "authoring_grant_row", AUTHORING_VALID_GRANT,
        %({"parent_id": "core.Domain.authcheck"})))
      bundle = authoring_bundle("authcheck", documents)

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::Domain::Portable::Import::Result)
      res = result.as(Facet::Domain::Portable::Import::Result)
      res.documents_created.should eq(3)

      db.query_one(
        "SELECT count(*) FROM projections WHERE (domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.authoring_viewer')" \
        " OR (domain = 'app' AND doc_type = 'App' AND id = 'authoring_app_row')" \
        " OR (domain = 'core' AND doc_type = 'DomainGrant' AND id = 'authoring_grant_row')",
        as: Int64
      ).should eq(3)
    end
  end

  it "refuses an app.App row with a wildcard grant target (422, names the row)" do
    with_db do |db|
      authoring_reseed_core(db)

      bundle = authoring_bundle("authcheck",
        authoring_document("app.App", "authoring_wild_app", AUTHORING_APP_WILDCARD_GRANT))

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("app.App#authoring_wild_app")
      err.message.should contain("Grant validation failed")
      err.message.should contain("Wildcard grant target")
    end
  end

  it "refuses a core.DomainGrant self-grant (422, names the row)" do
    with_db do |db|
      authoring_reseed_core(db)

      bundle = authoring_bundle("authcheck",
        authoring_document("core.DomainGrant", "authoring_self_grant", AUTHORING_GRANT_SELF,
          %({"parent_id": "core.Domain.authcheck"})))

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("core.DomainGrant#authoring_self_grant")
      err.message.should contain("self-grant")
    end
  end

  it "refuses a core.Domain whose context set has a non-SQL-safe select field (422, names the domain)" do
    with_db do |db|
      authoring_reseed_core(db)

      bundle = authoring_bundle("authcheck",
        {} of String => Array(Facet::Domain::Portable::Archive::DocumentEntry),
        domain_content: AUTHORING_DOMAIN_BAD_CONTEXT_SET)

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("core.Domain 'authcheck'")
      err.message.should contain("SQL-safe identifier")

      # Nothing landed — not even the domain row.
      db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = 'authcheck'",
        as: Int64
      ).should eq(0)
    end
  end

  it "refuses a core.Domain whose context set is missing 'from' with an import error, not a crash" do
    with_db do |db|
      authoring_reseed_core(db)

      bundle = authoring_bundle("authcheck",
        {} of String => Array(Facet::Domain::Portable::Archive::DocumentEntry),
        domain_content: AUTHORING_DOMAIN_INCOMPLETE_CONTEXT_SET)

      result = Facet::Domain::Portable::Import.call(db, bundle)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("core.Domain 'authcheck'")
      err.message.should contain("missing 'from'")
    end
  end
end
