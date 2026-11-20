# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/nested_path_resolver"

describe Facet::HTTP::NestedPathResolver do
  describe ".resolve" do
    it "returns Error for empty rest segments" do
      with_db do |db|
        result = Facet::HTTP::NestedPathResolver.resolve(
          db, "hr", "Employee", "e1", [] of String
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(400)
      end
    end
  end

  describe "structs" do
    it "ResolvedTarget holds domain, doc_type, and optional doc_id" do
      target = Facet::HTTP::NestedPathResolver::ResolvedTarget.new("hr", "CareerEvent", "ce1")
      target.domain.should eq("hr")
      target.doc_type.should eq("CareerEvent")
      target.doc_id.should eq("ce1")
    end

    it "ResolvedTarget doc_id can be nil" do
      target = Facet::HTTP::NestedPathResolver::ResolvedTarget.new("hr", "CareerEvent")
      target.domain.should eq("hr")
      target.doc_type.should eq("CareerEvent")
      target.doc_id.should be_nil
    end

    it "Resolved has list/get modes" do
      target = Facet::HTTP::NestedPathResolver::ResolvedTarget.new("hr", "CareerEvent")
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Employee", domain: "hr"
      )
      resolved = Facet::HTTP::NestedPathResolver::Resolved.new(
        target, defn, "e1", Facet::HTTP::NestedPathResolver::Resolved::Mode::List
      )
      resolved.mode.should eq(Facet::HTTP::NestedPathResolver::Resolved::Mode::List)
      resolved.parent_id.should eq("e1")
      resolved.target.doc_type.should eq("CareerEvent")
    end

    it "Error record holds status and message" do
      err = Facet::ServiceError.new(404, "Not found")
      err.status.should eq(404)
      err.message.should eq("Not found")
    end
  end
end
