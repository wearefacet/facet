# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/util/sequence"

describe Facet::Util::Sequence do
  # ── First identifier (current_value = nil) ──────────────────────────────

  describe ".next with nil (first value)" do
    it "generates the very first identifier with counter starting at 1" do
      result = Facet::Util::Sequence.next("INV-{year}-####", nil)
      result.overflow?.should be_false
      result.value.not_nil!.starts_with?("INV-").should be_true
      result.value.not_nil!.should match(/INV-\d{4}-0001/)
    end

    it "fills {year}, {month}, {day} from current time, counter starts at 1" do
      now = Time.utc
      result = Facet::Util::Sequence.next("DOC-{year}-{month}-{day}-##", nil)
      result.overflow?.should be_false
      expected = "DOC-#{now.year}-#{now.month.to_s.rjust(2, '0')}-#{now.day.to_s.rjust(2, '0')}-01"
      result.value.should eq(expected)
    end

    it "works with only digit groups (counter starts at 1)" do
      result = Facet::Util::Sequence.next("###", nil)
      result.overflow?.should be_false
      result.value.should eq("001")
    end

    it "works with a single digit group" do
      result = Facet::Util::Sequence.next("#", nil)
      result.overflow?.should be_false
      result.value.should eq("1")
    end

    it "multiple digit groups: only the rightmost starts at 1" do
      result = Facet::Util::Sequence.next("####-####", nil)
      result.overflow?.should be_false
      result.value.should eq("0000-0001")
    end
  end

  # ── Increment — single digit group ─────────────────────────────────────

  describe ".next with single digit group" do
    it "increments the digit group" do
      result = Facet::Util::Sequence.next("INV-#", "INV-1")
      result.overflow?.should be_false
      result.value.should eq("INV-2")
    end

    it "handles zero-padding within the group" do
      result = Facet::Util::Sequence.next("TKT-###", "TKT-005")
      result.overflow?.should be_false
      result.value.should eq("TKT-006")
    end

    it "increments from 9 to 10 preserving width" do
      result = Facet::Util::Sequence.next("ID-###", "ID-009")
      result.overflow?.should be_false
      result.value.should eq("ID-010")
    end

    it "handles wide digit groups" do
      result = Facet::Util::Sequence.next("BIG-######", "BIG-000099")
      result.overflow?.should be_false
      result.value.should eq("BIG-000100")
    end
  end

  # ── Increment — multiple digit groups ───────────────────────────────────

  describe ".next with multiple digit groups" do
    it "increments the rightmost group" do
      year = Time.utc.year
      result = Facet::Util::Sequence.next("INV-{year}-####-####", "INV-#{year}-0000-0001")
      result.overflow?.should be_false
      result.value.should eq("INV-#{year}-0000-0002")
    end

    it "carries to the left group when rightmost overflows" do
      year = Time.utc.year
      result = Facet::Util::Sequence.next("INV-{year}-####-####", "INV-#{year}-0000-9999")
      result.overflow?.should be_false
      result.value.should eq("INV-#{year}-0001-0000")
    end

    it "carries across multiple groups" do
      year = Time.utc.year
      result = Facet::Util::Sequence.next("INV-{year}-####-####", "INV-#{year}-0099-9999")
      result.overflow?.should be_false
      result.value.should eq("INV-#{year}-0100-0000")
    end

    it "works with mixed width groups" do
      result = Facet::Util::Sequence.next("TKT-####-#", "TKT-0000-1")
      result.overflow?.should be_false
      result.value.should eq("TKT-0000-2")
    end

    it "carries from a single-digit group to a wider left group" do
      result = Facet::Util::Sequence.next("TKT-####-#", "TKT-0000-9")
      result.overflow?.should be_false
      result.value.should eq("TKT-0001-0")
    end
  end

  # ── Time-variable rollover (variable ALWAYS reflects current time) ──────

  describe ".next time variable rollover" do
    it "resets counter to 1 when year changes" do
      result = Facet::Util::Sequence.next("INV-{year}-####", "INV-2020-0099")
      result.overflow?.should be_false
      result.value.not_nil!.should start_with("INV-#{Time.utc.year}-0001")
    end

    it "continues incrementing within same year" do
      now = Time.utc
      current = "INV-#{now.year}-0042"
      result = Facet::Util::Sequence.next("INV-{year}-####", current)
      result.overflow?.should be_false
      result.value.should eq("INV-#{now.year}-0043")
    end

    it "resets when month changes (day stays the same, counter resets)" do
      now = Time.utc
      past_month = now.month == 1 ? 12 : now.month - 1
      past_year = now.month == 1 ? now.year - 1 : now.year
      current = "DOC-#{past_year}-#{past_month.to_s.rjust(2, '0')}-#{now.day.to_s.rjust(2, '0')}-0099"
      result = Facet::Util::Sequence.next("DOC-{year}-{month}-{day}-####", current)
      result.overflow?.should be_false
      expected = "DOC-#{now.year}-#{now.month.to_s.rjust(2, '0')}-#{now.day.to_s.rjust(2, '0')}-0001"
      result.value.should eq(expected)
    end

    it "variable DID NOT change — normal increment (not reset)" do
      now = Time.utc
      current = "T-2023-06-01"
      result = Facet::Util::Sequence.next("T-{year}-{month}-##", current)
      result.overflow?.should be_false
      # 2023 != current year, so variables changed → reset
      result.value.should eq("T-#{now.year}-#{now.month.to_s.rjust(2, '0')}-01")
    end
  end

  # ── Overflow ────────────────────────────────────────────────────────────

  describe ".next overflow" do
    it "returns overflow: true when the leftmost digit group overflows" do
      result = Facet::Util::Sequence.next("INV-#", "INV-9")
      result.overflow?.should be_true
      result.value.should be_nil
    end

    it "returns overflow: true when all groups are maxed" do
      year = Time.utc.year
      result = Facet::Util::Sequence.next("INV-{year}-####-####", "INV-#{year}-9999-9999")
      result.overflow?.should be_true
      result.value.should be_nil
    end

    it "returns overflow: true when the only group is maxed" do
      result = Facet::Util::Sequence.next("###", "999")
      result.overflow?.should be_true
      result.value.should be_nil
    end
  end

  # ── Template validation (sad paths) ─────────────────────────────────────

  describe ".next template validation" do
    it "raises on template with no digit group and names the counter rule" do
      expect_raises(ArgumentError, /must contain at least one '#' digit group \(the auto-increment counter\)/) do
        Facet::Util::Sequence.next("INV-{year}-STATIC", nil)
      end
    end

    it "points at the grammar doc when the template has no digit group" do
      expect_raises(ArgumentError, /doc\/backend\/util-sequence\.md/) do
        Facet::Util::Sequence.next("INV-{year}-STATIC", nil)
      end
    end

    it "raises on unknown variable and names the valid variables" do
      expect_raises(ArgumentError, /Unknown variable \{foo\} \(valid variables: \{year\}, \{month\}, \{day\}\) in template/) do
        Facet::Util::Sequence.next("DOC-{foo}-#", nil)
      end
    end

    it "raises on unclosed brace" do
      expect_raises(ArgumentError, /Unclosed/) do
        Facet::Util::Sequence.next("DOC-{year-#", nil)
      end
    end
  end

  # ── current_value mismatch (sad paths) ─────────────────────────────────

  describe ".next value mismatch" do
    it "raises when current_value does not match the template pattern" do
      expect_raises(ArgumentError, /does not match/) do
        Facet::Util::Sequence.next("INV-{year}-####", "INV-ABCD-1234")
      end
    end

    it "raises on wrong length current_value" do
      expect_raises(ArgumentError, /does not match/) do
        Facet::Util::Sequence.next("TKT-###", "TKT-12")
      end
    end

    it "raises on extra suffix" do
      expect_raises(ArgumentError, /does not match/) do
        Facet::Util::Sequence.next("TKT-###", "TKT-123-EXTRA")
      end
    end
  end

  # ── Edge cases ──────────────────────────────────────────────────────────

  describe ".next edge cases" do
    it "works with a template that is only digits (counter starts at 1)" do
      result = Facet::Util::Sequence.next("####", "0001")
      result.overflow?.should be_false
      result.value.should eq("0002")
    end

    it "works with digits at the start of the template" do
      result = Facet::Util::Sequence.next("##-TKT", "01-TKT")
      result.overflow?.should be_false
      result.value.should eq("02-TKT")
    end

    it "handles the user's example from the issue" do
      year = Time.utc.year
      result = Facet::Util::Sequence.next("INV-{year}-####-####", "INV-#{year}-0000-0001")
      result.overflow?.should be_false
      result.value.should eq("INV-#{year}-0000-0002")
    end
  end
end
