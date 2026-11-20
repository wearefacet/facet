# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/rbac"
require "../../src/mutation/client"

# RBAC fixtures come from the shared iam helper (create_role_projection,
# create_account_projection, permission_json).
# Registers a minimal `production.Team` doctype and its rows so the
# Project fixture's `team` reference values pass the authoring-time
# reference existence check.
def cwss_register_production_teams(db, team_ids : Array(String)) : Nil
  ensure_domain(db, "production")
  defn = Facet::Doctype::DoctypeDefinition.from_json(
    %({"doctype": "Team", "domain": "production", "schema_version": 1, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}}),
  )
  created = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  expect_create_success(created)
  team_ids.each do |team_id|
    row = Facet::Document::Create.call(db, "production", "Team", %({"name": "#{team_id}"}), Facet::RBAC::AuthContext.system, doc_id: team_id)
    expect_create_success(row)
  end
end

def cwss_create_domain_with_context_sets(db, context_sets_json = %({}))
  domain = "crm-#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..8].downcase}"
  content = %({"context_sets": #{context_sets_json}})
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: domain,
    content: content,
    actioner_id: "system",
  )
  domain
end

module Facet::Document
  describe "Script integration" do
    # ── Create with script ───────────────────────────────────────────

    describe "create with script" do
      it "creates a document when the script has no create() function" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          script = <<-LUA
            local export = {}
            return export
          LUA
          defn_schema = %({"doctype": "#{dt}", "domain": "sc", "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, "sc", dt, %({"title": "hello"}), Facet::RBAC::AuthContext.system)
          expect_create_success(result)
        end
      end

      it "creates a document when export.create() passes" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          script = <<-LUA
            local export = {}
            function export.create(ctx)
              -- all good
            end
            return export
          LUA
          defn_schema = %({"doctype": "#{dt}", "domain": "sc", "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, "sc", dt, %({"title": "hello"}), Facet::RBAC::AuthContext.system)
          res = expect_create_success(result)
          res.projection.content["title"].should eq(JSON.parse(%("hello")))
        end
      end

      it "mutates the document via ctx.root in the create hook" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          script = <<-LUA
            local export = {}
            function export.create(ctx)
              ctx.root.slug = ctx.root.title:lower():gsub("%s+", "-")
              ctx.root.status = "draft"
            end
            return export
          LUA
          fields = %({"title": {"type": "string", "required": true}, "slug": {"type": "string"}, "status": {"type": "string"}})
          defn_schema = %({"doctype": "#{dt}", "domain": "sc", "fields": #{fields}, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, "sc", dt, %({"title": "My Document"}), Facet::RBAC::AuthContext.system)
          res = expect_create_success(result)
          content = res.projection.content
          content["title"].as_s.should eq("My Document")
          content["slug"].as_s.should eq("my-document")
          content["status"].as_s.should eq("draft")
        end
      end

      it "rejects creation when the script calls ctx.error()" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          script = <<-LUA
            local export = {}
            function export.create(ctx)
              if ctx.root.title == 'bad' then
                ctx.error('title cannot be bad')
              end
            end
            return export
          LUA
          defn_schema = %({"doctype": "#{dt}", "domain": "sc", "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, "sc", dt, %({"title": "bad"}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.message.should eq("Script validation failed")
          err.details.not_nil!.map(&.message).should eq(["title cannot be bad"])
        end
      end

      it "answers 422 with the Lua message when the create hook raises an uncaught Lua error (B-131)" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          script = <<-LUA
            local export = {}
            function export.create(ctx)
              no_such_helper()
            end
            return export
          LUA
          defn_schema = %({"doctype": "#{dt}", "domain": "sc", "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, "sc", dt, %({"title": "hello"}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.message.should start_with("Script error: ")
          err.message.should contain("no_such_helper")
        end
      end

      it "rejects creation with multiple script errors" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          script = <<-LUA
            local export = {}
            function export.create(ctx)
              if ctx.root.quantity <= 0 then
                ctx.error('quantity must be > 0')
              end
              if ctx.root.title == nil or ctx.root.title == '' then
                ctx.error('title is required')
              end
            end
            return export
          LUA
          fields = %({"title": {"type": "string", "required": true}, "quantity": {"type": "integer"}})
          defn_schema = %({"doctype": "#{dt}", "domain": "sc", "fields": #{fields}, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, "sc", dt, %({"title": "", "quantity": 0}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.details.not_nil!.map(&.message).should contain("quantity must be > 0")
          err.details.not_nil!.map(&.message).should contain("title is required")
        end
      end

      it "runs schema validation before script validation" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          script = <<-LUA
            local export = {}
            function export.create(ctx)
              ctx.error('should not reach here')
            end
            return export
          LUA
          defn_schema = %({"doctype": "#{dt}", "domain": "sc", "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          # Missing required field 'title' — schema validation should
          # run first and return before the script is executed.
          result = Create.call(db, "sc", dt, %({"quantity": 5}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.message.should eq("Document validation failed")
          err.details.not_nil!.any? { |e| e.field == "title" && e.code == "required" }.should be_true
        end
      end

      it "exposes document fields via ctx.root to the script" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          script = <<-LUA
            local export = {}
            function export.create(ctx)
              if ctx.root.title ~= 'My Document' then
                ctx.error('unexpected title')
              end
              if ctx.root.count ~= 42 then
                ctx.error('unexpected count')
              end
            end
            return export
          LUA
          fields = %({"title": {"type": "string", "required": true}, "count": {"type": "integer"}})
          defn_schema = %({"doctype": "#{dt}", "domain": "sc", "fields": #{fields}, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, "sc", dt, %({"title": "My Document", "count": 42}), Facet::RBAC::AuthContext.system)
          expect_create_success(result)
        end
      end

      it "rejects doctype registration with a Lua syntax error in the script" do
        with_db do |_|
          dt = "T#{unique_suffix(8)}"
          script = "local export = {}; @@@ invalid @@@; return export"
          defn = Facet::Doctype::DoctypeDefinition.from_json(%({"doctype": "#{dt}", "domain": "sc", "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}}))
          result = create_doctype(defn)
          err = expect_create_error(result, status: 422)
          err.message.should contain("Doctype validation failed")
          err.details.not_nil!.any?(&.message.includes?("syntax")).should be_true
        end
      end
    end

    # ── ctx.actor integration (RBAC surface in create hook) ───────────

    describe "create with ctx.actor" do
      it "forces author_id from ctx.actor.id when the create permission is scoped $mine" do
        with_db do |db|
          ensure_domain(db, "crm")
          dt = "Project"
          # Doctype with a `mine` named scope and an author_id field.
          defn_json = %({
            "doctype": "#{dt}",
            "domain": "crm",
            "fields": {
              "title":     {"type": "string", "required": true},
              "author_id": {"type": "string"}
            },
            "scopes": {
              "mine": {"where": {"author_id": "$self"}}
            },
            "script": #{%(local export = {}
function export.create(ctx)
  if ctx.actor.scope == "mine" then
    ctx.root.author_id = ctx.actor.id
  end
  if ctx.actor.role_id ~= "scoped_creator" then
    ctx.error("unexpected role")
  end
end
return export).to_json}
          })
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_json))

          # Role with a scoped create permission.
          create_role_projection(db, "scoped_creator", [
            permission_json("create", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "creator_1", ["scoped_creator"])
          role = Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "scoped_creator")
          )
          auth = Facet::RBAC::AuthContext.authenticated("creator_1", role)

          # Body omits author_id; the hook must force it to the actor's id.
          result = Create.call(db, "crm", dt, %({"title": "My Project"}), auth)
          res = expect_create_success(result)
          res.projection.content["author_id"].as_s.should eq("creator_1")
        end
      end

      it "does not force author_id for an unrestricted creator" do
        with_db do |db|
          ensure_domain(db, "crm")
          dt = "Project2"
          defn_json = %({
            "doctype": "#{dt}",
            "domain": "crm",
            "fields": {
              "title":     {"type": "string", "required": true},
              "author_id": {"type": "string"}
            },
            "scopes": {
              "mine": {"where": {"author_id": "$self"}}
            },
            "script": #{%(local export = {}
function export.create(ctx)
  if ctx.actor.scope ~= nil then
    ctx.error("scope should be nil for unrestricted creator")
  end
  if ctx.actor.scopes ~= nil then
    ctx.error("scopes should be nil for unrestricted creator")
  end
end
return export).to_json}
          })
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_json))

          # Unrestricted create permission (no scope).
          create_role_projection(db, "open_creator", [
            permission_json("create", "crm.Project2"),
          ])
          create_account_projection(db, "creator_2", ["open_creator"])
          role = Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "open_creator")
          )
          auth = Facet::RBAC::AuthContext.authenticated("creator_2", role)

          result = Create.call(db, "crm", dt, %({"title": "Open", "author_id": "someone_else"}), auth)
          res = expect_create_success(result)
          # Unrestricted → the hook leaves author_id alone.
          res.projection.content["author_id"].as_s.should eq("someone_else")
        end
      end

      it "exposes resolved context_sets for the caller's domain" do
        with_db do |db|
          # Define a `my_teams` context set on a fresh domain.
          domain = cwss_create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMember",
              "select": "team_id",
              "where": {"account_id": "$self"}
            }
          }))
          dt = "Project3"
          defn_json = %({
            "doctype": "#{dt}",
            "domain": "#{domain}",
            "fields": {
              "title":   {"type": "string", "required": true},
              "team_id": {"type": "string"}
            },
            "script": #{%(local export = {}
function export.create(ctx)
  if ctx.actor.context_sets == nil then
    ctx.error("context_sets missing")
  end
  if ctx.actor.context_sets.my_teams == nil then
    ctx.error("my_teams missing")
  end
  if #ctx.actor.context_sets.my_teams ~= 1 then
    ctx.error("expected 1 team")
  end
  if ctx.actor.context_sets.my_teams[1] ~= "team_1" then
    ctx.error("bad team value")
  end
end
return export).to_json}
          })
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_json))

          # Seed a TeamMember doctype + a document the context set can read.
          team_member_def = %({
            "doctype": "TeamMember",
            "domain": "#{domain}",
            "fields": {
              "account_id": {"type": "string"},
              "team_id":    {"type": "string"}
            }
          })
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(team_member_def))
          Facet::Mutation::Client.create(
            db, domain, "TeamMember",
            doc_id: Facet::Util::ScriptHelpers.ulid,
            content: %({"account_id": "iam.Account.member_1", "team_id": "team_1"}),
            actioner_id: "system",
          )

          create_role_projection(db, "team_creator", [
            permission_json("create", "#{domain}.#{dt}"),
          ])
          create_account_projection(db, "member_1", ["team_creator"])
          role = Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "team_creator")
          )
          auth = Facet::RBAC::AuthContext.authenticated("member_1", role)

          result = Create.call(db, domain, dt, %({"title": "Team Project"}), auth)
          expect_create_success(result)
        end
      end

      it "exposes a system actor table for system-context create calls" do
        with_db do |db|
          ensure_domain(db, "crm")
          dt = "Project4"
          defn_json = %({
            "doctype": "#{dt}",
            "domain": "crm",
            "fields": {"title": {"type": "string", "required": true}},
            "script": #{%(local export = {}
function export.create(ctx)
  if ctx.actor == nil then ctx.error("actor missing") end
  if ctx.actor.system ~= true then ctx.error("system should be true") end
  if ctx.actor.id ~= "system" then ctx.error("bad id") end
  if ctx.actor.role_id ~= nil then ctx.error("system has no role_id") end
end
return export).to_json}
          })
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_json))

          result = Create.call(db, "crm", dt, %({"title": "S"}), Facet::RBAC::AuthContext.system)
          expect_create_success(result)
        end
      end

      it "fixture: production.Project script forces owner_id from ctx.actor (mine scope)" do
        with_db do |db|
          ensure_domain(db, "production")
          # Load the fixture definition + its co-located script.lua.
          defn = build_doctype_definition("production.Project/definition.yml", "production.Project/script.lua")
          create_doctype(defn)

          # Scoped creator: create permission carries $mine (owner_id: $self).
          # `read production.Team` satisfies the B-356 reference check on
          # the `team` field.
          create_role_projection(db, "project_owner", [
            permission_json("create", "production.Project", "$mine"),
            permission_json("read", "production.Team"),
          ])
          create_account_projection(db, "account_eng_dao", ["project_owner"])
          cwss_register_production_teams(db, ["team_platform"])
          role = Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "project_owner")
          )
          auth = Facet::RBAC::AuthContext.authenticated("account_eng_dao", role)

          # Body omits owner_id; the fixture script must force it.
          result = Create.call(db, "production", "Project", %({"name": "New Project", "team": "team_platform"}), auth)
          res = expect_create_success(result)
          res.projection.content["owner_id"].as_s.should eq("iam.Account.account_eng_dao")
        end
      end

      it "fixture: production.Project script leaves owner_id alone for an unrestricted creator" do
        with_db do |db|
          ensure_domain(db, "production")
          defn = build_doctype_definition("production.Project/definition.yml", "production.Project/script.lua")
          create_doctype(defn)

          create_role_projection(db, "project_open", [
            permission_json("create", "production.Project"),
            permission_json("read", "production.Team"),
            # `owner_id` is an `iam.Account` reference (B-356).
            permission_json("read", "iam.Account"),
          ])
          create_account_projection(db, "account_recruiter_kim", ["project_open"])
          cwss_register_production_teams(db, ["team_growth"])
          ensure_iam_account(db, "existing_owner")
          role = Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(db, "iam", "Role", "project_open")
          )
          auth = Facet::RBAC::AuthContext.authenticated("account_recruiter_kim", role)

          # Body supplies owner_id; the script must NOT override it (no mine scope).
          result = Create.call(db, "production", "Project", %({"name": "Open", "team": "team_growth", "owner_id": "existing_owner"}), auth)
          res = expect_create_success(result)
          res.projection.content["owner_id"].as_s.should eq("iam.Account.existing_owner")
        end
      end

      it "fixture: production.Project script leaves owner_id alone for system-context create" do
        with_db do |db|
          ensure_domain(db, "production")
          defn = build_doctype_definition("production.Project/definition.yml", "production.Project/script.lua")
          create_doctype(defn)

          # System context: the script's actor.system == true guard leaves owner_id.
          cwss_register_production_teams(db, ["team_platform"])
          ensure_iam_account(db, "system_owner")
          result = Create.call(db, "production", "Project", %({"name": "Seeded", "team": "team_platform", "owner_id": "system_owner"}), Facet::RBAC::AuthContext.system)
          res = expect_create_success(result)
          res.projection.content["owner_id"].as_s.should eq("iam.Account.system_owner")
        end
      end
    end

    # ── Doctype without script ─────────────────────────────────────

    describe "doctype without script" do
      it "creates documents normally when no script is defined" do
        with_db do |db|
          dt = "T#{unique_suffix(8)}"
          defn_schema = %({"doctype": "#{dt}", "domain": "noscope", "fields": {"title": {"type": "string", "required": true}}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, "noscope", dt, %({"title": "works"}), Facet::RBAC::AuthContext.system)
          expect_create_success(result)
        end
      end
    end
  end
end
