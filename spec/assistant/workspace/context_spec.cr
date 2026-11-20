# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"
require "../../../src/assistant/workspace/context"

module Facet::Assistant::Workspace
  describe Context do
    describe ".from_conversation_context" do
      it "parses a workspace context from JSON" do
        json = JSON.parse(%({
          "kind": "workspace",
          "created_by": "account_42"
        }))

        ctx = Context.from_conversation_context(json)
        ctx.should_not be_nil
        ctx.not_nil!.created_by.should eq("account_42")
      end

      it "returns nil when kind is not workspace" do
        json = JSON.parse(%({"kind": "general-assistance", "created_by": "a"}))
        Context.from_conversation_context(json).should be_nil
      end

      it "returns nil when kind is domain-builder (payloads never mix)" do
        json = JSON.parse(%({"kind": "domain-builder", "draft_domain": "_x", "created_by": "a"}))
        Context.from_conversation_context(json).should be_nil
      end

      it "returns nil when created_by is missing" do
        json = JSON.parse(%({"kind": "workspace"}))
        Context.from_conversation_context(json).should be_nil
      end

      it "returns nil when created_by is empty" do
        json = JSON.parse(%({"kind": "workspace", "created_by": ""}))
        Context.from_conversation_context(json).should be_nil
      end

      it "returns nil when created_by is not a string" do
        json = JSON.parse(%({"kind": "workspace", "created_by": 42}))
        Context.from_conversation_context(json).should be_nil
      end

      it "returns nil when payload is not an object" do
        Context.from_conversation_context(JSON.parse("[]")).should be_nil
        Context.from_conversation_context(JSON.parse("null")).should be_nil
      end
    end

    describe "#to_json" do
      it "round-trips through from_conversation_context" do
        ctx = Context.new(created_by: "account_1")
        parsed = Context.from_conversation_context(JSON.parse(ctx.to_json)).not_nil!
        parsed.created_by.should eq("account_1")
      end

      it "carries exactly kind and created_by" do
        json = JSON.parse(Context.new(created_by: "u1").to_json).as_h
        json.keys.sort!.should eq(["created_by", "kind"])
        json["kind"].as_s.should eq("workspace")
      end
    end
  end
end
