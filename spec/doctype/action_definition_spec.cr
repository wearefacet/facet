# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/doctype"

module Facet::Doctype
  describe ActionDefinition do
    # ── Parsing ──────────────────────────────────────────────────────

    it "parses a minimal action definition" do
      json = %({
        "args": {}
      })
      action = ActionDefinition.from_json(json)
      action.args.should be_empty
    end

    it "parses an action with typed args" do
      json = %({
        "args": {
          "comment": { "type": "string", "required": true },
          "started_at": { "type": "datetime", "required": true }
        }
      })
      action = ActionDefinition.from_json(json)
      action.args.size.should eq(2)
      action.args["comment"].type.type_name.should eq("string")
      action.args["comment"].required.should be_true
      action.args["started_at"].type.type_name.should eq("datetime")
      action.args["started_at"].required.should be_true
    end

    it "parses an action with enum arg" do
      json = %({
        "args": {
          "status": { "type": "enum", "values": ["success", "failure"], "required": true },
          "notes":  { "type": "string" }
        }
      })
      action = ActionDefinition.from_json(json)
      arg = action.args["status"]
      arg.type.type_name.should eq("enum")
      arg.values.should eq(["success", "failure"])
      arg.required.should be_true
    end

    it "parses an action with integer constraint" do
      json = %({
        "args": {
          "quantity": { "type": "integer", "min": 1, "max": 100 }
        }
      })
      action = ActionDefinition.from_json(json)
      arg = action.args["quantity"]
      arg.type.type_name.should eq("integer")
      arg.min.should eq(1_i64)
      arg.max.should eq(100_i64)
    end

    it "parses an action with reference arg" do
      json = %({
        "args": {
          "assignee": { "type": "reference", "doctype": "hr.Employee" }
        }
      })
      action = ActionDefinition.from_json(json)
      arg = action.args["assignee"]
      arg.type.type_name.should eq("reference")
      arg.doctype.should eq("hr.Employee")
    end

    it "parses an action with collection arg" do
      json = %({
        "args": {
          "items": { "type": "string", "collection": true }
        }
      })
      action = ActionDefinition.from_json(json)
      arg = action.args["items"]
      arg.type.type_name.should eq("string")
      arg.collection.should be_true
    end

    it "parses an action with default values" do
      json = %({
        "args": {
          "priority": { "type": "string", "default": "normal" }
        }
      })
      action = ActionDefinition.from_json(json)
      arg = action.args["priority"]
      arg.type.type_name.should eq("string")
      arg.default.should eq(JSON::Any.new("normal"))
    end

    # ── Script validation ────────────────────────────────────────────

    it "rejects args with missing type" do
      json = %({
        "args": {
          "comment": { "required": true }
        }
      })
      expect_raises(JSON::ParseException, /Missing required field 'type'/) do
        ActionDefinition.from_json(json)
      end
    end

    # ── State gate ───────────────────────────────────────────────────

    it "parses an action with a state gate" do
      json = %({
        "args": {},
        "states": { "status": ["submitted", "pending"] }
      })
      action = ActionDefinition.from_json(json)
      action.states.should eq({"status" => ["submitted", "pending"]})
    end

    it "parses an action with a multi-field state gate" do
      json = %({
        "args": {},
        "states": { "status": ["open"], "locked": ["no"] }
      })
      action = ActionDefinition.from_json(json)
      action.states.not_nil!.size.should eq(2)
    end

    it "rejects a state gate that is not an object" do
      json = %({
        "args": {},
        "states": ["open"]
      })
      expect_raises(JSON::ParseException, /states must be an object keyed by field name/) do
        ActionDefinition.from_json(json)
      end
    end

    it "rejects an empty state gate" do
      json = %({
        "args": {},
        "states": {}
      })
      expect_raises(JSON::ParseException, /must name at least one field/) do
        ActionDefinition.from_json(json)
      end
    end

    it "rejects a state gate value that is not an array" do
      json = %({
        "args": {},
        "states": { "status": "open" }
      })
      expect_raises(JSON::ParseException, /states.status must be an array of strings/) do
        ActionDefinition.from_json(json)
      end
    end

    it "rejects a state gate with an empty values array" do
      json = %({
        "args": {},
        "states": { "status": [] }
      })
      expect_raises(JSON::ParseException, /must list at least one value/) do
        ActionDefinition.from_json(json)
      end
    end

    it "rejects a state gate with a non-string value" do
      json = %({
        "args": {},
        "states": { "status": ["open", 3] }
      })
      expect_raises(JSON::ParseException, /must contain only non-empty strings/) do
        ActionDefinition.from_json(json)
      end
    end

    it "rejects an unknown key next to states" do
      json = %({
        "args": {},
        "states": { "status": ["open"] },
        "visible_when": "status == open"
      })
      expect_raises(JSON::ParseException, /unknown key/i) do
        ActionDefinition.from_json(json)
      end
    end

    it "answers state_allowed? true without a gate" do
      action = ActionDefinition.new
      action.state_allowed?(JSON.parse(%({"status": "closed"}))).should be_true
    end

    it "answers state_allowed? on the gate" do
      action = ActionDefinition.from_json(%({"states": { "status": ["submitted", "pending"] }}))
      action.state_allowed?(JSON.parse(%({"status": "submitted"}))).should be_true
      action.state_allowed?(JSON.parse(%({"status": "closed"}))).should be_false
      action.state_allowed?(JSON.parse(%({}))).should be_false
      action.state_allowed?(JSON.parse(%({"status": 3}))).should be_false
    end

    it "requires every gated field to match" do
      action = ActionDefinition.from_json(%({"states": { "status": ["open"], "locked": ["no"] }}))
      action.state_allowed?(JSON.parse(%({"status": "open", "locked": "no"}))).should be_true
      action.state_allowed?(JSON.parse(%({"status": "open", "locked": "yes"}))).should be_false
      action.state_allowed?(JSON.parse(%({"status": "open"}))).should be_false
    end

    # ── JSON round-trip ──────────────────────────────────────────────

    it "round-trips through JSON" do
      original = ActionDefinition.new(
        args: {
          "comment" => ActionArgDefinition.new(type: FieldType.parse("string"), required: true),
        }
      )
      json = original.to_json
      parsed = ActionDefinition.from_json(json)
      parsed.args.size.should eq(original.args.size)
      parsed.args["comment"].type.should eq(original.args["comment"].type)
      parsed.args["comment"].required.should eq(original.args["comment"].required)
      parsed.event_name.should be_nil
    end

    # ── Event name ────────────────────────────────────────────────────

    it "parses an action with an explicit snake_case event_name" do
      json = %({
        "args": {},
        "event_name": "document_submitted_for_review"
      })
      action = ActionDefinition.from_json(json)
      action.event_name.should eq("document_submitted_for_review")
    end

    it "rejects event_name that is not snake_case" do
      json = %({
        "args": {},
        "event_name": "DocumentSubmittedForReview"
      })
      expect_raises(JSON::ParseException, /snake_case/) do
        ActionDefinition.from_json(json)
      end
    end

    it "rejects event_name with hyphens" do
      json = %({
        "args": {},
        "event_name": "document-submitted"
      })
      expect_raises(JSON::ParseException, /snake_case/) do
        ActionDefinition.from_json(json)
      end
    end

    it "resolves event_name to the explicit value when set" do
      action = ActionDefinition.new(event_name: "document_submitted")
      action.resolved_event_name("approve").should eq("document_submitted")
    end

    it "resolves event_name to past-tense inflection when event_name is nil" do
      action = ActionDefinition.new
      action.resolved_event_name("complete_review").should eq("review_completed")
    end

    it "round-trips event_name through JSON" do
      original = ActionDefinition.new(
        args: {
          "comment" => ActionArgDefinition.new(type: FieldType.parse("string"), required: true),
        },
        event_name: "document_approved"
      )
      json = original.to_json
      parsed = ActionDefinition.from_json(json)
      parsed.event_name.should eq("document_approved")
    end

    it "round-trips states through JSON" do
      original = ActionDefinition.new(
        args: {} of String => ActionArgDefinition,
        states: {"status" => ["submitted", "pending"]}
      )
      json = original.to_json
      parsed = ActionDefinition.from_json(json)
      parsed.states.should eq({"status" => ["submitted", "pending"]})
    end
  end
end
