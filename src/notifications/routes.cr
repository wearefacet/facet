# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../iam/helpers"
require "../http/helpers"
require "./list"
require "./mark_read"
require "./invoke_action"

module Facet
  module Notification
    # HTTP routes for the notification store.
    #
    # All routes are under `/Api/notifications`. They are self-service: the
    # authenticated user touches their own rows only, keyed off the verified
    # auth context's account id (`HTTP::Helpers.require_account` reads it
    # after `AuthHandler` checked the token signature — never an unverified
    # cookie claim) — the SQL `WHERE account_id = $1` is the isolation
    # boundary (no RBAC enforcer on the read/mark-read routes, mirroring
    # `src/settings/routes.cr`). The action route is the exception:
    # `InvokeAction` enforces RBAC at execute time under the recipient's
    # `RBAC::AuthContext` (decision 10).
    #
    # State-changing requests (POST) require the `X-Requested-With` header —
    # the CSRF defense of decision 14. GET routes do not require it.
    module Routes
      @@registered : Bool = false

      # Registers all notification routes on the Kemal router. Idempotent —
      # the HTTP server wiring and the spec harness both call it.
      def self.register : Nil
        return if @@registered
        @@registered = true

        # ── GET /Api/notifications ───────────────────────────────────────
        # `?unread=true&kind=...&page=1&per_page=20`; always newest first.
        get "/Api/notifications" do |env|
          handle_list(env)
        end

        # ── GET /Api/notifications/unread_count ──────────────────────────
        get "/Api/notifications/unread_count" do |env|
          handle_unread_count(env)
        end

        # ── POST /Api/notifications/read_all ─────────────────────────────
        post "/Api/notifications/read_all" do |env|
          handle_read_all(env)
        end

        # ── POST /Api/notifications/:id/read ─────────────────────────────
        post "/Api/notifications/:id/read" do |env|
          handle_read(env, env.params.url["id"])
        end

        # ── POST /Api/notifications/:id/actions/:key ─────────────────────
        # Dispatches the named doctype action on the notification's source
        # document under the recipient's RBAC context. A successful action
        # marks the notification as read (decision 10).
        post "/Api/notifications/:id/actions/:key" do |env|
          handle_action(env, env.params.url["id"], env.params.url["key"])
        end
      end

      # ── Route handlers ───────────────────────────────────────

      private def self.handle_list(env) : Nil
        account_id = Facet::HTTP::Helpers.require_account(env)
        return if account_id.nil?

        only_unread = env.params.query["unread"]? == "true"
        kind = env.params.query["kind"]?
        kind = nil if kind.try(&.empty?)

        page = int_query_param(env, "page", 1)
        per_page = int_query_param(env, "per_page", List::DEFAULT_PER_PAGE)
        if page.nil? || per_page.nil? || page < 1
          Facet::HTTP::Helpers.error_response(env, 422, "page and per_page must be positive integers")
          return
        end

        items, count, more = Database.with_db(:read_only) do |db|
          List.list(db, account_id, only_unread: only_unread, kind: kind,
            page: page, per_page: per_page)
        end

        Facet::HTTP::Helpers.write_json(env, 200, list_body(items, count, more))
      end

      private def self.handle_unread_count(env) : Nil
        account_id = Facet::HTTP::Helpers.require_account(env)
        return if account_id.nil?

        count = Database.with_db(:read_only) do |db|
          List.unread_count(db, account_id)
        end

        Facet::HTTP::Helpers.write_json(env, 200, {count: count})
      end

      private def self.handle_read_all(env) : Nil
        account_id = authorized_account(env)
        return if account_id.nil?

        marked = Database.with_db do |db|
          MarkRead.mark_all_read(db, account_id)
        end

        Facet::HTTP::Helpers.write_json(env, 200, {marked: marked})
      end

      private def self.handle_read(env, id : String) : Nil
        account_id = authorized_account(env)
        return if account_id.nil?

        # `mark_read` only transitions an unread owned row; the follow-up
        # select renders the resulting `read_at` — the first one, preserved
        # on an idempotent re-mark — and doubles as the 404 discriminator
        # for an unknown or not-owned id.
        read_at = Database.with_db do |db|
          MarkRead.mark_read(db, account_id, id)
          fetch_owned_read_at(db, account_id, id)
        end

        if read_at.nil?
          Facet::HTTP::Helpers.error_response(env, 404, "Not found")
          return
        end

        Facet::HTTP::Helpers.write_json(env, 200, {id: id, read_at: read_at.to_rfc3339})
      end

      private def self.handle_action(env, id : String, key : String) : Nil
        account_id = authorized_account(env)
        return if account_id.nil?

        args = parse_args(env)
        return if args.nil?

        begin
          result = Database.with_db do |db|
            InvokeAction.invoke_action(
              db, account_id, id, key, Facet::HTTP::Helpers.auth_context(env), args)
          end
        rescue ex : InvokeAction::Error
          Facet::HTTP::Helpers.error_response(env, ex.status, ex.message.to_s, ex.details)
          return
        rescue ex : RBAC::Error
          Facet::HTTP::Helpers.error_response(env, ex.status, ex.message.to_s)
          return
        end

        Facet::HTTP::Helpers.write_json(env, 200,
          {result: result.result, read_at: result.read_at.to_rfc3339, actioned_at: result.actioned_at.to_rfc3339})
      end

      # ── Private helpers ──────────────────────────────────────────

      # POST routes: CSRF check first (403 without the header), then auth
      # (401 without a token). Both gates write their own shared error
      # response.
      private def self.authorized_account(env) : String?
        return nil unless Facet::HTTP::Helpers.require_csrf(env)

        Facet::HTTP::Helpers.require_account(env)
      end

      # Reads an integer query parameter, or `nil` when present but not an
      # integer. `default` applies when the parameter is absent or empty.
      private def self.int_query_param(env, name : String, default : Int32) : Int32?
        raw = env.params.query[name]?
        return default if raw.nil? || raw.empty?
        raw.to_i?
      end

      # The action body is an optional argument object, passed to
      # `Document::Action` verbatim — normalized and validated there.
      # An empty body dispatches with an empty argument object.
      private def self.parse_args(env) : JSON::Any?
        body = env.request.body.try(&.gets_to_end)
        return JSON::Any.new({} of String => JSON::Any) if body.nil? || body.empty?

        JSON.parse(body)
      rescue ex : JSON::ParseException
        Facet::HTTP::Helpers.error_response(env, 422, "Invalid JSON: #{ex.message}")
        nil
      end

      private def self.fetch_owned_read_at(
        db : DB::Connection,
        account_id : String,
        id : String,
      ) : Time?
        db.query_one?(
          "SELECT read_at FROM notifications WHERE account_id = $1 AND id = $2",
          account_id, id,
        ) { |rs| rs.read(Time?) }
      end

      private def self.list_body(items : Array(Item), count : Int32, more : Bool) : String
        {
          data: items.map { |item| item_payload(item) },
          meta: {count: count, more: more},
        }.to_json
      end

      private def self.item_payload(item : Item)
        {
          id:          item.id,
          account_id:  item.account_id,
          domain:      item.domain,
          doc_type:    item.doc_type,
          doc_id:      item.doc_id,
          kind:        item.kind,
          icon:        item.icon,
          title:       item.title,
          body:        item.body,
          data:        item.data,
          actions:     item.actions.map { |action| action_payload(action) },
          read_at:     item.read_at.try(&.to_rfc3339),
          actioned_at: item.actioned_at.try(&.to_rfc3339),
          created_at:  item.created_at.to_rfc3339,
        }
      end

      # `variant` / `confirm` are omitted when absent — the same shape
      # `Send` writes.
      private def self.action_payload(action : Action)
        payload = {key: action.key, label: action.label}
        payload = payload.merge({variant: action.variant}) if action.variant
        payload = payload.merge({confirm: action.confirm}) if action.confirm
        payload
      end
    end
  end
end
