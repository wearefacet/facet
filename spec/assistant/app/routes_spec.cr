# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../support/app_assistant_helper"
require "../../support/doctype_helper"
require "../../support/agent_tools_helper"
require "../../support/iam_helper"
require "../../../src/http/server"
require "../../../src/assistant"
require "../../../src/document"
require "../../support/http_helper"
require "json"

HTTPTest.init

describe "App Assistant Routes" do
  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  describe "POST /Api/assistant/app/conversations" do
    it "creates an app conversation for an app-scoped caller with the assistant enabled" do
      with_db do |db|
        role_id = "appas_rt_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-rt-#{unique_suffix}", true)
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/app/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: %({"language": "fr"})),
          ctx,
        )

        assert_http_status(response, 201)
        data = JSON.parse(response.body)["data"].as_h

        # Stored context names the kind, the owner, and the app — all
        # server-derived, never from the request body.
        data["context"]["kind"].as_s.should eq("app")
        data["context"]["created_by"].as_s.should eq(account_id)
        data["context"]["app_id"].as_s.should eq(app.id)

        # System prompt: static body plus the Session context with the
        # app's display name, the token's role, and the language directive.
        prompt = data["system_prompt"].as_s
        prompt.should contain("Facet app")
        prompt.should contain("## Session context")
        prompt.should contain("- App: Appas Portal.")
        prompt.should contain("- Active role: #{role_id}.")
        prompt.should contain("## Language")
        prompt.should contain("`fr`")

        # enabled_tools: every registry entry minus ping — no skills, no UI
        # tools.
        tools = data["enabled_tools"].as_a.map(&.as_s)
        tools.should_not contain("ping")
        tools.should_not contain("read_skill")
        tools.should_not contain("navigate")
        tools.should contain("list_documents")
        tools.should contain("create_document")
        tools.should eq(Facet::Assistant::App::Registrar.tool_names)

        # The connection is server-owned and resolves live per turn — the
        # response carries no model or config, so no secret can ride it.
        data.has_key?("model").should be_false
        data.has_key?("config").should be_false
      end
    end

    it "bakes the app instructions block after the language directive" do
      with_db do |db|
        role_id = "appas_prompt_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-prompt-#{unique_suffix}", true,
          assistant_prompt: "Always quote the ticket number.")
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/app/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: %({"language": "fr"})),
          ctx,
        )

        assert_http_status(response, 201)
        prompt = JSON.parse(response.body)["data"]["system_prompt"].as_s
        prompt.should contain("## App instructions")
        prompt.should contain("Always quote the ticket number.")

        language_idx = prompt.index("## Language")
        app_idx = prompt.index("## App instructions")
        language_idx.should be_a(Int32)
        app_idx.should be_a(Int32)
        app_idx.not_nil!.should be > language_idx.not_nil!
      end
    end

    it "stores no app instructions block when the field is empty" do
      with_db do |db|
        role_id = "appas_noprompt_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-noprompt-#{unique_suffix}", true)
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/app/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "{}"),
          ctx,
        )

        assert_http_status(response, 201)
        JSON.parse(response.body)["data"]["system_prompt"].as_s
          .should_not contain("## App instructions")
      end
    end

    it "rejects the unauthenticated (denied) principal with 401" do
      response = call_api_as(
        HTTP::Request.new("POST", "/Api/assistant/app/conversations",
          headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
          body: "{}"),
        Facet::RBAC::AuthContext.denied,
      )

      assert_http_status(response, 401)
      JSON.parse(response.body)["error"].as_s.should contain("Authentication")
    end

    it "rejects a request without the CSRF header" do
      response = call_api_raw(
        HTTP::Request.new("POST", "/Api/assistant/app/conversations",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: "{}"),
      )

      assert_http_status(response, 403)
      JSON.parse(response.body)["error"].as_s.should contain("CSRF")
    end

    it "rejects a main-app session caller without an app token with 403" do
      with_db do |db|
        role_id = "appas_sess_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        appas_create_app(db, "appas-sess-#{unique_suffix}", true)
        ctx = appas_session_context(db, account_id, role_id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/app/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "{}"),
          ctx,
        )

        assert_http_status(response, 403)
        JSON.parse(response.body)["error"].as_s.should contain("app assistant")

        rows = db.query_one("SELECT COUNT(*) FROM agent_conversations", as: Int64)
        rows.should eq(0)
      end
    end

    it "rejects a disabled app with 403 and writes no row" do
      with_db do |db|
        role_id = "appas_dis_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-dis-#{unique_suffix}", false)
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/app/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "{}"),
          ctx,
        )

        assert_http_status(response, 403)
        JSON.parse(response.body)["error"].as_s.should contain("app assistant")

        rows = db.query_one("SELECT COUNT(*) FROM agent_conversations", as: Int64)
        rows.should eq(0)
      end
    end

    it "rejects a role without assistant_access with 403" do
      with_db do |db|
        role_id = "appas_noflag_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, false)
        app = appas_create_app(db, "appas-noflag-#{unique_suffix}", true)
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/app/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "{}"),
          ctx,
        )

        assert_http_status(response, 403)
        JSON.parse(response.body)["error"].as_s.should contain("app assistant")
      end
    end

    it "rejects a malformed JSON body" do
      with_db do |db|
        role_id = "appas_bad_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-bad-#{unique_suffix}", true)
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/app/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: "not json"),
          ctx,
        )

        assert_http_status(response, 422)
        JSON.parse(response.body)["error"].as_s.should contain("Invalid JSON")
      end
    end

    it "rejects a forged app kind on the generic create route with 422" do
      with_db do |db|
        role_id = "appas_forge_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        ctx = appas_session_context(db, account_id, role_id)

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/conversations",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: %({"context": {"kind": "app", "created_by": "someone-else", "app_id": "forged"}})),
          ctx,
        )

        assert_http_status(response, 422)
        JSON.parse(response.body)["error"].as_s
          .should contain(Facet::Assistant::App::Routes::CREATE_ROUTE)
      end
    end
  end

  describe "app conversation read surfaces" do
    it "lets the owner get, list with the app filters, and read turns" do
      with_db do |db|
        role_id = "appas_own_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app_a = appas_create_app(db, "appas-a-#{unique_suffix}", true)
        app_b = appas_create_app(db, "appas-b-#{unique_suffix}", true)
        ctx = appas_session_context(db, account_id, role_id)

        conv_a = appas_insert_conversation(db, account_id, app_a.id)
        appas_insert_conversation(db, account_id, app_b.id)

        get_response = call_api_as(HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_a}"), ctx)
        assert_http_status(get_response, 200)
        JSON.parse(get_response.body)["data"]["context"]["app_id"].as_s.should eq(app_a.id)

        turns_response = call_api_as(HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_a}/turns"), ctx)
        assert_http_status(turns_response, 200)
        JSON.parse(turns_response.body)["data"].as_a.size.should eq(0)

        # kind=app lists both own app conversations (the forced owner
        # filter AND-combines with the kind).
        list_app = call_api_as(
          HTTP::Request.new("GET", "/Api/assistant/conversations?filters[context.kind__eq]=app"), ctx)
        assert_http_status(list_app, 200)
        JSON.parse(list_app.body)["data"].as_a.size.should eq(2)

        # Adding the app filter narrows to one app: the two jsonb filters
        # AND-combine into one containment clause.
        list_narrow = call_api_as(
          HTTP::Request.new("GET", "/Api/assistant/conversations?filters[context.kind__eq]=app&filters[context.app_id__eq]=#{app_a.id}"), ctx)
        assert_http_status(list_narrow, 200)
        rows = JSON.parse(list_narrow.body)["data"].as_a
        rows.size.should eq(1)
        rows.first["id"].as_s.should eq(conv_a)
        rows.first["context"]["app_id"].as_s.should eq(app_a.id)
      end
    end

    it "denies another caller's get, turns, and list of an app conversation" do
      with_db do |db|
        owner_role = "appas_ghost_#{unique_suffix}"
        other_role = "appas_intr_#{unique_suffix}"
        owner_id = appas_create_role_and_account(db, owner_role, true)
        other_id = appas_create_role_and_account(db, other_role, true)
        other_ctx = appas_session_context(db, other_id, other_role)

        app = appas_create_app(db, "appas-ghost-#{unique_suffix}", true)
        conv_id = appas_insert_conversation(db, owner_id, app.id)

        get_response = call_api_as(HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}"), other_ctx)
        assert_http_status(get_response, 403)
        JSON.parse(get_response.body)["error"].as_s.should contain("access")

        turns_response = call_api_as(HTTP::Request.new("GET", "/Api/assistant/conversations/#{conv_id}/turns"), other_ctx)
        assert_http_status(turns_response, 403)

        list_response = call_api_as(
          HTTP::Request.new("GET", "/Api/assistant/conversations?filters[context.kind__eq]=app&filters[context.app_id__eq]=#{app.id}"), other_ctx)
        assert_http_status(list_response, 200)
        JSON.parse(list_response.body)["data"].as_a.size.should eq(0)
      end
    end

    it "gates the archive PATCH on ownership" do
      with_db do |db|
        owner_role = "appas_arch_#{unique_suffix}"
        other_role = "appas_arch2_#{unique_suffix}"
        owner_id = appas_create_role_and_account(db, owner_role, true)
        other_id = appas_create_role_and_account(db, other_role, true)
        owner_ctx = appas_session_context(db, owner_id, owner_role)
        other_ctx = appas_session_context(db, other_id, other_role)

        app = appas_create_app(db, "appas-arch-#{unique_suffix}", true)
        conv_id = appas_insert_conversation(db, owner_id, app.id)

        other_response = call_api_as(
          HTTP::Request.new("PATCH", "/Api/assistant/conversations/#{conv_id}",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: %({"archived": true})),
          other_ctx,
        )
        assert_http_status(other_response, 403)

        owner_response = call_api_as(
          HTTP::Request.new("PATCH", "/Api/assistant/conversations/#{conv_id}",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: %({"archived": true})),
          owner_ctx,
        )
        assert_http_status(owner_response, 200)
        JSON.parse(owner_response.body)["data"]["archived_at"].as_s.should_not be_empty
      end
    end
  end

  describe "app stream gate" do
    it "denies a disabled app on the next message with a clean 403" do
      with_db do |db|
        role_id = "appas_flip_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-flip-#{unique_suffix}", true)
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id)
        conv_id = appas_insert_conversation(db, account_id, app.id)
        appas_pin_connection(db, "http://localhost:59999")

        # Enabled: the gates pass (the fake LLM port never answers — this
        # stream errors on connect inside the SSE, but the gates ran).
        body = JSON.build { |j| j.object { j.field "content", "hello" } }
        headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}

        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
          ctx,
        )
        response.status_code.should eq(200)
        response.headers["Content-Type"]?.to_s.should contain("event-stream")

        # Disable the app.
        upd = Facet::Document::Update.call(
          db, "app", "App", app.id, %({"assistant_enabled": false}),
          Facet::RBAC::AuthContext.system,
        )
        upd.should be_a(Facet::Document::Update::Result)

        denied = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
          ctx,
        )
        assert_http_status(denied, 403)
        denied.headers["Content-Type"]?.to_s.should contain("json")
        JSON.parse(denied.body)["error"].as_s.should contain("app assistant")
      end
    end

    it "denies a caller whose token names a different app" do
      with_db do |db|
        role_id = "appas_swap_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true)
        app = appas_create_app(db, "appas-mine-#{unique_suffix}", true)
        other = appas_create_app(db, "appas-theirs-#{unique_suffix}", true)
        other_ctx = appas_app_scoped_context(db, account_id, role_id, other.id)

        conv_id = appas_insert_conversation(db, account_id, app.id)

        body = JSON.build { |j| j.object { j.field "content", "hello" } }
        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: body),
          other_ctx,
        )
        assert_http_status(response, 403)
        response.headers["Content-Type"]?.to_s.should contain("json")
        JSON.parse(response.body)["error"].as_s.should contain("app assistant")
      end
    end

    it "answers 429 when the usage limit is reached" do
      with_db do |db|
        role_id = "appas_budget_#{unique_suffix}"
        account_id = appas_create_role_and_account(db, role_id, true, budget: 0_i64)
        app = appas_create_app(db, "appas-budget-#{unique_suffix}", true)
        ctx = appas_app_scoped_context(db, account_id, role_id, app.id)
        conv_id = appas_insert_conversation(db, account_id, app.id)

        body = JSON.build { |j| j.object { j.field "content", "hello" } }
        response = call_api_as(
          HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream",
            headers: HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
            body: body),
          ctx,
        )
        assert_http_status(response, 429)
        response.headers["Content-Type"]?.to_s.should contain("json")
        JSON.parse(response.body)["error"].as_s.should contain("usage limit")
      end
    end
  end

  describe "scripted app stream" do
    it "runs create_document on a granted doctype and attributes the mutation to the app" do
      server = nil
      begin
        with_db do |db|
          domain, doctype = build_agg_doctype(db, "appasdom", %({"name": {"type": "string", "required": true}}))

          role_id = "appas_write_#{unique_suffix}"
          account_id = appas_create_role_and_account(db, role_id, true, permissions: %([
            {"action": "read", "on": "*.*"},
            {"action": "create", "on": "#{domain}.#{doctype}"}
          ]))
          grants = %([{"target": "#{domain}.#{doctype}", "actions": [{"name": "read", "required": true}, {"name": "write", "required": true}]}])
          app = appas_create_app(db, "appas-write-#{unique_suffix}", true)
          # The grant ceiling rides on the app document in production; the
          # spec pins the same grant set onto the resolved scope.
          ctx = appas_app_scoped_context(db, account_id, role_id, app.id, grants)
          conv_id = appas_insert_conversation(db, account_id, app.id)

          server = AppasStreamMock.new([
            appas_tool_call("create_document", %({"domain":"#{domain}","doctype":"#{doctype}","content":{"name":"From assistant"}})),
          ])
          appas_pin_connection(db, "http://localhost:#{server.not_nil!.port}")

          body = JSON.build { |j| j.object { j.field "content", "create a record" } }
          headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
          response = call_api_as(
            HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
            ctx,
          )

          response.status_code.should eq(200)
          response.headers["Content-Type"]?.to_s.should contain("event-stream")

          chunks = appas_sse_chunks(response.body)
          tool_calls = chunks.select { |c| c["kind"].as_s == "tool_call" }
          create_chunk = tool_calls.find { |c| c["name"].as_s == "create_document" && c["status"].as_s == "ok" }
          create_chunk.should_not be_nil
          JSON.parse(create_chunk.not_nil!["result"].as_s)["ok"].as_bool.should be_true

          # The app kind mounts no UI tools, so no raw arguments are
          # forwarded on the wire.
          create_chunk.not_nil!.as_h.has_key?("arguments").should be_false

          # The created document is live.
          doc_id = db.query_one(
            "SELECT id FROM projections WHERE domain = $1 AND doc_type = $2 AND content->>'name' = 'From assistant' AND deleted_at IS NULL",
            domain, doctype, as: String)

          # The write carries the app attribution and the assistant cause:
          # the same audit trail a REST write through the app token gets.
          app_col, cause_kind, channel = db.query_one(
            "SELECT app, cause_kind, channel FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND action = 'create'",
            domain, doctype, doc_id, as: {String?, String, String})
          app_col.should eq(app.id)
          cause_kind.should eq("assistant")
          channel.should eq("oauth_app")

          response.body.should contain("event: done")
        end
      ensure
        server.try(&.close)
      end
    end

    it "denies a doctype outside the app grant with the same denial a REST call gets" do
      server = nil
      begin
        with_db do |db|
          fields = %({"name": {"type": "string", "required": true}})
          domain, granted_dt = build_agg_doctype(db, "appasdeny", fields)
          _, secret_dt = build_agg_doctype(db, "appasdeny", fields)

          role_id = "appas_deny_#{unique_suffix}"
          account_id = appas_create_role_and_account(db, role_id, true, permissions: %([
            {"action": "read", "on": "*.*"},
            {"action": "create", "on": "#{domain}.*"}
          ]))
          # The app grant covers only the first doctype — the role would
          # allow the second, but the grant refuses it (Layer-1).
          grants = %([{"target": "#{domain}.#{granted_dt}", "actions": [{"name": "read", "required": true}, {"name": "write", "required": true}]}])
          app = appas_create_app(db, "appas-deny-#{unique_suffix}", true)
          ctx = appas_app_scoped_context(db, account_id, role_id, app.id, grants)

          # The same denial a REST call gets through the same token.
          rest = Facet::Document::Create.call(db, domain, secret_dt, %({"name": "direct"}), ctx)
          rest.should be_a(Facet::ServiceError)
          rest_message = rest.as(Facet::ServiceError).message
          rest.as(Facet::ServiceError).status.should eq(403)

          conv_id = appas_insert_conversation(db, account_id, app.id)
          server = AppasStreamMock.new([
            appas_tool_call("create_document", %({"domain":"#{domain}","doctype":"#{secret_dt}","content":{"name":"From assistant"}})),
          ])
          appas_pin_connection(db, "http://localhost:#{server.not_nil!.port}")

          body = JSON.build { |j| j.object { j.field "content", "create a secret record" } }
          headers = HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"}
          response = call_api_as(
            HTTP::Request.new("POST", "/Api/assistant/conversations/#{conv_id}/stream", headers: headers, body: body),
            ctx,
          )

          response.status_code.should eq(200)
          chunks = appas_sse_chunks(response.body)
          tool_calls = chunks.select { |c| c["kind"].as_s == "tool_call" }

          # The trace marks the refused call as an error: the registry catches
          # the ToolError and returns the error envelope, and the handler
          # classifies the envelope as a failed tool call (B-368 — a refusal
          # must not render as a clean execution).
          denied_chunk = tool_calls.find { |c| c["name"].as_s == "create_document" && c["status"].as_s == "error" }
          denied_chunk.should_not be_nil

          envelope = JSON.parse(denied_chunk.not_nil!["result"].as_s)
          envelope["ok"].as_bool.should be_false
          envelope["error"].as_s.should eq(rest_message)

          # The refused write landed no row.
          rows = db.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = $2 AND content->>'name' = 'From assistant'",
            domain, secret_dt, as: Int64)
          rows.should eq(0)
        end
      ensure
        server.try(&.close)
      end
    end
  end
end
