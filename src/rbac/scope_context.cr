# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "./account_loader"

module Facet
  module RBAC
    # Per-request resolved actioner attributes used by scope evaluation.
    #
    # Built by the enforcers from a trusted-bypass `iam.Account` read (see
    # `AccountLoader.organizational_unit`); never mutated after construction.
    # Carries the two actioner attributes a scope `where` clause can
    # reference: the bare account id (backing `$self`) and the account's
    # organizational-unit path (backing `$organizational_unit`).
    #
    # System and preview principals never evaluate named scopes; when a
    # `ScopeContext` is still required (e.g. context-set resolution reached
    # from a script context), use `.root` — the root-safe fallback that
    # scopes `$organizational_unit` to the root path.
    struct ScopeContext
      getter account_id : String
      getter organizational_unit : String

      def initialize(@account_id : String, @organizational_unit : String)
      end

      # Loads the actioner's attributes from the `iam.Account` projection.
      # Trusted bypass (single indexed row read). Root-safe: a missing
      # account or absent/blank field scopes the caller to the root path.
      def self.load(db : DB::Connection, account_id : String) : self
        new(account_id, AccountLoader.organizational_unit(db, account_id))
      end

      # Root-safe factory for system/preview principals and any flow where
      # the actioner OU is not material — read-side safety net.
      def self.root(account_id : String) : self
        new(account_id, "/")
      end
    end
  end
end
