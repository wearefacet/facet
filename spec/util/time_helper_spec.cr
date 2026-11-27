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

  # `m` is a minute and `mo` a month — the grammar's one collision point.
  describe ".relative?" do
    it "accepts a signed value and a bare positive value" do
      Facet::Util::TimeHelper.relative?("-7d").should be_true
      Facet::Util::TimeHelper.relative?("+7d").should be_true
      Facet::Util::TimeHelper.relative?("7d").should be_true
    end

    it "accepts every unit" do
      %w[-1y -1mo -1w -1d -1h -1m -1s].each do |value|
        Facet::Util::TimeHelper.relative?(value).should be_true
      end
    end

    it "accepts several components in one value" do
      Facet::Util::TimeHelper.relative?("-1y2mo3w4d5h6m7s").should be_true
    end

    it "rejects an unknown unit, a broken component and a bare number" do
      Facet::Util::TimeHelper.relative?("-1x").should be_false
      Facet::Util::TimeHelper.relative?("-1mo1").should be_false
      Facet::Util::TimeHelper.relative?("-7").should be_false
      Facet::Util::TimeHelper.relative?("2026-01-01").should be_false
    end
  end

  describe ".relative_has_time_unit?" do
    it "is true for h, m and s" do
      Facet::Util::TimeHelper.relative_has_time_unit?("-1h").should be_true
      Facet::Util::TimeHelper.relative_has_time_unit?("-1m").should be_true
      Facet::Util::TimeHelper.relative_has_time_unit?("-1s").should be_true
    end

    it "is false for calendar units only" do
      Facet::Util::TimeHelper.relative_has_time_unit?("-1y2mo3w4d").should be_false
    end
  end

  describe ".parse_relative" do
    it "applies the leading sign to every component" do
      parsed = Facet::Util::TimeHelper.parse_relative("-1mo6d")
      parsed.map(&.unit).should eq([:month, :day])
      parsed.map(&.amount).should eq([-1, -6])
    end

    it "treats no sign as a future shift" do
      Facet::Util::TimeHelper.parse_relative("1d").first.amount.should eq(1)
    end

    it "reads m as a minute and mo as a month" do
      Facet::Util::TimeHelper.parse_relative("-5m").first.unit.should eq(:minute)
      Facet::Util::TimeHelper.parse_relative("-5mo").first.unit.should eq(:month)
    end

    it "raises on a value outside the grammar" do
      expect_raises(Facet::Util::TimeHelper::RelativeDateError) do
        Facet::Util::TimeHelper.parse_relative("-1x")
      end
    end
  end

  describe ".apply_relative" do
    anchor = Time.utc(2026, 3, 15, 10, 30, 0)

    it "steps a calendar month back to the same day" do
      Facet::Util::TimeHelper.apply_relative("-1mo", anchor: anchor).should eq(Time.utc(2026, 2, 15, 10, 30, 0))
    end

    it "clamps to the target month's last day" do
      Facet::Util::TimeHelper.apply_relative("-1mo", anchor: Time.utc(2026, 3, 31)).should eq(Time.utc(2026, 2, 28))
      Facet::Util::TimeHelper.apply_relative("-1mo", anchor: Time.utc(2026, 1, 31)).should eq(Time.utc(2025, 12, 31))
    end

    it "clamps a leap day back a year to the 28th" do
      Facet::Util::TimeHelper.apply_relative("-1y", anchor: Time.utc(2024, 2, 29)).should eq(Time.utc(2023, 2, 28))
    end

    it "applies weeks, days, hours, minutes and seconds" do
      Facet::Util::TimeHelper.apply_relative("-1w", anchor: anchor).should eq(Time.utc(2026, 3, 8, 10, 30, 0))
      Facet::Util::TimeHelper.apply_relative("-1d", anchor: anchor).should eq(Time.utc(2026, 3, 14, 10, 30, 0))
      Facet::Util::TimeHelper.apply_relative("-1h", anchor: anchor).should eq(Time.utc(2026, 3, 15, 9, 30, 0))
      Facet::Util::TimeHelper.apply_relative("-20m", anchor: anchor).should eq(Time.utc(2026, 3, 15, 10, 10, 0))
      Facet::Util::TimeHelper.apply_relative("-30s", anchor: anchor).should eq(Time.utc(2026, 3, 15, 10, 29, 30))
    end

    it "applies a future shift without a sign" do
      Facet::Util::TimeHelper.apply_relative("2d", anchor: anchor).should eq(Time.utc(2026, 3, 17, 10, 30, 0))
    end

    it "chains components with the shared sign" do
      Facet::Util::TimeHelper.apply_relative("-1mo1d", anchor: anchor).should eq(Time.utc(2026, 2, 14, 10, 30, 0))
    end
  end

  describe ".resolve_bound" do
    anchor = Time.utc(2026, 3, 15, 10, 30, 0)

    it "resolves a relative value against the anchor" do
      Facet::Util::TimeHelper.resolve_bound("-7d", anchor: anchor).should eq("2026-03-08T10:30:00Z")
    end

    it "normalizes an ISO-8601 value" do
      Facet::Util::TimeHelper.resolve_bound("2025-01-15T10:30:00+02:00").should eq("2025-01-15T08:30:00Z")
    end

    it "returns nil for a value that is neither" do
      Facet::Util::TimeHelper.resolve_bound("garbage").should be_nil
    end
  end

  describe ".day_edge" do
    it "moves to the start of the UTC day" do
      Facet::Util::TimeHelper.day_edge("2026-03-08T10:30:00Z", :start).should eq("2026-03-08T00:00:00Z")
    end

    it "moves to the last second of the UTC day" do
      Facet::Util::TimeHelper.day_edge("2026-03-08T10:30:00Z", :end).should eq("2026-03-08T23:59:59Z")
    end
  end
end
