# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "digest/sha256"
require "./list_request"
require "../rbac"

module Facet
  module HTTP
    # ── HTTP caching (ETag) ───────────────────────────────────────────
    #
    # Two flavors of validators are emitted:
    #
    # - **Single-document reads** (`GET /Api/:domain/:doctype/:id` and
    #   nested child reads under `/Api/:domain/:doctype/:id/:rel/...`):
    #   the ETag is the projection's `state` (the ULID of the last
    #   mutation applied). It strictly identifies the served content —
    #   any mutation (create/update/delete/rollback) produces a new
    #   `state`, so a stale client `If-None-Match` never yields a
    #   phantom 304. The top-level route emits it inline; nested child
    #   reads inherit it from the `Document::Read::Result` branch of
    #   `write_result`.
    #
    # - **Collection reads** (top-level `GET /Api/:domain/:doctype`,
    #   nested child lists `GET .../:id/:rel`, and sidecar lists
    #   `GET .../:id/:sidecar`): the ETag is composed of three parts
    #   joined by `:`:
    #     `<role_fingerprint>:<request_digest>:<version_tag>`
    #   where `version_tag` is `max(updated_at)` over the rows that back
    #   the listing (live + tombstoned — so deletes bump it), scoped to
    #   the whole doctype at the top level, to one parent's children on a
    #   child list, and to one host's sidecars on a sidecar list. The
    #   role fingerprint prevents a scope/permission change (same
    #   `max(updated_at)`) from serving a stale body, and the request
    #   digest ensures different request parameters do not coalesce. On a
    #   child list the only caller-supplied parameter is `aggregate`
    #   (page/items/sort/filters are fixed), so the digest is built from a
    #   minimal `ListRequest` carrying just that value; on a sidecar list
    #   every parameter is fixed by the path, so the digest slot holds the
    #   constant marker `sidecar`. Because the heavy items query is
    #   short-circuited on a 304, collection routes need not run the
    #   items query at all on cache hits — the only DB cost on a hit is
    #   the O(log n) `max(updated_at)` lookup served by
    #   `idx_projections_doctype_updated_at` (top level) or
    #   `idx_projections_parent_updated_at` (child lists).
    module Caching
      extend self

      # Sets the response `ETag` header.Quotes the tag per RFC 7232.
      def set_etag_header(env, tag : String) : Nil
        env.response.headers["ETag"] = "\"#{tag}\""
      end

      # Returns true when the request's `If-None-Match` header matches `tag`.
      # Handles `*`, quoted validators, and the weak `W/"..."` prefix
      # (weak ETags are treated as equivalent to strong for the purposes of
      # `If-None-Match`, since we only emit strong validators and any match
      # means a fresh-enough resource for a GET).
      def not_modified?(env, tag : String) : Bool
        header = env.request.headers["If-None-Match"]?
        return false if header.nil? || header.empty?

        candidates = header.split(',').map(&.strip)
        return true if candidates.includes?("*")

        quoted = "\"#{tag}\""
        candidates.any? do |c|
          # Strip the weak prefix `W/` and compare the quoted validator.
          c.lchop("W/") == quoted
        end
      end

      # Writes a 304 Not Modified response (no body). The `ETag` header is
      # also set so reverse proxies and the client see the validator that
      # produced the 304.
      def write_not_modified(env, tag : String) : Nil
        set_etag_header(env, tag)
        env.response.status_code = 304
        env.response.headers["Cache-Control"] = "no-cache"
      end

      # Builds a stable role fingerprint for inclusion in collection ETags.
      #
      # The role fingerprint prevents a stale collection body from being
      # served with a 304 after the *same* `max(state)` but a different
      # user/role — e.g. an admin's cached listing must not be served to a
      # scoped user, and a role whose permissions expanded must not get its
      # old listing back even if no document mutated.
      #
      # The preview principal carries no `ActiveRole` — the capability is
      # bound to one draft domain — so the fingerprint is the account and
      # the draft domain, under a distinct `preview:` prefix. The prefix
      # also keeps a preview tag from matching a real principal's
      # `<account_id>:<role_id>` tag.
      def role_fingerprint(auth_context : Facet::RBAC::AuthContext) : String
        case principal = auth_context.principal
        when Facet::RBAC::Principal::System
          "system:#{principal.account_id}"
        when Facet::RBAC::Principal::Preview
          "preview:#{principal.account_id}:#{principal.preview_domain}"
        when Facet::RBAC::Principal::Real
          "#{principal.account_id}:#{principal.active_role.role_id}"
        else
          # The Principal hierarchy is closed (see src/rbac/principal.cr).
          # A new variant must extend this method — fail loud with the
          # variant name, not with a confusing cast error.
          raise "role_fingerprint: unhandled principal variant #{principal.class.name}"
        end
      end

      # Canonical SHA-256 digest (hex, first 16 chars) of a `ListRequest`.
      #
      # The list endpoint accepts parameters via JSON body, query string, or
      # a merge of both — so a URL-based fingerprint is insufficient. This
      # delegates the canonical serialization to `ListRequest#to_json` (which
      # sorts filter keys for stable output) and hashes the result. Two
      # requests with the same effective `ListRequest` collapse to the same
      # digest regardless of transport.
      def list_request_fingerprint(list_req : HTTP::ListRequest) : String
        Digest::SHA256.hexdigest(list_req.to_json)[0, 16]
      end
    end
  end
end
