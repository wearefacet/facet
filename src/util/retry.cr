# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Retries a block with exponential backoff when an exception matching
    # the given type is raised.
    module Retry
      extend self

      def with_retry(max_attempts = 5, base_delay = 0.1, exception : Exception.class = ::Exception, &)
        attempts = 0
        loop do
          attempts += 1
          return yield
        rescue ex
          if attempts >= max_attempts || !(ex.class <= exception)
            raise ex
          end
          ns = (base_delay * (2 ** (attempts - 1)) * 1e9).to_i64
          sleep(ns.nanoseconds)
        end
      end
    end
  end
end
