# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"
require "../../../src/assistant/tools"

# Step 3.2 of the workspace-assistant plan: a registry tool schema
# (`AgentTools::Registry::Entry#input_schema`) converts into the
# `parameters:` shape `Agent#register_tool` accepts, so tool metadata
# stays defined once, in the registry.
describe "Facet::Assistant::Tools.schema_parameters" do
  it "converts a schema with properties and required into the parameters shape" do
    schema = JSON.parse(%({
      "type": "object",
      "properties": {
        "domain":    {"type": "string"},
        "aggregate": {"type": "string", "enum": ["count", "sum"]},
        "filters":   {"type": "object", "description": "Filter keys"}
      },
      "required": ["domain", "aggregate"]
    }))

    params = Facet::Assistant::Tools.schema_parameters(schema)

    params.should be_a(Hash(String, JSON::Any))
    params["type"].as_s.should eq("object")
    props = params["properties"].as_h
    props["domain"].as_h["type"].as_s.should eq("string")
    props["aggregate"].as_h["enum"].as_a.map(&.as_s).should eq(["count", "sum"])
    props["filters"].as_h["description"].as_s.should eq("Filter keys")
    params["required"].as_a.map(&.as_s).should eq(["domain", "aggregate"])
  end

  it "rejects a non-object schema" do
    expect_raises(ArgumentError) do
      Facet::Assistant::Tools.schema_parameters(JSON.parse("[]"))
    end
  end
end

describe "Facet::Assistant::Tools.schema_object" do
  it "builds the parameters shape from flat string properties" do
    params = Facet::Assistant::Tools.schema_object(
      properties: {"domain" => {"type" => "string", "description" => "Domain of the target"}},
      required: ["domain"],
    )

    params["type"].as_s.should eq("object")
    props = params["properties"].as_h
    props["domain"].as_h["type"].as_s.should eq("string")
    props["domain"].as_h["description"].as_s.should eq("Domain of the target")
    params["required"].as_a.map(&.as_s).should eq(["domain"])
  end

  it "preserves a nested items schema and scalar constraints on an array property" do
    params = Facet::Assistant::Tools.schema_object(
      properties: {"ids" => {"type" => "array", "items" => {"type" => "string"}, "minItems" => 1}},
      required: ["ids"],
    )

    ids = params["properties"].as_h["ids"].as_h
    ids["type"].as_s.should eq("array")
    ids["items"].as_h["type"].as_s.should eq("string")
    ids["minItems"].as_i.should eq(1)
  end
end
