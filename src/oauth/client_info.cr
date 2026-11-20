# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"

module Facet
  module OAuth
    # Public client metadata for first-party CLI clients.
    #
    # Serves `GET /OAuth/client-info?slug=…`. The CLI resolves its own
    # `client_id` through this endpoint before it starts the PKCE authorize
    # flow — it cannot hard-code the id because the `app.App` create hook
    # assigns it at registration time.
    #
    # Every failure path — unknown slug, missing param, a draft or disabled
    # app, content without a `client_id` — resolves to `nil`. The route maps
    # all of them to the same `404 unknown_client` body, so the endpoint
    # never discloses the existence of a non-active app.
    module ClientInfo
      record Info,
        slug : String,
        client_id : String,
        name : String,
        client_type : String

      # Live lookup by slug against the `app.App` projections. Returns the
      # client info for an active app, `nil` otherwise (see the module doc).
      def self.find(db : DB::Connection, slug : String?) : Info?
        return nil if slug.nil? || slug.strip.empty?
        row = db.query_one?(
          <<-SQL,
            SELECT content FROM projections
            WHERE domain = 'app' AND doc_type = 'App'
              AND content->>'slug' = $1
              AND deleted_at IS NULL
          SQL
          slug,
        ) do |rs|
          {content: rs.read(JSON::Any)}
        end
        return nil unless row

        content = row[:content].as_h
        status = content["status"]?.try(&.as_s?) || "draft"
        return nil unless status == "active"
        client_id = content["client_id"]?.try(&.as_s?)
        return nil if client_id.nil? || client_id.empty?

        Info.new(
          slug: slug,
          client_id: client_id,
          name: content["name"]?.try(&.as_s?) || "",
          client_type: content["client_type"]?.try(&.as_s?) || "public",
        )
      end
    end
  end
end
