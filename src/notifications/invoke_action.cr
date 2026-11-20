# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../validation_error"
require "../rbac"
require "../event"
require "../http/helpers"
require "../document/action"

module Facet
  module Notification
    # Action execution for notifications: dispatch a named doctype action
    # on the notification's source document through `Document::Action`,
    # under the recipient's RBAC context.
    #
    # RBAC is enforced at execute time by `Document::Action` itself — a
    # notification action is not a privilege escalation (plan decision 10).
    # The producer can suggest an action, but the recipient can only fire
    # it if their own active role permits it on the source doctype. A
    # successful action marks the notification as read.
    module InvokeAction
      # Base error for notification-action failures. Carries the HTTP
      # status the caller (the `/Api/notifications` routes) renders, so
      # the route layer does not re-classify the failure.
      class Error < ::RuntimeError
        getter status : Int32
        getter details : Array(ValidationError)?

        def initialize(message : String, @status : Int32, @details : Array(ValidationError)? = nil)
          super(message)
        end
      end

      # 404 — the notification does not exist, is not owned by the caller,
      # or its source document is gone. Non-disclosing: all three cases
      # render identically.
      class NotFound < Error
        def initialize(message : String = "Not found")
          super(message, 404)
        end
      end

      # 422 — the notification carries no action descriptor with the
      # requested key. This includes the reserved `__read` dismiss key,
      # which never appears in `actions` (rejected at send time).
      class UnknownAction < Error
        def initialize(message : String)
          super(message, 422)
        end
      end

      # 409 — the notification already fired an action (its `actioned_at`
      # is set). Actions are one-shot: the first successful invocation
      # consumes every action on the notification, so a repeat click —
      # double-click, stale tab, replayed request — is rejected instead
      # of dispatching the mutation twice.
      class AlreadyActioned < Error
        def initialize(message : String = "Notification action already used")
          super(message, 409)
        end
      end

      # Outcome of invoking a notification action.
      #
      # `result` is the `Document::Action` return envelope — the same
      # `{data, meta}` shape `POST /Api/:domain/:doctype/:id/actions/:action`
      # returns. `read_at` is the read timestamp set by the successful
      # action (a pre-existing value is preserved — the user may have read
      # the notification before firing the action). `actioned_at` is the
      # one-shot marker set by the successful action — the frontend uses it
      # to disable the notification's action buttons.
      record InvokeResult, result : JSON::Any, read_at : Time, actioned_at : Time

      # Execute a notification action.
      #
      # Resolves the notification by `id`, verifies ownership
      # (`account_id == notification.account_id`), finds the action
      # descriptor with `action_key`, and dispatches the named action on
      # the source document `(domain, doc_type, doc_id)` through
      # `Document::Action` under the recipient's `RBAC::AuthContext` — the
      # same path `POST /Api/:domain/:doctype/:id/actions/:action` takes,
      # with the same projection lock. Actions are one-shot: the first
      # successful invocation sets `actioned_at` and consumes every action
      # on the notification — a later invocation raises `AlreadyActioned`.
      # On success, marks the notification as read and returns the action
      # result envelope + `read_at` + `actioned_at`.
      #
      # The dispatch runs in one transaction, so the action's mutation and
      # the read-mark commit together. Denials and action failures raise
      # only after the transaction commits, so a denied action's audit
      # side effects (the layer-1 denial event) are preserved.
      #
      # `account_id` is the bare `iam.Account` id — the same string the
      #   `notifications.account_id` column holds.
      # `auth` is the recipient's RBAC context.
      # `args` is the action argument object, passed to `Document::Action`
      #   verbatim (normalized and validated there).
      #
      # Raises `ArgumentError` on a blank `account_id`, `id`, or
      #   `action_key`.
      # Raises `NotFound` if the notification does not exist or is not
      #   owned by `account_id`.
      # Raises `AlreadyActioned` if the notification already fired an
      #   action (status 409 — the actions are consumed).
      # Raises `UnknownAction` if the notification has no action with the
      #   given key.
      # Raises `RBAC::NotAuthorized` if the recipient's active role lacks
      #   the named action permission on the source document.
      # Raises `Error` for any other `Document::Action` failure, carrying
      #   its status, message, and validation details.
      def self.invoke_action(
        db : DB::Connection,
        account_id : String,
        id : String,
        action_key : String,
        auth : RBAC::AuthContext,
        args : JSON::Any = JSON::Any.new({} of String => JSON::Any),
      ) : InvokeResult
        raise ArgumentError.new("Notification account_id is required") if account_id.blank?
        raise ArgumentError.new("Notification id is required") if id.blank?
        raise ArgumentError.new("Notification action key is required") if action_key.blank?

        outcome = Database.with_transaction(db) do |txn|
          resolve_and_dispatch(txn, account_id, id, action_key, auth, args)
        end

        case outcome
        in InvokeResult
          Event::Publisher.flush
          outcome
        in Facet::ServiceError
          if outcome.status == 403
            raise RBAC::NotAuthorized.new
          else
            raise Error.new(outcome.message, outcome.status, outcome.details)
          end
        end
      end

      # ── Private helpers ──────────────────────────────────────────────

      # The transaction body: resolve, check ownership, look up the
      # descriptor, lock the source document, dispatch. Raises `NotFound`
      # and `UnknownAction` before any write happens; otherwise returns
      # the dispatch outcome — a successful `InvokeResult` (read-mark
      # applied) or the action's `ServiceError` for post-commit
      # translation.
      private def self.resolve_and_dispatch(
        txn : DB::Connection,
        account_id : String,
        id : String,
        action_key : String,
        auth : RBAC::AuthContext,
        args : JSON::Any,
      ) : InvokeResult | Facet::ServiceError
        row = fetch_notification(txn, id)
        raise NotFound.new unless row
        raise NotFound.new unless row[:account_id] == account_id
        raise AlreadyActioned.new if row[:actioned_at]

        unless has_action?(row[:actions], action_key)
          raise UnknownAction.new("Notification has no action '#{action_key}'")
        end

        domain = row[:domain]
        doc_type = row[:doc_type]
        doc_id = row[:doc_id]

        # Lock the source document — the same lock-then-dispatch sequence
        # the direct action route takes.
        raise NotFound.new unless Facet::HTTP::Helpers.lock_projection_for_update(txn, domain, doc_type, doc_id)

        result = Facet::Document::Action.call(txn, domain, doc_type, doc_id, action_key, args.to_json, auth)
        if result.is_a?(Facet::Document::Action::Result)
          read_at, actioned_at = mark_actioned(txn, account_id, id)
          InvokeResult.new(action_envelope(result), read_at, actioned_at)
        else
          result
        end
      end

      # Fetches the columns an action dispatch needs. Ownership is checked
      # by the caller, so a not-owned row and a missing row fail the same.
      private def self.fetch_notification(txn : DB::Connection, id : String)
        txn.query_one?(
          "SELECT account_id, domain, doc_type, doc_id, actions, actioned_at
           FROM notifications WHERE id = $1",
          id,
        ) do |rs|
          {
            account_id:  rs.read(String),
            domain:      rs.read(String),
            doc_type:    rs.read(String),
            doc_id:      rs.read(String),
            actions:     rs.read(JSON::Any),
            actioned_at: rs.read(Time?),
          }
        end
      end

      private def self.has_action?(actions : JSON::Any, key : String) : Bool
        actions.as_a.any? { |entry| entry["key"]?.try(&.as_s) == key }
      end

      # Marks the notification read and stamps the one-shot `actioned_at`
      # on action success. Idempotent on `read_at`: a pre-existing value is
      # preserved, so re-running does not move the dismissal timestamp —
      # but the one-shot guard rejects a re-run before this point.
      private def self.mark_actioned(txn : DB::Connection, account_id : String, id : String) : {Time, Time}
        txn.query_one(
          "UPDATE notifications
           SET read_at = COALESCE(read_at, now()), actioned_at = COALESCE(actioned_at, now())
           WHERE id = $1 AND account_id = $2
           RETURNING read_at, actioned_at",
          id, account_id,
        ) { |rs| {rs.read(Time), rs.read(Time)} }
      end

      # Builds the `{data, meta}` envelope the direct action route
      # returns, via the shared document-meta builder.
      private def self.action_envelope(result : Facet::Document::Action::Result) : JSON::Any
        JSON.parse({
          "data" => result.projection.content,
          "meta" => Facet::HTTP::Helpers.document_meta(result.projection, mutation_id: result.mutation_id),
        }.to_json)
      end
    end
  end
end
