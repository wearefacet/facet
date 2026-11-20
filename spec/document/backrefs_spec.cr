# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/iam"
require "../../src/document"
require "../../src/rbac/auth_context"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# `Document::Backrefs` — the shared service behind the MCP `get_backrefs`
# tool and the HTTP `GET|QUERY /Api/:domain/:doctype/:id/backrefs` endpoint.
#
# Acceptance:
# - The fan-out covers every readable `(domain, doctype)` pair, across
#   domains, and carries the stub-row shape (`display_name` included).
# - The referrer side skips unreadable doctypes, AND-composes each readable
#   doctype's list scope, and excludes tombstoned rows.
# - A `?state=`-pinned reference is a distinct URN from the live one.
# - The target read gate is one non-disclosing `NotFound` (missing or denied).
# - `capped` reports honestly when the result set reaches the limit.
describe Facet::Document::Backrefs do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "finds referencing documents across doctypes in one call" do
    with_db do |db|
      domain, team_dt, project_dt, task_dt = build_backref_fixture(db)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Create.call(db, domain, project_dt, %({"name": "P1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, domain, task_dt, %({"name": "T1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      ctx = build_context(db, "iam.Roles.viewer")

      result = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, team.id)
      result.should be_a(Facet::Document::Backrefs::Result)
      r = result.as(Facet::Document::Backrefs::Result)
      r.items.size.should eq(2)
      r.items.map(&.doc_type).sort!.should eq(["Project", "Task"])
      r.target_urn.should eq("urn:facet:#{domain}:#{team_dt}:#{team.id}")
      r.capped.should be_false

      # The label rides every stub row — null here, because the fixture
      # doctypes declare no display_name template.
      r.items.each(&.display_name.should(be_nil))
    end
  end

  it "carries the display_name of referrers whose doctype declares a template" do
    with_db do |db|
      domain, team_dt, _project_dt, _task_dt = build_backref_fixture(db)
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Labelled", "domain": "#{domain}", "aggregate_root": true,
        "display_name": "{{ name }}",
        "fields": {
          "name": {"type": "string", "required": true},
          "team": {"type": "reference", "doctype": "#{domain}.#{team_dt}"}
        }
      }), Facet::RBAC::AuthContext.system)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Create.call(db, domain, "Labelled", %({"name": "L1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      ctx = build_context(db, "iam.Roles.viewer")

      r = Facet::Document::Backrefs.call(db, ctx, domain, "Team", team.id).as(Facet::Document::Backrefs::Result)
      r.items.size.should eq(1)
      r.items.first.display_name.should eq("L1")
    end
  end

  it "includes a referrer from another domain" do
    with_db do |db|
      domain, team_dt, project_dt, _task_dt = build_backref_fixture(db)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

      # A second domain whose doctype references the cross-domain target.
      ensure_domain(db, "mcpbackx")
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Note", "domain": "mcpbackx", "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string", "required": true},
          "team": {"type": "reference", "doctype": "#{domain}.#{team_dt}"}
        }
      }), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, "mcpbackx", "Note", %({"name": "N1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, domain, project_dt, %({"name": "P1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)

      ctx = build_context(db, "iam.Roles.viewer")
      r = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, team.id).as(Facet::Document::Backrefs::Result)
      domains = r.items.map(&.domain).sort!.uniq!
      domains.should eq(["mcpback", "mcpbackx"])
    end
  end

  it "skips a doctype the role cannot read" do
    with_db do |db|
      domain, team_dt, project_dt, task_dt = build_backref_fixture(db)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Create.call(db, domain, project_dt, %({"name": "P1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, domain, task_dt, %({"name": "T1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)

      # Reader may read the Team target and Project, but not Task — the
      # Task referrer contributes nothing (silently skipped).
      role = Facet::RBAC::ActiveRole.new(
        role_id: "mcpback.reader",
        visible_tags: Set.new(["default"]),
        permissions: [
          Facet::RBAC::Permission.new(action: "read", domain: domain, path: [team_dt]),
          Facet::RBAC::Permission.new(action: "read", domain: domain, path: ["Project"]),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated(create_test_account(db), role)

      r = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, team.id).as(Facet::Document::Backrefs::Result)
      r.items.map(&.doc_type).should eq(["Project"])
    end
  end

  it "narrows referrers by the role's scoped read permission" do
    with_db do |db|
      domain, team_dt, _project_dt, _task_dt = build_backref_fixture(db)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection

      # A referrer doctype declaring a named scope over `name`, plus two
      # rows that split on it.
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Scoped", "domain": "#{domain}", "aggregate_root": true,
        "display_name": "{{ name }}",
        "fields": {
          "name": {"type": "string", "required": true},
          "team": {"type": "reference", "doctype": "#{domain}.#{team_dt}"}
        },
        "scopes": {"pub": {"where": {"name": "Public"}, "description": "Public rows"}}
      }), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, domain, "Scoped", %({"name": "Public", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, domain, "Scoped", %({"name": "Private", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)

      # The role reads the target unrestricted and the referrer only
      # through its `pub` scope — the AND-composition hides "Private".
      ctx = build_context_with_permissions(db, [
        {"action" => "read", "on" => "#{domain}.#{team_dt}"},
        {"action" => "read", "on" => "#{domain}.Scoped", "scope" => "pub"},
      ])

      r = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, team.id).as(Facet::Document::Backrefs::Result)
      r.items.size.should eq(1)
      r.items.first.display_name.should eq("Public")
    end
  end

  it "excludes a tombstoned referrer" do
    with_db do |db|
      domain, team_dt, project_dt, _task_dt = build_backref_fixture(db)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Create.call(db, domain, project_dt, %({"name": "Keep", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      gone = Facet::Document::Create.call(db, domain, project_dt, %({"name": "Gone", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Delete.call(db, domain, project_dt, gone.id, Facet::RBAC::AuthContext.system)
      ctx = build_context(db, "iam.Roles.viewer")

      r = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, team.id).as(Facet::Document::Backrefs::Result)
      r.items.size.should eq(1)
      r.items.first.id.should_not eq(gone.id)
    end
  end

  it "does not match a state-pinned URN against the live document" do
    with_db do |db|
      domain, team_dt, project_dt, _task_dt = build_backref_fixture(db)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Create.call(db, domain, project_dt, %({"name": "P1", "team": "#{team.id}?state=01ARBDEMO0000000000000000"}), Facet::RBAC::AuthContext.system)
      ctx = build_context(db, "iam.Roles.viewer")

      r = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, team.id).as(Facet::Document::Backrefs::Result)
      # The pinned reference is a distinct URN — it does not match the
      # live target.
      r.items.size.should eq(0)
    end
  end

  it "answers NotFound for a missing target (non-disclosing)" do
    with_db do |db|
      domain, team_dt, _project_dt, _task_dt = build_backref_fixture(db)
      ctx = build_context(db, "iam.Roles.viewer")

      result = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, "absent")
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(404)
    end
  end

  it "answers 403 for a caller with no read grant on the target doctype" do
    with_db do |db|
      domain, team_dt, project_dt, _task_dt = build_backref_fixture(db)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Create.call(db, domain, project_dt, %({"name": "P1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)

      # The role reads Project but holds no Team grant — a class-level
      # denial on the target doctype, answered 403 like the read side.
      # A grant holder that cannot see the target keeps the
      # non-disclosing 404, and no referrer row may leak either way.
      role = Facet::RBAC::ActiveRole.new(
        role_id: "mcpback.denied",
        visible_tags: Set.new(["default"]),
        permissions: [
          Facet::RBAC::Permission.new(action: "read", domain: domain, path: ["Project"]),
        ],
      )
      ctx = Facet::RBAC::AuthContext.authenticated(create_test_account(db), role)

      result = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, team.id)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(403)
    end
  end

  it "reports capped honestly when the limit is reached" do
    with_db do |db|
      domain, team_dt, project_dt, task_dt = build_backref_fixture(db)
      team = Facet::Document::Create.call(db, domain, team_dt, %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Create.call(db, domain, project_dt, %({"name": "P1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, domain, task_dt, %({"name": "T1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
      ctx = build_context(db, "iam.Roles.viewer")

      r = Facet::Document::Backrefs.call(db, ctx, domain, team_dt, team.id, limit: 1).as(Facet::Document::Backrefs::Result)
      r.items.size.should eq(1)
      r.capped.should be_true
    end
  end

  # B-99: a preview principal on a draft domain must not 500. The fan-out
  # walks `readable_doctypes`, which now branches on `preview?` and returns
  # only the bound draft's doctypes — a draft Project referrer comes back,
  # nothing from other domains, no exception.
  it "answers a preview principal with the bound draft's referrers only" do
    with_db do |db|
      draft = "_#{unique_suffix(12)}"
      Facet::Mutation::Client.create(
        db, "core", "Domain", doc_id: draft, content: %({"draft": true}),
        actioner_id: "system:test",
      )
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Team", "domain": "#{draft}", "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {"name": {"type": "string", "required": true}}
      }), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Project", "domain": "#{draft}", "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {
          "name": {"type": "string", "required": true},
          "team": {"type": "reference", "doctype": "#{draft}.Team"}
        }
      }), Facet::RBAC::AuthContext.system)

      team = Facet::Document::Create.call(db, draft, "Team", %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
      Facet::Document::Create.call(db, draft, "Project", %({"name": "P1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)

      ctx = Facet::RBAC::AuthContext.preview("account_1", draft)
      r = Facet::Document::Backrefs.call(db, ctx, draft, "Team", team.id).as(Facet::Document::Backrefs::Result)
      r.items.map(&.doc_type).should eq(["Project"])
      r.items.map(&.domain).uniq!.should eq([draft])
    end
  end
end
