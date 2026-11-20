# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/websocket"
require "../../src/rbac"

# Helper: builds a minimal doctype definition and creates a test document.
private def create_test_document(db, domain, doc_type, doc_id, content = %({"name": "test"}))
  # Ensure the domain exists
  result = Facet::Document::Create.call(db, "core", "Domain", %({"domain": "#{domain}"}), Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  # Create the doctype definition
  schema = %({"doctype": "#{doc_type}", "domain": "#{domain}", "fields": {"name": {"type": "string"}, "dept": {"type": "string"}}})
  result = Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  # Create the document
  result = Facet::Document::Create.call(db, domain, doc_type, content, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

# Pure ActiveRole + EffectiveScope builders for the app-scoped gate specs —
# the same shapes the app-grant enforcement spec builds, under file-local names.
private def ws_notifications_role : Facet::RBAC::ActiveRole
  Facet::RBAC::ActiveRole.new(
    role_id: "ws_notifications_role",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [
      Facet::RBAC::Permission.new(action: "read", domain: "crm", path: ["Contact"], scope: nil),
    ],
  )
end

private def ws_notifications_app_ctx : Facet::RBAC::AuthContext
  content = JSON.parse(%({"grants": []}))
  app = Facet::RBAC::AppScope.from_content("app_scope_1", content)
  grant = Facet::RBAC::GrantResolver.resolve(app, ws_notifications_role)
  Facet::RBAC::AuthContext.app_scoped("acc-1", ws_notifications_role, grant, "app_1")
end

describe Facet::Websocket::SubscriptionResolver do
  describe "path resolution" do
    it "resolves a root document path" do
      Facet::Database.with_db do |db|
        create_test_document(db, "hr", "Employee", "hr.Employee.e1")

        resolved = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/hr/Employee/hr.Employee.e1",
          Facet::RBAC::AuthContext.system
        )

        case resolved
        in Facet::Websocket::SubscriptionResolver::Resolved
          resolved.domain.should eq("hr")
          resolved.doc_type.should eq("Employee")
          resolved.doc_id.should eq("hr.Employee.e1")
          resolved.fanout_channel.should eq("fanout:hr.Employee:hr.Employee.e1")
        in Facet::ServiceError
          fail "Expected resolved, got error: #{resolved.message}"
        end
      end
    end

    it "rejects collection paths (even segment count)" do
      Facet::Database.with_db do |db|
        create_test_document(db, "hr", "Employee", "hr.Employee.e1")

        # A path ending with a relationship name (4 segments) = collection
        resolved = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/hr/Employee/hr.Employee.e1/children",
          Facet::RBAC::AuthContext.system
        )

        case resolved
        in Facet::ServiceError
          resolved.status.should eq(400)
          resolved.message.should contain("Collection")
        in Facet::Websocket::SubscriptionResolver::Resolved
          fail "Expected error for collection path"
        end
      end
    end

    it "rejects paths with fewer than 2 segments" do
      Facet::Database.with_db do |db|
        resolved = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/hr",
          Facet::RBAC::AuthContext.system
        )

        case resolved
        in Facet::ServiceError
          resolved.status.should eq(400)
        in Facet::Websocket::SubscriptionResolver::Resolved
          fail "Expected error for short path"
        end
      end
    end
  end

  describe "RBAC authorization" do
    it "allows system principal (full bypass)" do
      Facet::Database.with_db do |db|
        create_test_document(db, "hr", "Employee", "hr.Employee.e2")

        resolved = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/hr/Employee/hr.Employee.e2",
          Facet::RBAC::AuthContext.system
        )

        resolved.should be_a(Facet::Websocket::SubscriptionResolver::Resolved)
      end
    end

    it "allows a real principal with viewer role (read on *.*)" do
      Facet::Database.with_db do |db|
        create_test_document(db, "finance", "Invoice", "finance.Invoice.i1")
        seed_test_roles(db)

        role = Facet::RBAC::ActiveRole.from_projection_content(
          Facet::Mutation::Client.fetch_content(db, "iam", "Roles", "iam.Roles.viewer")
        )
        auth = Facet::RBAC::AuthContext.authenticated("account_1", role)

        resolved = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/finance/Invoice/finance.Invoice.i1",
          auth
        )

        # viewer has read on *.* so it should be allowed for finance.Invoice
        resolved.should be_a(Facet::Websocket::SubscriptionResolver::Resolved)
      end
    end
  end

  describe "resolve_channel (unsubscribe helper)" do
    it "computes the fanout channel for a valid path" do
      channel = Facet::Websocket::SubscriptionResolver.resolve_channel("/hr/Employee/e1")
      channel.should eq("fanout:hr.Employee:e1")
    end

    it "returns nil for an invalid path" do
      Facet::Websocket::SubscriptionResolver.resolve_channel("/hr").should be_nil
    end
  end

  describe "notifications self-subscription" do
    it "recognizes the notifications path in every equivalent spelling" do
      resolver = Facet::Websocket::SubscriptionResolver
      resolver.notifications_path?("/notifications").should be_true
      resolver.notifications_path?("/notifications/").should be_true
      resolver.notifications_path?("notifications").should be_true
      resolver.notifications_path?("/hr/Employee/e1").should be_false
      resolver.notifications_path?("/notifications/extra").should be_false
    end

    it "derives the caller's own notifications channel from the principal" do
      channel = Facet::Websocket::SubscriptionResolver.notifications_channel(
        Facet::RBAC::AuthContext.system("acc-42")
      )
      channel.should eq("fanout:notifications:acc-42")
    end
  end

  describe "notifications authorization (app-scoped gate)" do
    it "permits a session or system principal" do
      resolver = Facet::Websocket::SubscriptionResolver
      resolver.notifications_authorized?(Facet::RBAC::AuthContext.system).should be_true
      resolver.notifications_authorized?(Facet::RBAC::AuthContext.authenticated("acc-1", ws_notifications_role)).should be_true
    end

    it "refuses an app-scoped principal (the feed sits outside the grant)" do
      Facet::Websocket::SubscriptionResolver.notifications_authorized?(ws_notifications_app_ctx).should be_false
    end
  end
end
