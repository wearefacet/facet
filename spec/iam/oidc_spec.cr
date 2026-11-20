# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/http/server"
require "../support/http_helper"
require "../support/oidc_helper"

HTTPTest.init

alias OIDC = Facet::IAM::OIDC

# Reads the `details` of every LoginEvent with the given event name — used
# to assert audit content without leaking it into responses.
def oidc_event_details(db, event : String) : Array(String)
  db.query_all(
    "SELECT content->>'details' FROM projections " \
    "WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL " \
    "AND content->>'event' = $1",
    event, as: String
  )
end

# Reads the content of an iam.Account projection.
def oidc_account_content(db, account_id : String) : JSON::Any
  db.query_one(
    "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' " \
    "AND id = $1 AND deleted_at IS NULL",
    account_id, as: JSON::Any
  )
end

# Writes a federated identity link straight onto the account document —
# the manual-link fixture for the step-1 resolution tests.
def oidc_link_account(db, account_id : String, provider_name : String, subject : String) : Nil
  patch = {
    "federated_identities" => [
      {"provider" => provider_name, "subject" => subject, "linked_at" => Time.utc.to_rfc3339},
    ],
  }.to_json
  result = Facet::IAM::AccountPatch.call(db, account_id, patch)
  raise "failed to link account: #{result.inspect}" if result.is_a?(Facet::ServiceError)
end

def oidc_links(db, account_id : String) : Array(JSON::Any)
  content = oidc_account_content(db, account_id)
  content["federated_identities"]?.try(&.as_a?) || [] of JSON::Any
end

private def claims(sub : String, email : String? = nil, verified : Bool = false,
                   name : String? = nil) : OIDC::Identity::Claims
  OIDC::Identity::Claims.new(sub: sub, email: email, email_verified: verified, display_name: name)
end

# The registry record the Identity specs act on — read through the store
# so the specs exercise the same provider shape the routes see. The
# describe blocks seed the `testidp` provider in `before_each`.
private def test_provider(db) : OIDC::Provider
  found = OIDC::Providers.find(db, "testidp")
  raise "testidp provider not seeded" if found.nil?
  found
end

private def ensure_oidc_doctypes(db) : Nil
  # Definitions only — the spec seeds its own role rows via
  # `seed_test_roles` (raw creates), and the provider's `default_role`
  # reference check needs the `iam.Roles` doctype registered, not its rows.
  %w[core.DocType core.Domain iam.Account iam.Roles iam.OIDCProvider].each do |dir|
    domain, doctype = dir.split(".", 2)
    Facet::Doctype::Seed.ensure_doctype_definition(db, domain, doctype)
  end
  Facet::Doctype::DefinitionStore.cache.clear
end

# Restores the seed corpus after the per-example truncation (scoped
# re-ensures — idempotent), then seeds the canonical provider and the
# account/role doctypes the Identity flow needs.
private def seed_oidc_fixture(db) : Nil
  ensure_oidc_doctypes(db)
  seed_test_roles(db)
  seed_oidc_provider(db)
end

describe Facet::IAM::OIDC::Providers do
  before_each do
    oidc_redis_cleanup
    with_db do |db|
      # Corpus only — each example seeds exactly the providers it asserts
      # on, so the counts below are exact.
      ensure_oidc_doctypes(db)
      seed_test_roles(db)
    end
  end

  after_each do
    oidc_redis_cleanup
    unstub_oidc
  end

  it "finds a seeded enabled provider by name" do
    with_db do |db|
      seed_oidc_provider(db, name: "okta")
      OIDC::Providers.find(db, "okta").should_not be_nil
      OIDC::Providers.find(db, "other").should be_nil
    end
  end

  it "hides a disabled provider — a disabled name denies like an unknown one" do
    with_db do |db|
      seed_oidc_provider(db, name: "okta", enabled: false)
      OIDC::Providers.find(db, "okta").should be_nil
      OIDC::Providers.summaries(db).should be_empty
    end
  end

  it "excludes tombstoned providers from the registry" do
    with_db do |db|
      doc_id = seed_oidc_provider(db, name: "okta")
      delete_oidc_provider(db, doc_id)
      OIDC::Providers.find(db, "okta").should be_nil
    end
  end

  it "summarizes providers with name and label only" do
    with_db do |db|
      seed_oidc_provider(db, name: "okta", label: "Okta")
      seed_oidc_provider(db, name: "authzero")
      summaries = OIDC::Providers.summaries(db)
      summaries.size.should eq(2)
      names = summaries.map(&.[:name]).sort!
      names.should eq(%w[authzero okta])
      okta = summaries.find { |s| s[:name] == "okta" }.should_not be_nil
      okta[:label].should eq("Okta")
    end
  end

  it "evicts the cached list on invalidate (fanout path)" do
    with_db do |db|
      seed_oidc_provider(db, name: "okta")
      OIDC::Providers.summaries(db).size.should eq(1)

      # A provider created after a cached read is invisible until the
      # invalidation lands — the exact contract the Pub/Sub subscriber
      # drives in the server process.
      seed_oidc_provider(db, name: "authzero")
      Facet::IAM::OIDC::ProviderStore.cache.should be_a(Facet::IAM::OIDC::ProviderStore::PassThrough)
      Facet::IAM::OIDC::ProviderStore.invalidate
      OIDC::Providers.summaries(db).size.should eq(2)
    end
  end
end

describe Facet::IAM::OIDC::Discovery do
  before_each do
    oidc_redis_cleanup
    OIDC::Discovery.reset!
  end

  after_each do
    oidc_redis_cleanup
    unstub_oidc
  end

  it "fetches the discovery document once and caches it" do
    stub = OidcIdpStub.new(discovery_body, jwks_body([] of OIDC::JWK))
    stub_oidc(stub)
    2.times { OIDC::Discovery.endpoints(OIDC_ISSUER) }
    stub.discovery_calls.should eq(1)
  end

  it "fetches the JWKS once and caches it" do
    rsa = oidc_rsa_key("k1")
    stub = OidcIdpStub.new(discovery_body, jwks_body([rsa.oidc_jwk]))
    stub_oidc(stub)
    endpoints = OIDC::Discovery.endpoints(OIDC_ISSUER)
    2.times { OIDC::Discovery.keys(OIDC_ISSUER, endpoints.jwks_uri) }
    stub.jwks_calls.should eq(1)
  end

  it "denies with discovery_failed when the discovery fetch fails" do
    stub = OidcIdpStub.new(discovery_body, "", discovery_status: 500)
    stub_oidc(stub)
    expect_raises(OIDC::Error, /discovery/) do
      OIDC::Discovery.endpoints(OIDC_ISSUER)
    end
  end

  it "denies when the discovery document is missing members" do
    partial = %({"issuer": "#{OIDC_ISSUER}", "authorization_endpoint": "#{OIDC_AUTHORIZE}"})
    stub = OidcIdpStub.new(partial, "")
    stub_oidc(stub)
    expect_raises(OIDC::Error, /token_endpoint/) do
      OIDC::Discovery.endpoints(OIDC_ISSUER)
    end
  end
end

describe Facet::IAM::OIDC::Verify do
  rsa = oidc_rsa_key("rsa-1")
  ec = oidc_ec_key("ec-1")
  provider = oidc_provider_record
  keys = {"rsa-1" => rsa.oidc_jwk, "ec-1" => ec.oidc_jwk}

  before_each do
    oidc_redis_cleanup
  end

  after_each do
    oidc_redis_cleanup
    unstub_oidc
  end

  it "verifies a valid RS256 token" do
    token = sign_id_token(id_token_payload(sub: "sub-1", nonce: "nonce"), rsa, kid: "rsa-1")
    payload = OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    payload["sub"].as_s.should eq("sub-1")
  end

  it "verifies a valid ES256 token" do
    token = sign_id_token(id_token_payload(sub: "sub-1", nonce: "nonce"), ec, alg: "ES256", kid: "ec-1")
    payload = OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    payload["sub"].as_s.should eq("sub-1")
  end

  it "rejects a wrong issuer" do
    token = sign_id_token(id_token_payload(iss: "https://evil.test"), rsa, kid: "rsa-1")
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("invalid_iss")
  end

  it "rejects a wrong audience" do
    token = sign_id_token(id_token_payload(aud: "other-client"), rsa, kid: "rsa-1")
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("invalid_aud")
  end

  it "rejects an expired token" do
    token = sign_id_token(id_token_payload(exp: Time.utc.to_unix - 10), rsa, kid: "rsa-1")
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("expired_token")
  end

  it "rejects a wrong nonce" do
    token = sign_id_token(id_token_payload(nonce: "other-nonce"), rsa, kid: "rsa-1")
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("invalid_nonce")
  end

  it "rejects an iat that is too far in the past" do
    payload = id_token_payload(iat: Time.utc.to_unix - 48 * 3600)
    token = sign_id_token(payload, rsa, kid: "rsa-1")
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("invalid_iat")
  end

  it "rejects a token with a missing iat" do
    payload = id_token_payload
    payload.delete("iat")
    token = sign_id_token(payload, rsa, kid: "rsa-1")
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("invalid_token")
  end

  it "rejects alg none" do
    token = unsigned_id_token(id_token_payload)
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("invalid_alg")
  end

  it "rejects alg HS256" do
    token = sign_id_token(id_token_payload, rsa, alg: "HS256", kid: "rsa-1")
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("invalid_alg")
  end

  it "rejects a bad signature" do
    token = sign_id_token(id_token_payload, rsa, kid: "rsa-1", bad_signature: true)
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("invalid_signature")
  end

  it "rejects a token signed by a key that is not in the key set" do
    stranger = oidc_rsa_key("stranger")
    token = sign_id_token(id_token_payload, stranger, kid: "stranger")
    ex = expect_raises(OIDC::Error) do
      OIDC::Verify.verify_with_keys(token, provider, "nonce", keys)
    end
    ex.code.should eq("unknown_kid")
  end

  it "refreshes the JWKS exactly once on an unknown kid and then succeeds" do
    rsa_old = oidc_rsa_key("k-old")
    rsa_new = oidc_rsa_key("k-new")
    jwks_fetches = 0
    Facet::IAM::OIDC::Fetcher.impl = ->(_method : String, url : String?, _headers : ::HTTP::Headers, _body : String?) do
      if url.as(String) == OIDC_JWKS_URI
        jwks_fetches += 1
        body_text = jwks_fetches == 1 ? jwks_body([rsa_old.oidc_jwk]) : jwks_body([rsa_new.oidc_jwk])
        {status: 200, body: body_text}
      else
        {status: 200, body: discovery_body}
      end
    end
    OIDC::Discovery.reset!

    token = sign_id_token(id_token_payload(sub: "sub-rot", nonce: "nonce"), rsa_new, kid: "k-new")
    payload = OIDC::Verify.call(token, provider, "nonce")
    payload["sub"].as_s.should eq("sub-rot")
    jwks_fetches.should eq(2)
  end
end

describe Facet::IAM::OIDC::Identity do
  before_each do
    oidc_redis_cleanup
    with_db do |db|
      seed_oidc_fixture(db)
      # The JIT specs pin `iam.oidc.provision_roles` through the document
      # pipeline — the doctype definition and the null singleton document
      # must exist after truncation.
      Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
      Facet::SystemSettings.mark_stale
    end
  end

  after_each do
    oidc_redis_cleanup
    unstub_oidc
  end

  it "resolves a known identity link to its account" do
    with_db do |db|
      account_id = create_test_account(db, email: "alice@example.test")
      oidc_link_account(db, account_id, "testidp", "sub-alice")

      result = OIDC::Identity.resolve(db, test_provider(db), claims("sub-alice"))
      result.should be_a(OIDC::Identity::Resolved)
      resolved = result.as(OIDC::Identity::Resolved)
      resolved.account.id.should eq(account_id)
      resolved.linked.should be_false
      resolved.provisioned.should be_false
      # No duplicate link appended.
      oidc_links(db, account_id).size.should eq(1)
    end
  end

  it "links on an email match only with email_verified and an allowlisted domain" do
    with_db do |db|
      account_id = create_test_account(db, email: "bob@example.test")
      provider = test_provider(db)

      result = OIDC::Identity.resolve(db, provider, claims("sub-bob", "bob@example.test", verified: true))
      resolved = result.as(OIDC::Identity::Resolved)
      resolved.account.id.should eq(account_id)
      resolved.linked.should be_true

      links = oidc_links(db, account_id)
      links.size.should eq(1)
      entry = links[0].as_h
      entry["provider"].as_s.should eq("testidp")
      entry["subject"].as_s.should eq("sub-bob")
      entry["linked_at"].as_s.should_not be_empty
    end
  end

  it "never links on an unverified email" do
    with_db do |db|
      account_id = create_test_account(db, email: "carol@example.test")
      provider = test_provider(db)

      result = OIDC::Identity.resolve(db, provider, claims("sub-carol", "carol@example.test", verified: false))
      result.should be_a(OIDC::Identity::Denied)
      oidc_links(db, account_id).size.should eq(0)
    end
  end

  it "never links when the email domain is not allowlisted" do
    with_db do |db|
      account_id = create_test_account(db, email: "dave@evil.test")
      provider = test_provider(db)

      result = OIDC::Identity.resolve(db, provider, claims("sub-dave", "dave@evil.test", verified: true))
      result.should be_a(OIDC::Identity::Denied)
      oidc_links(db, account_id).size.should eq(0)
    end
  end

  it "denies a suspended account that holds the matching link" do
    with_db do |db|
      account_id = create_test_account(db, email: "susp@example.test", status: "suspended")
      oidc_link_account(db, account_id, "testidp", "sub-susp")

      result = OIDC::Identity.resolve(db, test_provider(db), claims("sub-susp"))
      denied = result.as(OIDC::Identity::Denied)
      denied.reason.includes?("suspended").should be_true
      denied.account_id.should eq(account_id)
    end
  end

  it "denies a suspended account on email match without duplicating the link" do
    with_db do |db|
      account_id = create_test_account(db, email: "susp2@example.test", status: "suspended")

      result = OIDC::Identity.authenticate(db, test_provider(db),
        claims("sub-susp2", "susp2@example.test", verified: true))
      result.should be_a(Facet::ServiceError)
      oidc_links(db, account_id).size.should eq(0)
      login_events(db).includes?("oidc_denied").should be_true
    end
  end

  it "denies a service account on an email match" do
    with_db do |db|
      create_service_account(db, "bot@example.test")

      result = OIDC::Identity.resolve(db, test_provider(db), claims("sub-bot", "bot@example.test", verified: true))
      result.should be_a(OIDC::Identity::Denied)
    end
  end

  it "JIT-provisions an active account with the default role and the link" do
    with_db do |db|
      seed_test_roles(db)
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
      provider = test_provider(db)

      result = OIDC::Identity.authenticate(db, provider,
        claims("sub-jit", "fresh@example.test", verified: true, name: "Fresh User"))
      token_result = result.as(Facet::IAM::TokenEmitter::Result)

      content = oidc_account_content(db, token_result.account_id)
      content["status"].as_s.should eq("active")
      content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.admin"])
      content["default_role"].as_s.should eq("iam.Roles.admin")
      content["organizational_unit"].as_s.should eq("/")

      links = content["federated_identities"].as_a
      links.size.should eq(1)
      links[0].as_h["provider"].as_s.should eq("testidp")
      links[0].as_h["subject"].as_s.should eq("sub-jit")

      events = login_events(db)
      events.includes?("oidc_provisioned").should be_true
      events.includes?("oidc_login").should be_true
    end
  end

  it "provisions with the document id derived from the email" do
    with_db do |db|
      seed_test_roles(db)
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
      provider = test_provider(db)

      result = OIDC::Identity.authenticate(db, provider,
        claims("sub-id-email", "Fresh.User@Example.TEST", verified: true))
      token_result = result.as(Facet::IAM::TokenEmitter::Result)

      # The id IS the lowercased email — readable in every raw surface.
      token_result.account_id.should eq("fresh.user@example.test")
      content = oidc_account_content(db, token_result.account_id)
      content["email"].as_s.should eq("fresh.user@example.test")
    end
  end

  it "provisions the instance-wide role baseline when the provider sets no default_role" do
    with_db do |db|
      seed_test_roles(db)
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
      doc_id = seed_oidc_provider(db, name: "baseline", default_role: nil)
      patch = Facet::Document::Update.call(db, "iam", "OIDCProvider", doc_id,
        %({"default_role": null}), Facet::RBAC::AuthContext.system)
      raise "failed to drop role: #{patch.inspect}" if patch.is_a?(Facet::ServiceError)
      provider = OIDC::Providers.find(db, "baseline").should_not be_nil

      # Pin the instance baseline: editor + viewer (multi-role).
      settings = Facet::Document::Update.call(db, "core", "SystemSettings", "settings",
        %({"iam": {"oidc": {"provision_roles": ["iam.Roles.editor", "iam.Roles.viewer"]}}}),
        Facet::RBAC::AuthContext.system)
      raise "failed to pin baseline: #{settings.inspect}" if settings.is_a?(Facet::ServiceError)

      result = OIDC::Identity.resolve(db, provider.as(OIDC::Provider),
        claims("sub-baseline", "employee@example.test", verified: true))
      resolved = result.as(OIDC::Identity::Resolved)
      resolved.provisioned.should be_true
      resolved.account.id.should eq("employee@example.test")

      content = oidc_account_content(db, "employee@example.test")
      content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.editor", "iam.Roles.viewer"])
      # The first baseline role doubles as the account default.
      content["default_role"].as_s.should eq("iam.Roles.editor")
    end
  end

  it "prefers the provider default_role over the instance baseline" do
    with_db do |db|
      seed_test_roles(db)
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
      provider = test_provider(db) # default_role: iam.Roles.admin

      settings = Facet::Document::Update.call(db, "core", "SystemSettings", "settings",
        %({"iam": {"oidc": {"provision_roles": ["iam.Roles.viewer"]}}}),
        Facet::RBAC::AuthContext.system)
      raise "failed to pin baseline: #{settings.inspect}" if settings.is_a?(Facet::ServiceError)

      result = OIDC::Identity.resolve(db, provider,
        claims("sub-override", "override@example.test", verified: true))
      resolved = result.as(OIDC::Identity::Resolved)
      resolved.provisioned.should be_true

      content = oidc_account_content(db, "override@example.test")
      content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.admin"])
      content["default_role"].as_s.should eq("iam.Roles.admin")
    end
  end

  it "denies JIT provisioning when neither the provider nor the instance sets roles" do
    with_db do |db|
      seed_test_roles(db)
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
      doc_id = seed_oidc_provider(db, name: "roleless", default_role: nil)
      patch = Facet::Document::Update.call(db, "iam", "OIDCProvider", doc_id,
        %({"default_role": null}), Facet::RBAC::AuthContext.system)
      raise "failed to drop role: #{patch.inspect}" if patch.is_a?(Facet::ServiceError)
      provider = OIDC::Providers.find(db, "roleless").should_not be_nil

      resolved = OIDC::Identity.resolve(db, provider.as(OIDC::Provider),
        claims("sub-roleless", "roleless@example.test", verified: true))
      resolved.should be_a(OIDC::Identity::Denied)

      count = db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
        as: Int64
      )
      count.should eq(0)
    end
  end

  it "bootstraps a pending account on federated login" do
    with_db do |db|
      seed_test_roles(db)
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
      account_id = create_test_account(db, email: "pending@example.test", status: "pending")
      oidc_link_account(db, account_id, "testidp", "sub-pending")

      result = OIDC::Identity.authenticate(db, test_provider(db), claims("sub-pending"))
      token_result = result.as(Facet::IAM::TokenEmitter::Result)
      token_result.account_id.should eq(account_id)
      oidc_account_content(db, account_id)["status"].as_s.should eq("active")
    end
  end

  it "denies when auto_provision is false and the email is unknown" do
    with_db do |db|
      doc_id = seed_oidc_provider(db, name: "manual")
      # Patch the just-created provider to auto_provision: false.
      result = Facet::Document::Update.call(db, "iam", "OIDCProvider", doc_id,
        %({"auto_provision": false}), Facet::RBAC::AuthContext.system)
      raise "failed to disable auto_provision: #{result.inspect}" if result.is_a?(Facet::ServiceError)
      provider = OIDC::Providers.find(db, "manual").should_not be_nil

      resolved = OIDC::Identity.resolve(db, provider.as(OIDC::Provider),
        claims("sub-none", "ghost@example.test", verified: true))
      resolved.should be_a(OIDC::Identity::Denied)

      count = db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
        as: Int64
      )
      count.should eq(0)
    end
  end

  it "never provisions an unverified email" do
    with_db do |db|
      provider = test_provider(db)

      result = OIDC::Identity.resolve(db, provider,
        claims("sub-uv", "unverified@example.test", verified: false))
      result.should be_a(OIDC::Identity::Denied)

      count = db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
        as: Int64
      )
      count.should eq(0)
    end
  end

  it "does not silently take over: same email with a different sub follows the email rules" do
    with_db do |db|
      account_id = create_test_account(db, email: "erin@example.test")
      oidc_link_account(db, account_id, "testidp", "sub-erin")
      provider = test_provider(db)

      # A second, different sub with a verified matching email links
      # through the email-match rule — the original link stays intact.
      result = OIDC::Identity.resolve(db, provider, claims("sub-erin-2", "erin@example.test", verified: true))
      resolved = result.as(OIDC::Identity::Resolved)
      resolved.account.id.should eq(account_id)
      subjects = oidc_links(db, account_id).map(&.as_h["subject"].as_s)
      subjects.should eq(["sub-erin", "sub-erin-2"])

      # The original link still resolves to the account.
      again = OIDC::Identity.resolve(db, provider, claims("sub-erin"))
      again.as(OIDC::Identity::Resolved).account.id.should eq(account_id)

      # An unverified email with yet another sub never links.
      denied = OIDC::Identity.resolve(db, provider, claims("sub-erin-3", "erin@example.test", verified: false))
      denied.should be_a(OIDC::Identity::Denied)
      oidc_links(db, account_id).size.should eq(2)
    end
  end

  it "defensively denies when two accounts hold the same link and writes an audit event" do
    with_db do |db|
      seed_test_roles(db)
      account_a = create_test_account(db, email: "dup-a@example.test")
      account_b = create_test_account(db, email: "dup-b@example.test")
      oidc_link_account(db, account_a, "testidp", "sub-dup")
      oidc_link_account(db, account_b, "testidp", "sub-dup")

      result = OIDC::Identity.authenticate(db, test_provider(db), claims("sub-dup"))
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).message.should eq("Login denied")

      details = oidc_event_details(db, "oidc_denied")
      details.size.should eq(1)
      details[0].includes?("multiple accounts").should be_true
      login_events(db).includes?("oidc_login").should be_false
    end
  end

  it "carries no denial detail in the response" do
    with_db do |db|
      create_test_account(db, email: "susp3@example.test", status: "disabled")

      result = OIDC::Identity.authenticate(db, test_provider(db),
        claims("sub-susp3", "susp3@example.test", verified: true))
      error = result.as(Facet::ServiceError)
      error.message.should eq("Login denied")
      error.message.downcase.includes?("disabled").should be_false
    end
  end

  it "re-resolves instead of duplicating when JIT collides on the email" do
    with_db do |db|
      seed_test_roles(db)
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")

      # The spec template never materializes managed indexes (the singleton
      # pool is not initialized during template seeding), so the DB-level
      # unique enforcement the JIT race relies on does not exist here. This
      # index is exactly what production's `unique_btree` looks like.
      db.exec(<<-SQL)
        CREATE UNIQUE INDEX IF NOT EXISTS idx_spec_iam_account_email
        ON projections ((content->>'email'))
        WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL
      SQL

      provider = test_provider(db)
      race_claims = claims("sub-race", "race@example.test", verified: true)

      results = Channel(Facet::IAM::TokenEmitter::Result | Facet::ServiceError).new
      2.times do
        spawn do
          Facet::Database.with_db do |fiber_db|
            results.send(OIDC::Identity.authenticate(fiber_db, provider, race_claims))
          end
        end
      end
      first = results.receive
      second = results.receive

      ids = db.query_all(
        "SELECT id FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
        as: String
      )
      ids.size.should eq(1)

      first.should be_a(Facet::IAM::TokenEmitter::Result)
      second.should be_a(Facet::IAM::TokenEmitter::Result)
      first.as(Facet::IAM::TokenEmitter::Result).account_id.should eq(ids[0])
      second.as(Facet::IAM::TokenEmitter::Result).account_id.should eq(ids[0])

      # Exactly one provisioning happened; the loser re-resolved.
      oidc_event_details(db, "oidc_provisioned").size.should eq(1)
    end
  end
end

describe "GET /auth/oidc/:provider" do
  before_each do
    oidc_redis_cleanup
    OIDC::Discovery.reset!
    with_db do |db|
      seed_oidc_fixture(db)
    end
  end

  after_each do
    oidc_redis_cleanup
    unstub_oidc
  end

  it "redirects to the authorization endpoint with state, nonce, and PKCE" do
    stub = OidcIdpStub.new(discovery_body, jwks_body([] of OIDC::JWK))
    stub_oidc(stub)
    response = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp"))
    assert_http_status(response, 302)
    response.headers["Location"].should start_with(OIDC_AUTHORIZE)
    redirect_param(response, "response_type").should eq("code")
    redirect_param(response, "client_id").should eq("client-123")
    redirect_param(response, "redirect_uri").should eq("https://localhost:3000/auth/oidc/testidp/callback")
    redirect_param(response, "scope").should eq("openid email profile")
    redirect_param(response, "state").size.should eq(64)
    redirect_param(response, "nonce").size.should eq(64)
    redirect_param(response, "code_challenge").size.should eq(43)
    redirect_param(response, "code_challenge_method").should eq("S256")
    oidc_state_raw(redirect_param(response, "state")).should_not be_nil
  end

  it "denies an unknown provider with the generic redirect" do
    response = call_api(HTTP::Request.new("GET", "/auth/oidc/who-dis"))
    assert_http_status(response, 302)
    response.headers["Location"].should eq("/Login?error=oidc_denied")
  end

  it "denies a disabled provider with the same generic redirect" do
    with_db do |db|
      seed_oidc_provider(db, name: "off-provider", enabled: false)
      response = call_api(HTTP::Request.new("GET", "/auth/oidc/off-provider"))
      assert_http_status(response, 302)
      response.headers["Location"].should eq("/Login?error=oidc_denied")
    end
  end

  it "denies when discovery fails" do
    stub = OidcIdpStub.new(discovery_body, "", discovery_status: 500)
    stub_oidc(stub)
    response = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp"))
    assert_http_status(response, 302)
    response.headers["Location"].should eq("/Login?error=oidc_denied")
  end
end

# Starts the flow against the canonical stub IdP (the token endpoint is
# stubbed but not yet consumed) and returns the state value.
def start_flow(rsa : OidcRsaKey) : String
  stub = OidcIdpStub.new(discovery_body, jwks_body([rsa.oidc_jwk]))
  stub_oidc(stub)

  start = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp"))
  assert_http_status(start, 302)
  redirect_param(start, "state")
end

describe "GET /auth/oidc/:provider/callback" do
  before_each do
    oidc_redis_cleanup
    OIDC::Discovery.reset!
    with_db do |db|
      seed_oidc_fixture(db)
    end
  end

  after_each do
    oidc_redis_cleanup
    unstub_oidc
  end

  it "exchanges the code, provisions the account, sets cookies, and redirects home" do
    rsa = oidc_rsa_key("rsa-1")
    state = start_flow(rsa)

    # The nonce in the id_token must be the stored one.
    raw = oidc_state_raw(state)
    raise "missing state row" unless raw
    nonce = JSON.parse(raw)["nonce"].as_s
    token_body = {
      "access_token" => "at-123",
      "token_type"   => "Bearer",
      "id_token"     => sign_id_token(id_token_payload(sub: "sub-route",
        email: "routed@example.test", email_verified: true, name: "Route User",
        nonce: nonce), rsa, kid: "rsa-1"),
    }.to_json
    stub = OidcIdpStub.new(discovery_body, jwks_body([rsa.oidc_jwk]), token_body: token_body)
    stub_oidc(stub)

    response = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp/callback?code=auth-code&state=#{state}"))
    assert_http_status(response, 302)
    response.headers["Location"].should eq("/")

    # The session rides in cookies.
    cookies = response.headers.get?("Set-Cookie").try(&.join("; ")) || ""
    cookies.includes?("auth_token=").should be_true

    # The exchange carried the code and the PKCE verifier.
    stub.token_calls.should eq(1)
    body = stub.token_bodies[0]
    body.includes?("code=auth-code").should be_true
    body.includes?("code_verifier=").should be_true
    body.includes?("grant_type=authorization_code").should be_true

    # The account exists, provisioned and linked.
    with_db do |db|
      ids = db.query_all(
        "SELECT id FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
        as: String
      )
      ids.size.should eq(1)
      content = oidc_account_content(db, ids[0])
      content["email"].as_s.should eq("routed@example.test")
      content["status"].as_s.should eq("active")
      links = content["federated_identities"].as_a
      links.size.should eq(1)
      links[0].as_h["subject"].as_s.should eq("sub-route")

      events = login_events(db)
      events.includes?("oidc_provisioned").should be_true
      events.includes?("oidc_login").should be_true
    end
  end

  it "denies a replayed state" do
    rsa = oidc_rsa_key("rsa-1")
    state = start_flow(rsa)

    raw = oidc_state_raw(state)
    raise "missing state row" unless raw
    nonce = JSON.parse(raw)["nonce"].as_s
    token_body = {
      "id_token" => sign_id_token(id_token_payload(sub: "sub-replay",
        email: "replay@example.test", email_verified: true, nonce: nonce), rsa, kid: "rsa-1"),
    }.to_json
    stub = OidcIdpStub.new(discovery_body, jwks_body([rsa.oidc_jwk]), token_body: token_body)
    stub_oidc(stub)

    first = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp/callback?code=auth-code&state=#{state}"))
    assert_http_status(first, 302)
    second = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp/callback?code=auth-code&state=#{state}"))
    assert_http_status(second, 302)
    second.headers["Location"].should eq("/Login?error=oidc_denied")
  end

  it "carries the PKCE verifier in the exchange and fails on a wrong one" do
    rsa = oidc_rsa_key("rsa-1")
    state = start_flow(rsa)

    raw = oidc_state_raw(state)
    raise "missing state row" unless raw
    row = JSON.parse(raw)
    real_verifier = row["verifier"].as_s
    nonce = row["nonce"].as_s

    token_body = {
      "id_token" => sign_id_token(id_token_payload(sub: "sub-pkce",
        email: "pkce@example.test", email_verified: true, nonce: nonce), rsa, kid: "rsa-1"),
    }.to_json
    stub = OidcIdpStub.new(discovery_body, jwks_body([rsa.oidc_jwk]), token_body: token_body)
    stub.expected_verifier = real_verifier
    stub_oidc(stub)

    # Corrupt the stored verifier — the exchange then presents a wrong
    # one and the IdP rejects the grant.
    row_h = row.as_h
    row_h["verifier"] = JSON::Any.new("wrong-verifier-0000000000000000000000000000000000000000")
    with_redis do |r|
      r.set("oidc:state:#{state}", row_h.to_json, ex: 300.seconds)
    end

    response = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp/callback?code=auth-code&state=#{state}"))
    assert_http_status(response, 302)
    response.headers["Location"].should eq("/Login?error=oidc_denied")
    # The exchange DID go out with the (wrong) verifier — the IdP, not
    # the server, rejected it.
    stub.token_calls.should eq(1)
    stub.token_bodies[0].includes?("code_verifier=wrong-verifier").should be_true
    # No detail leaks into the response body.
    response.body.includes?("verifier").should be_false
  end

  it "denies without a state parameter and leaks no detail" do
    response = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp/callback?code=auth-code"))
    assert_http_status(response, 302)
    response.headers["Location"].should eq("/Login?error=oidc_denied")
  end

  it "denies when the token exchange is rejected" do
    rsa = oidc_rsa_key("rsa-1")
    state = start_flow(rsa)

    stub = OidcIdpStub.new(discovery_body, jwks_body([rsa.oidc_jwk]), token_body: "", token_status: 400)
    stub_oidc(stub)

    response = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp/callback?code=auth-code&state=#{state}"))
    assert_http_status(response, 302)
    response.headers["Location"].should eq("/Login?error=oidc_denied")
    with_db do |db|
      login_events(db).includes?("oidc_denied").should be_true
    end
  end

  it "denies when the provider has no readable client secret (fail closed)" do
    rsa = oidc_rsa_key("rsa-1")
    state = start_flow(rsa)

    nonce = JSON.parse(oidc_state_raw(state).not_nil!)["nonce"].as_s
    token_body = {
      "id_token" => sign_id_token(id_token_payload(sub: "sub-nosecret",
        email: "nosecret@example.test", email_verified: true, nonce: nonce), rsa, kid: "rsa-1"),
    }.to_json
    stub = OidcIdpStub.new(discovery_body, jwks_body([rsa.oidc_jwk]), token_body: token_body)
    stub_oidc(stub)

    # A seeded provider whose document content carries the secret marker
    # but whose sealed slot was cleared — the reveal cannot open.
    with_db do |db|
      db.exec(
        "DELETE FROM secrets WHERE domain = 'iam' AND doc_type = 'OIDCProvider' AND slot = 'client_secret'"
      )
    end

    response = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp/callback?code=auth-code&state=#{state}"))
    assert_http_status(response, 302)
    response.headers["Location"].should eq("/Login?error=oidc_denied")
    # The token endpoint was never reached — the denial precedes the
    # exchange.
    stub.token_calls.should eq(0)
    with_db do |db|
      details = oidc_event_details(db, "oidc_denied")
      details.any?(&.includes?("client secret")).should be_true
    end
  end

  it "denies when the id_token fails verification" do
    rsa = oidc_rsa_key("rsa-1")
    state = start_flow(rsa)

    raw = oidc_state_raw(state)
    raise "missing state row" unless raw

    # The token's nonce does not match the stored one.
    token_body = {
      "id_token" => sign_id_token(id_token_payload(sub: "sub-bad",
        email: "bad@example.test", email_verified: true, nonce: "wrong"), rsa, kid: "rsa-1"),
    }.to_json
    stub = OidcIdpStub.new(discovery_body, jwks_body([rsa.oidc_jwk]), token_body: token_body)
    stub_oidc(stub)

    response = call_api(HTTP::Request.new("GET", "/auth/oidc/testidp/callback?code=auth-code&state=#{state}"))
    assert_http_status(response, 302)
    response.headers["Location"].should eq("/Login?error=oidc_denied")
    with_db do |db|
      details = oidc_event_details(db, "oidc_denied")
      details.size.should eq(1)
      details[0].includes?("invalid_nonce").should be_true
    end
    # No account was created.
    with_db do |db|
      count = db.query_one(
        "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
        as: Int64
      )
      count.should eq(0)
    end
  end
end

describe "GET /Api/iam/oidc/providers" do
  before_each do
    with_db do |db|
      ensure_oidc_doctypes(db)
      seed_test_roles(db)
    end
  end

  after_each do
    unstub_oidc
  end

  it "carries the auth mode next to the enabled provider list" do
    with_db do |db|
      seed_oidc_provider(db, name: "okta-corp", label: "Okta Corp")
      seed_oidc_provider(db, name: "authzero")

      response = call_api(HTTP::Request.new("GET", "/Api/iam/oidc/providers"))
      assert_http_status(response, 200)
      body = JSON.parse(response.body)
      body["auth_mode"].to_s.should eq("hybrid")
      providers = body["providers"].as_a
      providers.size.should eq(2)
      names = providers.map(&.as_h["name"].as_s)
      names.sort!.should eq(%w[authzero okta-corp])
      providers.each do |p|
        p.as_h.keys.should eq(%w[name label])
      end
      # No issuer, client id, or secret material leaks.
      response.body.should_not contain(OIDC_ISSUER)
      response.body.should_not contain("client-123")
      response.body.should_not contain(OIDC_TEST_SECRET)
    end
  end

  it "returns an empty provider list with the auth mode for a fresh install" do
    response = call_api(HTTP::Request.new("GET", "/Api/iam/oidc/providers"))
    assert_http_status(response, 200)
    body = JSON.parse(response.body)
    body["auth_mode"].to_s.should eq("hybrid")
    body["providers"].as_a.should be_empty
  end
end

# ── Provider doctype pipeline (Lua validation) ─────────────────────────────────

describe "iam.OIDCProvider pipeline" do
  before_each do
    with_db do |db|
      ensure_oidc_doctypes(db)
      seed_test_roles(db)
    end
  end

  it "defaults the label to the name and the scopes to the OIDC trio" do
    with_db do |db|
      doc_id = seed_oidc_provider(db, name: "bare", label: nil, scopes: nil)
      content = db.query_one(
        "SELECT content FROM projections WHERE id = $1", doc_id, as: JSON::Any
      )
      content["label"].as_s.should eq("bare")
      content["scopes"].as_a.map(&.as_s).should eq(["openid", "email", "profile"])
      content["enabled"].as_bool.should be_true
    end
  end

  it "rejects a name outside the [a-z0-9-] grammar and an http issuer" do
    with_db do |db|
      bad_name = Facet::Document::Create.call(db, "iam", "OIDCProvider",
        oidc_provider_content(name: "Okta Corp"), Facet::RBAC::AuthContext.system)
      bad_name.should be_a(Facet::ServiceError)

      bad_issuer = Facet::Document::Create.call(db, "iam", "OIDCProvider",
        oidc_provider_content(name: "http-issuer", issuer: "http://idp.example.test"),
        Facet::RBAC::AuthContext.system)
      bad_issuer.should be_a(Facet::ServiceError)
    end
  end

  it "names the *.localhost carve-out in the issuer refusal" do
    with_db do |db|
      # Stage a client secret so the create passes schema validation and
      # reaches the Lua hook — the issuer gate is the refusal under test.
      # The implementation accepts every *.localhost subdomain
      # (Util::RedirectUri.loopback_host?), so the error text must report it.
      handle = "sh_" + Facet::Util::ScriptHelpers.ulid
      payload = Facet::Secrets::Codec.seal("pipeline-secret",
        Facet::Secrets::Staging.doc_ref(handle), "client_secret")
      Facet::Secrets::Staging.insert(db, "sealed", payload, "iam", "OIDCProvider",
        "client_secret", "system", handle: handle)
      content = JSON.parse(oidc_provider_content(name: "http-issuer", issuer: "http://idp.example.test"))
      content.as_h["client_secret"] = JSON::Any.new(handle)

      result = Facet::Document::Create.call(db, "iam", "OIDCProvider", content.to_json,
        Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      error = result.as(Facet::ServiceError)
      error.details.try(&.any?(&.message.includes?("*.localhost"))).should be_true
    end
  end

  it "accepts a loopback http issuer and rejects a non-loopback one" do
    with_db do |db|
      %w[http://127.0.0.1:9999 http://localhost:8080 http://mock-idp.localhost:9001].each do |issuer|
        name = "loopback-" + issuer.gsub(/[^a-z0-9-]/, "-")
        doc_id = seed_oidc_provider(db, name: name, issuer: issuer)
        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1", doc_id, as: JSON::Any
        )
        content["issuer"].as_s.should eq(issuer)
      end

      remote = Facet::Document::Create.call(db, "iam", "OIDCProvider",
        oidc_provider_content(name: "remote-http", issuer: "http://idp.example.test"),
        Facet::RBAC::AuthContext.system)
      remote.should be_a(Facet::ServiceError)
    end
  end

  it "rejects an issuer with a query or fragment" do
    with_db do |db|
      bad = Facet::Document::Create.call(db, "iam", "OIDCProvider",
        oidc_provider_content(name: "issuer-frag", issuer: "https://idp.example.test/path#frag"),
        Facet::RBAC::AuthContext.system)
      bad.should be_a(Facet::ServiceError)
    end
  end

  it "keeps the name immutable after create" do
    with_db do |db|
      doc_id = seed_oidc_provider(db, name: "fixed-name")
      result = Facet::Document::Update.call(db, "iam", "OIDCProvider", doc_id,
        %({"name": "renamed"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      error = result.as(Facet::ServiceError)
      error.details.try(&.any?(&.message.includes?("immutable"))).should be_true
    end
  end

  it "accepts auto_provision without a default_role — the baseline resolves at login time" do
    with_db do |db|
      # The save-time coupling is gone: a provider may rely on the
      # instance-wide iam.oidc.provision_roles baseline. Provisioning
      # without any role denies at runtime (the JIT specs cover it). The
      # client secret rides the stage/adopt flow, like every create.
      handle = "sh_" + Facet::Util::ScriptHelpers.ulid
      payload = Facet::Secrets::Codec.seal("pipeline-secret",
        Facet::Secrets::Staging.doc_ref(handle), "client_secret")
      Facet::Secrets::Staging.insert(db, "sealed", payload, "iam", "OIDCProvider",
        "client_secret", "system", handle: handle)
      created = Facet::Document::Create.call(db, "iam", "OIDCProvider",
        %({"name": "norole", "issuer": "#{OIDC_ISSUER}", "client_id": "cid",
           "client_secret": "#{handle}", "auto_provision": true}),
        Facet::RBAC::AuthContext.system)
      created.should be_a(Facet::Document::Create::Result)

      # A PATCH that drops the role while auto_provision stays on passes.
      doc_id = seed_oidc_provider(db, name: "droprole")
      patch = Facet::Document::Update.call(db, "iam", "OIDCProvider", doc_id,
        %({"default_role": null}), Facet::RBAC::AuthContext.system)
      patch.should be_a(Facet::Document::Update::Result)
    end
  end

  it "rejects an empty domains entry and lowercases the allowlist" do
    with_db do |db|
      doc_id = seed_oidc_provider(db, name: "mixed", domains: ["Example.Test"])
      content = db.query_one(
        "SELECT content FROM projections WHERE id = $1", doc_id, as: JSON::Any
      )
      content["domains"].as_a.map(&.as_s).should eq(["example.test"])

      bad = Facet::Document::Create.call(db, "iam", "OIDCProvider",
        oidc_provider_content(name: "empty-domain", domains: [""]),
        Facet::RBAC::AuthContext.system)
      bad.should be_a(Facet::ServiceError)
    end
  end

  it "refuses to recreate a name a tombstoned provider still holds" do
    with_db do |db|
      doc_id = seed_oidc_provider(db, name: "recycled")
      delete_oidc_provider(db, doc_id)

      # The unique constraint only covers live rows, so the pipeline-level
      # create hook is what blocks the reuse — the account links join on
      # the provider name, and a new issuer would silently re-authenticate
      # them. The handle-shaped client secret satisfies shape validation
      # so the hook (not the schema) is what answers.
      result = Facet::Document::Create.call(db, "iam", "OIDCProvider",
        %({"name": "recycled", "issuer": "https://evil.example.test", "client_id": "cid",
           "client_secret": "sh_#{"A" * 26}", "default_role": "iam.Roles.admin"}),
        Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      error = result.as(Facet::ServiceError)
      error.details.try(&.any?(&.message.includes?("deleted provider"))).should be_true
    end
  end

  it "enforces the secret placement: plaintext is refused, only handles and markers land" do
    with_db do |db|
      raw = Facet::Document::Create.call(db, "iam", "OIDCProvider",
        %({"name": "rawsecret", "issuer": "#{OIDC_ISSUER}", "client_id": "cid",
           "client_secret": "plaintext-never"}),
        Facet::RBAC::AuthContext.system)
      raw.should be_a(Facet::ServiceError)
    end
  end
end
