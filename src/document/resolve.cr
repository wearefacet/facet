# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../doctype/definition_store"
require "../rbac"
require "../error"
require "./uri"

module Facet
  module Document
    # Service that resolves a batch of document URNs to masked, authorized
    # projections in one query per target doctype.
    #
    # Every reference an agent holds — a reference-field value, an inline
    # longtext link, an entry of the `links` column — is a bare URN until
    # something resolves it. The only pre-existing path was one
    # `Document::Read.call` per id: N references cost N round trips, each
    # with its own authorization and mask pass. `Resolve` collapses that to
    # one query per `(domain, doctype)` group: the RBAC scope clauses are
    # AND-composed into the batch SELECT exactly as `Document::List` does,
    # so a denied target never appears (non-disclosing, like a single read
    # — a caller cannot distinguish "missing", "tombstoned", and "denied").
    #
    # The result is masked with `ReadEnforcer.mask_content` per target
    # doctype definition, so a field the role cannot see is absent — the
    # same contract as every other read surface.
    #
    # Not designed for lazy migration: a projection whose `meta
    # .schema_version` lags is served as stored (a resolve is a read
    # convenience, not the canonical read path — use `Document::Read` when
    # the migrated form matters).
    module Resolve
      # Parsed group of refs: the doctype coordinates plus the URNs and the
      # opaque ids to fetch.
      private record Group,
        domain : String,
        doc_type : String,
        refs : Hash(String, String) # canonical URN -> opaque id

      # Resolves `refs` (canonical `urn:facet:…` strings; the legacy dotted
      # form parses too) to projections keyed by the canonical URN the
      # caller passed. Unparseable, tombstoned, denied, and unknown refs
      # simply do not appear in the result.
      def self.call(
        db : DB::Connection,
        refs : Array(String),
        auth_context : RBAC::AuthContext,
      ) : Hash(String, Mutation::Client::Projection)
        groups = group_refs(refs)
        return {} of String => Mutation::Client::Projection if groups.empty?

        resolved = {} of String => Mutation::Client::Projection
        groups.each_value do |group|
          resolve_group(db, group, auth_context, resolved)
        end
        resolved
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Parses the raw ref strings and groups them by `(domain, doctype)`.
      # Unparseable strings are dropped — a malformed URN resolves to
      # nothing, the same non-disclosure as an unknown target.
      private def self.group_refs(refs : Array(String)) : Hash(String, Group)
        groups = {} of String => Group
        refs.each do |raw|
          uri = DocURI.parse(raw)
          next if uri.nil?
          next unless uri.valid?

          qualified = "#{uri.domain}.#{uri.doctype}"
          group = groups[qualified] ||= Group.new(
            domain: uri.domain,
            doc_type: uri.doctype,
            refs: {} of String => String,
          )
          group.refs[uri.to_s] = uri.opaque
        end
        groups
      end

      # Runs the batch SELECT for one group and merges the masked
      # projections into `resolved`. The scope clauses start at placeholder
      # 4 — after `domain`, `doc_type`, and the id set. The ids ride as one
      # comma-joined string split server-side by `string_to_array` (same
      # bind shape `ScopePredicateSql` uses for context sets) — opaque ids
      # match `DocURI::OPAQUE_RE` and can never contain a comma.
      private def self.resolve_group(
        db : DB::Connection,
        group : Group,
        auth_context : RBAC::AuthContext,
        resolved : Hash(String, Mutation::Client::Projection),
      ) : Nil
        ids = group.refs.values.uniq!
        id_list = ids.join(",")

        base_params = [group.domain, group.doc_type, id_list] of ::DB::Any
        scope_clauses, scope_params = RBAC::ReadEnforcer.list_where_clauses(
          db, group.domain, group.doc_type, auth_context, start_idx: base_params.size + 1
        )
        where_sql = String.build do |sql|
          sql << "domain = $1 AND doc_type = $2 AND deleted_at IS NULL AND id = ANY(string_to_array($3, ','))"
          scope_clauses.each { |clause| sql << " AND " << clause }
        end
        params = base_params + scope_params

        definition = Doctype::DefinitionStore.fetch(db, "#{group.domain}.#{group.doc_type}")
        return if definition.nil?

        projections = fetch_projections(db, where_sql, params)
        urn_by_id = group.refs.invert
        projections.each do |proj|
          masked = proj.with_content(RBAC::ReadEnforcer.mask_content(proj.content, auth_context, definition))
          urn = urn_by_id[proj.id]?
          resolved[urn] = masked if urn
        end
      end

      # Fetches the projection rows for the batch SELECT. Ordered by `id`
      # for determinism; the caller keys by URN. Same column reads as
      # `Mutation::Client.fetch_projection`.
      private def self.fetch_projections(
        db : DB::Connection,
        where_sql : String,
        params : Array(::DB::Any),
      ) : Array(Mutation::Client::Projection)
        db.query_all(
          "SELECT domain, doc_type, id, content, version, links, meta, state, display_name, deleted_at, updated_at, created_at " \
          "FROM projections WHERE #{where_sql} ORDER BY id ASC",
          args: params,
        ) do |rs|
          Mutation::Client::Projection.new(
            domain: rs.read(String),
            doc_type: rs.read(String),
            id: rs.read(String),
            content: rs.read(JSON::Any),
            version: rs.read(Int32),
            links: rs.read(JSON::Any),
            meta: rs.read(JSON::Any),
            state: rs.read(String),
            display_name: rs.read(String?),
            deleted_at: rs.read(Time?),
            updated_at: rs.read(Time),
            created_at: rs.read(Time),
          )
        end
      end
    end
  end
end
