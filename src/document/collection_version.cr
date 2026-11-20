# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"

module Facet
  module Document
    # Collection-version ETag validators. Each method returns the highest
    # `updated_at` over one scope of a doctype; the HTTP layer serializes it
    # as the collection ETag. See `doc/backend/http-layer.md` → HTTP Caching.
    module CollectionVersion
      # Returns the highest `updated_at` across *all* rows of the given
      # doctype — live + tombstoned. Used by the HTTP layer to compute a
      # collection ETag (see `HTTP::Helpers.set_etag_header` and
      # `doc/backend/http-layer.md` → HTTP Caching).
      #
      # Served by `idx_projections_doctype_updated_at` as an index-only backward
      # scan — O(log n) per doctype, no heap fetch, no `deleted_at` filter.
      # Includes tombstones on purpose: a soft-delete writes a new mutation that
      # bumps the tombstone row's `updated_at`, so `max(updated_at)` bumps on
      # delete and busts stale collection caches.
      #
      # `updated_at` (microsecond resolution) is preferred over the projection
      # `state` (mutation ULID) as the collection validator: the ULID random
      # suffix is freshly sampled per call, so `max(state)` is non-monotonic
      # across same-millisecond mutations and can fail to bump on a real data
      # change (false 304). Document IDs are also user-selectable, so any
      # id-derived signal would be unsafe as a version. `updated_at` is set
      # to `mutation.emitted_at` by the projection trigger on every mutation
      # (create/update/delete/snapshot/rollback).
      #
      # Returns `nil` when the doctype has no rows at all.
      def self.collection_version(db : DB::Connection, domain : String, doc_type : String) : Time?
        max_updated_at(db, domain, doc_type)
      end

      # Parent-scoped variant of `collection_version` for nested child list
      # routes: the highest `updated_at` across the rows of the given doctype
      # (live + tombstoned) whose `meta->>'parent_id'` equals `parent_id`, so
      # the `GET /Api/:domain/:doctype/:id/:rel` ETag bumps only when the
      # children of THAT parent change (see `doc/backend/http-layer.md` →
      # HTTP Caching).
      #
      # Tombstones keep `meta` (only `content`/`links`/`search` are cleared on
      # delete), so a soft-deleted child still matches the parent filter and
      # the validator still bumps on delete. Served by
      # `idx_projections_parent_updated_at` as an index-only backward scan —
      # O(log n) per parent, no heap fetch.
      #
      # Returns `nil` when the parent has no children at all.
      def self.child_collection_version(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        parent_id : String,
      ) : Time?
        max_updated_at(db, domain, doc_type, "meta->>'parent_id' = $3", [parent_id])
      end

      # Sidecar-scoped variant of `collection_version`: the highest
      # `updated_at` across the live rows of the given doctype whose
      # `content->>'{column}'` equals `value` (the sidecar `target` reference
      # URN), so the `GET /Api/:domain/:doctype/:id/:sidecar` ETag bumps only
      # when the sidecars of THAT host change.
      #
      # Tombstones are included WITHOUT the content filter: `delete` clears
      # `content`, so a tombstoned sidecar no longer carries its `target`
      # and cannot be matched to its host. Including every tombstone of the
      # doctype keeps the validator correct (a delete must bust the cache) at
      # the cost of precision — a soft-deleted sidecar busts the tag of every
      # host listing that doctype, not only its own host's.
      #
      # `column` comes from the published doctype definition (the sidecar's
      # declared reference field) — the same trust level as the sort
      # expression interpolation in `sort_expression_for`.
      #
      # Returns `nil` when the host has no sidecars and the doctype has no
      # tombstones.
      def self.sidecar_collection_version(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        column : String,
        value : String,
      ) : Time?
        max_updated_at(
          db, domain, doc_type,
          "((deleted_at IS NULL AND content->>'#{column}' = $3)\n       OR deleted_at IS NOT NULL)",
          [value],
        )
      end

      # Highest `updated_at` over the rows of one doctype, optionally
      # narrowed by an extra predicate. Shared by the three collection
      # version validators. `extra_where` may reference `$3` and later
      # placeholders, bound from `params` in order.
      private def self.max_updated_at(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        extra_where : String? = nil,
        params : Array(::DB::Any) = [] of ::DB::Any,
      ) : Time?
        sql = String.build do |io|
          io << "SELECT max(updated_at) FROM projections\n"
          io << "WHERE domain = $1 AND doc_type = $2\n"
          io << "  AND #{extra_where}\n" if extra_where
        end
        args = [domain, doc_type] of ::DB::Any
        args.concat(params)
        db.query_one?(sql, args: args) do |rs|
          rs.read(Time?)
        end
      end
    end
  end
end
