# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"

module Facet
  module RBAC
    # Loads an account's role IDs from the raw projections table.
    #
    # This is part of the trusted-bypass tier: it reads directly from
    # projections (no RBAC). It exists because the RBAC system itself
    # needs to verify that a requested active role is actually assigned
    # to the account.
    module AccountLoader
      # Returns the list of role IDs for a given account, or nil if the
      # account does not exist.
      def self.load_role_ids(
        db : DB::Connection,
        account_id : String,
      ) : Array(String)?
        row = db.query_one?(
          <<-SQL,
            SELECT content FROM projections
            WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1
            AND deleted_at IS NULL
          SQL
          account_id
        ) do |rs|
          rs.read(JSON::Any)
        end

        return nil if row.nil?

        h = row.as_h?
        return nil if h.nil?

        roles_raw = h["roles"]?.try(&.as_a?)
        return nil if roles_raw.nil?

        roles_raw.map(&.as_s)
      end

      # Verifies that `role_id` is in the account's assigned roles.
      def self.role_assigned?(
        db : DB::Connection,
        account_id : String,
        role_id : String,
      ) : Bool
        role_ids = load_role_ids(db, account_id)
        return false if role_ids.nil?
        role_ids.includes?(role_id)
      end

      # Returns `true` when the account exists, is not deleted, and its
      # `status` field is `"active"`. Trusted bypass: reads the raw
      # projection. A missing or deleted row is never active.
      def self.account_active?(db : DB::Connection, account_id : String) : Bool
        status = db.query_one?(
          <<-SQL,
            SELECT content->>'status'
            FROM projections
            WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1
              AND deleted_at IS NULL
          SQL
          account_id,
          as: String?,
        )
        status == "active"
      end

      # Returns the `iam.Account.organizational_unit` of the given account.
      # Trusted bypass: reads the raw projection, not RBAC-enforced.
      # Returns "/" when the row is missing, deleted, or the field is
      # absent/blank (root-safe; never raises). Used by the enforcers to
      # build the per-request `ScopeContext` for `$organizational_unit`
      # scope predicates.
      def self.organizational_unit(db : DB::Connection, account_id : String) : String
        row = db.query_one?(
          <<-SQL,
            SELECT content->>'organizational_unit'
            FROM projections
            WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1
              AND deleted_at IS NULL
          SQL
          account_id
        ) do |rs|
          rs.read(String?)
        end
        ou = row
        return "/" if ou.nil? || ou.empty?
        ou
      end
    end
  end
end
