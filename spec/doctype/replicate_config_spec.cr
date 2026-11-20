# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/doctype/replicate_config"

module Facet::Doctype
  describe ReplicateConfig do
    describe "from_json" do
      it "parses a valid replicate config" do
        json = %({"via": "employee_id", "field": "full_name"})
        config = ReplicateConfig.from_json(JSON.parse(json))
        config.via.should eq("employee_id")
        config.field.should eq("full_name")
      end

      it "raises on missing 'via' field" do
        json = %({"field": "full_name"})
        expect_raises(JSON::ParseException, /via/) do
          ReplicateConfig.from_json(JSON.parse(json))
        end
      end

      it "raises on missing 'field' field" do
        json = %({"via": "employee_id"})
        expect_raises(JSON::ParseException, /field/) do
          ReplicateConfig.from_json(JSON.parse(json))
        end
      end

      it "raises on empty object" do
        json = %({})
        expect_raises(JSON::ParseException, /via/) do
          ReplicateConfig.from_json(JSON.parse(json))
        end
      end
    end

    describe "from_yaml" do
      it "parses a valid replicate config from YAML" do
        yaml = "via: employee_id\nfield: full_name\n"
        config = ReplicateConfig.from_yaml(yaml)
        config.via.should eq("employee_id")
        config.field.should eq("full_name")
      end
    end

    describe "to_json" do
      it "serialises to the expected JSON shape" do
        config = ReplicateConfig.new(via: "employee_id", field: "full_name")
        json = config.to_json
        parsed = JSON.parse(json)
        parsed["via"].should eq("employee_id")
        parsed["field"].should eq("full_name")
      end

      it "round-trips via JSON" do
        original = ReplicateConfig.new(via: "person", field: "email")
        json = original.to_json
        parsed = ReplicateConfig.from_json(JSON.parse(json))
        parsed.via.should eq(original.via)
        parsed.field.should eq(original.field)
      end
    end
  end
end
