# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/util/cache_freshness"

# Unit coverage for the shared staleness bound of the invalidate-only
# process caches. Pure checks — the two-arg `expired?` takes the bound
# explicitly, so no config swap is needed; `configured_ttl` swaps the
# config singleton, following the established spec pattern.
describe Facet::Util::CacheFreshness do
  describe ".expired?(built_at, ttl)" do
    it "never expires when the bound is zero (disabled)" do
      stamp = Time.instant - 1.hour
      Facet::Util::CacheFreshness.expired?(nil, 0.seconds).should be_false
      Facet::Util::CacheFreshness.expired?(stamp, 0.seconds).should be_false
    end

    it "treats a missing stamp as expired when a bound is set" do
      # A cache that never rebuilt has no data to trust.
      Facet::Util::CacheFreshness.expired?(nil, 30.seconds).should be_true
    end

    it "serves a stamp inside the bound" do
      stamp = Time.instant - 1.second
      Facet::Util::CacheFreshness.expired?(stamp, 30.seconds).should be_false
    end

    it "expires a stamp past the bound" do
      stamp = Time.instant - 31.seconds
      Facet::Util::CacheFreshness.expired?(stamp, 30.seconds).should be_true
    end
  end

  describe ".configured_ttl" do
    it "reads the bound from cache.staleness_ttl_s" do
      original = Facet::Config.instance
      begin
        Facet::Config.instance = Facet::Config.new(
          artifact_grant_secret: original.artifact_grant_secret,
          cache: Facet::Config::CacheConfig.new(staleness_ttl_s: 45),
        )
        Facet::Util::CacheFreshness.configured_ttl.should eq(45.seconds)
      ensure
        Facet::Config.instance = original
      end
    end
  end

  describe ".expired?(built_at)" do
    it "applies the configured bound" do
      original = Facet::Config.instance
      begin
        Facet::Config.instance = Facet::Config.new(
          artifact_grant_secret: original.artifact_grant_secret,
          cache: Facet::Config::CacheConfig.new(staleness_ttl_s: 1),
        )
        # Missing stamp → expired under an enabled bound.
        Facet::Util::CacheFreshness.expired?(nil).should be_true

        # A fresh stamp serves; a stamp past the bound expires.
        Facet::Util::CacheFreshness.expired?(Time.instant).should be_false
        old = Time.instant - 2.seconds
        Facet::Util::CacheFreshness.expired?(old).should be_true
      ensure
        Facet::Config.instance = original
      end
    end

    it "never expires when the configured bound is disabled" do
      # config.test.yml sets `cache.staleness_ttl_s: 0`.
      Facet::Config.instance.cache.staleness_ttl_s.should eq(0)
      Facet::Util::CacheFreshness.expired?(nil).should be_false
      Facet::Util::CacheFreshness.expired?(Time.instant - 1.hour).should be_false
    end
  end
end
