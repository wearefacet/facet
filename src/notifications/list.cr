# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "./send"

module Facet
  module Notification
    # One row of a notification list response.
    #
    # `actions` is the parsed `Action` descriptor array — the same shape
    # `Send` validated at write time, so consumers never touch raw JSON.
    record Item,
      id : String,
      account_id : String,
      domain : String,
      doc_type : String,
      doc_id : String,
      kind : String,
      icon : String?,
      title : String,
      body : String,
      data : JSON::Any,
      actions : Array(Action),
      read_at : Time?,
      actioned_at : Time?,
      created_at : Time

    # Read paths for notifications: the paginated list and the unread
    # badge count. Both are scoped to a single account — there is no
    # cross-account read path.
    module List
      DEFAULT_PER_PAGE =  20
      MAX_PER_PAGE     = 100

      # Paginated list for one account.
      #
      # Ordering is always `created_at DESC, id DESC` (newest first),
      # regardless of filters. The `id` tiebreaker makes pagination
      # deterministic for rows that share the same `created_at`
      # millisecond (`id` is a ULID — time-sortable, monotonically
      # increasing). This is an invariant of the API — no `sort`
      # parameter is accepted. Callers that need a different order sort
      # client-side.
      #
      # `only_unread: true` filters on `read_at IS NULL`.
      # `kind: "..."` filters by kind (optional).
      # `per_page` defaults to 20, clamped to 1..100.
      #
      # Returns `{items, count, more}` where `count` is the number of
      # items in this page (`items.size`), not the global matching
      # total. The HTTP envelope exposes it as `meta.count`. The
      # frontend uses `meta.more` to decide whether to fetch the next
      # page; it does not need a global count, so no second `count(*)`
      # query runs per page — the query fetches one row beyond the page
      # and the extra row only decides `more`.
      def self.list(
        db : DB::Connection,
        account_id : String,
        only_unread : Bool = false,
        kind : String? = nil,
        page : Int32 = 1,
        per_page : Int32 = DEFAULT_PER_PAGE,
      ) : {Array(Item), Int32, Bool}
        raise ArgumentError.new("Notification list account_id is required") if account_id.blank?
        raise ArgumentError.new("Notification list page must be positive") if page < 1

        per_page = per_page.clamp(1, MAX_PER_PAGE)
        offset = (page - 1) * per_page

        conditions = ["account_id = $1"]
        params = [account_id] of ::DB::Any
        conditions << "read_at IS NULL" if only_unread
        if kind
          params << kind
          conditions << "kind = $#{params.size}"
        end

        # Capped count from the page offset: the caller learns the real
        # number of matching notifications up to the shared cap, not the
        # page size plus a probe row.
        count_params = params
        total = db.query_one(
          <<-SQL,
            SELECT COUNT(*) FROM (
              SELECT 1 FROM notifications
              WHERE #{conditions.join(" AND ")}
              ORDER BY created_at DESC, id DESC
              LIMIT #{HTTP::Responders::COUNT_CAP + 1} OFFSET #{offset}
            ) AS sub
          SQL


          args: count_params,
          as: Int64,
        )

        # One row beyond the page decides the `more` flag.
        params << per_page + 1
        params << offset

        rows = db.query_all(
          "SELECT id, account_id, domain, doc_type, doc_id, kind, icon, title, body,
                  data, actions, read_at, actioned_at, created_at
           FROM notifications
           WHERE #{conditions.join(" AND ")}
           ORDER BY created_at DESC, id DESC
           LIMIT $#{params.size - 1} OFFSET $#{params.size}",
          args: params,
        ) do |rs|
          id = rs.read(String)
          row_account_id = rs.read(String)
          domain = rs.read(String)
          doc_type = rs.read(String)
          doc_id = rs.read(String)
          row_kind = rs.read(String)
          icon = rs.read(String?)
          title = rs.read(String)
          body = rs.read(String)
          data = rs.read(JSON::Any)
          actions = parse_actions(rs.read(JSON::Any))
          read_at = rs.read(Time?)
          actioned_at = rs.read(Time?)
          created_at = rs.read(Time)
          Item.new(
            id, row_account_id, domain, doc_type, doc_id, row_kind, icon,
            title, body, data, actions, read_at, actioned_at, created_at,
          )
        end

        items = rows.first(per_page)
        {items, total.to_i32, total > HTTP::Responders::COUNT_CAP}
      end

      # Unread count for the account — cheap query for the badge,
      # served by the partial unread index.
      def self.unread_count(db : DB::Connection, account_id : String) : Int32
        raise ArgumentError.new("Notification unread_count account_id is required") if account_id.blank?

        db.scalar(
          "SELECT count(*) FROM notifications WHERE account_id = $1 AND read_at IS NULL",
          account_id,
        ).as(Int64).to_i32
      end

      private def self.parse_actions(json : JSON::Any) : Array(Action)
        json.as_a.map do |entry|
          Action.new(
            key: entry["key"].as_s,
            label: entry["label"].as_s,
            variant: entry["variant"]?.try(&.as_s),
            confirm: entry["confirm"]?.try(&.as_s),
          )
        end
      end
    end
  end
end
