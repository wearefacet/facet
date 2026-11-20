# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/util/mime_matcher"

# Tests for Facet::Util::MimeMatcher.
#
# Pure-logic coverage of MIME pattern validation and matching used by
# the `file` field's `accept` constraint. The DB-backed gate is exercised
# in `spec/document/file_mime_check_spec.cr`.
describe Facet::Util::MimeMatcher do
  describe ".valid_pattern?" do
    it "accepts a concrete type/subtype" do
      Facet::Util::MimeMatcher.valid_pattern?("application/pdf").should be_true
      Facet::Util::MimeMatcher.valid_pattern?("image/png").should be_true
    end

    it "accepts a wildcard subtype" do
      Facet::Util::MimeMatcher.valid_pattern?("image/*").should be_true
      Facet::Util::MimeMatcher.valid_pattern?("application/*").should be_true
    end

    it "rejects a wildcard type" do
      # `*/vnd.something` is intentionally not supported — omit `accept`
      # to allow any MIME. The implicit semantic is the same and avoids a
      # confusing synonym.
      Facet::Util::MimeMatcher.valid_pattern?("*/vnd.ms-excel").should be_false
    end

    it "rejects malformed patterns" do
      Facet::Util::MimeMatcher.valid_pattern?("image").should be_false
      Facet::Util::MimeMatcher.valid_pattern?("image/").should be_false
      Facet::Util::MimeMatcher.valid_pattern?("/png").should be_false
      Facet::Util::MimeMatcher.valid_pattern?("*").should be_false
      Facet::Util::MimeMatcher.valid_pattern?("").should be_false
    end
  end

  describe ".matches?" do
    it "matches a concrete pattern exactly" do
      Facet::Util::MimeMatcher.matches?("application/pdf", ["application/pdf"]).should be_true
      Facet::Util::MimeMatcher.matches?("image/png", ["application/pdf"]).should be_false
    end

    it "matches a wildcard subtype" do
      Facet::Util::MimeMatcher.matches?("image/png", ["image/*"]).should be_true
      Facet::Util::MimeMatcher.matches?("image/jpeg", ["image/*"]).should be_true
      Facet::Util::MimeMatcher.matches?("application/pdf", ["image/*"]).should be_false
    end

    it "matches any of several patterns" do
      patterns = ["image/*", "application/pdf"]
      Facet::Util::MimeMatcher.matches?("image/png", patterns).should be_true
      Facet::Util::MimeMatcher.matches?("application/pdf", patterns).should be_true
      Facet::Util::MimeMatcher.matches?("application/json", patterns).should be_false
    end

    it "does not match across the type boundary" do
      # Wildcard on subtype never widens to a different type — `image/*`
      # must not match `imagepng` or a stripped `png`.
      Facet::Util::MimeMatcher.matches?("imagepng", ["image/*"]).should be_false
      Facet::Util::MimeMatcher.matches?("png", ["image/*"]).should be_false
    end
  end
end
