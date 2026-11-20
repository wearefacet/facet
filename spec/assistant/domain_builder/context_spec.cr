# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/domain_builder/context"
require "../../../src/doctype/seed"
require "../../../src/domain/draft"

module Facet::Assistant::DomainBuilder
  describe Context do
    describe ".from_conversation_context" do
      it "parses a domain-builder context from JSON" do
        json = JSON.parse(%({
          "kind": "domain-builder",
          "draft_domain": "_abc123",
          "target_name": "hr",
          "description": "HR domain",
          "created_by": "account_42"
        }))

        ctx = Context.from_conversation_context(json)
        ctx.should_not be_nil
        ctx = ctx.not_nil!
        ctx.draft_domain.should eq("_abc123")
        ctx.target_name?.should eq("hr")
        ctx.description?.should eq("HR domain")
        ctx.created_by.should eq("account_42")
      end

      it "returns nil when kind is not domain-builder" do
        json = JSON.parse(%({"kind": "general-assistance"}))
        Context.from_conversation_context(json).should be_nil
      end

      it "returns nil when draft_domain is missing" do
        json = JSON.parse(%({"kind": "domain-builder"}))
        Context.from_conversation_context(json).should be_nil
      end

      it "returns nil when payload is not an object" do
        json = JSON.parse("[]")
        Context.from_conversation_context(json).should be_nil
      end

      it "defaults created_by to system:assistant when absent" do
        json = JSON.parse(%({
          "kind": "domain-builder",
          "draft_domain": "_test"
        }))
        ctx = Context.from_conversation_context(json).not_nil!
        ctx.created_by.should eq("system:assistant")
      end

      it "handles missing optional fields" do
        json = JSON.parse(%({
          "kind": "domain-builder",
          "draft_domain": "_test",
          "created_by": "u1"
        }))
        ctx = Context.from_conversation_context(json).not_nil!
        ctx.target_name?.should be_nil
        ctx.description?.should be_nil
      end
    end

    describe "#to_json" do
      it "round-trips through from_conversation_context" do
        ctx = Context.new(
          draft_domain: "_xyz",
          target_name: "orders",
          description: "Order domain",
          created_by: "account_1",
        )
        json = ctx.to_json
        parsed = Context.from_conversation_context(JSON.parse(json)).not_nil!
        parsed.draft_domain.should eq("_xyz")
        parsed.target_name?.should eq("orders")
        parsed.description?.should eq("Order domain")
        parsed.created_by.should eq("account_1")
      end

      it "omits nil optional fields" do
        ctx = Context.new(draft_domain: "_d", created_by: "u1")
        json = JSON.parse(ctx.to_json)
        json.as_h.has_key?("target_name").should be_false
        json.as_h.has_key?("description").should be_false
      end
    end

    describe "#verify_draft_domain?" do
      it "returns true when draft_domain points at a draft core.Domain row" do
        with_db do |db|
          restore_seeded_baseline(db)
          draft = Facet::Domain::Draft.create(db, "{}", "system:test")
          draft.should be_a(Facet::Domain::Draft::Result)
          draft_name = draft.as(Facet::Domain::Draft::Result).projection.id

          ctx = Context.new(draft_domain: draft_name)
          ctx.verify_draft_domain?(db).should be_true
        end
      end

      it "returns false when the domain row is absent" do
        with_db do |db|
          restore_seeded_baseline(db)

          ctx = Context.new(draft_domain: "_does_not_exist")
          ctx.verify_draft_domain?(db).should be_false
        end
      end

      it "returns false when draft_domain names a non-draft production domain" do
        with_db do |db|
          restore_seeded_baseline(db)
          # `core` itself is a live, non-draft domain projection.
          ctx = Context.new(draft_domain: "core")
          ctx.verify_draft_domain?(db).should be_false
        end
      end
    end
  end
end
