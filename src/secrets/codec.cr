# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "crypto/bcrypt/password"
require "digest/sha256"
require "base64"
require "openssl/cipher"
require "openssl/lib_crypto"
require "../config"

# Re-opening the stdlib binding to add the GCM context controls. Crystal
# 1.21 ships no `auth_data=` / `auth_tag` on `OpenSSL::Cipher`, so the
# sealed codec drives the OpenSSL EVP API directly.
lib LibCrypto
  fun cipher_ctx_ctrl = EVP_CIPHER_CTX_ctrl(ctx : EVP_CIPHER_CTX, type : Int32, arg : Int32, ptr : Void*) : Int32
end

module Facet
  module Secrets
    # Payload encode/decode for the three secret modes. Pure functions —
    # no database access.
    #
    # Every payload is **self-describing**: the prefix before the first `.`
    # names the algorithm, and all parameters (bcrypt cost, GCM key id,
    # nonce) live inside the payload string. Algorithms are never a schema
    # or authoring concern — the stored `mode` column stays authoritative,
    # and `parse_mode` exists for diagnostics only.
    #
    # | mode    | payload                                                            |
    # |---------|--------------------------------------------------------------------|
    # | `hash`  | native bcrypt modular-crypt string (`$2b$<cost>$…`)                 |
    # | `sealed`| `gcm-v1.<kid>.<b64 nonce>.<b64 ciphertext>.<b64 tag>`               |
    # | `token` | `sha256.<hex digest>`                                               |
    module Codec
      SEALED_ALGO = "gcm-v1"
      TOKEN_ALGO  = "sha256"

      # GCM nonce size in bytes. 96 bits is the NIST-recommended length.
      NONCE_BYTES = 12

      # ── hash ──────────────────────────────────────────────────────────

      # Produces a bcrypt payload for `plaintext`.
      #
      # The input is pre-hashed with SHA-256 and strict-base64-encoded
      # before bcrypt — because bcrypt truncates past 72 bytes and stops
      # at NUL bytes. The pre-hash removes both limits and keeps one
      # codepath for create
      # and verify.
      def self.hash_payload(plaintext : String) : String
        cost = Facet::Config.instance.secrets.bcrypt_cost
        Crypto::Bcrypt::Password.create(prehash(plaintext), cost: cost).to_s
      end

      # Compares `plaintext` against a bcrypt payload. Returns false on any
      # malformed payload — a broken hash never verifies.
      def self.verify_hash(plaintext : String, payload : String) : Bool
        Crypto::Bcrypt::Password.new(payload).verify(prehash(plaintext))
      rescue
        false
      end

      # ── sealed ────────────────────────────────────────────────────────

      # Seals `plaintext` under AES-256-GCM, bound to its row.
      #
      # The additional authenticated data is `"<doc_ref>|<slot>"` — a
      # payload copied into another row does not decrypt (invariant 6).
      # The nonce is fresh per seal.
      def self.seal(plaintext : String, doc_ref : String, slot : String) : String
        nonce = Random::Secure.random_bytes(NONCE_BYTES)
        ciphertext, tag = GCM.encrypt(
          aes_key(Facet::Secrets::Config::DEFAULT_KID), nonce,
          aad(doc_ref, slot), plaintext.to_slice,
        )

        [
          SEALED_ALGO,
          Facet::Secrets::Config::DEFAULT_KID,
          Base64.strict_encode(nonce),
          Base64.strict_encode(ciphertext),
          Base64.strict_encode(tag),
        ].join(".")
      end

      # Opens a sealed payload. Raises on tamper, AAD mismatch, or an
      # unknown key id — fail loud, never fall back.
      def self.open(payload : String, doc_ref : String, slot : String) : String
        parts = payload.split(".")
        unless parts.size == 5 && parts[0] == SEALED_ALGO
          raise ArgumentError.new("Malformed sealed payload: wrong shape")
        end

        _algo, kid, nonce_b64, ciphertext_b64, tag_b64 = parts
        nonce = Base64.decode(nonce_b64)
        ciphertext = Base64.decode(ciphertext_b64)
        tag = Base64.decode(tag_b64)

        plaintext = GCM.decrypt(aes_key(kid), nonce, aad(doc_ref, slot), ciphertext, tag)
        String.new(plaintext)
      end

      # ── token ─────────────────────────────────────────────────────────

      # Produces the payload for a raw token: one fast SHA-256, hex encoded.
      # Never bcrypt — tokens are high-entropy and the digest doubles as
      # the lookup key for atomic consume.
      def self.token_payload(raw_token : String) : String
        "#{TOKEN_ALGO}.#{Digest::SHA256.hexdigest(raw_token)}"
      end

      # Raw digest bytes of a token, for constant-time comparison against
      # a stored payload.
      def self.token_digest(raw_token : String) : Bytes
        Digest::SHA256.digest(raw_token)
      end

      # Decodes the digest half of a stored token payload. Returns nil when
      # the payload is malformed (fail closed at the caller).
      def self.token_digest_from_payload(payload : String) : Bytes?
        return nil unless payload.starts_with?("#{TOKEN_ALGO}.")
        hex = payload.lchop("#{TOKEN_ALGO}.")
        return nil unless hex.size == 64
        hex.hexbytes?
      end

      # ── diagnostics ───────────────────────────────────────────────────

      # Best-effort mode guess from a payload's prefix. Diagnostics only —
      # the stored `mode` column stays authoritative.
      def self.parse_mode(payload : String) : String
        return "hash" if payload.starts_with?("$2")
        return "sealed" if payload.starts_with?("#{SEALED_ALGO}.")
        return "token" if payload.starts_with?("#{TOKEN_ALGO}.")
        "unknown"
      end

      # Byte-for-byte comparison with no early exit on matching prefixes.
      # Both inputs are fixed-length digests in practice; the length check
      # leaks nothing (payload shapes are public).
      def self.constant_time_equal(a : Bytes, b : Bytes) : Bool
        return false if a.size != b.size
        diff = 0_u8
        a.each_with_index do |byte, i|
          diff |= byte ^ b[i]
        end
        diff == 0_u8
      end

      # ── Private ───────────────────────────────────────────────────────

      private def self.prehash(plaintext : String) : String
        Base64.strict_encode(Digest::SHA256.digest(plaintext))
      end

      private def self.aad(doc_ref : String, slot : String) : Bytes
        "#{doc_ref}|#{slot}".to_slice
      end

      # Normalizes the configured key material to the 32 bytes AES-256
      # needs. A key that decodes to exactly 32 bytes is used as-is; a
      # longer key is folded through SHA-256. Both forms are deterministic
      # for a given master key, so seals stay openable across restarts.
      private def self.aes_key(kid : String) : Bytes
        key = Facet::Config.instance.secrets.key_bytes(kid)
        return key if key.size == GCM::KEY_BYTES
        Digest::SHA256.digest(key)
      end

      # AES-256-GCM driven through the OpenSSL EVP API. Crystal 1.21's
      # `OpenSSL::Cipher` wrapper carries no GCM methods (no `auth_data=` /
      # `auth_tag`), so the primitive is bound here by hand.
      private module GCM
        EVP_CTRL_GCM_SET_IVLEN =  0x9
        EVP_CTRL_GCM_GET_TAG   = 0x10
        EVP_CTRL_GCM_SET_TAG   = 0x11

        KEY_BYTES   = 32
        NONCE_BYTES = 12
        TAG_BYTES   = 16

        CIPHER_NAME = "aes-256-gcm"

        def self.encrypt(key : Bytes, nonce : Bytes, aad : Bytes, plaintext : Bytes) : {Bytes, Bytes}
          ctx = LibCrypto.evp_cipher_ctx_new
          raise OpenSSL::Error.new("EVP_CIPHER_CTX_new failed") if ctx.null?
          begin
            init!(ctx, key, nonce, 1)
            outl = uninitialized Int32
            aad_out = Pointer(UInt8).null
            check!(LibCrypto.evp_cipherupdate(ctx, aad_out, pointerof(outl), aad.to_unsafe, aad.size))

            buffer = Bytes.new(plaintext.size + 16)
            written = 0
            check!(LibCrypto.evp_cipherupdate(ctx, buffer.to_unsafe, pointerof(outl), plaintext, plaintext.size))
            written += outl
            check!(LibCrypto.evp_cipherfinal_ex(ctx, buffer.to_unsafe + written, pointerof(outl)))
            written += outl

            tag = Bytes.new(TAG_BYTES)
            check!(LibCrypto.cipher_ctx_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, TAG_BYTES, tag.to_unsafe.as(Void*)))
            {buffer[0, written], tag}
          ensure
            LibCrypto.evp_cipher_ctx_free(ctx)
          end
        end

        def self.decrypt(key : Bytes, nonce : Bytes, aad : Bytes, ciphertext : Bytes, tag : Bytes) : Bytes
          raise ArgumentError.new("Malformed sealed payload: bad tag size") unless tag.size == TAG_BYTES

          ctx = LibCrypto.evp_cipher_ctx_new
          raise OpenSSL::Error.new("EVP_CIPHER_CTX_new failed") if ctx.null?
          begin
            init!(ctx, key, nonce, 0)
            outl = uninitialized Int32
            aad_out = Pointer(UInt8).null
            check!(LibCrypto.evp_cipherupdate(ctx, aad_out, pointerof(outl), aad.to_unsafe, aad.size))
            check!(LibCrypto.cipher_ctx_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, TAG_BYTES, tag.to_unsafe.as(Void*)))

            buffer = Bytes.new(ciphertext.size)
            written = 0
            check!(LibCrypto.evp_cipherupdate(ctx, buffer.to_unsafe, pointerof(outl), ciphertext, ciphertext.size))
            written += outl
            # For GCM (custom cipher) the final call is the authentication
            # step: 1 = tag verified, 0 = tampered payload or AAD mismatch.
            unless LibCrypto.evp_cipherfinal_ex(ctx, buffer.to_unsafe + written, pointerof(outl)) == 1
              raise ArgumentError.new("Sealed payload failed to open: authentication failed")
            end
            written += outl
            buffer[0, written]
          ensure
            LibCrypto.evp_cipher_ctx_free(ctx)
          end
        end

        private def self.init!(ctx : LibCrypto::EVP_CIPHER_CTX, key : Bytes, nonce : Bytes, enc : Int32) : Nil
          cipher = LibCrypto.evp_get_cipherbyname(CIPHER_NAME)
          raise OpenSSL::Error.new("Unknown cipher #{CIPHER_NAME}") if cipher.null?
          check!(LibCrypto.evp_cipherinit_ex(ctx, cipher, nil, nil, nil, enc))
          check!(LibCrypto.cipher_ctx_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, nonce.size, nil))
          check!(LibCrypto.evp_cipherinit_ex(ctx, nil, nil, key.to_unsafe, nonce.to_unsafe, enc))
        end

        private def self.check!(ok : Int32) : Nil
          raise OpenSSL::Error.new("AES-256-GCM operation failed") unless ok == 1
        end
      end
    end
  end
end
