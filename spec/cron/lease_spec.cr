# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/cron"

module Facet
  describe Cron::Lease do
    # Real Redis (`config.test.yml` → `redis://localhost:6379/1`): the
    # acquire is a plain `SET NX EX`, so the spec asserts the win / loss
    # lifecycle of the exact proc the scheduler wiring uses, plus that the
    # expiry is armed on the key. The sweep itself is Redis's contract —
    # deleting the key stands in for it.
    it "wins the lease once per key and again after the key is gone" do
      url = Config.instance.event.url
      key = "spec:cron-lease:#{Util::ScriptHelpers.ulid}"
      acquire = Cron::Lease.redis_acquirer(url)

      acquire.call(key, 1, "spec-a").should be_true
      acquire.call(key, 1, "spec-b").should be_false

      # The expiry is armed: the key carries its full TTL.
      with_redis do |r|
        r.ttl(key).should eq(1)
        r.del(key)
      end

      acquire.call(key, 1, "spec-c").should be_true
    end
  end
end
