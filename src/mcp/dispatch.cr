# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../config"
require "../database"
require "../iam/jwt"
require "../iam/token_emitter"
require "../rbac/auth_context"
require "../util/crypto"
require "../agent_tools"

module Facet
  module MCP
    # Verifies a bearer token and builds the request's `AuthContext` for the
    # MCP dispatch path.
    #
    # Enforcement order (every step rejects with `401` + `WWW-Authenticate:
    # Bearer error="invalid_token"` before any tool dispatch, before any DB
    # read):
    #
    # 1. Token decodes and verifies (ES256, alg-pinned).
    # 2. `aud` present and exactly equal to this route's resource identifier
    #    (`https://<origin>/Api/_mcp/<role_slug>`). No prefix match, no
    #    Host-header derivation.
    # 3. URL `:role_slug` equals the token's elected `role` claim.
    # 4. Account is `active` and not soft-deleted.
    # 5. Role still exists (defense in depth — authorize already gated it).
    # 6. `AuthContext.authenticated` built; `system?` asserted false.
    module Dispatch
      class Unauthorized < Exception
        getter www_authenticate : String

        def initialize(description : String)
          @www_authenticate = "Bearer error=\"invalid_token\", error_description=\"#{description}\""
          super(description)
        end
      end

      record Verified,
        auth_context : RBAC::AuthContext,
        session_id : String,
        role_id : String

      # Runs the full verification chain for a POST to `/Api/_mcp/:role_slug`.
      def self.verify(token : String?, role_slug : String) : Verified
        raise Unauthorized.new("Missing bearer token") if token.nil? || token.empty?

        decoded = IAM::JWT.decode(token, IAM::TokenEmitter.keys) rescue nil
        raise Unauthorized.new("Token verification failed") unless decoded

        payload = decoded.payload
        aud = payload["aud"]?.try(&.as_s?)
        unless aud && Util::Crypto.constant_time_eq?(aud, MCP.resource_identifier(role_slug))
          raise Unauthorized.new("Token audience does not match this resource")
        end

        account_id = payload["sub"]?.try(&.as_s)
        token_role = payload["role"]?.try(&.as_s)
        sid = payload["sid"]?.try(&.as_s)
        raise Unauthorized.new("Token missing required claims") unless account_id && token_role && sid

        unless Util::Crypto.constant_time_eq?(role_slug, token_role)
          raise Unauthorized.new("Token role does not match the mounted URL")
        end

        verified = load_verified_principal(account_id: account_id, role_id: token_role, sid: sid)
        verified
      rescue ArgumentError
        raise Unauthorized.new("Principal construction failed")
      end

      # Loads live state and builds the principal. Split out of `verify` so
      # the block's return type is explicit for the compiler.
      private def self.load_verified_principal(account_id : String, role_id : String, sid : String) : Verified
        Database.with_db do |db|
          # Account must be active and not soft-deleted, mirroring the
          # browser-session check.
          row = db.query_one?(
            "SELECT content->>'status' FROM projections WHERE id = $1 AND deleted_at IS NULL",
            account_id,
            as: String?,
          )
          raise Unauthorized.new("Account not found") unless row
          raise Unauthorized.new("Account is not active") unless row == "active"

          role_content = IAM::Helpers.find_role_content(db, role_id)
          raise Unauthorized.new("Role not found") unless role_content

          active_role = RBAC::ActiveRole.from_projection_content(role_content)
          # The MCP surface builds an MCP-principal context: the URL-pinned
          # role rides on the context as `acting_role`, which the mutation
          # services stamp into `mutations.meta.acting_role` (audit
          # invariant — one role per MCP session).
          auth_context = RBAC::AuthContext.mcp(account_id, active_role, role_id)

          # D6: `AuthContext.system` is forbidden on this path. The explicit
          # assertion makes the invariant mechanical rather than conventional.
          if auth_context.system?
            raise Unauthorized.new("System principal is forbidden on the MCP surface")
          end

          Verified.new(auth_context: auth_context, session_id: sid, role_id: role_id)
        end
      end

      # Per-`sid` concurrency semaphore. Parallel agent traffic shares one
      # session; the cap bounds pool pressure. Requests over the cap wait
      # rather than fail.
      @@semaphores = Hash(String, Channel(Nil)).new
      @@semaphores_mutex = Mutex.new

      def self.with_session_slot(sid : String, &)
        cap = Facet::Config.instance.mcp.max_concurrency_per_sid
        channel = @@semaphores_mutex.synchronize do
          @@semaphores[sid] ||= begin
            ch = Channel(Nil).new(cap)
            cap.times { ch.send(nil) }
            ch
          end
        end
        slot = channel.receive
        begin
          yield
        ensure
          channel.send(slot)
        end
      end
    end
  end
end
