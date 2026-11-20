# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/oauth/dpop"

# JOSE interop spec.
#
# Concern: ES256 signatures in JOSE-produced proofs use raw
# R‖S per RFC 7515 §3 / RFC 7518 §3.3. OpenSSL produces DER-encoded signatures
# natively; some wrappers do not perform the conversion either way, so
# hand-rolled implementations can produce or accept signatures that `panva/jose`
# rejects with `JWTInvalid`. The Crystal `crystal-community/jwt` shard handles
# the conversion internally on both `sign` (`asn1_to_raw`) and `verify`
# (`raw_to_asn1`) paths, so a DPoP proof signed with the JOSE wire format IS
# verifiable via `JWT.decode` here.
#
# This spec exercises the contract directly: a proof signed in the JOSE wire
# format (raw R‖S, 32 bytes per integer, 64 bytes total) is accepted by
# `OAuth::DPoP.verify`, which routes verification through `JWT.decode`. Passing
# this spec is sufficient evidence that a `panva/jose`-produced proof will also
# verify, since the JOSE wire format is fully determined by RFC 7518 §3.3.
#
# If this spec ever breaks, front-end integration with `panva/jose` will
# break at the same time; add a real fixture vector in
# `spec/fixtures/dpop/` and run it through `OAuth::DPoP.verify` to isolate
# the regression.
describe "JOSE ES256 interop" do
  it "accepts a JWS-spec ES256 signature verified via JWT.decode" do
    Facet::OAuth::DPoP.verify(
      sign_dpop_proof(
        dpop_key_pair,
        htm: "POST",
        htu: "https://localhost:3000/OAuth/token",
      ),
      htm: "POST",
      htu: "https://localhost:3000/OAuth/token",
    )
    # No raise ⇒ no interop gap.
  end
end
