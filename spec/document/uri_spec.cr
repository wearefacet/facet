# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

describe Facet::Document::DocURI do
  # ── Construction & to_s ────────────────────────────────────────────────

  it "renders the canonical URN form" do
    uri = Facet::Document::DocURI.build("hr", "Employee", "01J5X2ABC")
    uri.to_s.should eq("urn:facet:hr:Employee:01J5X2ABC")
  end

  it "includes the state q-component when set" do
    uri = Facet::Document::DocURI.build("hr", "Employee", "01J5X2ABC", state: "01J5Y9ZZ")
    uri.to_s.should eq("urn:facet:hr:Employee:01J5X2ABC?state=01J5Y9ZZ")
  end

  it "preserves qualified opaque ids (core.DocType special case)" do
    uri = Facet::Document::DocURI.build("core", "DocType", "hr.Employee")
    uri.to_s.should eq("urn:facet:core:DocType:hr.Employee")
  end

  # ── Parse ─────────────────────────────────────────────────────────────

  it "parses canonical URN form" do
    uri = Facet::Document::DocURI.parse("urn:facet:hr:Employee:01J5X2ABC")
    uri.should_not be_nil
    u = uri.not_nil!
    u.domain.should eq("hr")
    u.doctype.should eq("Employee")
    u.opaque.should eq("01J5X2ABC")
    u.state.should be_nil
  end

  it "parses URN with state" do
    uri = Facet::Document::DocURI.parse("urn:facet:hr:Employee:01J5X2ABC?state=01J5Y9ZZ")
    uri.should_not be_nil
    u = uri.not_nil!
    u.state.should eq("01J5Y9ZZ")
  end

  it "parses legacy dotted three-segment form" do
    uri = Facet::Document::DocURI.parse("hr.Employee.01J5X2ABC")
    uri.should_not be_nil
    u = uri.not_nil!
    u.domain.should eq("hr")
    u.doctype.should eq("Employee")
    u.opaque.should eq("01J5X2ABC")
  end

  it "parses legacy two-segment form (core.DocType / core.Domain)" do
    uri = Facet::Document::DocURI.parse("hr.Employee")
    uri.should_not be_nil
    u = uri.not_nil!
    u.domain.should eq("hr")
    u.doctype.should eq("Employee")
    u.opaque.should eq("hr.Employee")
  end

  it "round-trips through parse and to_s" do
    original = "urn:facet:core:Domain:hr"
    uri = Facet::Document::DocURI.parse(original).not_nil!
    uri.to_s.should eq(original)
  end

  # ── from_projection_id / to_projection_id ─────────────────────────────

  it "derives URN from a bare-ULID projection id" do
    uri = Facet::Document::DocURI.from_projection_id("hr", "Employee", "01J5X2ABC")
    uri.to_s.should eq("urn:facet:hr:Employee:01J5X2ABC")
    uri.to_projection_id.should eq("01J5X2ABC")
  end

  it "derives URN from a legacy three-segment projection id" do
    uri = Facet::Document::DocURI.from_projection_id("hr", "Employee", "hr.Employee.01J5X2ABC")
    uri.to_s.should eq("urn:facet:hr:Employee:01J5X2ABC")
    uri.to_projection_id.should eq("01J5X2ABC")
  end

  it "derives URN from a qualified projection id (core.DocType)" do
    uri = Facet::Document::DocURI.from_projection_id("core", "DocType", "hr.Employee")
    uri.to_s.should eq("urn:facet:core:DocType:hr.Employee")
    uri.to_projection_id.should eq("hr.Employee")
  end

  it "derives URN from a bare-domain projection id (core.Domain)" do
    uri = Facet::Document::DocURI.from_projection_id("core", "Domain", "hr")
    uri.to_s.should eq("urn:facet:core:Domain:hr")
    uri.to_projection_id.should eq("hr")
  end

  # ── Validation ────────────────────────────────────────────────────────

  it "rejects invalid domain names" do
    u = Facet::Document::DocURI.build("HR", "Employee", "abc")
    u.valid?.should be_false
    Facet::Document::DocURI.parse("urn:facet:HR:Employee:abc").should be_nil
  end

  it "rejects invalid doctype names" do
    u = Facet::Document::DocURI.build("hr", "employee", "abc")
    u.valid?.should be_false
    Facet::Document::DocURI.parse("urn:facet:hr:employee:abc").should be_nil
  end

  it "rejects malformed URN input" do
    Facet::Document::DocURI.parse("").should be_nil
    Facet::Document::DocURI.parse("urn:facet:hr").should be_nil                     # too few segments
    Facet::Document::DocURI.parse("urn:other:hr:Employee:abc").should be_nil        # wrong NID
    Facet::Document::DocURI.parse("urn:facet:hr:Employee:").should be_nil           # empty opaque
    Facet::Document::DocURI.parse("urn:facet:hr:Employee:abc?foo=1").should be_nil  # bad q-component
    Facet::Document::DocURI.parse("urn:facet:hr:Employee:abc?state=").should be_nil # empty state
  end

  it "accepts draft-domain names (leading underscore)" do
    u = Facet::Document::DocURI.build("_draft", "Employee", "abc")
    u.valid?.should be_true
    u.to_s.should eq("urn:facet:_draft:Employee:abc")
  end
end
