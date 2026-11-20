# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

# Normalize-on-write storage contract, end to end through
# `Document::Create`: a value submitted in an accepted input form lands in
# the projection content in its canonical stored form, and unparseable
# input stays a field-level 422 with no partial write.
#
# - B-103 — a `color` field stores the canonical `#RRGGBBAA` string.
# - B-104 — a `reference` field accepts the facet URN form and stores the
#   dotted qualified id, so the value resolves like the equivalent
#   qualified form (existence check passes).

private def create_norm_doctype(db, domain, doctype, fields) : Nil
  ensure_domain(db, domain)
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
    .should be_a(Facet::Document::Create::Result)
end

private def create_norm_doc(db, domain, doctype, content)
  Facet::Document::Create.call(db, domain, doctype, content, Facet::RBAC::AuthContext.system)
end

describe "normalize-on-write storage contract" do
  describe "color fields (B-103)" do
    it "stores each accepted input form as #RRGGBBAA" do
      with_temp_doctype("normcolor", "Swatch") do |db, domain, dt|
        create_norm_doctype(db, domain, dt, %({"accent": {"type": "color"}}))

        cases = {
          "#f00"                 => "#ff0000ff",
          "#abc"                 => "#aabbccff",
          "#11223344"            => "#11223344",
          "rgb(255, 0, 0)"       => "#ff0000ff",
          "rgba(255, 0, 0, 0.5)" => "#ff000080",
          "hsl(300, 100%, 50%)"  => "#ff00ffff",
        }

        cases.each do |input, stored|
          result = create_norm_doc(db, domain, dt, %({"accent": "#{input}"}))
          created = result.as(Facet::Document::Create::Result)
          created.projection.content["accent"].as_s.should eq(stored)
        end
      end
    end

    it "rejects unparseable input with a field-level 422" do
      with_temp_doctype("normcolor", "Swatch") do |db, domain, dt|
        create_norm_doctype(db, domain, dt, %({"accent": {"type": "color"}}))

        result = create_norm_doc(db, domain, dt, %({"accent": "not-a-color"}))
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.details.not_nil!.first.code.should eq("invalid_format")
      end
    end
  end

  describe "reference URN values (B-104)" do
    it "accepts a URN and stores the dotted qualified form that resolves" do
      with_temp_doctype("normref", "Task") do |db, domain, dt|
        create_norm_doctype(db, domain, "Company",
          %({"status": {"type": "enum", "values": [{"key": "active"}, {"key": "inactive"}]}}))
        company = create_norm_doc(db, domain, "Company", %({"status": "active"}))
        company_id = company.as(Facet::Document::Create::Result).projection.id

        create_norm_doctype(db, domain, dt,
          %({"company": {"type": "reference", "doctype": "#{domain}.Company"}}))
        result = create_norm_doc(db, domain, dt,
          %({"company": "urn:facet:#{domain}:Company:#{company_id}"}))

        created = result.as(Facet::Document::Create::Result)
        created.projection.content["company"].as_s.should eq("#{domain}.Company.#{company_id}")
      end
    end

    it "rejects a malformed URN with a clear 422" do
      with_temp_doctype("normref", "Task") do |db, domain, dt|
        create_norm_doctype(db, domain, "Company",
          %({"status": {"type": "enum", "values": [{"key": "active"}, {"key": "inactive"}]}}))
        create_norm_doctype(db, domain, dt,
          %({"company": {"type": "reference", "doctype": "#{domain}.Company"}}))

        result = create_norm_doc(db, domain, dt, %({"company": "urn:facet:#{domain}:Company"}))
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.details.not_nil!.first.message.should contain("well-formed facet document URN")
      end
    end

    it "rejects a state-pinned URN with a clear 422" do
      with_temp_doctype("normref", "Task") do |db, domain, dt|
        create_norm_doctype(db, domain, "Company",
          %({"status": {"type": "enum", "values": [{"key": "active"}, {"key": "inactive"}]}}))
        create_norm_doctype(db, domain, dt,
          %({"company": {"type": "reference", "doctype": "#{domain}.Company"}}))

        result = create_norm_doc(db, domain, dt,
          %({"company": "urn:facet:#{domain}:Company:01ABC?state=01XYZ"}))
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.details.not_nil!.first.message.should contain("state-pinned")
      end
    end
  end
end
