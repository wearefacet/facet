# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module RBAC
    # The caller principal for a single request.
    #
    # Three kinds exist:
    # - `System` — full bypass, no role loaded. Used for internal operations,
    #   migrations, and specs.
    # - `Real` — an authenticated principal with a loaded `ActiveRole`.
    # - `Preview` — a capability principal scoped to a single draft domain.
    #   Issued by the preview-session endpoint after the caller produced a
    #   valid `read`/`create` permission on `core.DocType` against the draft.
    #   The preview principal bypasses the role/permission system entirely —
    #   authorization is reduced to one rule: the target `(domain, doc_type)`
    #   must live inside the bound draft domain. See `doc/backend/draft-domains.md`
    #   → Preview Mode for the contract.
    #
    # The type hierarchy lets the compiler enforce that `System` has no
    # `active_role` while `Real` always has one, eliminating nilable checks.
    abstract struct Principal
      # The identity string that goes into mutation/audit logs.
      abstract def account_id : String

      # System — full bypass, no role loaded. The `account_id` overrides
      # the default `"system"` identity so a system-tier caller (e.g. the
      # assistant) can still be attributed in the mutation/audit log.
      struct System < Principal
        getter account_id : String

        def initialize(@account_id : String = "system")
        end
      end

      # A real principal with a loaded role.
      struct Real < Principal
        getter account_id : String
        getter active_role : ActiveRole

        def initialize(@account_id : String, @active_role : ActiveRole)
        end
      end

      # A capability principal scoped to a single draft domain.
      #
      # Used by preview mode: it carries the caller's real `account_id` (so
      # the mutation/audit log attributes work correctly) and the draft domain
      # id the principal is bound to. The enforcers consult `preview_domain`
      # — every operation outside that domain is denied directly here.
      #
      # No `ActiveRole` is loaded: the capability was issued after the caller
      # proved, on their real identity, that they can edit the draft's doctype
      # definitions. Resource-scope resolution (named scopes, context sets) is
      # not applicable to draft data — the draft has no production-tuned scopes
      # and the user is concurrently editing the schema.
      struct Preview < Principal
        getter account_id : String
        getter preview_domain : String

        def initialize(@account_id : String, @preview_domain : String)
        end
      end
    end
  end
end
