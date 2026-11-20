# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── OIDC test helpers ────────────────────────────────────────────────────────
#
# Helpers for the inbound-OIDC specs. The project ships no HTTP stubbing
# shard, so every IdP interaction runs through the one injectable fetch
# function (`Facet::IAM::OIDC::Fetcher`) — the helper installs a stub keyed
# by URL and captures what the flow sent.
#
# Key material is generated locally: RSA and EC keypairs sign id_tokens,
# and the JWKS is served from the matching public JWKs. This makes the
# JWK→PEM conversion in `Verify` part of the tested path — the spec keys
# are JWK-shaped, exactly what a real discovery document carries.

require "openssl"
require "jwt"
require "json"
require "base64"
require "../../src/config"
require "../../src/iam"
require "../../src/iam/oidc/providers"
require "../../src/iam/oidc/provider_store"
require "../../src/iam/oidc/discovery"
require "../../src/iam/oidc/verify"
require "../../src/iam/oidc/identity"
require "../../src/secrets/store"
require "../../src/secrets/staging"
require "../../src/secrets/codec"
require "./oauth_helper"
require "./iam_helper"
require "./redis_helper"

# Valid 32-byte master key fixture (same fixture as `spec/config_spec.cr`)
# for constructing a full `Config` in route specs.
OIDC_TEST_MASTER_KEY = "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="

# Canonical test issuer + endpoints. Every stub dispatches on these.
OIDC_ISSUER     = "https://idp.example.test"
OIDC_JWKS_URI   = "#{OIDC_ISSUER}/jwks"
OIDC_AUTHORIZE  = "#{OIDC_ISSUER}/authorize"
OIDC_TOKEN      = "#{OIDC_ISSUER}/token"
OIDC_WELL_KNOWN = "#{OIDC_ISSUER}/.well-known/openid-configuration"

# ── Provider factory ───────────────────────────────────────────────────────────────

# The client secret the provider factory seals into the store.
OIDC_TEST_SECRET = "secret-xyz"

# Content body for one `iam.OIDCProvider` document. The `client_secret`
# field is supplied by `seed_oidc_provider` (a stage handle — the real
# adoption path); this helper only shapes the non-secret fields.
def oidc_provider_content(
  name : String = "testidp",
  issuer : String = OIDC_ISSUER,
  client_id : String = "client-123",
  domains : Array(String) = ["example.test"],
  default_role : String? = "iam.Roles.admin",
  auto_provision : Bool = true,
  scopes : Array(String)? = ["openid", "email", "profile"],
  enabled : Bool = true,
  label : String? = nil,
) : String
  content = {
    "name"           => name,
    "label"          => label || name,
    "issuer"         => issuer,
    "client_id"      => client_id,
    "domains"        => domains,
    "auto_provision" => auto_provision,
    "scopes"         => scopes,
    "enabled"        => enabled,
  }
  content["default_role"] = default_role if default_role
  content.to_json
end

# Seeds one `iam.OIDCProvider` document through the real pipeline:
# stages the plaintext out-of-band (`Secrets::Staging`, sealed under the
# staging binding) and creates the document with the handle — the write
# pipeline's adoption step seals it into the store and leaves only the
# marker in content. Specs that only need the registry shape can pass
# `secret: nil`.
#
# Returns the projection id (a ULID — NOT the provider name).
def seed_oidc_provider(
  db,
  name : String = "testidp",
  issuer : String = OIDC_ISSUER,
  client_id : String = "client-123",
  domains : Array(String) = ["example.test"],
  default_role : String? = "iam.Roles.admin",
  auto_provision : Bool = true,
  scopes : Array(String)? = ["openid", "email", "profile"],
  enabled : Bool = true,
  label : String? = nil,
  secret : String? = OIDC_TEST_SECRET,
) : String
  content = JSON.parse(oidc_provider_content(name, issuer, client_id, domains,
    default_role, auto_provision, scopes, enabled, label))
  doc_id = Facet::Util::ScriptHelpers.ulid

  if plaintext = secret
    handle = "sh_" + Facet::Util::ScriptHelpers.ulid
    payload = Facet::Secrets::Codec.seal(plaintext, Facet::Secrets::Staging.doc_ref(handle), "client_secret")
    Facet::Secrets::Staging.insert(db, "sealed", payload, "iam", "OIDCProvider",
      "client_secret", "system", handle: handle)
    content.as_h["client_secret"] = JSON::Any.new(handle)
  end

  result = Facet::Document::Create.call(db, "iam", "OIDCProvider", content.to_json,
    Facet::RBAC::AuthContext.system, doc_id: doc_id)
  raise "failed to seed provider '#{name}': #{result.inspect}" if result.is_a?(Facet::ServiceError)
  doc_id
end

# Tombstones one provider document — the fixture for the tombstone-name
# rule and the registry's exclusion of deleted rows.
def delete_oidc_provider(db, doc_id : String) : Nil
  result = Facet::Document::Delete.call(db, "iam", "OIDCProvider", doc_id,
    Facet::RBAC::AuthContext.system)
  raise "failed to delete provider: #{result.inspect}" if result.is_a?(Facet::ServiceError)
end

# Builds the registry record directly (no DB round-trip) for the
# id_token verification specs — those exercise claim and signature checks
# against the record's issuer and client id only.
def oidc_provider_record(
  name : String = "testidp",
  issuer : String = OIDC_ISSUER,
  client_id : String = "client-123",
  doc_id : String = "provider-doc-1",
  domains : Array(String) = ["example.test"],
  default_role : String? = "iam.Roles.admin",
  auto_provision : Bool = true,
  scopes : Array(String)? = ["openid", "email", "profile"],
  label : String? = nil,
) : Facet::IAM::OIDC::Provider
  Facet::IAM::OIDC::Provider.new(
    name: name,
    label: label || name,
    issuer: issuer,
    client_id: client_id,
    doc_id: doc_id,
    domains: domains.map(&.downcase),
    default_role: default_role,
    auto_provision: auto_provision,
    scopes: scopes || ["openid", "email", "profile"],
  )
end

# ── Key material ──────────────────────────────────────────────────────────────────

# An RSA keypair shaped for the OIDC flow: the public JWK (as a JWKS entry
# would carry it) plus the private PEM for signing.
record OidcRsaKey, jwk : Hash(String, JSON::Any), private_pem : String do
  def oidc_jwk : Facet::IAM::OIDC::JWK
    Facet::IAM::OIDC::JWK.new(
      kty: jwk["kty"].as_s, kid: jwk["kid"].as_s, alg: nil, crv: nil,
      n: jwk["n"].as_s, e: jwk["e"].as_s, x: nil, y: nil)
  end
end

# An EC P-256 keypair with a `kid`-stamped JWK.
record OidcEcKey, jwk : Hash(String, JSON::Any), private_pem : String do
  def oidc_jwk : Facet::IAM::OIDC::JWK
    Facet::IAM::OIDC::JWK.new(
      kty: jwk["kty"].as_s, kid: jwk["kid"].as_s, alg: nil,
      crv: jwk["crv"].as_s, n: nil, e: nil,
      x: jwk["x"].as_s, y: jwk["y"].as_s)
  end
end

# Generates an RSA keypair and extracts the JWK members (n, e) by parsing
# the SubjectPublicKeyInfo DER of the public key — the inverse direction of
# `Verify.jwk_to_pem`, so the two paths cross-validate each other.
def oidc_rsa_key(kid : String) : OidcRsaKey
  rsa = OpenSSL::PKey::RSA.generate(2048, 65537_u32)
  der = Base64.decode(rsa.public_key.to_pem.lines.reject(&.starts_with?("-----")).join)

  spki_tag, spki, _ = oidc_read_tlv(der, 0)
  raise "expected SPKI SEQUENCE" unless spki_tag == 0x30
  _alg_tag, _alg, pos = oidc_read_tlv(spki, 0)
  bit_tag, bitstring, _ = oidc_read_tlv(spki, pos)
  raise "expected BIT STRING" unless bit_tag == 0x03
  # BIT STRING content: one unused-bits byte, then the RSAPublicKey DER.
  key_tag, key_der, _ = oidc_read_tlv(bitstring[1..], 0)
  raise "expected RSAPublicKey SEQUENCE" unless key_tag == 0x30

  n_tag, n_bytes, pos2 = oidc_read_tlv(key_der, 0)
  e_tag, e_bytes, _ = oidc_read_tlv(key_der, pos2)
  raise "expected INTEGERs" unless n_tag == 0x02 && e_tag == 0x02

  OidcRsaKey.new(
    jwk: {
      "kty" => JSON::Any.new("RSA"),
      "kid" => JSON::Any.new(kid),
      "n"   => JSON::Any.new(oidc_b64url(oidc_strip_leading_zeros(n_bytes))),
      "e"   => JSON::Any.new(oidc_b64url(oidc_strip_leading_zeros(e_bytes))),
    },
    private_pem: rsa.to_pem,
  )
end

# Generates an EC P-256 keypair, reusing the JWK construction from the
# DPoP helper and stamping a `kid` on it.
def oidc_ec_key(kid : String) : OidcEcKey
  pair = dpop_key_pair
  jwk = pair.jwk.dup
  jwk["kid"] = JSON::Any.new(kid)
  OidcEcKey.new(jwk: jwk, private_pem: pair.private_pem)
end

private def oidc_read_tlv(bytes : Bytes, pos : Int32) : {UInt8, Bytes, Int32}
  tag = bytes[pos]
  pos += 1
  len = bytes[pos].to_i
  pos += 1
  if len & 0x80 != 0
    count = len & 0x7f
    len = 0
    count.times do
      len = (len << 8) | bytes[pos]
      pos += 1
    end
  end
  {tag, bytes[pos, len], pos + len}
end

private def oidc_strip_leading_zeros(bytes : Bytes) : Bytes
  first = 0
  while first < bytes.size - 1 && bytes[first] == 0
    first += 1
  end
  bytes[first..]
end

private def oidc_b64url(bytes : Bytes) : String
  Base64.urlsafe_encode(bytes, padding: false)
end

# ── id_token building ────────────────────────────────────────────────────────

# Builds a standard id_token claim set. Only the given claims are included,
# so specs can omit members to exercise missing-claim paths.
def id_token_payload(
  sub : String? = "sub-abc",
  iss : String? = OIDC_ISSUER,
  aud : String? = "client-123",
  email : String? = nil,
  email_verified : Bool? = nil,
  nonce : String? = nil,
  name : String? = nil,
  iat : Int64? = Time.utc.to_unix,
  exp : Int64? = Time.utc.to_unix + 300,
) : Hash(String, JSON::Any)
  payload = Hash(String, JSON::Any).new
  payload["sub"] = JSON::Any.new(sub) if sub
  payload["iss"] = JSON::Any.new(iss) if iss
  payload["aud"] = JSON::Any.new(aud) if aud
  payload["email"] = JSON::Any.new(email) if email
  payload["email_verified"] = JSON::Any.new(email_verified) if !email_verified.nil?
  payload["nonce"] = JSON::Any.new(nonce) if nonce
  payload["name"] = JSON::Any.new(name) if name
  payload["iat"] = JSON::Any.new(iat) if iat
  payload["exp"] = JSON::Any.new(exp) if exp
  payload
end

# Signs a payload into an id_token with the given key. `alg` may be
# "RS256" (default), "ES256", or "HS256"; `bad_signature` corrupts the
# signature segment; `header_overrides` replaces the whole header (for the
# `alg: none` case, build the token with `unsigned_id_token`).
def sign_id_token(
  payload : Hash(String, JSON::Any),
  key : OidcRsaKey | OidcEcKey,
  alg : String = "RS256",
  kid : String? = nil,
  bad_signature : Bool = false,
) : String
  jwt_alg = ::JWT::Algorithm.parse(alg)
  token = if kid
            ::JWT.encode(payload, key.private_pem, jwt_alg, kid: kid)
          else
            ::JWT.encode(payload, key.private_pem, jwt_alg)
          end
  return token unless bad_signature
  parts = token.split('.')
  flipped = parts[2][0] == 'A' ? 'B' : 'A'
  "#{parts[0]}.#{parts[1]}.#{flipped}#{parts[2][1..]}"
end

# Builds an unsigned (alg: none) token by hand — the JWT shard refuses to
# mint one, which is exactly why the verifier must reject the shape.
def unsigned_id_token(payload : Hash(String, JSON::Any), header_alg : String = "none") : String
  header = {"alg" => header_alg, "typ" => "JWT"}
  b64 = ->(s : String) { Base64.urlsafe_encode(s, padding: false) }
  "#{b64.call(header.to_json)}.#{b64.call(payload.to_json)}."
end

# Serializes JWK records into a JWKS response body.
def jwks_body(keys : Array(Facet::IAM::OIDC::JWK)) : String
  JSON.build do |json|
    json.object do
      json.field("keys") do
        json.array do
          keys.each do |k|
            json.object do
              json.field("kty", k.kty)
              json.field("kid", k.kid) if k.kid
              json.field("alg", k.alg) if k.alg
              json.field("crv", k.crv) if k.crv
              json.field("n", k.n) if k.n
              json.field("e", k.e) if k.e
              json.field("x", k.x) if k.x
              json.field("y", k.y) if k.y
            end
          end
        end
      end
    end
  end
end

# A discovery-document body pointing at the canonical test endpoints.
def discovery_body(issuer : String = OIDC_ISSUER) : String
  {
    "issuer"                 => issuer,
    "authorization_endpoint" => OIDC_AUTHORIZE,
    "token_endpoint"         => OIDC_TOKEN,
    "jwks_uri"               => OIDC_JWKS_URI,
  }.to_json
end

# ── IdP stub (fetcher replacement) ───────────────────────────────────────────

# In-memory IdP: serves discovery, JWKS, and the token endpoint through the
# injectable fetcher. Records every call so specs can assert caching and
# inspect the token-exchange form body (PKCE verifier).
class OidcIdpStub
  property discovery_calls : Int32
  property jwks_calls : Int32
  property token_calls : Int32
  property discovery_status : Int32
  property jwks_status : Int32
  property token_status : Int32
  property discovery_body : String
  property jwks_body : String
  property token_body : String?
  # When set, the token endpoint answers 400 unless the exchange form
  # carries exactly this `code_verifier`.
  property expected_verifier : String?

  getter token_bodies : Array(String)

  def initialize(
    @discovery_body : String,
    @jwks_body : String,
    @token_body : String? = nil,
    @discovery_status : Int32 = 200,
    @jwks_status : Int32 = 200,
    @token_status : Int32 = 200,
  )
    @discovery_calls = 0
    @jwks_calls = 0
    @token_calls = 0
    @token_bodies = [] of String
    @expected_verifier = nil
  end

  def handle(method : String, url : String, body : String?) : {Int32, String}
    if url.ends_with?("/.well-known/openid-configuration")
      @discovery_calls += 1
      return {@discovery_status, @discovery_body}
    end
    if url == OIDC_JWKS_URI
      @jwks_calls += 1
      return {@jwks_status, @jwks_body}
    end
    if url == OIDC_TOKEN
      @token_calls += 1
      @token_bodies << body if body
      if (expected = @expected_verifier) && (!body || !body.includes?("code_verifier=#{expected}"))
        return {400, %({"error": "invalid_grant"})}
      end
      return {@token_status, @token_body || ""}
    end
    {404, ""}
  end

  def install : Nil
    stub = self
    Facet::IAM::OIDC::Fetcher.impl = ->(method : String, url : String?, _headers : ::HTTP::Headers, body : String?) do
      status, text = stub.handle(method, url.as(String), body)
      {status: status, body: text}
    end
  end
end

# Installs the stub and guarantees the discovery/JWKS caches start cold.
def stub_oidc(stub : OidcIdpStub) : Nil
  Facet::IAM::OIDC::Discovery.reset!
  stub.install
end

def unstub_oidc : Nil
  Facet::IAM::OIDC::Fetcher.reset!
  Facet::IAM::OIDC::Discovery.reset!
end

# ── Redis state helpers ──────────────────────────────────────────────────────

# Clears the OIDC state keys (the shared `redis_cleanup` list does not
# include the `oidc:` prefix).
def oidc_redis_cleanup : Nil
  with_redis do |r|
    r.scan_each(match: "oidc:*") do |key|
      r.del(key)
    end
  end
end

# Reads the raw JSON payload of a state row (nil when consumed/absent).
def oidc_state_raw(state : String) : String?
  with_redis do |r|
    value = r.get("oidc:state:#{state}")
    value.is_a?(String) ? value : nil
  end
end

# Extracts a single query value from a redirect Location.
def redirect_param(response : HTTP::Client::Response, name : String) : String
  uri = URI.parse(response.headers["Location"])
  ::URI::Params.parse(uri.query || "")[name]? || ""
end
