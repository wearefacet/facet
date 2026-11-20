# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../rbac"

module Facet
  module Assistant
    module DomainBuilder
      # The system-tier identity the assistant uses for every mutation
      # produced via a tool callback. RBAC is fully bypassed
      # (every enforcer returns `true` when `auth_context.system?`); the
      # draft-domain scoping is enforced inside each tool callback instead.
      module Auth
        ACCOUNT_ID = "system:assistant"

        def self.auth_context : RBAC::AuthContext
          RBAC::AuthContext.system(ACCOUNT_ID)
        end

        # Per-turn system-tier context attributed to the conversation
        # owner. The context stays system-tier, so the RBAC bypass and
        # the in-tool draft-domain scoping are unchanged; only the audit
        # attribution moves — `actioner_id` on every write-tool mutation
        # is the account that asked for the change, not the assistant.
        # Falls back to `ACCOUNT_ID` for conversations whose stored
        # `context.created_by` is missing or unparsable (the parse in
        # `Context.from_conversation_context` already defaults there).
        def self.auth_context_for(context : Context) : RBAC::AuthContext
          RBAC::AuthContext.system(context.created_by)
        end
      end
    end
  end
end
