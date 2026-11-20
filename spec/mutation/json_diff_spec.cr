# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/mutation/json_diff"

describe Facet::Mutation::JsonDiff do
  describe ".diff" do
    it "returns an empty diff for identical JSON objects" do
      old = JSON.parse(%({"a": 1, "b": "hello"}))
      new = JSON.parse(%({"a": 1, "b": "hello"}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.should be_empty
    end

    it "returns an empty diff for identical nested objects" do
      old = JSON.parse(%({"a": {"b": 1, "c": 2}}))
      new = JSON.parse(%({"a": {"b": 1, "c": 2}}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.should be_empty
    end

    it "detects a scalar value change" do
      old = JSON.parse(%({"submitted": false}))
      new = JSON.parse(%({"submitted": true}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["submitted"]
      entry.value.should be_true
      result.unset.should be_empty
    end

    it "detects a new top-level key" do
      old = JSON.parse(%({}))
      new = JSON.parse(%({"submitted_by": "01JUSER..."}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["submitted_by"]
      entry.value.should eq "01JUSER..."
      result.unset.should be_empty
    end

    it "detects a removed top-level key" do
      old = JSON.parse(%({"draft_token": "abc123"}))
      new = JSON.parse(%({}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.unset.size.should eq 1
      result.unset.first.should eq ["draft_token"]
      result.set.should be_empty
    end

    it "detects a nested value change" do
      old = JSON.parse(%({"address": {"city": "Paris", "zip": "75001"}}))
      new = JSON.parse(%({"address": {"city": "Bangkok", "zip": "75001"}}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["address", "city"]
      entry.value.should eq "Bangkok"
      result.unset.should be_empty
    end

    it "detects a nested key removal" do
      old = JSON.parse(%({"address": {"city": "Paris", "zip": "75001"}}))
      new = JSON.parse(%({"address": {"city": "Paris"}}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.unset.size.should eq 1
      result.unset.first.should eq ["address", "zip"]
      result.set.should be_empty
    end

    it "detects a nested key addition" do
      old = JSON.parse(%({"address": {"city": "Paris"}}))
      new = JSON.parse(%({"address": {"city": "Paris", "country": "France"}}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["address", "country"]
      entry.value.should eq "France"
      result.unset.should be_empty
    end

    it "does not recurse into arrays (treats them as atomic values)" do
      old = JSON.parse(%({"tags": ["a", "b"]}))
      new = JSON.parse(%({"tags": ["a", "b", "c"]}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["tags"]
      entry.value.should eq JSON.parse(%(["a", "b", "c"]))
      result.unset.should be_empty
    end

    it "handles mixed: set + unset in one diff" do
      old = JSON.parse(%({"submitted": false, "draft_token": "abc123"}))
      new = JSON.parse(%({"submitted": true, "submitted_by": "01JUSER..."}))

      result = Facet::Mutation::JsonDiff.diff(old, new)

      # Find set entries by path
      set_paths = result.set.map(&.path)
      set_paths.should contain ["submitted"]
      set_paths.should contain ["submitted_by"]

      # Find unset entries by path
      result.unset.should contain ["draft_token"]
    end

    it "matches the example from the specification" do
      old = JSON.parse(%({"submitted": false, "submitted_by": null, "address": {"city": "Paris"}, "draft_token": "abc"}))
      new = JSON.parse(%({"submitted": true, "submitted_by": "01JUSER...", "address": {"city": "Bangkok"}}))

      result = Facet::Mutation::JsonDiff.diff(old, new)

      result.set.find { |e| e.path == ["submitted"] }.try(&.value).should be_true
      result.set.find { |e| e.path == ["submitted_by"] }.try(&.value).should eq "01JUSER..."
      result.set.find { |e| e.path == ["address", "city"] }.try(&.value).should eq "Bangkok"
      result.unset.should contain ["draft_token"]
    end

    it "handles null values properly" do
      old = JSON.parse(%({"a": null}))
      new = JSON.parse(%({"a": "value"}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["a"]
      entry.value.should eq "value"
      result.unset.should be_empty
    end

    it "handles boolean values" do
      old = JSON.parse(%({"flag": false}))
      new = JSON.parse(%({"flag": true}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["flag"]
      entry.value.should be_true
    end

    it "handles number values" do
      old = JSON.parse(%({"count": 1}))
      new = JSON.parse(%({"count": 42}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["count"]
      entry.value.should eq 42
    end

    it "serializes to JSON correctly" do
      old = JSON.parse(%({"name": "Alice", "age": 30}))
      new = JSON.parse(%({"name": "Alice", "age": 31, "city": "Paris"}))

      result = Facet::Mutation::JsonDiff.diff(old, new)

      json_str = result.to_json
      parsed = JSON.parse(json_str)

      parsed["set"].should be_a(JSON::Any)
      parsed["unset"].should be_a(JSON::Any)

      set_array = parsed["set"].as_a
      set_array.any? { |e| e["path"] == ["age"] && e["value"] == 31 }.should be_true
      set_array.any? { |e| e["path"] == ["city"] && e["value"] == "Paris" }.should be_true
      parsed["unset"].as_a.should be_empty
    end

    it "returns empty result for empty objects" do
      old = JSON.parse(%({}))
      new = JSON.parse(%({}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.should be_empty
    end

    it "detects type changes (string -> object)" do
      old = JSON.parse(%({"a": "string"}))
      new = JSON.parse(%({"a": {"b": 1}}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["a"]
      entry.value.should eq JSON.parse(%({"b": 1}))
    end

    it "detects deep nested changes" do
      old = JSON.parse(%({"level1": {"level2": {"level3": "old"}}}))
      new = JSON.parse(%({"level1": {"level2": {"level3": "new"}}}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.set.size.should eq 1

      entry = result.set.first
      entry.path.should eq ["level1", "level2", "level3"]
      entry.value.should eq "new"
    end

    it "detects deep nested removal" do
      old = JSON.parse(%({"level1": {"level2": {"a": 1, "b": 2}}}))
      new = JSON.parse(%({"level1": {"level2": {"a": 1}}}))

      result = Facet::Mutation::JsonDiff.diff(old, new)
      result.unset.should contain ["level1", "level2", "b"]
    end
  end
end
