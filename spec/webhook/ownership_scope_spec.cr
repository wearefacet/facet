# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/webhook_helper"
require "../support/iam_helper"
require "../../src/rbac"

# Ownership scoping on core.Webhook (B-76 arbitration): non-admin roles hold
# create unrestricted and read/update/delete through the `mine` named scope
# (`account_id == $self`); admin keeps the plain wildcard. The examples
# drive the RBAC enforcers and the document list exactly as the HTTP routes
# do, with role shapes that mirror the seeded editor line block.
# The webhook content as stored on the projection.
def webhook_content_of(db, doc_id : String) : Hash(String, JSON::Any)
  content = Facet::Mutation::Client.fetch_content(db, "core", "Webhook", doc_id)
  content.as_h.not_nil!
end

# The editor-shaped auth context: blanket grants with core.Webhook carved
# out of the management actions, plus the $mine-scoped lines. Mirrors the
# seeded editor line block.
def webhook_editor_auth(account_id : String) : ::Facet::RBAC::AuthContext
  permissions = [
    ::Facet::RBAC::Permission.new(action: "create", domain: "*", path: ["*"],
      except: ["core.DocType", "core.DocumentView", "core.DomainEditor", "core.SystemSettings", "iam.OIDCProvider"]),
    ::Facet::RBAC::Permission.new(action: "update", domain: "*", path: ["*"],
      except: ["core.Domain", "core.DocType", "core.DocumentView", "core.DomainEditor", "core.SystemSettings", "iam.OIDCProvider", "core.Webhook"]),
    ::Facet::RBAC::Permission.new(action: "delete", domain: "*", path: ["*"],
      except: ["core.Domain", "core.DocType", "core.DocumentView", "core.DomainEditor", "core.SystemSettings", "iam.OIDCProvider", "core.Webhook"]),
    ::Facet::RBAC::Permission.new(action: "read", domain: "*", path: ["*"],
      except: ["core.SystemSettings", "iam.OIDCProvider", "core.Webhook"]),
    ::Facet::RBAC::Permission.new(action: "create", domain: "core", path: ["Webhook"]),
    ::Facet::RBAC::Permission.new(action: "read", domain: "core", path: ["Webhook"], scope: ["$mine"]),
    ::Facet::RBAC::Permission.new(action: "update", domain: "core", path: ["Webhook"], scope: ["$mine"]),
    ::Facet::RBAC::Permission.new(action: "delete", domain: "core", path: ["Webhook"], scope: ["$mine"]),
  ]
  role = ::Facet::RBAC::ActiveRole.new(
    role_id: "iam.Roles.editor",
    visible_tags: ::Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: permissions,
  )
  ::Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# The admin shape: one wildcard line, no scopes.
def webhook_admin_auth(account_id : String) : ::Facet::RBAC::AuthContext
  permissions = [::Facet::RBAC::Permission.new(action: "*", domain: "*", path: ["*"])]
  role = ::Facet::RBAC::ActiveRole.new(
    role_id: "iam.Roles.admin",
    visible_tags: ::Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: permissions,
  )
  ::Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Creates a webhook the real way — through Document::Create, so the
# create hook stamps the binding from the caller.

# Grants the `webhook` connectivity channel to a seeded role projection.
# The production seed gives the editor role no `webhook` channel (QA
# F07-01); this fixture exercises ownership scoping, so it opens the
# channel on the role it drives.
def grant_webhook_channel(db, role_id : String) : Nil
  content = db.query_one(
    "SELECT content FROM projections WHERE id = $1 AND deleted_at IS NULL",
    role_id, as: JSON::Any).as_h
  content["connectivity"] = JSON::Any.new([JSON::Any.new("webhook")] + (content["connectivity"]?.try(&.as_a?) || [] of JSON::Any))
  db.exec(
    "UPDATE projections SET content = $2 WHERE id = $1 AND deleted_at IS NULL",
    role_id, JSON::Any.new(content).to_json,
  )
end

def create_webhook_as(db, ctx : ::Facet::RBAC::AuthContext, doc_id : String) : Nil
  body = %({"label": "Relay #{doc_id}", "url": "https://1.1.1.1/hook", "source_doctype": "core.DocType.sales.Invoice"})
  result = ::Facet::Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: doc_id)
  case result
  in ::Facet::Document::Create::Result
    # created
  in ::Facet::ServiceError
    details = result.details.try(&.map(&.message).join("; ")) || ""
    fail "webhook create failed: #{result.message} #{details}"
  end
end

module Facet
  describe "core.Webhook ownership scope ($mine)" do
    before_each do
      with_db do |db|
        %w[core.DocType core.Domain iam.Account].each do |dir|
          domain, doctype = dir.split(".", 2)
          Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
        end
        ensure_seed_roles_with_dependencies(db)
        grant_webhook_channel(db, "iam.Roles.editor")
        Facet::Doctype::DefinitionStore.cache.clear
        seed_webhook_source(db)
      end
    end

    it "stamps the binding from the caller, not from the body" do
      with_db do |db|
        ctx = webhook_editor_auth("acc_alice")
        create_webhook_as(db, ctx, "wh_alice")
        content = webhook_content_of(db, "wh_alice")
        content["account_id"]?.try(&.as_s).should eq("iam.Account.acc_alice")
      end
    end

    it "lets an editor read their own webhook but not another editor's" do
      with_db do |db|
        create_webhook_as(db, webhook_editor_auth("acc_alice"), "wh_alice")
        create_webhook_as(db, webhook_editor_auth("acc_bob"), "wh_bob")

        alice = webhook_editor_auth("acc_alice")
        ::Facet::RBAC::ReadEnforcer.authorized?(db, "core", "Webhook", "wh_alice", alice).should be_true
        # Non-disclosing denial on the foreign webhook.
        ::Facet::RBAC::ReadEnforcer.authorized?(db, "core", "Webhook", "wh_bob", alice).should be_false
      end
    end

    it "lets an editor update and delete their own webhook but not another's" do
      with_db do |db|
        create_webhook_as(db, webhook_editor_auth("acc_alice"), "wh_alice")
        create_webhook_as(db, webhook_editor_auth("acc_bob"), "wh_bob")

        alice = webhook_editor_auth("acc_alice")
        ::Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "Webhook", "wh_alice", alice).should be_true
        ::Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "Webhook", "wh_bob", alice).should be_false
        ::Facet::RBAC::WriteEnforcer.authorize_delete(db, "core", "Webhook", "wh_alice", alice).should be_true
        ::Facet::RBAC::WriteEnforcer.authorize_delete(db, "core", "Webhook", "wh_bob", alice).should be_false
      end
    end

    it "scopes the document list to the caller's own webhooks" do
      with_db do |db|
        create_webhook_as(db, webhook_editor_auth("acc_alice"), "wh_alice")
        create_webhook_as(db, webhook_editor_auth("acc_bob"), "wh_bob")
        create_webhook_as(db, webhook_editor_auth("acc_alice"), "wh_alice_2")

        result = ::Facet::Document::List.call(db, "core", "Webhook", filters: {} of String => JSON::Any, auth_context: webhook_editor_auth("acc_alice"))
        fail "list failed: #{result.message}" if result.is_a?(::Facet::ServiceError)
        fail "unexpected aggregate result" unless result.is_a?(::Facet::Document::List::Result)
        ids = result.items.map(&.id).sort!
        ids.should eq(["wh_alice", "wh_alice_2"])
      end
    end

    it "shows the admin every webhook regardless of owner" do
      with_db do |db|
        create_webhook_as(db, webhook_editor_auth("acc_alice"), "wh_alice")
        create_webhook_as(db, webhook_editor_auth("acc_bob"), "wh_bob")

        admin = webhook_admin_auth("acc_root")
        ::Facet::RBAC::ReadEnforcer.authorized?(db, "core", "Webhook", "wh_alice", admin).should be_true
        ::Facet::RBAC::ReadEnforcer.authorized?(db, "core", "Webhook", "wh_bob", admin).should be_true

        result = ::Facet::Document::List.call(db, "core", "Webhook", filters: {} of String => JSON::Any, auth_context: admin)
        fail "list failed: #{result.message}" if result.is_a?(::Facet::ServiceError)
        fail "unexpected aggregate result" unless result.is_a?(::Facet::Document::List::Result)
        ids = result.items.map(&.id).sort!
        ids.should eq(["wh_alice", "wh_bob"])
      end
    end
  end
end
