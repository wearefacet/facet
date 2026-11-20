# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/doctype"
require "../../src/mutation/client"
require "../../src/document"
require "../support/rbac_helper"

# B-123 — the metadata gate is a union with the generic gate, so it is
# monotonic: more permissions never remove visibility.
#
# Before the fix, a scoped `read core.DocType` line (e.g. `$domain_editor`)
# made the generic gate `Scoped`, which bypassed the metadata gate. The scope
# predicate then filtered the definition list, so a doctype the role could
# otherwise read through its document grants disappeared from the definition
# list and its pages 404'd. Adding a scoped metadata read REMOVED visibility.
#
# The fix OR-s the scope clause with the metadata clause, so a row readable
# through either path stays visible.

# Creates the `hr.Request` doctype definition row (the document grant target).
private def create_b123_request_doctype(db) : Nil
  Facet::Document::Create.call(
    db, "core", "DocType",
    %({"doctype": "Request", "domain": "hr", "schema_version": 1, "fields": {"title": {"type": "string"}}}),
    Facet::RBAC::AuthContext.system,
  )
end

# Grants `account_id` editorship of `domain_id` — the row the `$domain_editor`
# scope resolves through the `editor_domains` context set.
private def create_b123_domain_editor_row(db, account_id : String, domain_id : String) : Nil
  Facet::Document::Create.call(
    db, "core", "DomainEditor",
    %({"account": "iam.Account.#{account_id}", "domain": "#{domain_id}"}),
    Facet::RBAC::AuthContext.system,
  )
end

# The B-123 role: a scoped `read core.DocType` line (the editor's domain
# scope) PLUS a document grant on `hr.Request`. The scope narrows to `crm`,
# so `hr.Request` (domain `hr`) is out of the scope's reach.
private def b123_editor_ctx : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.authenticated("acc_editor", rbac_role([
    rbac_perm("read", "core.DocType", ["$domain_editor"]),
    rbac_perm("read", "hr.Request"),
  ]))
end

# The same shape for the `core.Domain` structural doctype.
private def b123_domain_ctx : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.authenticated("acc_editor", rbac_role([
    rbac_perm("read", "core.Domain", ["$domain_editor"]),
    rbac_perm("read", "hr.Request"),
  ]))
end

module Facet::RBAC
  describe "structural metadata union (B-123)" do
    before_each do
      with_db do |db|
        # The per-example TRUNCATE wipes the seed; rebuild the core corpus so
        # the `core` domain context sets and the `core.DocType` definition
        # (which declares `$domain_editor`) resolve.
        restore_seeded_baseline(db)
        ensure_iam_account(db, "acc_editor")
        ensure_domain(db, "crm")
        ensure_domain(db, "hr")
        create_b123_request_doctype(db)
        create_b123_domain_editor_row(db, "acc_editor", "crm")
      end
    end

    describe ".list_where_clauses" do
      it "OR-s the scope clause with the metadata clause for core.DocType" do
        with_db do |db|
          clauses, params = ReadEnforcer.list_where_clauses(db, "core", "DocType", b123_editor_ctx)
          clauses.size.should eq(1)
          sql = clauses.first
          # The scoped clause narrows to the edited domain...
          sql.should contain("content->>'domain' = ANY(string_to_array($1, ','))")
          # ...and the metadata clause keeps the granted definition.
          sql.should contain("id = $2")
          params.should eq(["crm", "hr.Request"])
        end
      end

      it "keeps an ungranted definition absent from the list" do
        with_db do |db|
          _clauses, params = ReadEnforcer.list_where_clauses(db, "core", "DocType", b123_editor_ctx)
          # `iam.Roles` is reachable through neither the scope (domain `iam`)
          # nor the metadata gate (no grant on it).
          params.should_not contain("iam.Roles")
        end
      end

      it "OR-s the scope clause with the metadata clause for core.Domain" do
        with_db do |db|
          clauses, params = ReadEnforcer.list_where_clauses(db, "core", "Domain", b123_domain_ctx)
          clauses.size.should eq(1)
          sql = clauses.first
          # The `$domain_editor` scope on core.Domain matches the row id.
          sql.should contain("id = ANY(string_to_array($1, ','))")
          # The metadata clause keeps the domain the document grant lives in.
          sql.should contain("id = $2")
          params.should eq(["crm", "hr"])
        end
      end
    end

    describe ".authorized?" do
      it "resolves a granted definition on a single read" do
        with_db do |db|
          expect_rbac_authorized(db, "core", "DocType", "hr.Request", b123_editor_ctx)
        end
      end

      it "denies an ungranted definition (non-disclosing)" do
        with_db do |db|
          expect_rbac_denied(db, "core", "DocType", "iam.Roles", b123_editor_ctx)
        end
      end
    end

    describe ".read_denied?" do
      it "is not denied when the grants reach a structural row" do
        ReadEnforcer.read_denied?("core", "DocType", b123_editor_ctx).should be_false
        ReadEnforcer.read_denied?("core", "Domain", b123_domain_ctx).should be_false
      end
    end
  end
end
