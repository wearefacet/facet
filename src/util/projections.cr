# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"

module Facet
  module Util
    # Small shared queries against the `projections` table that several
    # services (doctype, domain, iam) would otherwise re-write inline.
    module Projections
      # True when a live (non-tombstoned) projection row exists.
      def self.exists?(db : DB::Connection, domain : String, doc_type : String, id : String) : Bool
        !db.query_one?(
          "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
          domain, doc_type, id, as: Int32
        ).nil?
      end

      # True when a projection row exists in any state — live or tombstoned.
      # Used by id resolution: the lifecycle of the row (404 vs 410) must come
      # from the service that reads it, not from this lookup.
      def self.row_exists?(db : DB::Connection, domain : String, doc_type : String, id : String) : Bool
        !db.query_one?(
          "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
          domain, doc_type, id, as: Int32
        ).nil?
      end

      # Reads the `draft` flag of a `core.Domain` projection. With `lock: true`
      # the row read takes `FOR UPDATE` — keep it where callers had the lock
      # (publish-gate and version-bump paths rely on it).
      def self.draft_domain?(db : DB::Connection, domain : String, lock : Bool = false) : Bool
        sql = "SELECT content->>'draft' FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL"
        sql += " FOR UPDATE" if lock
        # `query_one?` with a block yields the first row pre-positioned (or
        # returns nil when there is none) — do not call `rs.each` here, it
        # would skip the row.
        row = db.query_one?(sql, domain) do |rs|
          # NULL (no `draft` key) reads as not-draft — same as the
          # pre-consolidation call sites.
          rs.read(String?)
        end
        row == "true"
      end
    end
  end
end
