# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module AgentTools
    # Tool-level error taxonomy for agent tool calls.
    #
    # Every tool failure maps to one of these subclasses. `MCP::Routes.tools_call`
    # renders them as a JSON-RPC error response with a stable `code` and a
    # machine-readable `data` payload; the assistant registrars map them to
    # the tool error envelope. Either way an agent that misuses a tool gets
    # an actionable message instead of a generic 500.
    #
    # Rendering contract (see `MCP::Routes.render_tool_error`):
    #
    # | Class          | JSON-RPC code | Meaning                                  |
    # | -------------- | ------------- | ---------------------------------------- |
    # | `InvalidParams`| `-32602`      | bad arguments (unknown field, bad shape) |
    # | `RbacDenied`   | `-32603`      | role lacks the permission                |
    # | `NotFound`     | `-32602`      | unknown domain/doctype/document/action   |
    # | `Capped`       | `-32603`      | result exceeded a governance cap         |
    # | `ToolError`    | `-32603`      | anything else (fallback)                 |
    class ToolError < Exception
      # JSON-RPC error code carried in the response envelope.
      getter rpc_code : Int32

      # Optional structured payload surfaced as `error.data`.
      getter data : JSON::Any?

      def initialize(message : String, @rpc_code : Int32 = -32603, @data : JSON::Any? = nil)
        super(message)
      end
    end

    # Builds the standard `data` payload for a malformed tool argument
    # (missing, wrong shape, out of range). Shared by every argument helper
    # so the `reason` vocabulary stays identical across tool groups.
    def self.invalid_params_data(argument : String) : JSON::Any
      JSON.parse(%({"reason": "invalid_params", "argument": #{argument.to_json}}))
    end

    # The caller supplied arguments that do not satisfy the tool's input
    # schema or the doctype definition (unknown field, malformed filter,
    # wrong type). Message must name the offending argument.
    class InvalidParams < ToolError
      def initialize(message : String, data : JSON::Any? = nil)
        super(message, -32602, data)
      end
    end

    # The active role's permission map does not permit the operation.
    # Mirrors REST semantics: never leaks which permission line failed.
    class RbacDenied < ToolError
      def initialize(message : String = "Forbidden")
        super(message, -32603, JSON.parse(%({"reason": "rbac_denied"})))
      end
    end

    # The referenced domain, doctype, document, or action does not exist
    # (or is a tombstone). A grant holder that cannot see a document
    # surfaces here — an inaccessible document is indistinguishable from
    # a missing one. A caller with no grant on the doctype at all
    # surfaces as `RbacDenied`. The split follows the platform
    # read-disclosure policy: doctype existence is acceptable to reveal;
    # document existence is not.
    class NotFound < ToolError
      def initialize(message : String, data : JSON::Any? = nil)
        super(message, -32602, data)
      end
    end

    # The result exceeded `mcp.max_result_rows` or `mcp.max_response_bytes`.
    # Carries the cap value so the agent can page instead of retrying blind.
    class Capped < ToolError
      getter cap : Int32

      def initialize(message : String, @cap : Int32)
        super(message, -32603, JSON.parse(%({"reason": "capped", "cap": #{@cap}})))
      end
    end
  end
end
