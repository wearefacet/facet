# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"
require "../../src/jobs/handler"
require "../../src/import_export/caller_context"

# `ImportExport::CallerContext` — the enqueue-time → execution-time
# caller rebuild shared by the document and domain import/export jobs.
#
# Contract: a job payload's `role_id` must be the
# QUALIFIED `iam.Roles` projection id — the exact form
# `IAM::Helpers.find_role_content` resolves. The HTTP payload builders
# stamp through `CallerContext.role_reference`, because
# `ActiveRole#role_id` carries the role's own `name` field, not the
# reference. A bare name in the payload fails the execution-time lookup
# with "Import/export role X no longer exists".
describe Facet::ImportExport::CallerContext do
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    register_seed_currencies
  end

  it "role_reference builds the qualified form from an ActiveRole built the AuthHandler way" do
    with_db do |db|
      # Seed the role the production way: doc_id is the qualified
      # reference (`iam.Roles.<name>`), content.name the bare name.
      Facet::Mutation::Client.create(
        db, "iam", "Roles",
        doc_id: "iam.Roles.impex_ref_role",
        content: %({"name": "impex_ref_role", "visible_tags": ["default"], "permissions": []}),
        actioner_id: "system",
      ).should be_a(String)

      # Build the ActiveRole exactly as AuthHandler does: resolve the
      # role content by the qualified reference, then parse it.
      role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.impex_ref_role").not_nil!
      auth = Facet::RBAC::AuthContext.authenticated(
        "impex_ref_owner",
        Facet::RBAC::ActiveRole.from_projection_content(role_content),
      )

      # ActiveRole#role_id is the bare name; the payload reference is not.
      auth.principal.as(Facet::RBAC::Principal::Real).active_role.role_id.should eq("impex_ref_role")
      Facet::ImportExport::CallerContext.role_reference(auth)
        .should eq("iam.Roles.impex_ref_role")
    end
  end

  it "rebuild resolves a context from the role_reference round trip" do
    with_db do |db|
      Facet::Mutation::Client.create(
        db, "iam", "Roles",
        doc_id: "iam.Roles.impex_ref_roundtrip",
        content: %({"name": "impex_ref_roundtrip", "visible_tags": ["default"], "permissions": []}),
        actioner_id: "system",
      ).should be_a(String)

      role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.impex_ref_roundtrip").not_nil!
      auth = Facet::RBAC::AuthContext.authenticated(
        "impex_ref_owner",
        Facet::RBAC::ActiveRole.from_projection_content(role_content),
      )

      reference = Facet::ImportExport::CallerContext.role_reference(auth).not_nil!
      caller = Facet::ImportExport::CallerContext::Caller.new(
        account_id: "impex_ref_owner",
        role_id: reference,
        app_id: nil,
        api_key_id: nil,
      )
      rebuilt = Facet::ImportExport::CallerContext.rebuild(db, caller)
      rebuilt.account_id.should eq("impex_ref_owner")
      rebuilt.principal.as(Facet::RBAC::Principal::Real).active_role.role_id
        .should eq("impex_ref_roundtrip")
    end
  end

  it "role_reference answers nil for a system principal" do
    Facet::ImportExport::CallerContext.role_reference(Facet::RBAC::AuthContext.system)
      .should be_nil
  end
end
