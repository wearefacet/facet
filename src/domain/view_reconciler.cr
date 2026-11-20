# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Domain
    # Converges a live set of definition-owned view rows to a desired set,
    # matched by `kind`. One algorithm behind the two flows that reconcile
    # `core.DocumentView` rows:
    #
    # - `Domain::Publish` — draft views → live domain (overwrite publish).
    # - `Domain::Portable::Import` — bundled views → target domain (merge).
    #
    # The caller owns persistence and equality: it supplies the live rows,
    # the desired payloads, and the `create` / `update` / `delete` /
    # `equal` callbacks. The reconciler owns the convergence:
    #
    # - Desired kind absent from live → `create`.
    # - Desired kind present, contents differ (per `equal`) → `update`
    #   in place.
    # - Desired kind present, contents identical → untouched.
    # - Live kind not desired → `delete` (when `delete_unmatched`).
    #
    # Upserts run before deletes: a live row is only removed after every
    # desired row had its chance to claim its kind. Returns the operation
    # counts so callers can feed their own stats.
    #
    # CollectionViews are out of scope — they are live-authored, so import
    # only upserts them by `name` and publish never touches them.
    module ViewReconciler
      # One live row. `kind` is `nil` when the stored row carries no kind —
      # such a row never matches a desired kind.
      record Live,
        id : String,
        kind : String?,
        content : JSON::Any

      # One desired row. `meta` carries caller metadata for the create
      # path (import remaps `meta.parent_id`; publish ignores it).
      record Desired,
        kind : String,
        content : JSON::Any,
        meta : JSON::Any

      # Persistence callbacks.
      #
      # - `equal(live_content, desired_content)` — true when the live row
      #   already carries the desired state.
      # - `create(kind, content, meta)` — persists a new row.
      # - `update(id, live_content, desired_content)` — rewrites a row in
      #   place; returns `true` when a mutation was written.
      # - `delete(id)` — soft-deletes a live row.
      record Ops,
        equal : Proc(JSON::Any, JSON::Any, Bool),
        create : Proc(String, JSON::Any, JSON::Any, Nil),
        update : Proc(String, JSON::Any, JSON::Any, Bool),
        delete : Proc(String, Nil)

      # Converges the live set to the desired set. Returns
      # `{created, updated, deleted}`.
      def self.converge(
        live : Array(Live),
        desired : Array(Desired),
        ops : Ops,
        *,
        delete_unmatched : Bool = true,
      ) : {Int32, Int32, Int32}
        created = updated = deleted = 0
        live_by_kind = live.to_h { |row| {row.kind, row} }

        desired.each do |want|
          if existing = live_by_kind.delete(want.kind)
            next if ops.equal.call(existing.content, want.content)
            updated += 1 if ops.update.call(existing.id, existing.content, want.content)
          else
            ops.create.call(want.kind, want.content, want.meta)
            created += 1
          end
        end

        if delete_unmatched
          live_by_kind.each_value do |stale|
            ops.delete.call(stale.id)
            deleted += 1
          end
        end

        {created, updated, deleted}
      end
    end
  end
end
