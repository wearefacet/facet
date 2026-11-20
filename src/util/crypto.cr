# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "openssl"

module Facet
  module Util
    # Constant-time comparison helpers for secret tokens (PKCE verifiers,
    # bearer tokens, webhook signatures). Prevents timing oracles on the
    # byte comparison; the length check is unavoidable for equality.
    module Crypto
      # Constant-time byte comparison. Returns false early only when the
      # lengths differ (which is unavoidable for an equality check).
      def self.constant_time_eq?(a : String, b : String) : Bool
        return false unless a.bytesize == b.bytesize
        result = 0_u8
        a.to_slice.zip(b.to_slice) do |x, y|
          result |= x ^ y
        end
        result == 0
      end
    end
  end
end
