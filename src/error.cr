# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./validation_error"

module Facet
  # Marker module for error result values.
  #
  # A type that includes `ErrorResult` names a failed operation. When a
  # `Database.with_transaction` block returns such a value, the wrapper
  # rolls the transaction back and returns the value unchanged to the
  # caller. The rule is marker-based, not type-specific: a new error type
  # must include this module, or the wrapper will commit its partial
  # writes.
  module ErrorResult
  end

  # A value-type error returned by service operations (read, create, update,
  # mutate, action, audit, IAM, etc.).
  #
  # This is **not** a `::Exception`: it has no backtrace, cannot be `raise`d,
  # and is not caught by `rescue`. It is an *output* value — closer to Go's
  # `(T, error)` idiom than to a language-level exception. Services return a
  # `Result | ServiceError` union from `self.call`, and callers pattern-match
  # on it with `case ... in Facet::ServiceError`.
  #
  # It carries `status` (HTTP status code), `message`, optional `details`
  # (validation errors), and optional `meta` (flat string key/values merged
  # into the JSON error body) — all the information needed to render an error
  # response without subclassing.
  class ServiceError
    include ErrorResult

    getter status : Int32
    getter message : String
    getter details : Array(ValidationError)?
    getter meta : Hash(String, String)?

    def initialize(
      @status : Int32,
      @message : String,
      @details : Array(ValidationError)? = nil,
      @meta : Hash(String, String)? = nil,
    )
    end
  end

  # `ValidationError` rides inside arrays and tuples; callers usually
  # convert it to a `ServiceError`. It still carries the marker: the
  # error-result contract covers every type that names a failed operation.
  struct ValidationError
    include ErrorResult
  end

  # The exception form of a service failure, for the rare site that must
  # abort a transaction from deep inside a `Database.with_transaction` block
  # (which cannot `return` a union). `Document::Create` raises it for the
  # iam.Roles named-id derivation (missing name → 422, name conflict → 409)
  # and converts it back to a `ServiceError` at the rescue boundary.
  class NamedIdError < ::Exception
    getter status : Int32

    def initialize(@status : Int32, message : String)
      super(message)
    end
  end
end
