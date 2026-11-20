# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../event/publisher"
require "../util/script_helpers"

module Facet
  module Notification
    # Result of a send call.
    record SendResult, id : String, created_at : Time

    # One action descriptor attached to a notification.
    #
    # Every descriptor is a named doctype action on the notification's
    # source document (the `domain` / `doc_type` / `doc_id` columns on the
    # notification row). The descriptor does not repeat the document
    # reference — the notification row is the single source of truth for
    # "which document". Navigation to the document is an implicit
    # capability of every notification and is not modelled as a descriptor.
    #
    # `key` is executed via `POST /Api/notifications/:id/actions/:key`
    # (dispatched through `Document::Action`). `__`-prefixed keys are
    # reserved — `__read` is the dismiss control and lives only on the
    # HTTP route — and are rejected at send time. `variant` is a
    # free-form visual hint ("primary", "danger", …). `confirm` is an
    # optional confirmation prompt string shown by the frontend before
    # firing the action.
    record Action,
      key : String,
      label : String,
      variant : String? = nil,
      confirm : String? = nil

    # The single write path for notifications: insert one row.
    #
    # Every producer — the Lua `notification.send` helper today, the
    # watch/mention producers later — goes through this module, so the
    # field validation and the reserved-key rule live here and cannot be
    # bypassed.
    module Send
      KIND_MAX  =  64
      ICON_MAX  =  32
      TITLE_MAX = 256

      # Insert one notification row. Returns the new id + `created_at`.
      #
      # `account_id` is the bare `iam.Account` id — not a qualified reference.
      # `domain`, `doc_type`, `doc_id` identify the source document the
      #   notification points at — the frontend routes a click back to it.
      # `kind` is a free-form discriminator (max 64 chars).
      # `icon` is an optional icon name (max 32 chars, may be null).
      # `title` is required (max 256 chars).
      # `body` is optional (defaults to empty string).
      # `data` is optional structured context (defaults to empty object).
      # `actions` is an optional array of `Action` descriptors (defaults
      #   to empty — an informational notification with no inline
      #   buttons).
      #
      # Raises `ArgumentError` on a missing/blank `account_id`, `kind`,
      #   or `title`, on an oversized `kind` / `icon` / `title`, or on a
      #   `__`-prefixed action key.
      # Raises the raw driver error (`PQ::PQError`) when the insert fails
      #   at the database level (e.g. a column overflow) — the failure is
      #   deliberately not wrapped so it keeps its PG provenance. Account
      #   existence is enforced at enqueue time (`Queue.enqueue`), not
      #   here.
      def self.send(
        db : DB::Connection,
        account_id : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        kind : String,
        title : String,
        icon : String? = nil,
        body : String = "",
        data : JSON::Any = JSON::Any.new({} of String => JSON::Any),
        actions : Array(Action) = [] of Action,
      ) : SendResult
        validate!(account_id, kind, title, icon, actions)

        id = Util::ScriptHelpers.ulid
        created_at = db.query_one(
          "INSERT INTO notifications
             (id, account_id, domain, doc_type, doc_id, kind, icon, title, body, data, actions)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
           RETURNING created_at",
          id, account_id, domain, doc_type, doc_id, kind, icon, title, body,
          data.to_json, serialize_actions(actions),
        ) { |rs| rs.read(Time) }

        enqueue_event(id, account_id, domain, doc_type, doc_id, kind, icon,
          title, body, data, actions, created_at)

        SendResult.new(id, created_at)
      end

      # The authoritative field validation for a notification. Public —
      # the deferred queue (`Notification::Queue.enqueue`) calls it at
      # enqueue time, before anything is staged.
      def self.validate!(
        account_id : String,
        kind : String,
        title : String,
        icon : String?,
        actions : Array(Action),
      ) : Nil
        raise ArgumentError.new("Notification account_id is required") if account_id.blank?
        raise ArgumentError.new("Notification kind is required") if kind.blank?
        raise ArgumentError.new("Notification kind exceeds #{KIND_MAX} characters") if kind.size > KIND_MAX
        raise ArgumentError.new("Notification title is required") if title.blank?
        raise ArgumentError.new("Notification title exceeds #{TITLE_MAX} characters") if title.size > TITLE_MAX
        unless icon.nil?
          raise ArgumentError.new("Notification icon exceeds #{ICON_MAX} characters") if icon.size > ICON_MAX
        end

        actions.each do |action|
          raise ArgumentError.new("Notification action key is required") if action.key.blank?
          if action.key.starts_with?("__")
            raise ArgumentError.new(
              "Notification action key #{action.key.inspect} uses the reserved __ prefix " \
              "(dismiss is a route, not a descriptor)"
            )
          end
        end
      end

      # Enqueue the `notified` event on the fiber-local publisher queue.
      # `Send` always runs inside the owning operation's transaction, so a
      # rollback discards the event and the HTTP layer (or the owning
      # flow) flushes it after commit.
      #
      # The event rides the **source document's** stream — webhooks bind
      # to a doctype, and the six-step `AuthCheck` authorizes against the
      # source projection. The fanout goes **only** to the recipient's own
      # `fanout:notifications:{account_id}` channel: a notification is
      # private to its recipient, so it must not land on the document
      # fanout channel where any watcher of the document would read it.
      private def self.enqueue_event(
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
        created_at : Time,
      ) : Nil
        payload = {
          "id"           => JSON::Any.new(doc_id),
          "notification" => JSON::Any.new({
            "notification_id" => JSON::Any.new(id),
            "account_id"      => JSON::Any.new(account_id),
            "domain"          => JSON::Any.new(domain),
            "doc_type"        => JSON::Any.new(doc_type),
            "doc_id"          => JSON::Any.new(doc_id),
            "kind"            => JSON::Any.new(kind),
            "icon"            => JSON::Any.new(icon),
            "title"           => JSON::Any.new(title),
            "body"            => JSON::Any.new(body),
            "data"            => data,
            "actions"         => JSON.parse(serialize_actions(actions)),
            "created_at"      => JSON::Any.new(created_at.to_rfc3339),
          } of String => JSON::Any),
        }

        Event::Publisher.enqueue(
          domain: domain,
          doc_type: doc_type,
          doc_id: doc_id,
          event: Event::NOTIFIED,
          actioner_id: "system",
          payload: payload,
          fanout_channels: [Event.notifications_fanout_channel(account_id)],
        )
      end

      private def self.serialize_actions(actions : Array(Action)) : String
        JSON.build do |json|
          json.array do
            actions.each do |action|
              json.object do
                json.field("key", action.key)
                json.field("label", action.label)
                json.field("variant", action.variant) if action.variant
                json.field("confirm", action.confirm) if action.confirm
              end
            end
          end
        end
      end
    end
  end
end
