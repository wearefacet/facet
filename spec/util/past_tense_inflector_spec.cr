# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/util/past_tense_inflector"

# Helper to define multiple (input → expected) examples for a given inflector.
private def assert_past(inflector : Facet::Util::PastTenseInflector, cases : Hash(String, String))
  cases.each do |input, expected|
    it "inflects #{input.inspect} to #{expected.inspect}" do
      inflector.inflect_past(input).should eq(expected)
    end
  end
end

describe Facet::Util::PastTenseInflector do
  # ---------------------------------------------------------------------------
  # #inflect_past
  # ---------------------------------------------------------------------------

  describe "#inflect_past" do
    context "with regular verbs" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "work"   => "worked",
        "create" => "created",
        "update" => "updated",
      })
    end

    context "with verbs ending in 'e'" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "free"  => "freed",
        "agree" => "agreed",
        "die"   => "died",
        "tie"   => "tied",
      })
    end

    context "with verbs ending in consonant + 'y'" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "try"   => "tried",
        "apply" => "applied",
        "copy"  => "copied",
        "deny"  => "denied",
      })
    end

    context "with verbs ending in vowel + 'y'" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "play"   => "played",
        "stay"   => "stayed",
        "obey"   => "obeyed",
        "convey" => "conveyed",
        "enjoy"  => "enjoyed",
        "survey" => "surveyed",
        "delay"  => "delayed",
      })
    end

    context "with verbs ending in 'c'" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "picnic" => "picnicked",
        "panic"  => "panicked",
        "mimic"  => "mimicked",
      })
    end

    context "with monosyllabic CVC verbs (final consonant doubling)" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "stop" => "stopped",
        "plan" => "planned",
        "grab" => "grabbed",
        "nod"  => "nodded",
        "stir" => "stirred",
        "rub"  => "rubbed",
        "tag"  => "tagged",
        "trim" => "trimmed",
        "drop" => "dropped",
        "scan" => "scanned",
        "ship" => "shipped",
        "log"  => "logged",
      })
    end

    context "with verbs ending in 'w', 'x' or 'y' (never doubled)" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "snow" => "snowed",
        "fix"  => "fixed",
        "flow" => "flowed",
        "tax"  => "taxed",
      })
    end

    context "with polysyllabic verbs, unstressed final syllable (no doubling)" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "visit"   => "visited",
        "open"    => "opened",
        "offer"   => "offered",
        "benefit" => "benefited",
        "target"  => "targeted",
        "edit"    => "edited",
        "listen"  => "listened",
        "happen"  => "happened",
        "order"   => "ordered",
        "limit"   => "limited",
        "audit"   => "audited",
        "exit"    => "exited",
      })
    end

    context "with polysyllabic verbs, stressed final syllable (doubling)" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "occur"    => "occurred",
        "prefer"   => "preferred",
        "admit"    => "admitted",
        "commit"   => "committed",
        "submit"   => "submitted",
        "transfer" => "transferred",
        "regret"   => "regretted",
        "permit"   => "permitted",
        "control"  => "controlled",
        "equip"    => "equipped",
      })
    end

    context "with irregular verbs" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "be"    => "been",
        "get"   => "gotten",
        "write" => "written",
        "seek"  => "sought",
        "split" => "split",
        "flee"  => "fled",
        "weep"  => "wept",
        "spit"  => "spat",
        "take"  => "taken",
        "go"    => "gone",
      })
    end

    context "with prefixed irregular verbs" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "rebuild"  => "rebuilt",
        "rewrite"  => "rewritten",
        "undergo"  => "undergone",
        "overtake" => "overtaken",
        "mislead"  => "misled",
        "foresee"  => "foreseen",
        "undo"     => "undone",
        "withhold" => "withheld",
      })
    end

    context "with compound verb_object inputs (event naming)" do
      assert_past(Facet::Util::PastTenseInflector.new, {
        "create_object" => "object_created",
        "delete_user"   => "user_deleted",
        "submit_form"   => "form_submitted",
      })
    end

    context "with non-letter characters" do
      it "normalizes separators to underscores" do
        inflector = Facet::Util::PastTenseInflector.new
        inflector.inflect_past("create-object").should eq("object_created")
      end
    end

    context "with custom verb exceptions" do
      it "uses the custom exception table" do
        custom = Facet::Util::PastTenseInflector.new(
          verb_exceptions: {"ping" => "pinged!"}
        )
        custom.inflect_past("ping").should eq("pinged!")
      end

      it "falls back to rules for verbs not in the custom table" do
        custom = Facet::Util::PastTenseInflector.new(
          verb_exceptions: {"ping" => "pinged!"}
        )
        custom.inflect_past("stop").should eq("stopped")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #pluralize
  # ---------------------------------------------------------------------------

  describe "#pluralize" do
    it "handles exceptions" do
      inflector = Facet::Util::PastTenseInflector.new
      inflector.pluralize("child").should eq("children")
      inflector.pluralize("person").should eq("people")
    end

    it "handles regular words" do
      inflector = Facet::Util::PastTenseInflector.new
      inflector.pluralize("user").should eq("users")
      inflector.pluralize("city").should eq("cities")
      inflector.pluralize("stay").should eq("stays")
    end

    it "returns the word unchanged when count <= 1" do
      inflector = Facet::Util::PastTenseInflector.new
      inflector.pluralize("user", 1).should eq("user")
    end
  end

  # ---------------------------------------------------------------------------
  # #singularize
  # ---------------------------------------------------------------------------

  describe "#singularize" do
    it "handles exceptions" do
      inflector = Facet::Util::PastTenseInflector.new
      inflector.singularize("children").should eq("child")
      inflector.singularize("people").should eq("person")
    end

    it "handles regular words" do
      inflector = Facet::Util::PastTenseInflector.new
      inflector.singularize("users").should eq("user")
      inflector.singularize("cities").should eq("city")
    end
  end
end
