# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/mutation/json_diff"

# Helper: build a long string of N numbered lines.
def build_long_string(lines : Int32, suffix : String = "")
  String.build do |io|
    (1..lines).each do |i|
      io << "line " << i << suffix << '\n'
    end
  end
end

# Tests for the line-based patch encoding in `Facet::Mutation::JsonDiff`.
#
# These cover:
# - Short string changes still emit a full `value` (no patch).
# - Long string changes emit a `patch` with unified-diff hunks.
# - Round-trip: applying the emitted patch to the old string yields the new.
# - Sad paths: context/removed-line mismatches raise at apply time.
describe Facet::Mutation::JsonDiff do
  describe "patch emission" do
    it "emits a plain value for short string changes" do
      old = JSON.parse(%({"name": "Alice"}))
      new = JSON.parse(%({"name": "Bob"}))
      result = Facet::Mutation::JsonDiff.diff(old, new)

      entry = result.set.first
      entry.patch.should be_nil
      entry.value.should eq "Bob"
    end

    it "emits a plain value when the new string is below the threshold" do
      # Old is long, new is short — the new value is what would be stored.
      long_old = "x" * 300
      short_new = "tiny"
      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{long_old.inspect}})), JSON.parse(%({"body": #{short_new.inspect}})))

      entry = result.set.first
      entry.patch.should be_nil
      entry.value.should eq short_new
    end

    it "emits a patch for a small edit in a long string" do
      old_str = build_long_string(50)
      new_str = old_str.gsub("line 25", "line 25 (edited)")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      entry = result.set.first

      entry.patch.should_not be_nil
      entry.value.should be_nil

      # Applying the patch to the old string yields the new string.
      Facet::Mutation::JsonDiff.apply_patch(old_str, entry.patch.not_nil!).should eq(new_str)
    end

    it "falls back to a full value when the patch is larger than the value" do
      # Construct a case where almost every line changes — the patch
      # would be roughly the same size as the new value, so emit value.
      old_str = (1..40).map { |i| "old line #{i}\n" }.join
      new_str = (1..40).map { |i| "new line #{i}\n" }.join

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      entry = result.set.first

      # When the patch is not smaller, we should get a plain value.
      entry.value.should eq new_str
      entry.patch.should be_nil
    end

    it "includes context lines around changes" do
      old_str = build_long_string(50)
      new_str = old_str.gsub("line 25", "line 25 (edited)")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      hunk = result.set.first.patch.not_nil!.hunks.first

      # The hunk should have 3 lines of preceding context, the removed
      # line, the added line, and 3 lines of trailing context.
      hunk.lines.count(&.starts_with?(' ')).should eq 6
      hunk.lines.count(&.starts_with?('-')).should eq 1
      hunk.lines.count(&.starts_with?('+')).should eq 1
    end

    it "merges nearby changes into a single hunk" do
      old_str = build_long_string(60)
      # Two edits 2 lines apart — gap is < 2*CONTEXT_LINES+1, so they merge.
      new_str = old_str
        .gsub("line 20", "line 20 (a)")
        .gsub("line 22", "line 22 (b)")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      result.set.first.patch.not_nil!.hunks.size.should eq 1

      Facet::Mutation::JsonDiff.apply_patch(old_str, result.set.first.patch.not_nil!).should eq(new_str)
    end

    it "splits distant changes into separate hunks" do
      old_str = build_long_string(80)
      # Two edits more than 2*CONTEXT_LINES+1 = 7 lines apart.
      new_str = old_str
        .gsub("line 10", "line 10 (a)")
        .gsub("line 70", "line 70 (b)")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      result.set.first.patch.not_nil!.hunks.size.should eq 2

      Facet::Mutation::JsonDiff.apply_patch(old_str, result.set.first.patch.not_nil!).should eq(new_str)
    end
  end

  describe "no-newline-at-end" do
    it "patches when the old text has no trailing newline" do
      old_str = (1..60).map { |i| "line #{i}" }.join('\n') # No trailing newline
      new_str = old_str.gsub("line 30", "line 30 (edited)")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      entry = result.set.first

      entry.patch.should_not be_nil
      Facet::Mutation::JsonDiff.apply_patch(old_str, entry.patch.not_nil!).should eq(new_str)
    end

    it "patches when the edit introduces a trailing newline" do
      old_str = (1..60).map { |i| "line #{i}" }.join('\n')
      new_str = old_str + '\n' # Add trailing newline

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      entry = result.set.first

      Facet::Mutation::JsonDiff.apply_patch(old_str, entry.patch.not_nil!).should eq(new_str)
    end
  end

  describe "patch serialization" do
    it "round-trips through JSON" do
      old_str = build_long_string(50)
      new_str = old_str.gsub("line 25", "line 25 (edited)")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))

      json = result.to_json
      parsed = JSON.parse(json)

      set_entry = parsed["set"].as_a.first
      set_entry["path"].should eq ["body"]
      set_entry.as_h.has_key?("patch").should be_true
      set_entry.as_h.has_key?("value").should be_false

      hunks = set_entry["patch"]["hunks"].as_a
      hunks.should_not be_empty
    end
  end

  describe ".apply_patch sad paths" do
    it "raises on a context line mismatch" do
      old_str = build_long_string(50)
      new_str = old_str.gsub("line 25", "line 25 (edited)")
      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      patch = result.set.first.patch.not_nil!

      # Apply the patch to a different string — context lines around
      # line 25 won't match the tampered value.
      wrong_str = build_long_string(50).gsub("line 25", "tampered")
      expect_raises(ArgumentError, /context mismatch/i) do
        Facet::Mutation::JsonDiff.apply_patch(wrong_str, patch)
      end
    end

    it "raises on an invalid line marker" do
      patch = Facet::Mutation::JsonDiff::Patch.new([
        Facet::Mutation::JsonDiff::Hunk.new(
          old_start: 1, old_count: 1, new_start: 1, new_count: 1,
          lines: ["?bad"],
        ),
      ])
      expect_raises(ArgumentError, /invalid patch line marker/i) do
        Facet::Mutation::JsonDiff.apply_patch("hello\n", patch)
      end
    end

    it "raises when a hunk extends past the end of the old text" do
      patch = Facet::Mutation::JsonDiff::Patch.new([
        Facet::Mutation::JsonDiff::Hunk.new(
          old_start: 5, old_count: 1, new_start: 5, new_count: 1,
          lines: ["-missing"],
        ),
      ])
      expect_raises(ArgumentError, /exceeds old line count|expects line/i) do
        Facet::Mutation::JsonDiff.apply_patch("only one line\n", patch)
      end
    end
  end

  describe ".invert" do
    it "restores the original string: apply_patch(apply_patch(s, p), invert(p)) == s" do
      old_str = build_long_string(50)
      new_str = old_str.gsub("line 25", "line 25 (edited)")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      patch = result.set.first.patch.not_nil!

      inverted = Facet::Mutation::JsonDiff.invert(patch)
      Facet::Mutation::JsonDiff.apply_patch(new_str, inverted).should eq(old_str)
    end

    it "restores the original for a multi-hunk patch" do
      old_str = build_long_string(120)
      new_str = old_str.gsub("line 10", "line ten").gsub("line 60", "line sixty").gsub("line 110", "line one-ten")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      patch = result.set.first.patch.not_nil!
      patch.hunks.size.should be > 1 # the three regions split

      inverted = Facet::Mutation::JsonDiff.invert(patch)
      Facet::Mutation::JsonDiff.apply_patch(new_str, inverted).should eq(old_str)
    end

    it "swaps markers and counts, keeps context lines" do
      patch = Facet::Mutation::JsonDiff::Patch.new([
        Facet::Mutation::JsonDiff::Hunk.new(
          old_start: 10, old_count: 3, new_start: 10, new_count: 4,
          lines: [" ctx\n", "-old\n", "+new\n", "+added\n", " ctx2\n"],
        ),
      ])

      inverted = Facet::Mutation::JsonDiff.invert(patch)
      hunk = inverted.hunks.first
      hunk.old_start.should eq(10)
      hunk.old_count.should eq(4)
      hunk.new_start.should eq(10)
      hunk.new_count.should eq(3)
      hunk.lines.should eq([" ctx\n", "+old\n", "-new\n", "-added\n", " ctx2\n"])
    end

    it "inverts a pure insertion to a pure deletion (position conventions kept)" do
      old_str = build_long_string(50)
      # Insert lines in the middle: a hunk with old_count == 0.
      new_str = old_str.gsub("line 25\n", "inserted A\ninserted B\nline 25\n")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      patch = result.set.first.patch.not_nil!
      patch.hunks.all?(&.old_count.positive?).should be_true # context rides the hunks

      inverted = Facet::Mutation::JsonDiff.invert(patch)
      Facet::Mutation::JsonDiff.apply_patch(new_str, inverted).should eq(old_str)
    end

    it "inverts a patch whose final line has no trailing newline" do
      old_str = (1..60).map { |i| "line #{i}" }.join('\n') # no trailing newline
      new_str = old_str.gsub("line 30", "line 30 (edited)")

      result = Facet::Mutation::JsonDiff.diff(JSON.parse(%({"body": #{old_str.inspect}})), JSON.parse(%({"body": #{new_str.inspect}})))
      patch = result.set.first.patch.not_nil!

      inverted = Facet::Mutation::JsonDiff.invert(patch)
      Facet::Mutation::JsonDiff.apply_patch(new_str, inverted).should eq(old_str)
    end

    it "satisfies the inversion property for random strings and edits" do
      random = Random.new(20260929)
      25.times do
        base = String.build do |io|
          (1..random.rand(40..90)).each { |i| io << "line " << i << '\n' }
        end
        edited = base.gsub("line #{random.rand(5..35)}\n", "edited #{random.rand(100)}\n")

        result = Facet::Mutation::JsonDiff.diff(
          JSON.parse(%({"body": #{base.inspect}})),
          JSON.parse(%({"body": #{edited.inspect}}))
        )
        patch = result.set.first.patch
        next if patch.nil? # below threshold or not smaller — literal entry

        inverted = Facet::Mutation::JsonDiff.invert(patch)
        Facet::Mutation::JsonDiff.apply_patch(
          Facet::Mutation::JsonDiff.apply_patch(base, patch), inverted
        ).should eq(base)
      end
    end
  end
end
