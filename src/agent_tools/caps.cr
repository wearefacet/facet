# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../config"

module Facet
  module AgentTools
    # Response-cap enforcement for tool results.
    #
    # `max_result_rows` is applied at query time (the read tools clamp
    # `items`); `max_response_bytes` is applied here, after serialization:
    # when the JSON payload exceeds the cap, `meta.truncated` flips to
    # `true` and `meta.next_cursor` carries the next page number so the
    # agent can continue instead of retrying blind (plan D5, result
    # envelope).
    module Caps
      # Applies `mcp.max_response_bytes` to a `{data, meta}` payload.
      # Returns the payload unchanged when it fits. When it does not, the
      # `data` array is cut back until it fits and `meta.truncated` /
      # `meta.next_cursor` are set. `page` is the page the caller asked
      # for, so the cursor is `page + 1`.
      #
      # `row_urns` is the per-row list of `resolved`-map keys each row
      # references (parallel to `data`); when provided and rows are cut,
      # the `resolved` entries only those rows referenced are dropped too —
      # an orphaned resolved document would leak bytes the caller cannot
      # associate with any kept row.
      def self.apply_response_caps(
        payload : Hash(String, JSON::Any),
        page : Int32,
        row_urns : Array(Array(String))? = nil,
      ) : Hash(String, JSON::Any)
        cap = Facet::Config.instance.mcp.max_response_bytes
        return payload if payload.to_json.bytesize <= cap

        data = payload["data"]?.try(&.as_a?) || return payload
        meta = payload["meta"].as_h

        # Drop rows from the end until the payload fits (or one row is
        # left — a single oversized row is still returned, truncated
        # marker set, so the caller learns the cap exists).
        kept = data.dup
        while kept.size > 1 && build_payload(kept, meta, page, truncated: true).to_json.bytesize > cap
          kept.pop
        end

        payload["data"] = JSON::Any.new(kept)
        if row_urns && payload["resolved"]?.try(&.as_h?)
          keep_urns = row_urns.first(kept.size).flatten.to_set
          resolved = payload["resolved"].as_h.select { |urn, _| keep_urns.includes?(urn) }
          payload["resolved"] = JSON::Any.new(resolved)
        end
        payload["meta"] = JSON::Any.new(truncated_meta(meta, page))
        payload
      end

      private def self.build_payload(
        data : Array(JSON::Any),
        meta : Hash(String, JSON::Any),
        page : Int32,
        truncated : Bool,
      ) : JSON::Any
        JSON::Any.new({
          "data" => JSON::Any.new(data),
          "meta" => JSON::Any.new(truncated_meta(meta, page, truncated)),
        } of String => JSON::Any)
      end

      private def self.truncated_meta(
        meta : Hash(String, JSON::Any),
        page : Int32,
        truncated : Bool = true,
      ) : Hash(String, JSON::Any)
        h = meta.dup
        h["truncated"] = JSON::Any.new(truncated)
        h["next_cursor"] = JSON::Any.new((page + 1).to_i64)
        h
      end
    end
  end
end
