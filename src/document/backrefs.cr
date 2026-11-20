# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../error"
require "../rbac"
require "./read"
require "./uri"

module Facet
  module Document
    # Service answering the inverse of the `links` column: which live
    # documents point at X?
    #
    # Every projection row carries `links` — the canonical `urn:facet:…`
    # URNs the document references (see `doc/backend/links.md`). The inverse
    # query runs per readable doctype over the partial GIN index
    # `idx_projections_links_gin` (`links @> '["<target urn>"]'`), with each
    # doctype's list scope AND-composed, so a referrer row can never leak
    # past the caller's list visibility.
    #
    # The target read gate runs first: a missing, tombstoned, or denied
    # target is one `NotFound` for a grant holder who cannot see it (the
    # `Document::Read` 404 contract — an inaccessible target is
    # indistinguishable from a missing one) and one `403` for a caller
    # with no read grant on the target doctype at all (the class-level
    # denial `Document::Read` answers with).
    #
    # Match is on the exact URN string: a `?state=`-pinned link is a
    # distinct reference from a link to the live document. Tombstoned
    # referrers are excluded by the partial index; `deleted_at IS NULL`
    # stays in the query for clarity.
    #
    # Pure read: no mutation, no events. Serves the MCP `get_backrefs` tool
    # and the HTTP `GET|QUERY /Api/:domain/:doctype/:id/backrefs` endpoint.
    module Backrefs
      # One referring document, in the stub-row shape the relation surfaces
      # already consume.
      record Item,
        id : String,
        domain : String,
        doc_type : String,
        display_name : String?

      record Result,
        items : Array(Item),
        target_urn : String,
        capped : Bool

      # Returns the live documents whose `links` contain the target's URN,
      # stopped at `limit` with `capped` set when the result set reaches it.
      # A failed target gate returns the `Facet::ServiceError` to surface.
      def self.call(
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        domain : String,
        doc_type : String,
        doc_id : String,
        limit : Int32 = 100,
      ) : Result | Facet::ServiceError
        # Target gate first — a grant holder that cannot see the target
        # (404) and a caller with no read grant on the doctype at all
        # (403) take their answers from the `Document::Read` contract.
        read_result = Read.call(db, domain, doc_type, doc_id, auth_context)
        return read_result if read_result.is_a?(Facet::ServiceError)

        target_urn = DocURI.from_projection_id(domain, doc_type, doc_id).to_s
        needle = JSON::Any.new([JSON::Any.new(target_urn)]).to_json

        items = [] of Item
        RBAC::ReadEnforcer.readable_doctypes(db, auth_context).each do |(ref_domain, ref_doctype)|
          break if items.size >= limit
          items.concat(backrefs_of_doctype(db, auth_context, ref_domain, ref_doctype, needle, limit - items.size))
        end

        Result.new(items: items, target_urn: target_urn, capped: limit > 0 && items.size >= limit)
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Runs the per-doctype backref query. The scope clauses start at
      # placeholder 4 (after domain, doc_type, and the URN needle).
      private def self.backrefs_of_doctype(
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        ref_domain : String,
        ref_doctype : String,
        needle : String,
        limit : Int32,
      ) : Array(Item)
        return [] of Item if limit <= 0

        scope_clauses, scope_params = RBAC::ReadEnforcer.list_where_clauses(
          db, ref_domain, ref_doctype, auth_context, start_idx: 4
        )
        where = String.build do |sql|
          sql << "domain = $1 AND doc_type = $2 AND deleted_at IS NULL AND links @> $3::jsonb"
          scope_clauses.each { |clause| sql << " AND " << clause }
        end
        params = [ref_domain, ref_doctype, needle] of ::DB::Any
        params.concat(scope_params)

        rows = db.query_all(
          "SELECT id, doc_type, domain, display_name FROM projections WHERE #{where} ORDER BY id ASC LIMIT #{limit}",
          args: params,
          as: {String, String, String, String?},
        )
        rows.map do |(id, doc_type, dom, display_name)|
          # Always present — null when the doctype declares no template
          # (same shape as the other stub rows).
          Item.new(id: id, domain: dom, doc_type: doc_type, display_name: display_name)
        end
      end
    end
  end
end
