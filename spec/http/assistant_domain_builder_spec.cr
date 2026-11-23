# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/assistant"
require "../../src/assistant/domain_builder"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"
require "../support/iam_helper"

HTTPTest.init

private def post_domain_builder_conversation(body : String) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
  call_api(HTTP::Request.new("POST", "/Api/assistant/domain-builder/conversations", headers: headers, body: body))
end

# The same request shape for a preview-capability caller — the auth context
# rides the fiber via `call_api_as`, the CSRF header stays required.
private def preview_post_request(body : String) : HTTP::Request
  headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
  HTTP::Request.new("POST", "/Api/assistant/domain-builder/conversations", headers: headers, body: body)
end

describe "Domain Builder Conversation Routes" do
  before_each do
    # `Doctype::Create` (invoked by the create_doctype tool during the
    # streaming turn) needs the seeded `core.DocType` and `core.Domain`
    # definitions to exist; the per-test TRUNCATE wipes them. Scoped
    # `ensure_doctype` calls restore exactly those (idempotent, ~10 ms).
    with_db do |db|
      %w[core.DocType core.Domain].each do |dir|
        domain, doctype = dir.split(".", 2)
        Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
      end
      Facet::Doctype::DefinitionStore.cache.clear
    end
    Facet::Event::Publisher.flush
  end

  describe "POST /Api/assistant/domain-builder/conversations" do
    it "creates a conversation, a draft domain, and returns 201" do
      body = %({
        "target_name": "hr",
        "description": "HR domain for employees and career events"
      })

      resp = post_domain_builder_conversation(body)
      assert_http_status(resp, 201)

      data = JSON.parse(resp.body)["data"].as_h
      id = data["id"].as_s
      id.should_not be_empty

      # session_id / cache_key are server-generated; the response carries no
      # model/config — the connection resolves live per turn.
      data["session_id"].as_s.should_not be_empty
      data["cache_key"].as_s.should_not be_empty
      data.has_key?("model").should be_false

      # The system prompt is baked in and references the draft domain.
      system_prompt = data["system_prompt"].as_s
      system_prompt.should contain("Draft domain:")
      system_prompt.should contain("HR domain")

      # The context jsonb carries the domain-builder context.
      context = data["context"].as_h
      context["kind"].as_s.should eq("domain-builder")
      draft = context["draft_domain"].as_s
      draft.should start_with("_")
      context["target_name"].as_s.should eq("hr")
      context["description"].as_s.should contain("HR domain")
      context["created_by"].as_s.should eq("system") # test mode → AuthContext.system

      # The draft domain projection exists with draft=true.
      with_db do |db|
        row = db.query_one?(
          "SELECT content->>'draft' FROM projections WHERE domain='core' AND doc_type='Domain' AND id=$1 AND deleted_at IS NULL",
          draft,
          as: String?,
        )
        row.should eq("true")
      end

      # All 26 tool names are persisted on the conversation's enabled_tools.
      tools = data["enabled_tools"].as_a.map(&.as_s)
      tools.sort!
      tools.size.should eq(26)
      tools.should contain("create_doctype")
      tools.should contain("read_skill")
      tools.should contain("delete_document_view")
      tools.should contain("preview_view")
      tools.should contain("go_to_page")
      tools.should contain("create_collection_view")
      tools.should contain("get_document_view")
    end

    it "bakes the custom-instructions block into the stored prompt when the setting is pinned" do
      with_db do |db|
        Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
        pin = Facet::Document::Update.call(
          db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
          %({"assistant": {"system_prompt": "Prefer French labels."}}),
          Facet::RBAC::AuthContext.system,
        )
        pin.should be_a(Facet::Document::Update::Result)
        # No Redis fanout runs in the unit suite — invalidate like the subscriber.
        Facet::SystemSettings.mark_stale
      end

      resp = post_domain_builder_conversation(%({"target_name": "hr"}))
      assert_http_status(resp, 201)

      prompt = JSON.parse(resp.body)["data"]["system_prompt"].as_s
      prompt.should contain("## Custom instructions")
      prompt.should contain("Prefer French labels.")

      session_idx = prompt.index("## Session context")
      custom_idx = prompt.index("## Custom instructions")
      session_idx.should be_a(Int32)
      custom_idx.should be_a(Int32)
      custom_idx.not_nil!.should be > session_idx.not_nil!
    ensure
      Facet::SystemSettings.reset_cache!
    end

    it "works without optional target_name and description" do
      body = %({})

      resp = post_domain_builder_conversation(body)
      assert_http_status(resp, 201)

      data = JSON.parse(resp.body)["data"].as_h
      context = data["context"].as_h
      context["kind"].as_s.should eq("domain-builder")
      context["draft_domain"].as_s.should start_with("_")
      # target_name / description are omitted when absent.
      context.has_key?("target_name").should be_false
      context.has_key?("description").should be_false
    end

    it "requires a non-empty body" do
      resp = post_domain_builder_conversation("")
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("body")
    end

    it "rejects malformed JSON body" do
      resp = post_domain_builder_conversation("not json")
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("Invalid JSON")
    end
  end

  describe "preview-capability callers" do
    # While a preview session is active, `apiFetch` overlays the preview
    # Bearer on every request, so the conversation-create call arrives as a
    # `Principal::Preview` bound to one draft. The capability authorises the
    # conversation; it binds to the preview domain.

    it "creates the conversation bound to the preview domain when draft_domain is absent" do
      draft = create_draft_via_api
      preview_ctx = Facet::RBAC::AuthContext.preview("account_previewer", draft)

      resp = call_api_as(
        preview_post_request(%({"target_name": "crm"})),
        preview_ctx,
      )
      assert_http_status(resp, 201)

      context = JSON.parse(resp.body)["data"]["context"].as_h
      context["kind"].as_s.should eq("domain-builder")
      context["draft_domain"].as_s.should eq(draft)
      context["created_by"].as_s.should eq("account_previewer")
      context["target_name"].as_s.should eq("crm")
    end

    it "accepts a draft_domain that matches the preview domain" do
      draft = create_draft_via_api
      preview_ctx = Facet::RBAC::AuthContext.preview("account_previewer", draft)

      resp = call_api_as(
        preview_post_request(%({"draft_domain": "#{draft}"})),
        preview_ctx,
      )
      assert_http_status(resp, 201)

      context = JSON.parse(resp.body)["data"]["context"].as_h
      context["draft_domain"].as_s.should eq(draft)
      context["created_by"].as_s.should eq("account_previewer")
    end

    it "rejects a draft_domain naming another domain with 403" do
      draft = create_draft_via_api
      other = create_draft_via_api
      preview_ctx = Facet::RBAC::AuthContext.preview("account_previewer", draft)

      resp = call_api_as(
        preview_post_request(%({"draft_domain": "#{other}"})),
        preview_ctx,
      )
      assert_http_status(resp, 403)
      JSON.parse(resp.body)["error"].as_s.should contain("bound to draft '#{draft}'")
    end

    it "never creates a fresh draft for a preview caller" do
      draft = create_draft_via_api
      preview_ctx = Facet::RBAC::AuthContext.preview("account_previewer", draft)

      resp = call_api_as(preview_post_request("{}"), preview_ctx)
      assert_http_status(resp, 201)

      bound = JSON.parse(resp.body)["data"]["context"]["draft_domain"].as_s
      bound.should eq(draft)

      # Exactly one draft-domain projection exists beyond the one the setup
      # created — the route did not mint another one for the absent field.
      with_db do |db|
        count = db.scalar(
          "SELECT count(*) FROM projections WHERE domain='core' AND doc_type='Domain' " \
          "AND content->>'draft'='true' AND deleted_at IS NULL",
        ).as(Int64)
        count.should eq(1)
      end
    end
  end

  describe "privilege-escalation guard (P0-4)" do
    it "rejects streaming a domain-builder conversation whose draft_domain is not a draft" do
      # Simulate an attacker who somehow persisted a forged `context` payload
      # naming a production domain as `draft_domain` (e.g. via legacy data or a
      # direct DB write). The stream must refuse to wire the system-tier
      # assistant tools against the production domain.
      with_db do |db|
        restore_seeded_baseline(db)
        # `core` is a live production domain — not a draft.
        ctx_json = %({"kind":"domain-builder","draft_domain":"core","created_by":"attacker"})
        # Insert the conversation row directly so we can forge the `context`.
        db.exec(
          "INSERT INTO agent_conversations (id, session_id, cache_key, " \
          "system_prompt, context, enabled_tools) " \
          "VALUES ($1, $2, $3, $4, $5::jsonb, $6::jsonb)",
          "01ATTACK0001", "sess", "cache", "sys",
          ctx_json, "[]",
        )
      end
      Facet::Event::Publisher.flush

      body = JSON.build { |j| j.object { j.field "content", "hello" } }
      headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
      resp = call_api(HTTP::Request.new("POST", "/Api/assistant/conversations/01ATTACK0001/stream", headers: headers, body: body))

      assert_http_status(resp, 403)
      JSON.parse(resp.body)["error"].as_s.should contain("draft")
    end
  end

  describe "CSRF protection" do
    it "rejects the domain-builder create route without X-Requested-With" do
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      resp = call_api_raw(HTTP::Request.new("POST", "/Api/assistant/domain-builder/conversations", headers: headers, body: "{}"))

      assert_http_status(resp, 403)
      JSON.parse(resp.body)["error"].as_s.should contain("CSRF")
    end
  end
end
