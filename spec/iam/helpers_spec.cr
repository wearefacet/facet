# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/helpers"

# Builds one permission line, exactly as role content stores it.
private def manifest_perm(action : String, on : String, except : Array(String)? = nil, scope : Array(String)? = nil) : JSON::Any
  raw = {
    "action" => JSON::Any.new(action),
    "on"     => JSON::Any.new(on),
  } of String => JSON::Any
  raw["except"] = JSON::Any.new(except.map { |entry| JSON::Any.new(entry) }) if except
  raw["scope"] = JSON::Any.new(scope.map { |scope_alias| JSON::Any.new(scope_alias) }) if scope
  JSON.parse(raw.to_json)
end

# Builds a role document content around the given permission lines.
private def manifest_role_content(perms : Array(JSON::Any)) : JSON::Any
  JSON.parse({permissions: perms.map(&.raw)}.to_json)
end

describe "Facet::IAM::Helpers.build_permission_manifest" do
  it "folds wildcard excepts per action under reserved *.*.except.<action> keys" do
    role = manifest_role_content([
      manifest_perm("create", "*.*", except: ["core.DocType", "core.SystemSettings"]),
      manifest_perm("read", "*.*", except: ["core.SystemSettings", "iam.OIDCProvider"]),
    ])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    permissions = manifest[:permissions].not_nil!
    permissions["*.*"].should eq(["create", "read"])
    # Per-action fold — each action keeps its own line's carve-outs.
    permissions["*.*.except.create"].should eq(["core.DocType", "core.SystemSettings"])
    permissions["*.*.except.read"].should eq(["core.SystemSettings", "iam.OIDCProvider"])
    permissions.has_key?("*.*.except").should be_false
  end

  it "intersects the except lists of same-action wildcard lines" do
    role = manifest_role_content([
      manifest_perm("create", "*.*", except: ["core.DocType", "core.SystemSettings"]),
      manifest_perm("create", "*.*", except: ["core.SystemSettings", "iam.OIDCProvider"]),
    ])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    # A grant exists when any line matches, so a doctype is excepted only
    # when every same-action line subtracts it — the intersection.
    permissions = manifest[:permissions].not_nil!
    permissions["*.*.except.create"].should eq(["core.SystemSettings"])
  end

  it "collapses the fold when a same-action wildcard line has no except" do
    role = manifest_role_content([
      manifest_perm("create", "*.*", except: ["core.DocType"]),
      manifest_perm("create", "*.*"),
    ])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    permissions = manifest[:permissions].not_nil!
    permissions.has_key?("*.*.except.create").should be_false
  end

  it "keeps the webhook create grant beside its $mine re-grants (B-85)" do
    role = manifest_role_content([
      manifest_perm("create", "*.*", except: ["core.DocType", "core.SystemSettings"]),
      manifest_perm("update", "*.*", except: ["core.SystemSettings", "core.Webhook"]),
      manifest_perm("read", "*.*", except: ["core.SystemSettings", "core.Webhook"]),
      manifest_perm("read", "core.Webhook", scope: ["$mine"]),
      manifest_perm("update", "core.Webhook", scope: ["$mine"]),
    ])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    permissions = manifest[:permissions].not_nil!
    permissions["core.Webhook"].should eq(["read", "update"])
    # The create line does not subtract core.Webhook — the create fold must
    # not name it, or the frontend hides the create button the API serves.
    permissions["*.*.except.create"].should eq(["core.DocType", "core.SystemSettings"])
    permissions["*.*.except.update"].should eq(["core.SystemSettings", "core.Webhook"])
  end

  it "emits no reserved key for a wildcard line without except" do
    role = manifest_role_content([manifest_perm("read", "*.*")])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    permissions = manifest[:permissions].not_nil!
    permissions["*.*"].should eq(["read"])
    permissions.has_key?("*.*.except.read").should be_false
  end

  it "keeps explicit doctype keys unchanged next to the reserved key" do
    role = manifest_role_content([
      manifest_perm("update", "*.*", except: ["core.Domain"]),
      manifest_perm("update", "core.Domain"),
    ])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    permissions = manifest[:permissions].not_nil!
    permissions["core.Domain"].should eq(["update"])
    permissions["*.*"].should eq(["update"])
    permissions["*.*.except.update"].should eq(["core.Domain"])
  end

  it "normalizes a bare doctype path to the iam domain" do
    role = manifest_role_content([manifest_perm("read", "Account")])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    manifest[:permissions].not_nil!["iam.Account"].should eq(["read"])
  end

  it "emits a domain-wildcard key for a domain-wide line" do
    role = manifest_role_content([manifest_perm("read", "hr")])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    permissions = manifest[:permissions].not_nil!
    permissions["hr.*"].should eq(["read"])
    # A domain-wide line must NOT be prefixed with `iam.` (B-121).
    permissions.has_key?("iam.hr").should be_false
  end

  it "keeps a domain-wide key beside an explicit doctype key in the same domain" do
    role = manifest_role_content([
      manifest_perm("read", "hr"),
      manifest_perm("update", "hr.Request"),
    ])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    permissions = manifest[:permissions].not_nil!
    permissions["hr.*"].should eq(["read"])
    permissions["hr.Request"].should eq(["update"])
  end

  it "carries a domain-wide line's scopes under the domain-wildcard key" do
    role = manifest_role_content([manifest_perm("create", "hr", scope: ["$mine"])])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    scopes = manifest[:scopes].not_nil!
    scopes["hr.*"].should eq({"create" => ["mine"]})
  end

  it "produces a scopes entry for wildcard lines under *.*" do
    role = manifest_role_content([manifest_perm("read", "*.*")])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    scopes = manifest[:scopes].not_nil!
    scopes["*.*"].should eq({"read" => [] of String})
  end

  it "carries the wildcard line's named scopes under scopes[*.*]" do
    role = manifest_role_content([manifest_perm("create", "*.*", scope: ["$mine"])])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    scopes = manifest[:scopes].not_nil!
    scopes["*.*"].should eq({"create" => ["mine"]})
  end

  it "merges wildcard and explicit lines per action without cross-talk" do
    role = manifest_role_content([
      manifest_perm("read", "*.*"),
      manifest_perm("read", "crm.Deal", scope: ["$mine"]),
    ])

    manifest = Facet::IAM::Helpers.build_permission_manifest(role)

    scopes = manifest[:scopes].not_nil!
    scopes["*.*"].should eq({"read" => [] of String})
    scopes["crm.Deal"].should eq({"read" => ["mine"]})
  end

  it "returns nil for both fields when the role has no permissions" do
    empty_array = manifest_role_content([] of JSON::Any)
    missing_key = JSON.parse(%({"name": "viewer"}))

    Facet::IAM::Helpers.build_permission_manifest(empty_array)[:permissions].should be_nil
    Facet::IAM::Helpers.build_permission_manifest(empty_array)[:scopes].should be_nil
    Facet::IAM::Helpers.build_permission_manifest(missing_key)[:permissions].should be_nil
    Facet::IAM::Helpers.build_permission_manifest(missing_key)[:scopes].should be_nil
  end
end

describe "Facet::IAM::Helpers.link_validity_text" do
  it "states the largest unit that divides the TTL exactly" do
    Facet::IAM::Helpers.link_validity_text(86_400).should eq("1 day")
    Facet::IAM::Helpers.link_validity_text(172_800).should eq("2 days")
    Facet::IAM::Helpers.link_validity_text(3_600).should eq("1 hour")
    Facet::IAM::Helpers.link_validity_text(7_200).should eq("2 hours")
    Facet::IAM::Helpers.link_validity_text(1_800).should eq("30 minutes")
    Facet::IAM::Helpers.link_validity_text(5_400).should eq("90 minutes")
    Facet::IAM::Helpers.link_validity_text(60).should eq("1 minute")
  end

  it "floors a non-minute multiple to whole minutes so the copy never overstates" do
    Facet::IAM::Helpers.link_validity_text(3_661).should eq("61 minutes")
  end

  it "falls back to seconds below one minute" do
    Facet::IAM::Helpers.link_validity_text(59).should eq("59 seconds")
    Facet::IAM::Helpers.link_validity_text(30).should eq("30 seconds")
    Facet::IAM::Helpers.link_validity_text(1).should eq("1 second")
  end
end
