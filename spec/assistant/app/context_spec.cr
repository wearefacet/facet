# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/app/context"

describe Facet::Assistant::App::Context do
  describe ".from_conversation_context" do
    it "parses a stored app context" do
      json = JSON.parse(%({"kind": "app", "created_by": "acct_1", "app_id": "app_1"}))
      ctx = Facet::Assistant::App::Context.from_conversation_context(json)
      ctx.should be_a(Facet::Assistant::App::Context)
      ctx.not_nil!.created_by.should eq("acct_1")
      ctx.not_nil!.app_id.should eq("app_1")
    end

    it "rejects a payload that names another kind" do
      json = JSON.parse(%({"kind": "workspace", "created_by": "acct_1", "app_id": "app_1"}))
      Facet::Assistant::App::Context.from_conversation_context(json).should be_nil
    end

    it "fails closed on a missing or empty owner" do
      Facet::Assistant::App::Context.from_conversation_context(
        JSON.parse(%({"kind": "app", "app_id": "app_1"})),
      ).should be_nil
      Facet::Assistant::App::Context.from_conversation_context(
        JSON.parse(%({"kind": "app", "created_by": "", "app_id": "app_1"})),
      ).should be_nil
    end

    it "fails closed on a missing or empty app id" do
      Facet::Assistant::App::Context.from_conversation_context(
        JSON.parse(%({"kind": "app", "created_by": "acct_1"})),
      ).should be_nil
      Facet::Assistant::App::Context.from_conversation_context(
        JSON.parse(%({"kind": "app", "created_by": "acct_1", "app_id": ""})),
      ).should be_nil
    end

    it "fails closed on a non-object payload" do
      Facet::Assistant::App::Context.from_conversation_context(JSON.parse(%("app"))).should be_nil
      Facet::Assistant::App::Context.from_conversation_context(JSON.parse(%([]))).should be_nil
    end
  end

  describe "#to_json" do
    it "round-trips through the parser with all three fields" do
      ctx = Facet::Assistant::App::Context.new(created_by: "acct_1", app_id: "app_1")
      parsed = JSON.parse(ctx.to_json)
      parsed["kind"].as_s.should eq("app")
      parsed["created_by"].as_s.should eq("acct_1")
      parsed["app_id"].as_s.should eq("app_1")

      round = Facet::Assistant::App::Context.from_conversation_context(parsed)
      round.should be_a(Facet::Assistant::App::Context)
      round.not_nil!.created_by.should eq("acct_1")
      round.not_nil!.app_id.should eq("app_1")
    end
  end
end
