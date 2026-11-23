# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/settings"

describe Facet::Settings::Keys do
  describe ".descriptor?" do
    it "returns the descriptor for a registered key" do
      d = Facet::Settings::Keys.descriptor?("core", "timezone")
      d.should_not be_nil
      d.not_nil!.kind.should eq(Facet::Settings::Keys::Kind::String)
      d.not_nil!.default.as_s.should eq("auto")
    end

    it "returns nil for an unknown key" do
      Facet::Settings::Keys.descriptor?("core", "nonexistent").should be_nil
    end

    it "returns nil for an unknown app" do
      Facet::Settings::Keys.descriptor?("other_app", "timezone").should be_nil
    end

    it "returns the core.show_welcome descriptor with a bool kind and a true default" do
      d = Facet::Settings::Keys.descriptor?("core", "show_welcome")
      d.should_not be_nil
      d.not_nil!.kind.should eq(Facet::Settings::Keys::Kind::Bool)
      d.not_nil!.default.as_bool.should be_true
    end

    it "returns the notifications.in_app descriptor with a bool kind and a true default" do
      d = Facet::Settings::Keys.descriptor?("notifications", "in_app")
      d.should_not be_nil
      d.not_nil!.kind.should eq(Facet::Settings::Keys::Kind::Bool)
      d.not_nil!.default.as_bool.should be_true
    end
  end

  describe ".for_app" do
    it "lists descriptors for the core app" do
      descriptors = Facet::Settings::Keys.for_app("core")
      keys = descriptors.map(&.key).sort!
      keys.should eq(["language", "pinned_collection_views", "pinned_doctypes", "show_welcome", "timezone"])
    end

    it "returns an empty array for an unknown app" do
      Facet::Settings::Keys.for_app("other_app").should be_empty
    end

    it "lists the in_app descriptor for the notifications app" do
      descriptors = Facet::Settings::Keys.for_app("notifications")
      descriptors.map(&.key).should eq(["in_app"])
    end
  end

  describe ".validate" do
    it "accepts a valid timezone" do
      error = Facet::Settings::Keys.validate("core", "timezone", JSON::Any.new("UTC"))
      error.should be_nil
    end

    it "accepts a real IANA timezone name" do
      error = Facet::Settings::Keys.validate("core", "timezone", JSON::Any.new("Europe/Paris"))
      error.should be_nil
    end

    it "accepts the auto sentinel (follow the browser)" do
      error = Facet::Settings::Keys.validate("core", "timezone", JSON::Any.new("auto"))
      error.should be_nil
    end

    it "rejects an invalid timezone name" do
      error = Facet::Settings::Keys.validate("core", "timezone", JSON::Any.new("Bogus/Nowhere"))
      error.should_not be_nil
      error.not_nil!.should contain("Invalid timezone")
    end

    it "rejects a non-string timezone" do
      error = Facet::Settings::Keys.validate("core", "timezone", JSON::Any.new(42))
      error.should_not be_nil
      error.not_nil!.should contain("must be a string")
    end

    it "accepts the allowed language 'en'" do
      error = Facet::Settings::Keys.validate("core", "language", JSON::Any.new("en"))
      error.should be_nil
    end

    it "accepts the allowed language 'fr'" do
      error = Facet::Settings::Keys.validate("core", "language", JSON::Any.new("fr"))
      error.should be_nil
    end

    it "rejects an unsupported language" do
      error = Facet::Settings::Keys.validate("core", "language", JSON::Any.new("de"))
      error.should_not be_nil
      error.not_nil!.should contain("Unsupported language")
    end

    it "rejects an unregistered key" do
      error = Facet::Settings::Keys.validate("core", "nonexistent", JSON::Any.new("value"))
      error.should_not be_nil
      error.not_nil!.should contain("Unknown setting")
    end

    it "accepts a boolean in_app value" do
      Facet::Settings::Keys.validate("notifications", "in_app", JSON::Any.new(true)).should be_nil
      Facet::Settings::Keys.validate("notifications", "in_app", JSON::Any.new(false)).should be_nil
    end

    it "rejects a non-boolean in_app value" do
      error = Facet::Settings::Keys.validate("notifications", "in_app", JSON::Any.new("yes"))
      error.should_not be_nil
      error.not_nil!.should contain("must be a boolean")
    end

    it "accepts boolean show_welcome values" do
      Facet::Settings::Keys.validate("core", "show_welcome", JSON::Any.new(true)).should be_nil
      Facet::Settings::Keys.validate("core", "show_welcome", JSON::Any.new(false)).should be_nil
    end

    it "rejects a non-boolean show_welcome value" do
      error = Facet::Settings::Keys.validate("core", "show_welcome", JSON::Any.new("yes"))
      error.should_not be_nil
      error.not_nil!.should contain("must be a boolean")
    end

    it "rejects an unregistered key in the notifications app" do
      error = Facet::Settings::Keys.validate("notifications", "digest", JSON::Any.new(true))
      error.should_not be_nil
      error.not_nil!.should contain("Unknown setting")
    end

    it "accepts an empty pinned_doctypes array" do
      error = Facet::Settings::Keys.validate("core", "pinned_doctypes", JSON::Any.new([] of JSON::Any))
      error.should be_nil
    end

    it "accepts a list of qualified doctype names" do
      value = JSON::Any.new([JSON::Any.new("crm.Company"), JSON::Any.new("hr.Employee")])
      error = Facet::Settings::Keys.validate("core", "pinned_doctypes", value)
      error.should be_nil
    end

    it "rejects a non-array pinned_doctypes" do
      error = Facet::Settings::Keys.validate("core", "pinned_doctypes", JSON::Any.new("crm.Company"))
      error.should_not be_nil
      error.not_nil!.should contain("must be an array")
    end

    it "rejects a non-string element in pinned_doctypes" do
      value = JSON::Any.new([JSON::Any.new("crm.Company"), JSON::Any.new(42)])
      error = Facet::Settings::Keys.validate("core", "pinned_doctypes", value)
      error.should_not be_nil
      error.not_nil!.should contain("only contain strings")
    end

    it "rejects a malformed doctype name in pinned_doctypes" do
      value = JSON::Any.new([JSON::Any.new("no-dot-name")])
      error = Facet::Settings::Keys.validate("core", "pinned_doctypes", value)
      error.should_not be_nil
      error.not_nil!.should contain("Invalid doctype name")
    end

    it "accepts an empty pinned_collection_views array" do
      error = Facet::Settings::Keys.validate("core", "pinned_collection_views", JSON::Any.new([] of JSON::Any))
      error.should be_nil
    end

    it "accepts a list of view ids" do
      value = JSON::Any.new([JSON::Any.new("01J0ABC123DEF456"), JSON::Any.new("01J0XYZ789")])
      error = Facet::Settings::Keys.validate("core", "pinned_collection_views", value)
      error.should be_nil
    end

    it "rejects a non-array pinned_collection_views" do
      error = Facet::Settings::Keys.validate("core", "pinned_collection_views", JSON::Any.new("01J0ABC"))
      error.should_not be_nil
      error.not_nil!.should contain("must be an array")
    end

    it "rejects a non-string element in pinned_collection_views" do
      value = JSON::Any.new([JSON::Any.new("01J0ABC"), JSON::Any.new(42)])
      error = Facet::Settings::Keys.validate("core", "pinned_collection_views", value)
      error.should_not be_nil
      error.not_nil!.should contain("only contain strings")
    end

    it "rejects an empty string element in pinned_collection_views" do
      value = JSON::Any.new([JSON::Any.new("")])
      error = Facet::Settings::Keys.validate("core", "pinned_collection_views", value)
      error.should_not be_nil
      error.not_nil!.should contain("must not contain empty strings")
    end
  end
end
