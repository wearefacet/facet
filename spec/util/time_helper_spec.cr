# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/util/time_helper"

describe Facet::Util::TimeHelper do
  describe ".to_utc_rfc3339" do
    it "normalizes a UTC ISO-8601 value to itself" do
      subject = Facet::Util::TimeHelper.to_utc_rfc3339("2025-01-15T10:30:00Z")
      subject.should eq("2025-01-15T10:30:00Z")
    end

    it "normalizes a positive timezone offset to UTC" do
      subject = Facet::Util::TimeHelper.to_utc_rfc3339("2025-01-15T10:30:00+02:00")
      subject.should eq("2025-01-15T08:30:00Z")
    end

    it "normalizes a negative timezone offset to UTC" do
      subject = Facet::Util::TimeHelper.to_utc_rfc3339("2025-01-15T10:30:00-05:00")
      subject.should eq("2025-01-15T15:30:00Z")
    end

    it "drops fractional seconds in the canonical form" do
      subject = Facet::Util::TimeHelper.to_utc_rfc3339("2025-01-15T10:30:00.123Z")
      subject.should eq("2025-01-15T10:30:00Z")
    end

    it "returns nil for an unparseable string" do
      subject = Facet::Util::TimeHelper.to_utc_rfc3339("not-a-date")
      subject.should be_nil
    end

    it "returns nil for a tz-naive datetime (Crystal rejects these)" do
      subject = Facet::Util::TimeHelper.to_utc_rfc3339("2025-01-15T10:30:00")
      subject.should be_nil
    end
  end
end
