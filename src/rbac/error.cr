# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module RBAC
    # Base error type for all RBAC failures.
    class Error < ::RuntimeError
      getter status : Int32

      def initialize(message : String, status : Int32 = 403)
        super(message)
        @status = status
      end
    end

    # The active principal's permission map does not permit the operation.
    # Raised by callers that surface RBAC failures as exceptions rather
    # than `Facet::ServiceError` values — e.g. `Notification::InvokeAction`,
    # which re-dispatches a doctype action under the recipient's context.
    class NotAuthorized < Error
      def initialize(message : String = "Forbidden")
        super(message)
      end
    end
  end
end
