# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../http/helpers"
require "../http/list_request"
require "../rbac"
require "./list"

module Facet
  module Index
    # HTTP route for the managed-index status surface.
    #
    # `GET /Api/Indexes` lists the `doctype_indexes` tracking rows — one
    # row per physical PostgreSQL partial index the `Index::Manager` owns,
    # with its lifecycle status. The path is a pseudo-doctype (one segment
    # after `/Api`, like `/Api/Audit`) because indexes span every domain;
    # `HTTP::DomainGate` passes the path through unchanged.
    #
    # Registered by `HTTP::Server.routes` next to the doctype routes.
    # Authorization mirrors the global audit log: the caller must hold
    # wildcard `read` permission (`*.*`) — the operator gate. The route is
    # read-only; DDL stays with `Index::Manager` and the `index:retry` CLI.
    # Both transports admit list parameters strictly: a query parameter or
    # body key outside the list grammar answers `422`, and the filter map
    # must match the served grammar (`Index::List.validate_filters`).
    module Routes
      def self.register : Nil
        get "/Api/Indexes" do |env|
          handle_list(env)
        end

        query "/Api/Indexes" do |env|
          handle_query_list(env)
        end
      end

      # Strict admission: a query parameter (or merged body key) outside
      # the list grammar answers `422` naming it — the same contract the
      # document list and the audit list serve. The route reads no keys
      # beyond the grammar, so no extras are admitted.
      private def self.handle_list(env)
        list_req = HTTP::Helpers.get_list_request(env, strict: true) || return
        render_list(env, list_req)
      end

      # QUERY variant: the parameters ride the body only. The parse is
      # strict like the GET form — `Gates.query_body_json` holds the
      # body-only transport contract (query-string `422`, `415` media-type
      # gate, JSON-object gate) and `ListRequest.from_json` runs with
      # `strict: true`, the same shim the document list route runs.
      private def self.handle_query_list(env)
        parsed = HTTP::Helpers.query_body_json(env) || return
        result = HTTP::ListRequest.from_json(parsed, strict: true)
        if result.is_a?(Facet::ServiceError)
          HTTP::Helpers.error_response(env, result.status, result.message)
          return
        end
        render_list(env, result)
      end

      private def self.render_list(env, list_req)
        HTTP::Helpers.accept_query(env)
        result = Database.with_db(:read_only) do |db|
          Index::List.call(
            db,
            filters: list_req.filters,
            sort: list_req.sort,
            page: list_req.page,
            items_per_page: list_req.items,
            auth_context: HTTP::Helpers.auth_context(env),
          )
        end
        write_list_result(env, result)
      end

      # Writes the list result in the platform `{ data, meta }` shape. `count`
      # is the real total from the page offset, truncated at the shared cap;
      # `more` comes from the service and is true only when counting was
      # truncated (B-297).
      private def self.write_list_result(env, result)
        case result
        in Index::List::Result
          env.response.status_code = 200
          count, _ = HTTP::Helpers.capped_count(result.total, 0)
          {
            data: result.items.map { |row| row_hash(row) },
            meta: {count: count, more: result.more},
          }.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      # Converts one tracking row to a JSON-safe hash. Timestamps are the
      # stored tz-naive UTC columns serialized verbatim (RFC-3339).
      private def self.row_hash(row : Index::List::Row) : NamedTuple
        {
          id:            row.id,
          domain:        row.domain,
          doc_type:      row.doc_type,
          field_name:    row.field_name,
          index_type:    row.index_type,
          index_name:    row.index_name,
          status:        row.status,
          error_message: row.error_message,
          created_at:    row.created_at.to_rfc3339,
          updated_at:    row.updated_at.to_rfc3339,
        }
      end
    end
  end
end
