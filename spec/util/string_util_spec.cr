# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/util/string_util"

describe Facet::Util::StringUtil do
  describe ".truncate" do
    it "returns the input unchanged when its length is at most max" do
      described = Facet::Util::StringUtil

      described.truncate("short", 10).should eq("short")
      described.truncate("exact", 5).should eq("exact")
      described.truncate("", 5).should eq("")
    end

    it "appends the ellipsis and total length equals max when input is longer" do
      described = Facet::Util::StringUtil

      result = described.truncate("a" * 100, 10)
      result.size.should eq(10)
      result.should eq("aaaaaaa...")

      result = described.truncate("Hello, world!", 8)
      result.size.should eq(8)
      result.should eq("Hello...")
    end

    it "supports a custom ellipsis" do
      described = Facet::Util::StringUtil

      result = described.truncate("a" * 100, 10, ellipsis: "…")
      result.size.should eq(10)
      result.should eq(("a" * 9) + "…")
    end

    it "clamps to ellipsis truncated to max when max is smaller than the ellipsis" do
      described = Facet::Util::StringUtil

      described.truncate("abcdef", 2).should eq("..")
      described.truncate("abcdef", 1).should eq(".")
      described.truncate("abcdef", 0).should eq("")
    end

    it "is codepoint-aware, not byte-aware" do
      described = Facet::Util::StringUtil

      # "é" is two bytes in UTF-8 but one codepoint.
      input = "é" * 10
      result = described.truncate(input, 5)
      result.size.should eq(5)
      result.should eq("éé...")
    end
  end

  describe ".humanize" do
    it "capitalizes words separated by underscores" do
      Facet::Util::StringUtil.humanize("in_progress").should eq("In Progress")
    end

    it "capitalizes words separated by hyphens" do
      Facet::Util::StringUtil.humanize("on-hold").should eq("On Hold")
    end

    it "handles a single word" do
      Facet::Util::StringUtil.humanize("done").should eq("Done")
    end

    it "handles empty string" do
      Facet::Util::StringUtil.humanize("").should eq("")
    end
  end
end
