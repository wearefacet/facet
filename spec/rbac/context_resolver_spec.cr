# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/mutation/client"

# ── Helpers ────────────────────────────────────────────────────────────────

# Creates a domain with the given context_sets, using a random doc_id so
# tests don't collide. Returns the domain name (which acts as the doc_id).
def create_domain_with_context_sets(db, context_sets_json = %({}))
  domain = "crm_#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..8]}"
  content = %({"context_sets": #{context_sets_json}})
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: domain,
    content: content,
    actioner_id: "system",
  )
  domain
end

def create_context_set_projection(db, domain, doc_type, doc_id, content_overrides = {} of String => String)
  content = {"title" => JSON::Any.new("test")}
  content_overrides.each { |k, v| content[k] = JSON::Any.new(v) }
  Facet::Mutation::Client.create(
    db, domain, doc_type,
    doc_id: doc_id,
    content: JSON::Any.new(content).to_json,
    actioner_id: "system",
  )
end

# Creates a child projection whose `meta.parent_id` is set, simulating a
# document created via its parent's nested route. Used to exercise context
# sets that `select: $parent_id`.
def create_child_projection(db, domain, doc_type, doc_id, parent_id, content_overrides = {} of String => String)
  content = {"title" => JSON::Any.new("test")}
  content_overrides.each { |k, v| content[k] = JSON::Any.new(v) }
  meta = {"parent_id" => JSON::Any.new(parent_id)}
  Facet::Mutation::Client.create(
    db, domain, doc_type,
    doc_id: doc_id,
    content: JSON::Any.new(content).to_json,
    meta: JSON::Any.new(meta).to_json,
    actioner_id: "system",
  )
end

module Facet::RBAC
  describe ContextResolver do
    # ── extract_context_sets ───────────────────────────────────────────────

    describe ".extract_context_sets" do
      it "returns empty hash when domain_content is nil" do
        ContextResolver.extract_context_sets(nil).should be_empty
      end

      it "returns empty hash when domain_content has no context_sets" do
        content = JSON.parse(%({"name": "crm"}))
        ContextResolver.extract_context_sets(content).should be_empty
      end

      it "parses context sets from domain content" do
        content = JSON.parse(%({
          "context_sets": {
            "my_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"account": "$self"}
            }
          }
        }))
        sets = ContextResolver.extract_context_sets(content)
        sets.size.should eq(1)
        sets["my_teams"].name.should eq("my_teams")
        sets["my_teams"].from.should eq("TeamMembership")
        sets["my_teams"].select_field.should eq("team")
        sets["my_teams"].where.should eq({"account" => "$self"})
      end

      it "returns empty hash when context_sets key is not a hash" do
        content = JSON.parse(%({"context_sets": "invalid"}))
        ContextResolver.extract_context_sets(content).should be_empty
      end
    end

    # ── fetch_domain_content ───────────────────────────────────────────────

    describe ".fetch_domain_content" do
      it "returns nil for a non-existent domain" do
        with_db do |db|
          ContextResolver.fetch_domain_content(db, "nonexistent").should be_nil
        end
      end

      it "returns content for an existing domain" do
        with_db do |db|
          domain = create_domain_with_context_sets(db)
          content = ContextResolver.fetch_domain_content(db, domain)
          content.should_not be_nil
        end
      end
    end

    # ── resolve (integration) ──────────────────────────────────────────────

    describe ".resolve" do
      it "resolves a $self-based context set" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"account": "$self"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"account" => "iam.Account.account_1", "team" => "engineering"})
          create_context_set_projection(db, domain, "TeamMembership", "tm_2", {"account" => "iam.Account.account_1", "team" => "design"})
          create_context_set_projection(db, domain, "TeamMembership", "tm_3", {"account" => "other", "team" => "marketing"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve(db, domain, "my_teams", Facet::RBAC::ScopeContext.root("account_1"), context_sets)
          results.sort.should eq(["design", "engineering"])
        end
      end

      it "resolves a $organizational_unit-based context set" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_ou_members": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"ou": "$organizational_unit"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"ou" => "/engineering/", "team" => "eng_team"})
          create_context_set_projection(db, domain, "TeamMembership", "tm_2", {"ou" => "/marketing/", "team" => "mkt_team"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          scope_context = Facet::RBAC::ScopeContext.new("account_1", "/engineering/")
          results = ContextResolver.resolve(db, domain, "my_ou_members", scope_context, context_sets)
          results.should eq(["eng_team"])
        end
      end

      it "applies a starts_with operator in the where clause" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "eng_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"team__starts_with": "eng"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"team" => "engineering"})
          create_context_set_projection(db, domain, "TeamMembership", "tm_2", {"team" => "design"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve(db, domain, "eng_teams", Facet::RBAC::ScopeContext.root("account_1"), context_sets)
          results.should eq(["engineering"])
        end
      end

      it "applies a match operator with a literal percent (never a wildcard)" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "pct_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"team__match": "%"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"team" => "engineering"})
          create_context_set_projection(db, domain, "TeamMembership", "tm_2", {"team" => "50%off"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve(db, domain, "pct_teams", Facet::RBAC::ScopeContext.root("account_1"), context_sets)
          results.should eq(["50%off"])
        end
      end

      it "resolves a context set with a dependency" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"account": "$self"}
            },
            "my_projects": {
              "from": "Project",
              "select": "id",
              "where": {"team": "$my_teams"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"account" => "iam.Account.account_1", "team" => "engineering"})
          create_context_set_projection(db, domain, "Project", "proj_1", {"id" => "proj_1", "team" => "engineering"})
          create_context_set_projection(db, domain, "Project", "proj_2", {"id" => "proj_2", "team" => "engineering"})
          create_context_set_projection(db, domain, "Project", "proj_3", {"id" => "proj_3", "team" => "design"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve(db, domain, "my_projects", Facet::RBAC::ScopeContext.root("account_1"), context_sets)
          results.sort.should eq(["proj_1", "proj_2"])
        end
      end

      it "fails closed when a Ne dependency resolves to an empty set" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"account": "$self"}
            },
            "other_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"team__ne": "$my_teams"}
            }
          }))
          # account_1 belongs to no teams, so $my_teams resolves empty.
          # "not in an empty set" is vacuously true — the unified compiler
          # fails closed instead and the set resolves to no rows.
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"team" => "engineering"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve(db, domain, "other_teams", Facet::RBAC::ScopeContext.root("account_1"), context_sets)
          results.should be_empty
        end
      end

      it "resolves Ne against a non-empty dependency set" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"account": "$self"}
            },
            "other_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"team__ne": "$my_teams"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"account" => "iam.Account.account_1", "team" => "engineering"})
          create_context_set_projection(db, domain, "TeamMembership", "tm_2", {"team" => "design"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve(db, domain, "other_teams", Facet::RBAC::ScopeContext.root("account_1"), context_sets)
          results.should eq(["design"])
        end
      end

      it "resolves a context set that selects $parent_id (child doctype scoping)" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMember",
              "select": "$parent_id",
              "where": {"account": "$self"}
            }
          }))
          # TeamMember rows are children of Team — the team id lives in
          # meta.parent_id, not in content.
          create_child_projection(db, domain, "TeamMember", "tm_1", "team_platform", {"account" => "iam.Account.account_1"})
          create_child_projection(db, domain, "TeamMember", "tm_2", "team_growth", {"account" => "iam.Account.account_1"})
          create_child_projection(db, domain, "TeamMember", "tm_3", "team_platform", {"account" => "other"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve(db, domain, "my_teams", Facet::RBAC::ScopeContext.root("account_1"), context_sets)
          results.sort.should eq(["team_growth", "team_platform"])
        end
      end

      it "filters by $parent_id in where (child doctype membership lookup)" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMember",
              "select": "$parent_id",
              "where": {"account": "$self"}
            },
            "my_team_tasks": {
              "from": "Task",
              "select": "id",
              "where": {"$parent_id": "$my_teams"}
            }
          }))
          # Tasks are children of Project, so $parent_id is the project id.
          # But we want to filter tasks whose project belongs to one of my
          # teams — there's no direct project.team link in meta, so this
          # context set would only return tasks whose parent_id is itself a
          # team. Keep this as a sanity check that $parent_id works in where.
          create_child_projection(db, domain, "TeamMember", "tm_1", "team_platform", {"account" => "iam.Account.account_1"})
          create_child_projection(db, domain, "Task", "task_1", "team_platform", {"id" => "task_1", "assignee" => "account_1"})
          create_child_projection(db, domain, "Task", "task_2", "team_growth", {"id" => "task_2", "assignee" => "account_1"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve(db, domain, "my_team_tasks", Facet::RBAC::ScopeContext.root("account_1"), context_sets)
          results.should eq(["task_1"])
        end
      end

      it "raises Error for undefined context set" do
        with_db do |db|
          expect_raises(RBAC::Error, /not defined/) do
            ContextResolver.resolve(db, "crm", "undefined_set", Facet::RBAC::ScopeContext.root("account_1"), {} of String => ContextSet)
          end
        end
      end

      it "raises ArgumentError for a SQL injection select field" do
        with_db do |db|
          malicious = ContextSet.new(
            name: "mine",
            from: "Thing",
            where: {"account" => "$self"},
            select_field: "x' UNION SELECT password_hash FROM auth_secrets --",
          )
          expect_raises(ArgumentError, /select field/) do
            ContextResolver.resolve(db, "crm", "mine", Facet::RBAC::ScopeContext.root("account_1"), {"mine" => malicious})
          end
        end
      end

      it "raises ArgumentError for a SQL injection where field" do
        with_db do |db|
          malicious = ContextSet.new(
            name: "mine",
            from: "Thing",
            where: {"x' UNION SELECT 1 --" => "$self"},
            select_field: "id",
          )
          expect_raises(ArgumentError, /where field/) do
            ContextResolver.resolve(db, "crm", "mine", Facet::RBAC::ScopeContext.root("account_1"), {"mine" => malicious})
          end
        end
      end

      it "raises ArgumentError for a field name with a space" do
        with_db do |db|
          malicious = ContextSet.new(
            name: "mine",
            from: "Thing",
            where: {"account" => "$self"},
            select_field: "bad field",
          )
          expect_raises(ArgumentError, /select field/) do
            ContextResolver.resolve(db, "crm", "mine", Facet::RBAC::ScopeContext.root("account_1"), {"mine" => malicious})
          end
        end
      end

      it "memoizes results across calls" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"account": "$self"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"account" => "iam.Account.account_1", "team" => "engineering"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)
          memo = {} of String => Hash(String, Array(String))

          # First call populates memo
          results1 = ContextResolver.resolve(db, domain, "my_teams", Facet::RBAC::ScopeContext.root("account_1"), context_sets, memo)
          results1.should eq(["engineering"])

          # Second call returns cached result
          results2 = ContextResolver.resolve(db, domain, "my_teams", Facet::RBAC::ScopeContext.root("account_1"), context_sets, memo)
          results2.should eq(["engineering"])
        end
      end
    end

    # ── resolve_all ────────────────────────────────────────────────────────

    describe ".resolve_all" do
      it "resolves all context sets in a domain" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"account": "$self"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"account" => "iam.Account.account_1", "team" => "engineering"})

          domain_content = ContextResolver.fetch_domain_content(db, domain)
          context_sets = ContextResolver.extract_context_sets(domain_content)

          results = ContextResolver.resolve_all(db, domain, context_sets, Facet::RBAC::ScopeContext.root("account_1"))
          results.has_key?("my_teams").should be_true
          results["my_teams"].should eq(["engineering"])
        end
      end
    end

    # ── resolve_for_domain ─────────────────────────────────────────────────

    describe ".resolve_for_domain" do
      it "fetches, extracts, and resolves in one call" do
        with_db do |db|
          domain = create_domain_with_context_sets(db, %({
            "my_teams": {
              "from": "TeamMembership",
              "select": "team",
              "where": {"account": "$self"}
            }
          }))
          create_context_set_projection(db, domain, "TeamMembership", "tm_1", {"account" => "iam.Account.account_1", "team" => "engineering"})

          results = ContextResolver.resolve_for_domain(db, domain, Facet::RBAC::ScopeContext.root("account_1"))
          results.has_key?("my_teams").should be_true
          results["my_teams"].should eq(["engineering"])
        end
      end

      it "returns empty hash when domain has no context_sets" do
        with_db do |db|
          results = ContextResolver.resolve_for_domain(db, "crm", Facet::RBAC::ScopeContext.root("account_1"))
          results.should be_empty
        end
      end
    end
  end
end
