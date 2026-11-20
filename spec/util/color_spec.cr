# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/util/color"

describe Facet::Util::Color do
  # ── Hex ───────────────────────────────────────────────────────────────

  describe ".normalize" do
    it "normalizes #RGB to #RRGGBBFF" do
      Facet::Util::Color.normalize("#ABC").should eq("#aabbccff")
      Facet::Util::Color.normalize("#abc").should eq("#aabbccff")
      Facet::Util::Color.normalize("#F0A").should eq("#ff00aaff")
    end

    it "normalizes #RRGGBB to #RRGGBBFF" do
      Facet::Util::Color.normalize("#FF00CC").should eq("#ff00ccff")
      Facet::Util::Color.normalize("#ff00cc").should eq("#ff00ccff")
      Facet::Util::Color.normalize("#123456").should eq("#123456ff")
    end

    it "normalizes #RRGGBBAA to #RRGGBBAA" do
      Facet::Util::Color.normalize("#FF00CC80").should eq("#ff00cc80")
      Facet::Util::Color.normalize("#ff00cc80").should eq("#ff00cc80")
      Facet::Util::Color.normalize("#00000000").should eq("#00000000")
    end

    it "normalizes #RGBA to #RRGGBBAA" do
      Facet::Util::Color.normalize("#F0A8").should eq("#ff00aa88")
      Facet::Util::Color.normalize("#f0a8").should eq("#ff00aa88")
    end
  end

  # ── rgb / rgba ────────────────────────────────────────────────────────

  it "normalizes rgb(r,g,b) to #RRGGBBFF" do
    Facet::Util::Color.normalize("rgb(255, 0, 204)").should eq("#ff00ccff")
    Facet::Util::Color.normalize("rgb(0, 0, 0)").should eq("#000000ff")
    Facet::Util::Color.normalize("rgb(255, 255, 255)").should eq("#ffffffff")
  end

  it "normalizes rgba(r,g,b,a) to #RRGGBBAA" do
    Facet::Util::Color.normalize("rgba(255, 0, 0, 0.5)").should eq("#ff000080")
    Facet::Util::Color.normalize("rgba(0, 255, 0, 1.0)").should eq("#00ff00ff")
    Facet::Util::Color.normalize("rgba(0, 0, 255, 0)").should eq("#0000ff00")
  end

  it "handles extra whitespace in rgb/rgba" do
    Facet::Util::Color.normalize("  rgb( 10 , 20 , 30 )  ").should eq("#0a141eff")
  end

  # ── hsl / hsla ───────────────────────────────────────────────────────

  it "normalizes hsl(h,s,l) to #RRGGBBFF" do
    Facet::Util::Color.normalize("hsl(300, 100%, 50%)").should eq("#ff00ffff")
    Facet::Util::Color.normalize("hsl(0, 0%, 0%)").should eq("#000000ff")
    Facet::Util::Color.normalize("hsl(0, 0%, 100%)").should eq("#ffffffff")
  end

  it "normalizes hsla(h,s,l,a) to #RRGGBBAA" do
    Facet::Util::Color.normalize("hsla(120, 100%, 50%, 0.5)").should eq("#00ff0080")
    result = Facet::Util::Color.normalize("hsla(0, 100%, 50%, 1.0)")
    result.should eq("#ff0000ff")
  end

  it "converts a known HSL color correctly" do
    Facet::Util::Color.normalize("hsl(210, 100%, 50%)").should eq("#007fffff")
  end

  # ── Alpha edge cases ──────────────────────────────────────────────────

  it "accepts alpha percentage" do
    Facet::Util::Color.normalize("rgba(255, 0, 0, 50%)").should eq("#ff000080")
  end

  it "accepts alpha 0 (transparent)" do
    Facet::Util::Color.normalize("rgba(255, 0, 0, 0)").should eq("#ff000000")
  end

  it "accepts alpha 1 (opaque)" do
    Facet::Util::Color.normalize("rgba(255, 0, 0, 1)").should eq("#ff0000ff")
  end

  # ── Error handling ────────────────────────────────────────────────────

  it "raises on invalid hex format" do
    expect_raises(ArgumentError, /Invalid color format/) do
      Facet::Util::Color.normalize("#GGG")
    end
  end

  it "raises on out-of-range RGB values" do
    expect_raises(ArgumentError, /range/) do
      Facet::Util::Color.normalize("rgb(300, 0, 0)")
    end
  end

  it "raises on malformed rgb syntax" do
    expect_raises(ArgumentError, /Invalid color format/) do
      Facet::Util::Color.normalize("rgb(255, 0)")
    end
  end

  it "raises on out-of-range HSL hue" do
    expect_raises(ArgumentError, /out of range/) do
      Facet::Util::Color.normalize("hsl(400, 50%, 50%)")
    end
  end

  it "raises on alpha out of range" do
    expect_raises(ArgumentError, /Alpha must be in range/) do
      Facet::Util::Color.normalize("rgba(255, 0, 0, 1.5)")
    end
  end

  it "raises on completely invalid strings" do
    expect_raises(ArgumentError, /Invalid color format/) do
      Facet::Util::Color.normalize("not-a-color")
    end
  end

  it "raises on alpha percentage out of range" do
    expect_raises(ArgumentError, /Alpha percentage must be in range/) do
      Facet::Util::Color.normalize("rgba(255, 0, 0, 150%)")
    end
  end

  # ── .valid? ──────────────────────────────────────────────────────────

  describe ".valid?" do
    it "returns true for valid colors" do
      Facet::Util::Color.valid?("#FF00CC").should be_true
      Facet::Util::Color.valid?("rgb(255,0,0)").should be_true
      Facet::Util::Color.valid?("hsl(210, 100%, 50%)").should be_true
    end

    it "returns false for invalid strings" do
      Facet::Util::Color.valid?("#GGG").should be_false
      Facet::Util::Color.valid?("not-a-color").should be_false
      Facet::Util::Color.valid?("rgb(300, 0, 0)").should be_false
    end
  end

  # ── hash_color ────────────────────────────────────────────────────────

  describe ".hash_color" do
    it "returns a stable hex color for the same seed" do
      Facet::Util::Color.hash_color("crm.Deal").should eq(Facet::Util::Color.hash_color("crm.Deal"))
    end

    it "returns a #RRGGBB hex string" do
      result = Facet::Util::Color.hash_color("in_progress")
      result.should match(/^#[0-9a-f]{6}$/)
    end

    it "produces different hues across different seeds" do
      seeds = %w[a b c d e f g h]
      colors = seeds.map { |s| Facet::Util::Color.hash_color(s) }
      colors.uniq.size.should be >= 6
    end
  end
end
