# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "./send"
require "../document/uri"

module Facet
  module Notification
    # One validated notification staged by a producer (the Lua
    # `notification.send` helper today) that is not yet inserted.
    #
    # All argument conversion happened at enqueue time — the producer's
    # Lua stack is gone by drain time — so a `Pending` is fully
    # self-contained. `doc_ref` is `nil` for "this context's document"
    # (resolved at drain time by the owning flow) and a qualified
    # `{domain}.{Doctype}.{id}` string otherwise.
    record Pending,
      account_id : String,
      kind : String,
      title : String,
      icon : String?,
      body : String,
      data : JSON::Any,
      actions : Array(Action),
      doc_ref : String?

    # Deferred write path for notifications: producers validate and
    # enqueue at send time; the owning operation drains the queue after
    # its mutation persists.
    #
    # Notifications are low-quality data: a lost notification is
    # acceptable, a notification that breaks a business mutation is not.
    # Two invariants follow:
    #
    # - **Enqueue validates synchronously.** Malformed input raises
    #   `ArgumentError` before anything is staged — the producer (a Lua
    #   script) learns about the mistake at send time and can catch it
    #   with `pcall` or let it fail the operation.
    # - **Drain failures are logged and dropped.** A drain insert runs
    #   inside `Database.with_transaction` — its own transaction
    #   standalone, a savepoint inside an ambient transaction — so one
    #   failed notification never aborts the already-persisted mutation
    #   or its sibling notifications.
    module Queue
      Log = ::Log.for("facet.notifications")

      # Validates one notification and appends it to the queue. Nothing
      # is inserted — the row materializes at drain time.
      #
      # Runs the authoritative field validation (`Send.validate!`), the
      # `doc_ref` format check, and a cheap account existence check, so a
      # typo'd account id surfaces as a synchronous `ArgumentError` instead
      # of a silent drain drop.
      #
      # Raises `ArgumentError` on any malformed input.
      def self.enqueue(
        queue : Array(Pending),
        db : DB::Connection,
        account_id : String,
        kind : String,
        title : String,
        icon : String? = nil,
        body : String = "",
        data : JSON::Any = JSON::Any.new({} of String => JSON::Any),
        actions : Array(Action) = [] of Action,
        doc_ref : String? = nil,
      ) : Pending
        Send.validate!(account_id, kind, title, icon, actions)
        validate_doc_ref!(doc_ref)

        unless auth_account_exists?(db, account_id)
          raise ArgumentError.new(
            "Notification account_id #{account_id.inspect} does not match an existing account"
          )
        end

        pending = Pending.new(
          account_id: account_id,
          kind: kind,
          title: title,
          icon: icon,
          body: body,
          data: data,
          actions: actions,
          doc_ref: doc_ref,
        )
        queue << pending
        pending
      end

      # Applies a drained queue: inserts each entry through `Send.send`,
      # the single write path, resolving `doc_ref = nil` entries against
      # the owning operation's coordinates.
      #
      # `self_doc_id` is the document id the enqueueing operation just
      # persisted (`nil` never happens for a wired flow; a `nil` with a
      # pending self entry is logged and dropped like any other drain
      # failure). Each insert runs inside `Database.with_transaction(db)`
      # — standalone its own transaction, nested a savepoint — so a
      # failed entry is logged, dropped, and the queue continues.
      def self.drain(
        db : DB::Connection,
        pending : Array(Pending),
        domain : String,
        doc_type : String,
        self_doc_id : String?,
      ) : Nil
        pending.each do |entry|
          begin
            n_domain, n_doc_type, n_doc_id = resolve(entry, domain, doc_type, self_doc_id)
            Database.with_transaction(db) do
              Send.send(
                db, entry.account_id, n_domain, n_doc_type, n_doc_id,
                entry.kind, entry.title,
                icon: entry.icon, body: entry.body, data: entry.data,
                actions: entry.actions,
              )
            end
          rescue ex : Exception
            Log.warn do
              "notification drain failed for account #{entry.account_id}, " \
              "kind #{entry.kind.inspect}: #{ex.message} — dropped"
            end
          end
        end
      end

      # ── Private ──────────────────────────────────────────────────────

      # Rejects a malformed `doc_ref` at enqueue time. `nil` means "this
      # context's document" and is resolved at drain. A bare id without
      # the `domain.Doctype` prefix is rejected so the producer is
      # explicit about all three coordinates.
      private def self.validate_doc_ref!(doc_ref : String?) : Nil
        return if doc_ref.nil?
        unless doc_ref.count('.') >= 2
          raise ArgumentError.new(
            "Notification doc_ref #{doc_ref.inspect} must be qualified as {domain}.{Doctype}.{id}"
          )
        end
        uri = Document::DocURI.parse(doc_ref)
        if uri.nil? || !uri.valid?
          raise ArgumentError.new(
            "Notification doc_ref #{doc_ref.inspect} is not a valid document reference"
          )
        end
      end

      # Cheap indexed existence check against the `iam.Account` projections
      # — the account a notification points at must be a live document.
      private def self.auth_account_exists?(db : DB::Connection, account_id : String) : Bool
        !db.query_one?(
          "SELECT 1 FROM projections WHERE domain = 'iam' AND doc_type = 'Account' " \
          "AND id = $1 AND deleted_at IS NULL",
          account_id, as: Int32).nil?
      end

      # Resolves one entry's `(domain, doc_type, doc_id)` coordinates.
      # A `doc_ref` was format-validated at enqueue; a parse failure
      # here is a defect and surfaces as a drain drop like any other
      # failure.
      private def self.resolve(
        entry : Pending,
        domain : String,
        doc_type : String,
        self_doc_id : String?,
      ) : {String, String, String}
        if ref = entry.doc_ref
          uri = Document::DocURI.parse(ref)
          raise ArgumentError.new("Notification doc_ref #{ref.inspect} is not a valid document reference") if uri.nil?
          {uri.domain, uri.doctype, uri.opaque}
        else
          raise ArgumentError.new("Notification doc_ref is nil but no self document id was supplied") if self_doc_id.nil?
          {domain, doc_type, self_doc_id}
        end
      end
    end
  end
end
