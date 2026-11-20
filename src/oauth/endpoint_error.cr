# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module OAuth
    # One error type for the OAuth protocol endpoints (`authorize`, `token`,
    # `refresh` and its MCP branch). It carries the OAuth `error_code` and
    # the HTTP status the route renders. Route code rescues the base type;
    # the per-module names below stay as subclasses so their default
    # statuses and existing rescue sites keep working.
    #
    # Default status 400 per RFC 6749 §5.2 — the refresh module raises with
    # an explicit 401 where a failed grant is an authentication failure.
    class EndpointError < Exception
      getter error_code : String
      getter status : Int32

      def initialize(@error_code : String, message : String, @status : Int32 = 400)
        super(message)
      end
    end

    # Returns the value when present and non-empty; raises `EndpointError`
    # (`invalid_request`) otherwise. Shared by the authorize and token
    # parameter validation. The return type narrows to `String` so callers
    # can pass the result to constructors expecting a non-nil value.
    def self.require_present(value : String?, name : String) : String
      raise EndpointError.new("invalid_request", "Missing '#{name}'", 400) if value.nil? || value.empty?
      value
    end
  end
end
