# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../config"
require "../database"
require "../iam/helpers"
require "../http/auth_handler"
require "./protected_resource"
require "../agent_tools"
require "./dispatch"
require "./skills"

module Facet
  module MCP
    # HTTP surface for the MCP resource server.
    #
    # - `POST /Api/_mcp/:role_slug` — Streamable HTTP transport. Minimal
    #   JSON-RPC framing: one request in, one response out (no SSE stream,
    #   no batching). Methods: `initialize`, `ping`, `tools/list`,
    #   `tools/call`.
    # - `GET /Api/_mcp/endpoints` — browser-facing directory of the
    #   caller's held-role MCP endpoints (Settings page).
    # - `GET /.well-known/oauth-protected-resource` — RFC 9728 metadata,
    #   parameterized by the `resource` query string.
    #
    # The 401 handshake advertises the PRM URL so a spec-compliant client
    # discovers the authorization server on its first unauthenticated call.
    # No CORS checks run on this surface — MCP clients are
    # server-to-server, browser fetch is not a supported flow.
    module Routes
      def self.register : Nil
        # ── GET /.well-known/oauth-protected-resource ────────────
        #
        # Two shapes, both required by RFC 9728 §3.1:
        # - bare  /.well-known/oauth-protected-resource
        # - path-carrying /.well-known/oauth-protected-resource/<path>
        #   (the well-known segment inserted between host and the
        #   resource's own path — what spec-compliant clients derive for
        #   a path-bearing resource like /Api/_mcp/<role_slug>).
        # The advertised resource comes from the request path when present,
        # else from the ?resource= query string.
        get "/.well-known/oauth-protected-resource" do |env|
          Facet::HTTP::Helpers.write_json(env, 200, ProtectedResource.metadata(env.request.query_params["resource"]?))
        end

        # The glob must carry a name: the radix router keys a catch-all
        # param by the text after `*`. An anonymous `*` stores the suffix
        # under the empty-string key, so `params.url["splat"]` is always
        # nil and the path-carrying form would serve the bare document.
        get "/.well-known/oauth-protected-resource/*suffix" do |env|
          suffix = env.params.url["suffix"]?
          requested = if suffix.nil? || suffix.empty?
                        env.request.query_params["resource"]?
                      else
                        "#{MCP.base_url}/#{suffix}"
                      end
          Facet::HTTP::Helpers.write_json(env, 200, ProtectedResource.metadata(requested))
        end

        # ── GET /Api/_mcp/endpoints ──────────────────────────
        get "#{PATH_PREFIX}/endpoints" do |env|
          mcp_endpoints(env)
        end

        # ── POST /Api/_mcp/:role_slug ──────────────────────────────
        post "#{PATH_PREFIX}/:role_slug" do |env|
          role_slug = env.params.url["role_slug"]

          token = bearer_token(env)
          unless token
            next unauthorized_with_prm(env)
          end

          begin
            verified = Dispatch.verify(token, role_slug)
          rescue ex : Dispatch::Unauthorized
            Log.warn { "MCP dispatch rejected: #{ex.message} (role=#{role_slug})" }
            next unauthorized_with_prm(env)
          end

          body = env.request.body.try(&.gets_to_end) || ""
          request = JSON.parse(body) rescue nil
          unless request && request.as_h?
            next json_rpc_error(env, nil, -32700, "Parse error")
          end

          handle_rpc(env, verified, role_slug, request)
        end
      end

      # Browser-facing directory of the caller's MCP endpoints (the Settings
      # page renders one copyable row per held role). AuthHandler skips the
      # `/Api/_mcp/` prefix — the resource server performs its own bearer
      # verification on POST — so this route builds its context through
      # `AuthHandler.auth_context_from_request` itself: cookie or Bearer
      # session machinery, exactly like the REST surface. MCP tokens are
      # rejected by the REST `aud` rule, which is correct here — an MCP
      # token pins one role and must not enumerate the account's others.
      #
      # The URLs come from `MCP.resource_identifier` — the exact string
      # dispatch compares the token `aud` against. The browser must never
      # derive them from `window.location.origin` (a non-Caddy origin would
      # mint links whose `aud` fails the exact-match check).
      private def self.mcp_endpoints(env) : Nil
        auth_context = HTTP::AuthHandler.auth_context_from_request(env)
        unless auth_context
          Facet::HTTP::Helpers.error_response(env, 401, "Authentication required")
          return
        end

        endpoints = Database.with_db(:read_only) do |db|
          account = IAM::Helpers.find_account_by_id(db, auth_context.account_id)
          roles = account ? account[:roles] : [] of String
          roles.sort.map do |role|
            {role: role, url: MCP.resource_identifier(role)}
          end
        end

        Facet::HTTP::Helpers.write_json(env, 200, {endpoints: endpoints})
      end

      # ── JSON-RPC dispatch ─────────────────────────────────────────

      private def self.handle_rpc(env, verified : Dispatch::Verified, role_slug : String, request : JSON::Any) : Nil
        method = request["method"]?.try(&.as_s?)
        id = request["id"]?

        case method
        when "initialize"
          result = initialize_result(role_slug)
          json_rpc_result(env, id, result)
        when "notifications/initialized"
          # A notification carries no id and expects no response body.
          env.response.status_code = 202
        when "ping"
          json_rpc_result(env, id, JSON::Any.new({} of String => JSON::Any))
        when "tools/list"
          tools_list(env, verified, id)
        when "tools/call"
          tools_call(env, verified, id, request["params"]?)
        else
          json_rpc_error(env, id, -32601, "Method not found")
        end
      end

      private def self.initialize_result(role_slug : String) : JSON::Any
        JSON::Any.new({
          "protocolVersion" => JSON::Any.new("2025-06-18"),
          "capabilities"    => JSON::Any.new({
            "tools" => JSON::Any.new({} of String => JSON::Any),
          }),
          "serverInfo" => JSON::Any.new({
            "name"    => JSON::Any.new("facet"),
            "version" => JSON::Any.new("1.0"),
            "role"    => JSON::Any.new(role_slug),
          }),
        })
      end

      # Role-filtered tool listing. When the roles generation moved since
      # dispatch started, the response header signals the change; a client
      # that keeps the session open re-lists on its own schedule.
      #
      # The listing runs inside the per-`sid` slot: a stale generation
      # rebuilds the registry from the DB, so the listing is not free and
      # must not bypass the concurrency cap.
      private def self.tools_list(env, verified : Dispatch::Verified, id : JSON::Any?) : Nil
        Dispatch.with_session_slot(verified.session_id) do
          generation_at_start = AgentTools.current_generation
          tools = AgentTools.list_for(verified.auth_context)
          items : Array(JSON::Any) = tools.map do |t|
            tool_entry(t.name, t.description, t.input_schema)
          end
          # The skill loader rides after the catalogue. It is not a registry
          # entry — the surface is a property of the mount, the same way the
          # assistant registrars mount their own — and it serves every real
          # principal: skill files are static reference documents with no
          # tenant data, so no permission gate applies. `nil` when the
          # surface corpus is empty.
          if skill_def = MCP::Skills.definition
            items << tool_entry(skill_def.name, skill_def.description, skill_def.input_schema)
          end
          if AgentTools.current_generation != generation_at_start
            env.response.headers["MCP-Tools-Changed"] = "true"
          end
          json_rpc_result(env, id, JSON::Any.new({"tools" => JSON::Any.new(items)}))
        end
      end

      private def self.tool_entry(name : String, description : String, input_schema : JSON::Any) : JSON::Any
        JSON::Any.new({
          "name"        => JSON::Any.new(name),
          "description" => JSON::Any.new(description),
          "inputSchema" => input_schema,
        })
      end

      private def self.tools_call(env, verified : Dispatch::Verified, id : JSON::Any?, params : JSON::Any?) : Nil
        name = params.try(&.as_h?).try(&.dig?("name")).try(&.as_s?)
        arguments = params.try(&.as_h?).try(&.["arguments"]?) || JSON::Any.new({} of String => JSON::Any)

        unless name
          next_json = json_rpc_error_body(id, -32602, "Missing tool name")
          return respond_json_rpc(env, next_json)
        end

        begin
          result = Dispatch.with_session_slot(verified.session_id) do
            Database.with_db do
              Fiber.current.auth_context = verified.auth_context
              begin
                # The skill loader intercepts before the catalogue: it is
                # mounted per surface, not a registry entry (see tools_list).
                payload = if name == MCP::Skills::TOOL_NAME
                            MCP::Skills.call(arguments)
                          else
                            AgentTools.call(verified.auth_context, name, arguments)
                          end
                JSON::Any.new({
                  "content" => JSON::Any.new([
                    JSON::Any.new({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(payload.to_json)}),
                  ] of JSON::Any),
                  "structuredContent" => payload,
                  "isError"           => JSON::Any.new(false),
                })
              ensure
                Fiber.current.auth_context = nil
              end
            end
          end || JSON::Any.new({} of String => JSON::Any)
          json_rpc_result(env, id, result)
        rescue ex : AgentTools::ToolError
          render_tool_error(env, id, ex)
        end
      end

      # Renders a tool failure as a JSON-RPC error response with a stable
      # code and a machine-readable `data` payload (see `Tools::ToolError`).
      private def self.render_tool_error(env, id : JSON::Any?, ex : AgentTools::ToolError) : Nil
        error_h = {
          "code"    => JSON::Any.new(ex.rpc_code.to_i64),
          "message" => JSON::Any.new(ex.message || "Tool failed"),
        }
        if d = ex.data
          error_h["data"] = d
        end
        respond_json_rpc(env, JSON::Any.new({
          "jsonrpc" => JSON::Any.new("2.0"),
          "id"      => id || JSON::Any.new(nil),
          "error"   => JSON::Any.new(error_h),
        }))
      end

      # ── Response helpers ──────────────────────────────────────────────

      private def self.json_rpc_result(env, id : JSON::Any?, result : JSON::Any) : Nil
        respond_json_rpc(env, JSON::Any.new({
          "jsonrpc" => JSON::Any.new("2.0"),
          "id"      => id || JSON::Any.new(nil),
          "result"  => result,
        }))
      end

      private def self.json_rpc_error(env, id : JSON::Any?, code : Int32, message : String) : Nil
        respond_json_rpc(env, json_rpc_error_body(id, code, message))
      end

      private def self.json_rpc_error_body(id : JSON::Any?, code : Int32, message : String) : JSON::Any
        JSON::Any.new({
          "jsonrpc" => JSON::Any.new("2.0"),
          "id"      => id || JSON::Any.new(nil),
          "error"   => JSON::Any.new({
            "code"    => JSON::Any.new(code.to_i64),
            "message" => JSON::Any.new(message),
          }),
        })
      end

      private def self.respond_json_rpc(env, body : JSON::Any) : Nil
        env.response.status_code = 200
        env.response.content_type = "application/json"
        env.response.print(body.to_json)
      end

      # The 401 handshake: `WWW-Authenticate` points at the PRM document so
      # the client can discover the authorization server unauthenticated.
      # Per RFC 9728 §3.1 the metadata URL for a path-bearing resource is
      # the well-known segment inserted between host and resource path — the
      # request's own path, which always carries the role slug here. The
      # path-carrying PRM then advertises the role-pinned resource
      # identifier, so the client's RFC 8707 `resource` parameter matches
      # what dispatch pins the token's `aud` to.
      private def self.unauthorized_with_prm(env) : Nil
        base = MCP.base_url
        env.response.headers["WWW-Authenticate"] =
          "Bearer resource_metadata=" +
            "\"#{base}/.well-known/oauth-protected-resource#{env.request.path}\""
        Facet::HTTP::Helpers.error_response(env, 401, "Authentication required")
      end

      # The MCP resource server checks the Authorization header only —
      # never the session cookie (the surface performs its own bearer
      # verification; the shared extractor is cookie-free here).
      private def self.bearer_token(env) : String?
        Facet::HTTP::Helpers.extract_access_token(env, schemes: ["Bearer"], cookie: false)
      end
    end
  end
end
