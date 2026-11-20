# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"
require "../error"
require "../rbac"
require "../document/delete"
require "./qualified_ref"

module Facet
  # Shared tombstone routine for sidecar records.
  #
  # Two maintenance paths delete sidecars whose host document is gone:
  # `Event::Subscriber::SidecarSweep::Handler` (event-driven, per deleted
  # host event) and `Cron::SidecarReconcile` (periodic backstop). Both run
  # the same loop: find the live sidecar records whose reference column
  # points at the dead host, and soft-delete each one. This module is that
  # loop, shared.
  module Sidecars
    Log = ::Log.for("facet.sidecars")

    # Soft-deletes every live sidecar record of *sidecar_qualified* whose
    # reference column *column* equals *qualified_target*.
    #
    # The delete goes through `Document::Delete` (not a direct UPDATE) so
    # the projection trigger, the cascade-delete of owned children, and the
    # `deleted` event all fire with the correct semantics.
    # `Document::Delete.call` opens its own transaction when one is already
    # open, so the caller's connection suffices.
    #
    # - *actioner_id* — audit attribution (`system:sidecar-sweep` /
    #   `system:sidecar-reconcile`).
    # - *label* — prefixes the log lines (`Sweep` / `Reconcile`).
    #
    # Idempotent: an already-tombstoned record yields `410 Gone` and counts
    # as success (the desired end state has been reached). Returns the
    # number of records tombstoned by this call; 410s are not counted.
    #
    # The caller flushes `Event::Publisher` after its batch — both paths
    # run outside the HTTP layer.
    def self.tombstone_by_target(
      db : DB::Connection,
      sidecar_qualified : String,
      column : String,
      qualified_target : String,
      actioner_id : String,
      label : String,
    ) : Int32
      domain, doctype = Util::QualifiedRef.split_doctype(sidecar_qualified)

      sidecar_ids = db.query_all(
        <<-SQL,
          SELECT id FROM projections
          WHERE domain = $1 AND doc_type = $2
            AND content->>$3 = $4
            AND deleted_at IS NULL
        SQL
        domain, doctype, column, qualified_target,
        as: String,
      )

      tombstoned = 0
      sidecar_ids.each do |sidecar_id|
        result = Facet::Document::Delete.call(
          db, domain, doctype, sidecar_id,
          auth_context: Facet::RBAC::AuthContext.system,
          actioner_id: actioner_id,
        )
        case result
        in Facet::Document::Delete::Result
          tombstoned += 1
          Log.debug { "#{label} tombstoned #{domain}.#{doctype}##{sidecar_id} (target=#{qualified_target})" }
        in Facet::ServiceError
          # 410 Gone is the desired idempotent end state: a redelivered
          # event, or a rerun after an interrupted pass.
          if result.status == 410
            Log.debug { "#{label} no-op: #{domain}.#{doctype}##{sidecar_id} already tombstoned (target=#{qualified_target})" }
          else
            Log.warn { "#{label} could not tombstone #{domain}.#{doctype}##{sidecar_id}: #{result.status} #{result.message}" }
          end
        end
      end

      tombstoned
    end
  end
end
