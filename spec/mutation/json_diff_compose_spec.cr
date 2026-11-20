# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/mutation/json_diff"

# Tests for diff composition (`Facet::Mutation::JsonDiff.compose`) and patch
# inversion (`Facet::Mutation::JsonDiff.invert`).
#
# The composition contract is a property: for consecutive diffs
# `d1 : X → Y` and `d2 : Y → Z`,
#
#     apply(apply(X, d1), d2) == apply(X, compose(d1, d2, Y))
#
# The case table below pins each row of the composition rules; the
# property test covers the rest over random documents.
# Applies a Result to a JSON document (serialize → parse → apply_diff,
# so the stored-JSON path is what gets exercised).
def apply_result(x : JSON::Any, result : Facet::Mutation::JsonDiff::Result) : JSON::Any
  Facet::Mutation::JsonDiff.apply_diff(x, JSON.parse(result.to_json))
end

def diff_of(a : JSON::Any, b : JSON::Any) : Facet::Mutation::JsonDiff::Result
  Facet::Mutation::JsonDiff.diff(a, b)
end

# Tests for diff composition (`Facet::Mutation::JsonDiff.compose`) and patch
# inversion (`Facet::Mutation::JsonDiff.invert`).
#
# The composition contract is a property: for consecutive diffs
# `d1 : X → Y` and `d2 : Y → Z`,
#
#     apply(apply(X, d1), d2) == apply(X, compose(d1, d2, Y))
#
# The case table below pins each row of the composition rules; the
# property test covers the rest over random documents.
describe Facet::Mutation::JsonDiff do
  describe ".compose case table" do
    it "keeps second's unset when second unsets a path" do
      x = JSON.parse(%({"a": 1, "b": 2}))
      y = JSON.parse(%({"a": 1, "b": 2, "c": 3}))
      z = JSON.parse(%({"a": 1, "b": 2}))

      d1 = diff_of(x, y) # set c = 3
      d2 = diff_of(y, z) # unset c

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
      composed.unset.should contain(["c"])
    end

    it "keeps first's entry when second does not touch the path" do
      x = JSON.parse(%({"a": 1}))
      y = JSON.parse(%({"a": 2, "b": 1}))
      z = JSON.parse(%({"a": 2, "b": 2}))

      d1 = diff_of(x, y) # set a = 2, set b = 1
      d2 = diff_of(y, z) # set b = 2

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
    end

    it "second's literal wins over first's literal (same path)" do
      x = JSON.parse(%({"a": 1}))
      y = JSON.parse(%({"a": 2}))
      z = JSON.parse(%({"a": 3}))

      d1 = diff_of(x, y)
      d2 = diff_of(y, z)

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      composed.set.size.should eq(1)
      composed.set.first.value.should eq(JSON.parse("3"))
      apply_result(x, composed).should eq(z)
    end

    it "second's literal wins over first's patch (same path)" do
      # A long base, a patch-sized first edit, then a short literal
      # replacement (new below the threshold forces a literal in d2).
      base = (1..60).map { |i| "line #{i}\n" }.join
      v1 = base.gsub("line 30\n", "line thirty\n")
      short = "tiny"

      x = JSON.parse(%({"body": #{base.inspect}}))
      y = JSON.parse(%({"body": #{v1.inspect}}))
      z = JSON.parse(%({"body": #{short.inspect}}))

      d1 = diff_of(x, y)
      d1.set.first.patch.should_not be_nil # first write emitted a patch

      d2 = diff_of(y, z)
      d2.set.first.value.should_not be_nil # second write emitted a literal

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      composed.set.first.value.should eq(JSON.parse(short.inspect))
      apply_result(x, composed).should eq(z)
    end

    it "keeps second's patch when first has no entry for the path" do
      base = (1..60).map { |i| "line #{i}\n" }.join
      v2 = base.gsub("line 30\n", "line thirty\n")

      x = JSON.parse(%({"body": #{base.inspect}}))
      y = JSON.parse(%({"body": #{base.inspect}, "note": "kept"}))
      z = JSON.parse(%({"body": #{v2.inspect}, "note": "kept"}))

      d1 = diff_of(x, y) # set note (body untouched)
      d2 = diff_of(y, z) # patch body

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
    end

    it "composes a patch over a first literal set" do
      v1 = (1..60).map { |i| "line #{i}\n" }.join
      v2 = v1.gsub("line 30\n", "line thirty\n")

      x = JSON.parse(%({"body": "short"}))
      y = JSON.parse(%({"body": #{v1.inspect}}))
      z = JSON.parse(%({"body": #{v2.inspect}}))

      d1 = diff_of(x, y) # literal set (old below threshold)
      d1.set.first.value.should_not be_nil
      d2 = diff_of(y, z) # patch (both sides long)
      d2.set.first.patch.should_not be_nil

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      composed.set.first.value.should eq(JSON.parse(v2.inspect))
      apply_result(x, composed).should eq(z)
    end

    it "composes patch over patch through invert and re-diff" do
      base = (1..60).map { |i| "line #{i}\n" }.join
      v1 = base.gsub("line 30\n", "line thirty\n")
      v2 = v1.gsub("line 40\n", "line forty\n")

      x = JSON.parse(%({"body": #{base.inspect}}))
      y = JSON.parse(%({"body": #{v1.inspect}}))
      z = JSON.parse(%({"body": #{v2.inspect}}))

      d1 = diff_of(x, y)
      d1.set.first.patch.should_not be_nil
      d2 = diff_of(y, z)
      d2.set.first.patch.should_not be_nil

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
      # The composed entry may itself be a patch — the differ decides.
    end

    it "composes patch over patch with moved offsets and merged hunks" do
      base = (1..80).map { |i| "line #{i}\n" }.join
      # Two edits in d1 far apart, then d2 edits between them — the composed
      # X→Z patch must span both regions.
      v1 = base.gsub("line 10\n", "line ten\n").gsub("line 60\n", "line sixty\n")
      v2 = v1.gsub("line 35\n", "line thirty-five\n")

      x = JSON.parse(%({"body": #{base.inspect}}))
      y = JSON.parse(%({"body": #{v1.inspect}}))
      z = JSON.parse(%({"body": #{v2.inspect}}))

      d1 = diff_of(x, y)
      d1.set.first.patch.not_nil!.hunks.size.should eq(2) # two separate regions
      d2 = diff_of(y, z)

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
    end

    it "composes unset-then-set across the two diffs" do
      x = JSON.parse(%({"a": 1, "b": 2}))
      y = JSON.parse(%({"b": 2}))
      z = JSON.parse(%({"b": 2, "a": 9}))

      d1 = diff_of(x, y) # unset a
      d2 = diff_of(y, z) # set a = 9

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
    end

    it "composes set-object then set-nested-key in application order" do
      x = JSON.parse(%({"a": {"b": 1, "c": 2}}))
      y = JSON.parse(%({"a": {"b": 1, "c": 2, "d": 3}}))
      z = JSON.parse(%({"a": {"b": 1, "c": 2, "d": 4}}))

      d1 = diff_of(x, y) # set a.d = 3 (nested)
      d2 = diff_of(y, z) # set a.d = 4 (nested)

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
    end

    it "composes whole-subtree set then nested set in application order" do
      x = JSON.parse(%({"a": {"old": true}}))
      y = JSON.parse(%({"a": {"b": 1, "c": 2}}))
      z = JSON.parse(%({"a": {"b": 9, "c": 2}}))

      d1 = diff_of(x, y) # set a = whole object (subtree replaced)
      d2 = diff_of(y, z) # set a.b = 9 (nested)

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
    end

    it "raises ArgumentError when patch∘patch arises without middle" do
      base = (1..60).map { |i| "line #{i}\n" }.join
      v1 = base.gsub("line 30\n", "line thirty\n")
      v2 = v1.gsub("line 40\n", "line forty\n")

      x = JSON.parse(%({"body": #{base.inspect}}))
      y = JSON.parse(%({"body": #{v1.inspect}}))
      z = JSON.parse(%({"body": #{v2.inspect}}))

      d1 = diff_of(x, y)
      d2 = diff_of(y, z)

      expect_raises(ArgumentError, /middle content is required/) do
        Facet::Mutation::JsonDiff.compose(d1, d2, nil)
      end
    end

    it "chains: compose(compose(d1, d2), d3) equals the sequential application" do
      x = JSON.parse(%({"n": 0, "s": "seed"}))
      y = JSON.parse(%({"n": 1, "s": "seed one"}))
      z = JSON.parse(%({"n": 2, "s": "seed two"}))
      w = JSON.parse(%({"n": 3, "s": "seed two three", "extra": true}))

      d1 = diff_of(x, y)
      d2 = diff_of(y, z)
      d3 = diff_of(z, w)

      merged_1 = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      merged_2 = Facet::Mutation::JsonDiff.compose(merged_1, d3, z)

      apply_result(apply_result(apply_result(x, d1), d2), d3).should eq(w)
      apply_result(x, merged_2).should eq(w)
    end

    it "composes meta diffs with the same rules" do
      x = JSON.parse(%({"schema_version": 1}))
      y = JSON.parse(%({"schema_version": 1, "label": "a"}))
      z = JSON.parse(%({"schema_version": 1, "label": "b"}))

      d1 = diff_of(x, y)
      d2 = diff_of(y, z)

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
    end
  end

  describe ".compose property" do
    it "satisfies apply(apply(X, d1), d2) == apply(X, compose(d1, d2, Y))" do
      random = Random.new(20260929)
      50.times do
        x = random_document(random)
        y = random_document(random)
        z = random_document(random)

        d1 = diff_of(x, y)
        next if d1.empty?
        d2 = diff_of(y, z)
        next if d2.empty?

        sequential = apply_result(apply_result(x, d1), d2)
        composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
        apply_result(x, composed).should eq(sequential)
      end
    end
  end

  describe ".compose with stored JSON" do
    it "composes a Result parsed back from its stored JSON form" do
      base = (1..60).map { |i| "line #{i}\n" }.join
      v1 = base.gsub("line 30\n", "line thirty\n")
      v2 = v1.gsub("line 40\n", "line forty\n")

      x = JSON.parse(%({"body": #{base.inspect}}))
      y = JSON.parse(%({"body": #{v1.inspect}}))
      z = JSON.parse(%({"body": #{v2.inspect}}))

      d1_stored = JSON.parse(diff_of(x, y).to_json)
      d1 = Facet::Mutation::JsonDiff::Result.from_json(d1_stored)
      d2 = diff_of(y, z)

      composed = Facet::Mutation::JsonDiff.compose(d1, d2, y)
      apply_result(x, composed).should eq(z)
    end

    it "round-trips set and unset through from_json" do
      body_old = "line\n" * 100
      body_new = "edited\n#{"line\n" * 99}"
      x = JSON.parse(%({"a": 1, "b": {"c": 2}, "body": #{body_old.inspect}}))
      y = JSON.parse(%({"a": 2, "d": 4, "body": #{body_new.inspect}}))

      result = diff_of(x, y)
      parsed = Facet::Mutation::JsonDiff::Result.from_json(JSON.parse(result.to_json))

      parsed.set.size.should eq(result.set.size)
      parsed.unset.should eq(result.unset)
      apply_result(x, parsed).should eq(apply_result(x, result))
    end

    it "parses an explicit null value entry" do
      stored = JSON.parse(%({"set": [{"path": ["a"], "value": null}], "unset": []}))
      parsed = Facet::Mutation::JsonDiff::Result.from_json(stored)
      parsed.set.size.should eq(1)
      value = parsed.set.first.value
      value.should_not be_nil
      value.not_nil!.raw.nil?.should be_true
    end

    it "treats a missing set/unset key as empty" do
      stored = JSON.parse(%({"set": []}))
      parsed = Facet::Mutation::JsonDiff::Result.from_json(stored)
      parsed.empty?.should be_true
    end
  end
end

# ── Random document generator ─────────────────────────────────────────────
#
# Produces nested JSON documents with string fields long enough to engage
# the patch path (≥ 256 chars), short string fields, numbers, and keys that
# appear and disappear between draws — so the composed diffs exercise every
# row of the composition table, patch∘patch included.

def random_string(random : Random, long : Bool) : String
  max_lines = long ? 60 : 20
  lines = random.rand(4..max_lines)
  String.build do |io|
    lines.times do |i|
      # Occasionally rewrite a line so consecutive draws share lines.
      marker = random.rand(10).zero? ? "edited" : "line"
      io << marker << " " << i << '\n'
    end
  end
end

def random_document(random : Random) : JSON::Any
  h = {} of String => JSON::Any
  # Shared key pool so documents overlap.
  {"alpha", "beta", "gamma", "delta"}.each_with_index do |key, i|
    next if random.rand(4).zero? # key absent in this draw
    case random.rand(4)
    when 0 then h[key] = JSON::Any.new(random_string(random, i.even?))
    when 1 then h[key] = JSON::Any.new(random.rand(100))
    when 2 then h[key] = JSON::Any.new({"nested" => JSON::Any.new(random_string(random, false)), "flag" => JSON::Any.new(random.rand(2) == 1)})
    else        h[key] = JSON::Any.new([JSON::Any.new(random_string(random, false)), JSON::Any.new("x#{random.rand(10)}")])
    end
  end
  JSON::Any.new(h)
end
