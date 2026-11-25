# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── OAuth test helpers ─────────────────────────────────────────────────────────
#
# Shared builders for the OAuth specs. Each OAuth spec (`authorize_spec`,
# `token_spec`, `oauth_flow_spec`, `auth_handler_app_token_spec`, `cors_spec`)
# constructs the same `app.App`, `iam.Roles`, and `iam.Account` fixtures, then
# exercises the flow. Centralizing the builders here:
#
# - keeps the role-id convention uniform across specs (Accounts store **bare**
#   role names — `find_role_content` splits a qualified `"iam.Roles.reader"`
#   on `.` with limit 2, producing `name="Roles.reader"` which never matches
#   a role whose `name` is `"reader"`; bare names always work;
# - runs the Lua `create` hook on `app.App` so the auto-generated `client_id`
#   is materialized the same way production paths do it;
# - returns the auto-generated `client_id` alongside the doc id, so callers
#   drive authorize/token flows against the value the server will see.

require "../../src/doctype"
require "../../src/document"
require "../../src/util/script_helpers"
require "../../src/mutation/client"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../../src/oauth/dpop"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../support/app_helper"

# Builds a fresh `app.App` projection with the given parameters.
#
# The `app.App` `create` lifecycle hook overwrites `client_id` (it is
# `read_only`), so the auto-generated value is read back from the projection
# and returned alongside the doc id. Uses `Document::Create.call` so the Lua
# hook runs and the projection is materialized the same way production code
# paths materialize it (Mutation::Client.create skips script execution).
#
# `grants` is a `Hash(String, JSON::Any)` matching the `app.App` grant shape:
#
# ```
# oauth_grant("crm.Contact", [oauth_action("read", required: true)])
# ```
def create_test_app(
  db,
  slug : String,
  display_name = "Test App",
  description = "An app for tests.",
  redirect_uris = ["https://app.example.com/cb"],
  allowed_origins = ["https://app.example.com"],
  status = "active",
  no_launcher = false,
  client_type = "public",
  grants : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
  owner_id : String? = nil,
  host : String? = nil,
) : {String, String} # {doc_id, client_id}
  # `slug` is unique: appending a random suffix keeps parallel tests isolated.
  unique_slug = "#{slug}-#{Facet::Util::ScriptHelpers.ulid.downcase[0..12]}"
  content = {
    slug:            unique_slug,
    name:            display_name,
    description:     description,
    client_type:     client_type,
    redirect_uris:   redirect_uris,
    allowed_origins: allowed_origins,
    status:          status,
    no_launcher:     no_launcher,
    grants:          grants,
    owner_id:        owner_id,
    host:            host,
  }.to_json

  result = Facet::Document::Create.call(
    db, "app", "App", content, Facet::RBAC::AuthContext.system,
  )
  raise "Failed to create test app: #{result.inspect}" unless result.is_a?(Facet::Document::Create::Result)
  doc_id = result.projection.id
  client_id = result.projection.content["client_id"].as_s
  {doc_id, client_id}
end

# Creates a fresh `iam.Roles` row with the given permission set. Returns the
# **qualified role id** (e.g. `"iam.Roles.reader"`), which is what
# `iam.Account.roles` stores and what `IAM::Helpers.find_role_content`
# resolves by `projections.id`.
def create_test_role(db, name : String, perms : Array, level : Int32 = 20) : String
  create_test_role(db, name, perms, level, connectivity: ["mcp", "webhook", "api", "assistant"])
end

# Same as the three-argument form, with an explicit `connectivity` list —
# for specs that need a role whose channels exclude `mcp` (or any other).
def create_test_role(db, name : String, perms : Array, level : Int32, connectivity : Array(String)) : String
  content = {
    name:         name,
    level:        level,
    description:  "Test role #{name}",
    visible_tags: ["*"],
    connectivity: connectivity,
    permissions:  perms,
  }.to_json
  Facet::Mutation::Client.create(
    db, "iam", "Roles",
    doc_id: "iam.Roles.#{name}",
    content: content,
    actioner_id: "system",
    meta: %({"parent_id": "iam"}),
  )
  "iam.Roles.#{name}"
end

# A grant entry as it would appear on an `app.App` document. Each action
# carries an explicit `required` flag — the authorize/token flow consults
# this when resolving the effective scope.
#
# The names `oauth_grant` / `oauth_action` / `oauth_perm` are prefixed to
# avoid clashing with the `perm` / `grant` helpers in `spec/rbac/` (which
# build `RBAC::Permission` and `RBAC::Grant` value types for pure-logic specs).
# Top-level `def`s in Crystal do not overload; a same-named redefinition in
# a later-required file wins by shadowing.
def oauth_grant(target : String, actions : Array(NamedTuple(name: String, required: Bool)))
  {
    "target"  => JSON::Any.new(target),
    "actions" => JSON::Any.new(actions.map do |a|
      JSON::Any.new({
        "name"     => JSON::Any.new(a[:name]),
        "required" => JSON::Any.new(a[:required]),
      })
    end),
  }
end

# Builds a single grant action. The first argument is the action name; the
# second declares whether the app requires the role to cover it.
def oauth_action(name : String, required : Bool = false)
  {name: name, required: required}
end

# Builds a permission line for a test role.
def oauth_perm(action : String, on : String)
  {action: action, on: on}
end

# Computes the S256 code challenge for a verifier (RFC 7636 §4.2):
# `BASE64URL(SHA-256(verifier))` with no padding. Used both at authorize
# (challenge param) and at token (verifier re-derivation).
def s256_challenge(verifier : String) : String
  digest = OpenSSL::Digest.new("SHA256")
  digest.update(verifier)
  Base64.urlsafe_encode(digest.final, padding: false)
end

# Builds well-formed OAuth authorize params for tests. Defaults match the
# valid S256 / exact-redirect_uri contract the brief requires.
def make_authorize_params(
  client_id : String,
  redirect_uri : String,
  code_challenge : String = "challenge_abc",
  method : String = "S256",
  state : String? = "state_xyz",
  scope : String? = nil,
)
  Facet::OAuth::Authorize.parse_params(
    client_id: client_id,
    redirect_uri: redirect_uri,
    state: state,
    code_challenge: code_challenge,
    code_challenge_method: method,
    scope: scope,
  )
end

# Signs a Facet app token (`typ: "app"`) using the same backing signing
# key + payload factory as `OAuth::Token.call`. Use this to hand-craft an
# app token when you want to test `AuthHandler` directly without going
# through the full authorize → token HTTP flow.
def sign_app_token(account_id : String, role : String, app_id : String) : String
  payload, _exp = Facet::IAM::JWT.build_app_payload(
    account_id: account_id,
    sid: Random::Secure.urlsafe_base64(24),
    role: role,
    app_id: app_id,
  )
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

# ── DPoP test helpers ─────────────────────────────────────────────────────────
#
# Builders for DPoP proofs used by the App System DPoP specs.
# All helpers operate on a single client-held EC P-256 key pair generated
# fresh per spec via `dpop_key_pair`.

# A client DPoP key pair: the JWK (public part, as sent in the proof header)
# and the matching PEM private key (only ever held in tests; the server
# sees only the JWK).
record DpopKeyPair,
  jwk : Hash(String, JSON::Any),
  private_pem : String,
  jkt : String

# Generates a fresh EC P-256 key pair for use in a DPoP proof.
#
# Returns the public JWK (the same shape the client would put in the proof
# header), the private key as PEM (for signing the proof), and the RFC 7638
# thumbprint (`jkt`) pre-computed so specs can compare it without re-running
# the digest. The JWK members are integers base64url-encoded without padding,
# matching RFC 7518 §6.3.1.
def dpop_key_pair : DpopKeyPair
  ec = OpenSSL::PKey::EC.generate("P-256")

  # `public_key_bytes` returns the uncompressed point `0x04 || x || y`
  # (65 bytes for P-256). Splitting it gives the public key coordinates the
  # JWK needs, with fixed 32-byte width per RFC 7518 §6.3.1.
  point = ec.public_key_bytes
  raise "unexpected public key size for P-256" unless point.size == 65 && point[0] == 0x04
  x_bin = point[1, 32]
  y_bin = point[33, 32]

  jwk = {
    "kty" => JSON::Any.new("EC"),
    "crv" => JSON::Any.new("P-256"),
    "x"   => JSON::Any.new(Base64.urlsafe_encode(x_bin, padding: false)),
    "y"   => JSON::Any.new(Base64.urlsafe_encode(y_bin, padding: false)),
  }
  jkt = dpop_thumbprint(jwk)
  DpopKeyPair.new(jwk: jwk, private_pem: ec.to_pem, jkt: jkt)
end

# Computes the RFC 7638 JWK thumbprint for a public EC JWK. Mirrors the
# server's `OAuth::DPoP.verify` computation so specs can assert equality.
def dpop_thumbprint(jwk : Hash(String, JSON::Any)) : String
  canonical = %({"crv":"#{jwk["crv"].as_s}","kty":"#{jwk["kty"].as_s}","x":"#{jwk["x"].as_s}","y":"#{jwk["y"].as_s}"})
  digest = OpenSSL::Digest.new("SHA256")
  digest.update(canonical)
  Base64.urlsafe_encode(digest.final, padding: false)
end

# Builds and signs a DPoP proof JWT.
#
# `headers` and `payload_claims` are merged into the standard DPoP shape so
# specs can construct bad proofs (wrong `typ`, missing `jwk`, private key in
# `jwk`, etc.) without copy-pasting the whole builder.
#
# Signature handling: the JWT shard's `JWT.encode` performs the DER→raw-R‖S
# conversion internally (`asn1_to_raw`), so a proof signed via this helper
# is byte-identical to one a JOSE library like `panva/jose` would produce.
# That is what makes this the interop check.
def sign_dpop_proof(
  key_pair : DpopKeyPair,
  htm : String,
  htu : String,
  jti : String = Random::Secure.hex(16),
  iat : Int64 = Time.utc.to_unix,
  ath : String? = nil,
  override_header : Hash(String, JSON::Any)? = nil,
  extra_payload : Hash(String, JSON::Any)? = nil,
  bad_signature : Bool = false,
  alg : String = "ES256",
) : String
  header = {
    "typ" => JSON::Any.new("dpop+jwt"),
    "alg" => JSON::Any.new(alg),
    "jwk" => JSON::Any.new(key_pair.jwk),
  }
  header = override_header if override_header

  payload = {
    "htm" => JSON::Any.new(htm),
    "htu" => JSON::Any.new(htu),
    "jti" => JSON::Any.new(jti),
    "iat" => JSON::Any.new(iat),
  }
  payload["ath"] = JSON::Any.new(ath) if ath
  payload = payload.merge(extra_payload) if extra_payload

  signing_input =
    Base64.urlsafe_encode(header.to_json, padding: false) + "." +
      Base64.urlsafe_encode(payload.to_json, padding: false)

  signature_bytes = if bad_signature
                      Random::Secure.random_bytes(64)
                    else
                      # `JWT.encode` would re-serialize and re-sign the whole token — but we
                      # already assembled the signing_input above, and we want byte-exact
                      # match. Use the shard's internal `sign` + `asn1_to_raw` conversion by
                      # calling the encode path with a custom sign on this exact input.
                      #
                      # The shard exports `JWT.encode` only via the high-level API; the
                      # simplest correct approach is to call `OpenSSL::PKey::EC#ec_sign`
                      # directly and then convert DER → raw R‖S using the same logic the
                      # shard uses for `asn1_to_raw` (which it never exports publicly).
                      # `asn1_to_raw` is private on the shard, so we re-implement it
                      # minimally here (duplicating shard internals, but staying inside
                      # helpers).
                      ec = OpenSSL::PKey::EC.new(key_pair.private_pem)
                      digest = OpenSSL::Digest.new("SHA256")
                      digest.update(signing_input)
                      asn1 = ec.ec_sign(digest.final)
                      raw_r_s(asn1, 32)
                    end
  signature = Base64.urlsafe_encode(signature_bytes, padding: false)
  "#{signing_input}.#{signature}"
end

# Converts a DER-encoded ECDSA signature into the raw `R ‖ S` form that
# JOSE/JWS mandates (RFC 7515 §3.4, RFC 7518 §3.3). Mirrors what the JWT
# shard does on the verify path (`raw_to_asn1`), reversed.
# Used only by the test helper — production code goes through `JWT.decode`.
def raw_r_s(asn1 : Bytes, half_size : Int32) : Bytes
  raise "bad DER signature (too short)" if asn1.size < 6
  raise "bad DER signature (expected SEQUENCE)" unless asn1[0] == 0x30
  pos = 0
  pos += 1 # SEQUENCE tag
  pos += 1 # total length byte (short-form assumed; JWT shard always produces short)
  r, pos = read_asn1_integer(asn1, pos)
  s, _pos = read_asn1_integer(asn1, pos)
  r_bytes = big_int_to_bytes(r, half_size)
  s_bytes = big_int_to_bytes(s, half_size)
  out_bytes = Bytes.new(half_size * 2)
  r_bytes.copy_to(out_bytes)
  s_bytes.copy_to(out_bytes + half_size)
  out_bytes
end

private def read_asn1_integer(asn1 : Bytes, pos : Int32) : {OpenSSL::BN, Int32}
  raise "bad DER (expected INTEGER)" unless asn1[pos] == 0x02
  pos += 1
  length = asn1[pos].to_i32
  pos += 1
  start = pos
  pos += length
  {OpenSSL::BN.from_bin(asn1[start, length]), pos}
end

private def big_int_to_bytes(bn : OpenSSL::BN, size : Int32) : Bytes
  bin = bn.to_bin
  if bin.size > size
    # Strip leading 0x00 padding added by DER when the high bit is set.
    bin = bin[bin.size - size..]
  elsif bin.size < size
    padded = Bytes.new(size, 0_u8)
    bin.copy_to(padded + (size - bin.size))
    bin = padded
  end
  bin
end

# Convenience: builds a DPoP proof for a token-endpoint request and returns
# the proof string together with the key pair that signed it.
def dpop_proof_for_token_endpoint(
  htu : String,
  jti : String = Random::Secure.hex(16),
  iat : Int64 = Time.utc.to_unix,
  bad_signature : Bool = false,
  override_header : Hash(String, JSON::Any)? = nil,
  extra_payload : Hash(String, JSON::Any)? = nil,
  alg : String = "ES256",
) : {String, DpopKeyPair}
  pair = dpop_key_pair
  proof = sign_dpop_proof(
    pair,
    htm: "POST",
    htu: htu,
    jti: jti,
    iat: iat,
    override_header: override_header,
    extra_payload: extra_payload,
    bad_signature: bad_signature,
    alg: alg,
  )
  {proof, pair}
end

# Builds and signs a DPoP proof with one claim omitted. Used by specs that
# exercise the "missing claim" failure paths — `sign_dpop_proof` always
# populates `htm`/`htu`/`jti`/`iat`, so the only way to omit a claim is to
# build the payload from scratch.
def sign_proof_without_claim(
  key_pair : DpopKeyPair,
  claim : String,
  htu : String,
  htm : String = "POST",
  bad_signature : Bool = false,
) : String
  header = {
    "typ" => JSON::Any.new("dpop+jwt"),
    "alg" => JSON::Any.new("ES256"),
    "jwk" => JSON::Any.new(key_pair.jwk),
  }
  payload = Hash(String, JSON::Any).new
  payload["htm"] = JSON::Any.new(htm) unless claim == "htm"
  payload["htu"] = JSON::Any.new(htu) unless claim == "htu"
  payload["jti"] = JSON::Any.new(Random::Secure.hex(16)) unless claim == "jti"
  payload["iat"] = JSON::Any.new(Time.utc.to_unix) unless claim == "iat"

  signing_input =
    Base64.urlsafe_encode(header.to_json, padding: false) + "." +
      Base64.urlsafe_encode(payload.to_json, padding: false)
  signature_bytes = if bad_signature
                      Random::Secure.random_bytes(64)
                    else
                      ec = OpenSSL::PKey::EC.new(key_pair.private_pem)
                      digest = OpenSSL::Digest.new("SHA256").update(signing_input).final
                      raw_r_s(ec.ec_sign(digest), 32)
                    end
  signature = Base64.urlsafe_encode(signature_bytes, padding: false)
  "#{signing_input}.#{signature}"
end
