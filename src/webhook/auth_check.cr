# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "pg"
require "../database"
require "../rbac"
require "../iam/helpers"

module Facet
  module Webhook
    # The enqueue-time authorization gate for webhook deliveries (decision 8).
    #
    # One code path, two callers:
    #
    # - `Webhook::Handler` runs it per binding on the event-stream fiber,
    #   before enqueueing a `webhook_delivery` job.
    # - the replay route (`Webhook::Routes`) runs it against the **original**
    #   source document before replaying a delivery — replay must never send
    #   a message on behalf of an identity that lost the read right
    #   (decision 9).
    #
    # The seven steps:
    #
    # 1. Read the live `core.Webhook` projection — `enabled`, `url`,
    #    `headers`, `secret`, and the bound `account_id` / `role_id`. All of
    #    it is read at gate time, so a toggle, delete, or unbinding between
    #    registry build and this call is caught here (decision 4).
    # 2. `enabled == true` (a stored NULL counts as enabled — the doctype
    #    default).
    # 3. The bound account exists, is not deleted (`load_role_ids` nil covers
    #    both), and `status == "active"`.
    # 4. The bound role is still assigned to the account. The stored
    #    `role_id` is the qualified reference (`iam.Roles.<name>`) — passed
    #    as-is.
    # 5. The bound role projection exists and is not deleted → the
    #    `ActiveRole` the check runs under. Its `connectivity` list
    #    must still carry the `webhook` channel (5b) — a role edited
    #    down to browser-only stops delivering at the next event.
    # 6. The bound role can read the event's subject. For the four
    #    import/export job lifecycle events the subject is a job id (not a
    #    projection), so the gate swaps to the source doctype's own
    #    `core.DocType` projection; for every other event it is the source
    #    document (`ReadEnforcer.authorized?`, context resolved fresh —
    #    no memoization across events or requests).
    # 7. Aggregate `child_changed` frames only: the bound role can also
    #    read the CHILD the frame names (the payload's `child` pointer).
    #    The subject of step 6 is the parent — the frame is keyed to it —
    #    but the payload is an envelope, not a document body, so this step
    #    makes the gate consistent with the two-rule read model. A missing
    #    or malformed child pointer fails closed.
    #
    # On any failure the caller logs and skips — no job row is produced, and
    # (for replay) the endpoint answers 422 with the skip reason.
    module AuthCheck
      Log = ::Log.for("facet.webhook.auth_check")

      # On a pass, carries the transport fields freshly read from the
      # `core.Webhook` projection (decision 4).
      record Pass, url : String, secret : String, headers : JSON::Any?

      enum SkipReason
        WebhookMissing
        Disabled
        MissingTransport
        Unbound
        AccountMissing
        AccountInactive
        RoleUnassigned
        RoleDeleted
        ChannelClosed
        SourceUnreadable
        ChildUnreadable
      end

      # Human-readable reason for the log line / replay error. A missing
      # member raises — a programmer error, not a runtime state.
      SKIP_LABELS = {
        SkipReason::WebhookMissing   => "webhook projection missing",
        SkipReason::Disabled         => "disabled",
        SkipReason::MissingTransport => "url or secret missing — signing impossible",
        SkipReason::Unbound          => "no bound account/role",
        SkipReason::AccountMissing   => "bound account missing or deleted",
        SkipReason::AccountInactive  => "bound account not active",
        SkipReason::RoleUnassigned   => "bound role not assigned to account",
        SkipReason::RoleDeleted      => "bound role missing or deleted",
        SkipReason::ChannelClosed    => "bound role's connectivity excludes the 'webhook' channel",
        SkipReason::SourceUnreadable => "source document not readable by bound role",
        SkipReason::ChildUnreadable  => "child document not readable by bound role",
      }

      def self.skip_label(reason : SkipReason) : String
        SKIP_LABELS[reason]
      end

      # Runs the seven-step check for one webhook. `source_*` identifies the
      # source document of the event — for replay, the original job's source
      # identity (decision 9). `event_name` selects a step-6 branch: a job
      # lifecycle event (`export_completed` etc.) has a job id as its
      # subject, which is not a projection row, so the gate is instead that
      # the bound role can read the source doctype's own `core.DocType`
      # projection — whoever may see the doctype may hear that a job over
      # it finished; the payload carries no row data. `content` is the
      # event payload: the handler passes the live message content, replay
      # passes the stored envelope. It feeds the step-7 child-visibility
      # gate for `child_changed` frames. Returns the fresh transport
      # fields when every step passes, otherwise the skip reason. No job
      # row is produced on any failure.
      def self.call(
        db : DB::Connection,
        webhook_id : String,
        source_domain : String,
        source_doc_type : String,
        source_id : String,
        event_name : String? = nil,
        content : JSON::Any? = nil,
      ) : Pass | SkipReason
        # 1 + 2. Fresh projection read + enabled gate. A toggle (or delete)
        #        between registry build and this event is caught here, and
        #        url / headers / secret are read at enqueue time per
        #        decision 4.
        row = read_webhook_projection(db, webhook_id)
        return SkipReason::WebhookMissing if row.nil?
        return SkipReason::Disabled unless row[:enabled] == "true"

        url = row[:url]
        secret = row[:secret]
        return SkipReason::MissingTransport if url.nil? || url.empty? || secret.nil? || secret.empty?

        # 3. The bound account exists, is not deleted, and is active. The
        #    identity comes from the projection, not from a registry
        #    binding: the fields are read-only after create, so registry and
        #    projection always agree, and reading them here lets the replay
        #    route run this exact gate without a registry round-trip.
        account_raw = row[:account_id]
        role_id = row[:role_id]
        account_id = resolve_bound_account(db, account_raw, role_id)
        return account_id if account_id.is_a?(SkipReason)

        # 5. The bound role projection exists and is not deleted → the
        #    ActiveRole the check runs under.
        role_content = IAM::Helpers.find_role_content(db, role_id.as(String))
        return SkipReason::RoleDeleted if role_content.nil?
        active_role = RBAC::ActiveRole.from_projection_content(role_content)

        # 5b. The bound role's connectivity must still carry the `webhook`
        #     channel. A role edited down to browser-only loses its webhook
        #     deliveries at the next event — derive, never mark. Fail
        #     closed: a missing or malformed list carries no channels.
        webhook_channels = role_content["connectivity"]?.try(&.as_a?)
        webhook_ok = webhook_channels.try(&.any?(&.as_s?.try(&.==("webhook")))) == true
        return SkipReason::ChannelClosed unless webhook_ok

        # 6. The bound role can read the event's subject. For a job
        #    lifecycle event the subject is a `background_jobs` row, not a
        #    projection — the gate swaps to the source doctype's own
        #    definition projection (`core.DocType`, id `{domain}.{doc_type}`).
        #    Otherwise the source document itself. The enforcer resolves
        #    context sets fresh on this call — no cross-event memoization
        #    (decision 8 step 6).
        auth_ctx = RBAC::AuthContext.authenticated(account_id, active_role)
        return SkipReason::SourceUnreadable unless subject_readable?(
                                                     db, source_domain, source_doc_type, source_id, event_name, auth_ctx,
                                                   )

        # 7. Aggregate child frames: the binding must also read the child
        #    the frame names. The pointer comes from the payload; a missing
        #    or malformed pointer fails closed.
        if reason = child_gate(db, source_domain, event_name, content, auth_ctx)
          return reason
        end

        Pass.new(url, secret, row[:headers])
      end

      # Steps 3 + 4: the bound account exists, is active, and still holds
      # the bound role. Returns the bare account id on success, the skip
      # reason otherwise.
      private def self.resolve_bound_account(
        db : DB::Connection,
        account_raw : String?,
        role_id : String?,
      ) : SkipReason | String
        return SkipReason::Unbound if account_raw.nil? || role_id.nil?

        account_id = unqualify_account(account_raw)
        return SkipReason::AccountMissing if RBAC::AccountLoader.load_role_ids(db, account_id).nil?
        return SkipReason::AccountInactive unless RBAC::AccountLoader.account_active?(db, account_id)

        # 4. The bound role is still assigned to the account.
        return SkipReason::RoleUnassigned unless RBAC::AccountLoader.role_assigned?(db, account_id, role_id)

        account_id
      end

      # The step-6 gate: a job lifecycle event's subject is a job id, so the
      # source doctype's definition projection stands in for it. Every other
      # event reads the source document itself.
      private def self.subject_readable?(
        db : DB::Connection,
        source_domain : String,
        source_doc_type : String,
        source_id : String,
        event_name : String?,
        auth_ctx : RBAC::AuthContext,
      ) : Bool
        if en = event_name
          if ::Facet::Event.job_lifecycle_event?(en)
            return RBAC::ReadEnforcer.authorized?(db, "core", "DocType", "#{source_domain}.#{source_doc_type}", auth_ctx)
          end
        end

        RBAC::ReadEnforcer.authorized?(db, source_domain, source_doc_type, source_id, auth_ctx)
      end

      # The step-7 gate for `child_changed`: the payload's `child` pointer
      # names the document the frame is really about. The child shares the
      # event's domain (owned children live in the parent's domain).
      # Returns the skip reason when the step fails, `nil` when the frame
      # passes — or when the event is not an aggregate child frame.
      private def self.child_gate(
        db : DB::Connection,
        domain : String,
        event_name : String?,
        content : JSON::Any?,
        auth_ctx : RBAC::AuthContext,
      ) : SkipReason?
        return nil unless event_name == ::Facet::Event::CHILD_CHANGED
        return SkipReason::ChildUnreadable unless child_readable?(db, domain, content, auth_ctx)

        nil
      end

      private def self.child_readable?(
        db : DB::Connection,
        domain : String,
        content : JSON::Any?,
        auth_ctx : RBAC::AuthContext,
      ) : Bool
        child = content.try(&.as_h?).try(&.["child"]?).try(&.as_h?)
        child_doc_type = child.try(&.["doc_type"]?).try(&.as_s?)
        child_doc_id = child.try(&.["doc_id"]?).try(&.as_s?)
        return false if child_doc_type.nil? || child_doc_id.nil?

        RBAC::ReadEnforcer.authorized?(db, domain, child_doc_type, child_doc_id, auth_ctx)
      end

      # ── Private ───────────────────────────────────────────────────────

      # Reads the live `core.Webhook` projection row. A tombstoned or absent
      # row returns nil — the webhook was deleted (or never existed).
      private def self.read_webhook_projection(db : DB::Connection, webhook_id : String)
        db.query_one?(
          <<-SQL,
            SELECT COALESCE(content->>'enabled', 'true') AS enabled,
                   content->>'url'                       AS url,
                   content->'headers'                    AS headers,
                   content->>'secret'                    AS secret,
                   content->>'account_id'                AS account_id,
                   content->>'role_id'                   AS role_id
            FROM projections
            WHERE domain = 'core' AND doc_type = 'Webhook' AND id = $1
              AND deleted_at IS NULL
          SQL
          webhook_id,
        ) do |rs|
          {
            enabled:    rs.read(String),
            url:        rs.read(String?),
            headers:    rs.read(JSON::Any?),
            secret:     rs.read(String?),
            account_id: rs.read(String?),
            role_id:    rs.read(String?),
          }
        end
      end

      # The projection stores the account reference in the fully qualified
      # storage form (`iam.Account.<id>` — see
      # `RBAC::PRINCIPAL_QUALIFIED_DOCTYPE`); `AccountLoader` expects the
      # bare projection id. A bare value passes through unchanged.
      private def self.unqualify_account(qualified : String) : String
        prefix = RBAC::PRINCIPAL_QUALIFIED_DOCTYPE.to_s + "."
        qualified.starts_with?(prefix) ? qualified[prefix.size..] : qualified
      end
    end
  end
end
