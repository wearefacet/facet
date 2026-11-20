# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module RBAC
    # The result of an authorization query (`AuthContext#can?`).
    #
    # Three variants:
    # - `Denied` — no matching permission. The caller is not authorized.
    # - `All` — wildcard permission, or at least one matching permission is
    #   unrestricted (absent scope or `$all`). Full access, no further checks.
    # - `Scoped` — every matching permission references a named scope alias.
    #   The enforcer resolves the alias against the target doctype definition
    #   at enforcement time.
    #
    # This is an abstract struct hierarchy rather than a Crystal `enum` because
    # `Scoped` carries a payload (`Array(Permission)`), which Crystal enums
    # cannot express.
    abstract struct CanResult
      # No matching permission — deny.
      struct Denied < CanResult; end

      # Wildcard/empty scope — full access, no further checks.
      struct All < CanResult; end

      # Matching permissions with scope constraints.
      #
      # Scopes are unresolved here — the enforcer resolves context sets
      # using its own DB connection and memoization.
      struct Scoped < CanResult
        getter permissions : Array(Permission)

        def initialize(@permissions : Array(Permission))
        end
      end
    end
  end
end
