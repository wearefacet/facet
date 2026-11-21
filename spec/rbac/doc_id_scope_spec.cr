# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/mutation/client"
require "../../src/document"
require "../support/rbac_helper"

# The `$doc_id` reserved field token: a named-scope `where` field (and a
# context-set `select`/`where` field) that reads the row's own
# `projections.id`. Covers the SQL compilation, the single-row gate, the
# list path, and the context-set select projection.
#
# The fixture mirrors the seeded domain-editor scopes: a `core.Domain`-like
# row whose identity lives in the row id, not in content.
private def create_doc_id_fixture(db) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "Domain")
  Facet::Doctype::Seed.ensure_doctype(db, "core", "DomainEditor")
  Facet::Doctype::Seed.ensure_doctype(db, "core", "DocType")

  # The context sets on the `core` domain document (the seed normally
  # carries them; re-create explicitly so the fixture is self-contained).
  core_content = Facet::Mutation::Client.fetch_content(db, "core", "Domain", "core")
  core_h = core_content.as_h
  core_h["context_sets"] = JSON.parse(
    <<-YAML
      {
        "editor_domains":       {"from": "DomainEditor", "select": "domain", "where": {"account": "$self"}},
        "editor_doctypes":      {"from": "DocType", "select": "$doc_id", "where": {"domain": "$editor_domains"}},
        "editor_draft_domains": {"from": "Domain", "select": "$doc_id", "where": {"$doc_id": "$editor_domains", "draft": "true"}}
      }
    YAML
  )
  Facet::Document::Update.call(db, "core", "Domain", "core", core_h.to_json, Facet::RBAC::AuthContext.system)

  # Two domains — one live, one draft — and one editor grant on each.
  Facet::Mutation::Client.create(db, "core", "Domain", doc_id: "live1", content: %({}), actioner_id: "system")
  Facet::Mutation::Client.create(db, "core", "Domain", doc_id: "_draft1", content: %({"draft": true}), actioner_id: "system")
  Facet::Mutation::Client.create(db, "core", "DomainEditor",
    doc_id: "de_live1_#{unique_suffix}",
    content: %({"account": "iam.Account.acc_1", "domain": "live1"}),
    actioner_id: "system",
  )
  Facet::Mutation::Client.create(db, "core", "DomainEditor",
    doc_id: "de_draft1_#{unique_suffix}",
    content: %({"account": "iam.Account.acc_1", "domain": "_draft1"}),
    actioner_id: "system",
  )
end

# A role whose `read`/`update core.Domain` grants are scoped to
# `$domain_editor`.
private def doc_id_role_ctx(db, account_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "domain_editor",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [
      Facet::RBAC::Permission.new(action: "update", domain: "core", path: ["Domain"], scope: ["$domain_editor"]),
      Facet::RBAC::Permission.new(action: "read", domain: "core", path: ["Domain"], scope: ["$domain_editor"]),
    ],
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

module Facet::RBAC
  describe "ScopePredicateSql $doc_id field expression" do
    it "compiles the token to the row id column" do
      ScopePredicateSql.field_expr("$doc_id", "test").should eq("id")
    end

    it "keeps content fields on the content extraction" do
      ScopePredicateSql.field_expr("domain", "test").should eq("content->>'domain'")
    end
  end

  describe "$doc_id in named scopes (single-row gate)" do
    before_each do
      with_db do |db|
        create_doc_id_fixture(db)
      end
    end

    it "matches when the row id is in the resolved context set" do
      with_db do |db|
        ctx = doc_id_role_ctx(db, "acc_1")
        WriteEnforcer.authorize_update(db, "core", "Domain", "live1", ctx)
          .should be_true
      end
    end

    it "does not match a row outside the context set" do
      with_db do |db|
        Facet::Mutation::Client.create(db, "core", "Domain", doc_id: "other", content: %({}), actioner_id: "system")
        ctx = doc_id_role_ctx(db, "acc_1")
        WriteEnforcer.authorize_update(db, "core", "Domain", "other", ctx)
          .should be_false
      end
    end

    it "resolves the draft subset through the chained context set" do
      with_db do |db|
        # The draft-scoped scope (delete) matches the draft, not the live
        # domain — the `draft: "true"` filter lives inside the
        # `editor_draft_domains` context set (SQL-only, text comparison).
        role = ActiveRole.new(
          role_id: "draft_discarder",
          visible_tags: ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [
            Permission.new(action: "delete", domain: "core", path: ["Domain"], scope: ["$domain_editor_draft"]),
          ],
        )
        ctx = AuthContext.authenticated("acc_1", role)
        WriteEnforcer.authorize_delete(db, "core", "Domain", "_draft1", ctx).should be_true
        WriteEnforcer.authorize_delete(db, "core", "Domain", "live1", ctx).should be_false
      end
    end
  end

  describe "$doc_id in named scopes (SQL list path)" do
    before_each do
      with_db do |db|
        create_doc_id_fixture(db)
      end
    end

    it "compiles the token against projections.id for scoped lists" do
      with_db do |db|
        ctx = doc_id_role_ctx(db, "acc_1")
        clauses, _params = ReadEnforcer.list_where_clauses(db, "core", "Domain", ctx)
        clauses.size.should eq(1)
        clauses.first.should contain("id = ANY(")

        # The observable behaviour of the compiled clause: a scoped list
        # returns exactly the granted rows.
        listed = Facet::Document::List.call(
          db, "core", "Domain",
          filters: {} of String => JSON::Any,
          sort: ["id"],
          page: 1,
          items_per_page: 100,
          auth_context: ctx,
        )
        listed.should be_a(Facet::Document::List::Result)
        listed.as(Facet::Document::List::Result).items.map(&.id).sort!
          .should eq(["_draft1", "live1"])
      end
    end

    it "returns the fail-closed empty clause for a caller with no grants" do
      with_db do |db|
        role = ActiveRole.new(
          role_id: "outsider",
          visible_tags: ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [
            Permission.new(action: "update", domain: "core", path: ["Domain"], scope: ["$domain_editor"]),
          ],
        )
        ctx = AuthContext.authenticated("acc_nobody", role)
        clauses, params = ReadEnforcer.list_where_clauses(db, "core", "Domain", ctx)
        clauses.should eq(["1=0"])
        params.should be_empty
      end
    end
  end

  describe "$doc_id in context-set select" do
    before_each do
      with_db do |db|
        create_doc_id_fixture(db)
      end
    end

    it "projects the row id into the resolved set" do
      with_db do |db|
        # A doctype inside a granted domain — editor_doctypes selects the
        # qualified row ids of the granted domains' doctypes.
        result = Facet::Document::Create.call(
          db, "core", "DocType",
          %({"doctype": "Widget", "domain": "live1", "schema_version": 1, "fields": {}}),
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::Document::Create::Result)

        scope_context = ScopeContext.load(db, "acc_1")
        results = ContextResolver.resolve_for_domain(db, "core", scope_context)
        results["editor_domains"]?.try(&.sort!).should eq(["_draft1", "live1"])
        # editor_doctypes selects $doc_id over core.DocType rows — the
        # qualified ids of the granted domains' doctypes.
        results["editor_doctypes"]?.should eq(["live1.Widget"])
        # editor_draft_domains chains the root set through the draft filter.
        results["editor_draft_domains"]?.should eq(["_draft1"])
      end
    end
  end

  describe "authoring-time validation" do
    it "accepts $doc_id with eq in named scopes" do
      with_db do |db|
        create_doc_id_fixture(db)
        fetched = Doctype::DefinitionStore.fetch(db, "core.Domain")
        fetched.should_not be_nil
        definition = fetched.not_nil!
        domain_content = ContextResolver.fetch_domain_content(db, "core")
        domain_sets = ContextResolver.extract_context_sets(domain_content)

        errors = [] of ValidationError
        Validator.validate_named_scopes(definition, domain_sets, errors)
        errors.should be_empty
      end
    end

    it "rejects $doc_id with operators other than eq/ne" do
      with_db do |db|
        create_doc_id_fixture(db)
        fetched = Doctype::DefinitionStore.fetch(db, "core.Domain")
        fetched.should_not be_nil
        definition = fetched.not_nil!
        domain_content = ContextResolver.fetch_domain_content(db, "core")
        domain_sets = ContextResolver.extract_context_sets(domain_content)

        named = Doctype::NamedScope.new(
          name: "bad_token_op",
          where: {"$doc_id__starts_with" => "_"},
        )
        definition_with_scope = definition.class.new(
          doctype: definition.doctype, domain: definition.domain,
          schema_version: definition.schema_version,
          fields: definition.fields, scopes: {"bad_token_op" => named},
        )
        errors = [] of ValidationError
        Validator.validate_named_scopes(definition_with_scope, domain_sets, errors)
        errors.should_not be_empty
        errors.first.message.should contain("eq/ne")
      end
    end

    it "rejects $doc_id in context-set where maps with other operators" do
      parsed = JSON.parse(
        %({"context_sets": {"bad": {"from": "Domain", "select": "$doc_id", "where": {"$doc_id__match": "_"}}}}),
      )
      sets = ContextResolver.extract_context_sets(parsed)
      errors = [] of ValidationError
      Validator.validate_context_set_definitions(parsed, "core", sets, errors)
      errors.should_not be_empty
      # The suffixed reserved token fails the SQL-safety gate (the raw key
      # is not a bare token); rejection — not the message layer — is the
      # contract here.
      errors.first.message.should contain("$doc_id__match")
    end

    it "accepts $doc_id in context-set select and where" do
      parsed = JSON.parse(
        %({"context_sets": {"ok": {"from": "Domain", "select": "$doc_id", "where": {"$doc_id": "$other"}}}}),
      )
      sets = ContextResolver.extract_context_sets(parsed)
      # Declare the dependency so the value-grammar check resolves it.
      sets["other"] = ContextSet.new(name: "other", from: "Domain", where: {"draft" => "true"}, select_field: "id")
      errors = [] of ValidationError
      Validator.validate_context_set_definitions(parsed, "core", sets, errors)
      errors.should be_empty
    end
  end
end
