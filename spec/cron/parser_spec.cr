# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/cron"

# 2024-01-01 is a Monday, 00:00:00 UTC.
REF = Time.utc(2024, 1, 1, 0, 0, 0)

describe Facet::Cron::Parser do
  it "computes the next minute for an every-minute expression" do
    parser = Facet::Cron::Parser.new("* * * * *")
    parser.next(REF).should eq Time.utc(2024, 1, 1, 0, 1, 0)
  end

  it "honours a specific minute and hour" do
    parser = Facet::Cron::Parser.new("30 5 * * *")
    parser.next(REF).should eq Time.utc(2024, 1, 1, 5, 30, 0)
  end

  it "rolls into the next day when the time has passed" do
    parser = Facet::Cron::Parser.new("30 5 * * *")
    parser.next(Time.utc(2024, 1, 1, 6, 0, 0)).should eq Time.utc(2024, 1, 2, 5, 30, 0)
  end

  it "respects the day-of-month field" do
    parser = Facet::Cron::Parser.new("0 0 15 * *")
    parser.next(REF).should eq Time.utc(2024, 1, 15, 0, 0, 0)
  end

  it "respects the month field and rolls the year" do
    parser = Facet::Cron::Parser.new("0 0 1 6 *")
    parser.next(Time.utc(2024, 7, 1, 0, 0, 0)).should eq Time.utc(2025, 6, 1, 0, 0, 0)
  end

  it "computes the last occurrence before the reference" do
    parser = Facet::Cron::Parser.new("30 5 * * *")
    parser.last(Time.utc(2024, 1, 1, 6, 0, 0)).should eq Time.utc(2024, 1, 1, 5, 30, 0)
  end

  it "expands the @hourly alias" do
    parser = Facet::Cron::Parser.new("@hourly")
    parser.next(Time.utc(2024, 1, 1, 0, 30, 0)).should eq Time.utc(2024, 1, 1, 1, 0, 0)
  end

  it "supports a 6-field expression with seconds" do
    parser = Facet::Cron::Parser.new("30 0 * * * *")
    parser.next(Time.utc(2024, 1, 1, 0, 0, 0)).should eq Time.utc(2024, 1, 1, 0, 0, 30)
  end

  it "raises ArgumentError on a malformed expression" do
    expect_raises(ArgumentError) { Facet::Cron::Parser.new("not a cron") }
  end

  it "raises ArgumentError on @reboot (unpredictable)" do
    expect_raises(ArgumentError) { Facet::Cron::Parser.new("@reboot") }
  end

  it "exposes the raw expression" do
    parser = Facet::Cron::Parser.new("*/5 * * * *")
    parser.expression.should eq "*/5 * * * *"
  end
end
