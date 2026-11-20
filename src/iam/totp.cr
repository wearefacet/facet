# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "openssl/hmac"
require "openssl/digest"
require "random/secure"
require "crypto/subtle"

module Facet
  module IAM
    # TOTP (RFC 6238) implementation using HMAC-SHA1.
    #
    # Vendored (~90 lines) rather than pulled in as a shard because the
    # primitives are all stdlib (HMAC, Secure random) and the arithmetic
    # is deterministic non-secret encoding. Validated against RFC 4226
    # Appendix D and RFC 6238 Appendix B test vectors.
    #
    # ## Parameters (fixed for authenticator-app compatibility)
    #
    # - Algorithm: HMAC-SHA1
    # - Digits: 6
    # - Period: 30 seconds
    # - Secret: 160-bit (20 bytes), base32 encoded (RFC 4648, no padding)
    module TOTP
      # The number of digits in the OTP code.
      DIGITS = 6

      # The time step in seconds.
      PERIOD = 30

      # Generates a 160-bit (20-byte) random secret and returns it
      # base32-encoded (RFC 4648, no padding).
      def self.generate_secret : String
        raw = Random::Secure.random_bytes(20)
        base32_encode(raw)
      end

      # Generates the TOTP code for a given base32 secret and Unix timestamp.
      def self.generate(secret_base32 : String, time : Int64 = Time.utc.to_unix) : String
        counter = time // PERIOD
        generate_hotp(secret_base32, counter)
      end

      # Validates a TOTP code against a base32 secret.
      #
      # Returns the time step of the accepted code, or `nil` if no step matches.
      # The caller must compare the returned step against `last_totp_step` for
      # replay protection.
      #
      # Accepts codes from the current time step ± `window` steps (default 1).
      # Comparison is constant-time via `Crypto::Subtle`.
      def self.validate(
        secret_base32 : String,
        code : String,
        time : Int64 = Time.utc.to_unix,
        window : Int32 = 1,
      ) : Int64?
        counter = time // PERIOD

        (-window..window).each do |offset|
          step = counter + offset
          expected = generate_hotp(secret_base32, step)
          if Crypto::Subtle.constant_time_compare(code, expected)
            return step
          end
        end

        nil
      end

      # Builds an `otpauth://` URI for QR code rendering.
      def self.otpauth_uri(
        secret_base32 : String,
        account : String,
        issuer : String = "Facet",
      ) : String
        encoded_account = URI.encode_www_form(account)
        encoded_issuer = URI.encode_www_form(issuer)
        "otpauth://totp/#{encoded_issuer}:#{encoded_account}" \
        "?secret=#{secret_base32}" \
        "&issuer=#{encoded_issuer}" \
        "&algorithm=SHA1&digits=#{DIGITS}&period=#{PERIOD}"
      end

      # ── Private ──────────────────────────────────────────────────────

      # Generates an HOTP (RFC 4226) code for a given secret and counter.
      private def self.generate_hotp(secret_base32 : String, counter : Int64) : String
        secret = base32_decode(secret_base32)

        # Encode counter as 8-byte big-endian
        counter_bytes = Bytes.new(8)
        8.times do |i|
          counter_bytes[7 - i] = ((counter >> (i * 8)) & 0xFF).to_u8
        end

        # HMAC-SHA1
        hmac = OpenSSL::HMAC.digest(:sha1, secret, counter_bytes)

        # Dynamic truncation (RFC 4226 §5.3)
        offset = hmac[-1] & 0x0F
        code_bytes = hmac[offset, 4]

        # Mask the most significant byte
        masked = (code_bytes[0].to_u32 & 0x7F) << 24 |
                 code_bytes[1].to_u32 << 16 |
                 code_bytes[2].to_u32 << 8 |
                 code_bytes[3].to_u32

        # Mod 10^6, zero-padded
        code = masked % 10_u32 ** DIGITS
        code.to_s.rjust(DIGITS, '0')
      end

      # ── Base32 (RFC 4648, no padding) ────────────────────────────────────

      private ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

      # Encodes raw bytes to base32 (RFC 4648, no padding).
      private def self.base32_encode(data : Bytes) : String
        result = IO::Memory.new
        bits = 0_u32
        bit_count = 0

        data.each do |byte|
          bits = (bits << 8) | byte
          bit_count += 8

          while bit_count >= 5
            bit_count -= 5
            index = (bits >> bit_count) & 0x1F
            result.write_byte(ALPHABET[index].ord.to_u8)
          end
        end

        if bit_count > 0
          bits <<= (5 - bit_count)
          result.write_byte(ALPHABET[(bits & 0x1F)].ord.to_u8)
        end

        result.to_s
      end

      # Decodes a base32 string (RFC 4648, no padding tolerated) to raw bytes.
      private def self.base32_decode(encoded : String) : Bytes
        # Remove padding and whitespace
        cleaned = encoded.upcase.gsub(/[^A-Z2-7]/, "")

        buffer = IO::Memory.new
        bits = 0_u32
        bit_count = 0

        cleaned.each_byte do |byte|
          index = ALPHABET.index(byte.chr) || raise ArgumentError.new("Invalid base32 character: #{byte.chr}")
          bits = (bits << 5) | index
          bit_count += 5

          while bit_count >= 8
            bit_count -= 8
            buffer.write_byte(((bits >> bit_count) & 0xFF).to_u8)
          end
        end

        buffer.to_slice
      end
    end
  end
end
