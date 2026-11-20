# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../http/helpers"
require "./query"

module Facet
  module Search
    # HTTP routes of the cross-doctype search.
    #
    # Two scopes, each in the GET + QUERY pair the list surfaces use —
    # one handler, two transports:
    #
    # - `GET|QUERY /Api/:domain/search` — one domain. The domain comes
    #   from the URL; an unknown domain answers a non-disclosing 404.
    # - `GET|QUERY /Api/search` — the whole application (fan-out over the
    #   routed databases). No domain segment, so `search` sits in the
    #   DomainGate's reserved segments.
    #
    # GET merges the query string with a JSON body `{"q": ...}` — the
    # query string wins, every other body key is ignored. QUERY is
    # body-only under the shared `Gates` contract (any query-string
    # parameter → 422, non-JSON media type → 415, non-object body → 422,
    # empty body → defaults).
    #
    # The contract is one parameter, `q`. A missing or short term answers
    # 200 with an empty result — never a 422. The response carries labels
    # only (id, display names, ranks) and never document `content`: no
    # field-maskable value leaves the server, so the field-level read
    # mask needs no per-row application here.
    module Routes
      def self.register : Nil
        # Domain-scoped search
        get "/Api/:domain/search" do |env|
          handle_get(env, app_wide: false)
        end

        query "/Api/:domain/search" do |env|
          handle_query(env, app_wide: false)
        end

        # App-wide search (fan-out)
        get "/Api/search" do |env|
          handle_get(env, app_wide: true)
        end

        query "/Api/search" do |env|
          handle_query(env, app_wide: true)
        end
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.handle_get(env, app_wide : Bool)
        q = env.params.query["q"]?
        if q.nil?
          raw = HTTP::Helpers.parse_body(env)
          unless raw.nil? || raw.empty?
            body = parse_get_body(env, raw) || return
            q = body["q"]?.try(&.as_s?)
          end
        end
        render(env, q || "", app_wide)
      end

      private def self.handle_query(env, app_wide : Bool)
        body = HTTP::Helpers.query_body_json(env) || return
        render(env, body["q"]?.try(&.as_s?) || "", app_wide)
      end

      # Parses a GET request body that must be a JSON object. Returns nil
      # after writing the 422 error response.
      private def self.parse_get_body(env, raw : String) : JSON::Any?
        parsed = begin
          JSON.parse(raw)
        rescue
          HTTP::Helpers.error_response(env, 422, "Invalid JSON body")
          return nil
        end
        unless parsed.as_h?
          HTTP::Helpers.error_response(env, 422, "Invalid JSON body — the request body must be a JSON object")
          return nil
        end
        parsed
      end

      private def self.render(env, raw_term : String, app_wide : Bool)
        HTTP::Helpers.accept_query(env)
        term = raw_term.strip
        hits = fetch_hits(env, term, app_wide)
        return HTTP::Helpers.error_response(env, 404, "Not found") if hits.nil?
        write_response(env, term, hits, app_wide ? "app" : "domain")
      end

      # Runs the search. Returns nil only when the domain-scoped route
      # named an unknown domain (the caller answers 404).
      private def self.fetch_hits(env, term : String, app_wide : Bool) : Array(Search::Hit)?
        return [] of Search::Hit if term.size < Search::MIN_TERM_LENGTH
        auth_context = HTTP::Helpers.auth_context(env)
        if app_wide
          Search::Query.app_search(term, auth_context)
        else
          Search::Query.domain_search(term, env.params.url["domain"], auth_context)
        end
      end

      # ── Response ────────────────────────────────────────────────────────

      # Writes the standard envelope: per-doctype groups in rank order,
      # each carrying its hits, plus the term, the hit count, and the
      # scope in `meta`.
      private def self.write_response(env, term : String, hits : Array(Search::Hit), scope : String)
        body = JSON.build do |json|
          json.object do
            json.field "data" do
              json.array do
                each_group(hits) do |domain, doctype, group_hits|
                  json.object do
                    json.field "domain", domain
                    json.field "doctype", doctype
                    json.field "hits" do
                      json.array do
                        group_hits.each { |hit| hit_json(json, hit) }
                      end
                    end
                  end
                end
              end
            end
            json.field "meta" do
              json.object do
                json.field "q", term
                json.field "count", hits.size
                json.field "scope", scope
              end
            end
          end
        end
        HTTP::Helpers.write_json(env, 200, body)
      end

      private def self.hit_json(json : JSON::Builder, hit : Search::Hit)
        json.object do
          json.field "id", hit.id
          json.field "display_name", hit.display_name
          json.field "rank", hit.rank
          json.field "root_doctype", hit.root_doctype
          json.field "root_id", hit.root_id
          json.field "root_display_name", hit.root_display_name
          json.field "child_label", hit.child_label
        end
      end

      # Walks the hit groups in first-hit order. Hits arrive rank-ordered,
      # so the first hit of a (domain, doctype) pair fixes the group's
      # position; Crystal hashes are unordered, so the key order is kept
      # in a separate array.
      private def self.each_group(hits : Array(Search::Hit), & : (String, String, Array(Search::Hit)) -> Nil)
        keys = [] of Tuple(String, String)
        grouped = {} of Tuple(String, String) => Array(Search::Hit)
        hits.each do |hit|
          key = {hit.domain, hit.doc_type}
          group = grouped[key]?
          if group.nil?
            group = [] of Search::Hit
            grouped[key] = group
            keys << key
          end
          group << hit
        end
        keys.each { |key| yield key[0], key[1], grouped[key] }
      end
    end
  end
end
