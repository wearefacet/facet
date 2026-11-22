# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "opentelemetry"
require "../config"
require "./provenance"
require "../util/script_helpers"
require "../error"

module Facet
  module Mutation
    # High‑level client for creating mutations and reading projections.
    #
    # Wraps the raw SQL insert into `mutations` (which triggers the
    # PL/pgSQL trigger to upsert the corresponding `projections` row)
    # and provides read helpers.
    module Client
      # ── Data types ──────────────────────────────────────────────────────

      # Lightweight projection row for spec / handler assertions.
      record Projection,
        domain : String,
        doc_type : String,
        id : String,
        content : JSON::Any,
        version : Int32,
        links : JSON::Any,
        meta : JSON::Any,
        state : String,
        display_name : String?,
        deleted_at : Time?,
        updated_at : Time,
        created_at : Time

      struct Projection
        # Returns a copy of this projection with `content` replaced. Used by
        # the read-mask paths, which swap only the content field.
        def with_content(content : JSON::Any) : Projection
          Projection.new(
            domain: domain,
            doc_type: doc_type,
            id: id,
            content: content,
            version: version,
            links: links,
            meta: meta,
            state: state,
            display_name: display_name,
            deleted_at: deleted_at,
            updated_at: updated_at,
            created_at: created_at,
          )
        end

        # Returns a copy of this projection with `meta` replaced. Used by the
        # migration-retry path, which rebuilds the row without the
        # `migration_error` marker before re-running `Document::Migrate`.
        def with_meta(meta : JSON::Any) : Projection
          Projection.new(
            domain: domain,
            doc_type: doc_type,
            id: id,
            content: content,
            version: version,
            links: links,
            meta: meta,
            state: state,
            display_name: display_name,
            deleted_at: deleted_at,
            updated_at: updated_at,
            created_at: created_at,
          )
        end
      end

      # ── Public API ──────────────────────────────────────────────────────
      #
      # Every writer takes the audit metadata as two structs:
      #
      # - `provenance` — who/what surface wrote it (`Provenance.from`
      #   derives it from the request's auth context). Defaults to the
      #   system-internal channel.
      # - `cause` — what directly triggered it (`Mutation::Cause`). `nil`
      #   means a root mutation of kind `request`. When `trace` is nil it
      #   resolves to this mutation's own id.
      #
      # `mutation_id` pins the mutation ULID. Callers that drive Lua
      # `document.*` writes pre-generate it (via `Mutation::Client.new_id`)
      # so the nested writes can stamp it as their `cause.parent`.

      # Creates a new document by inserting a `create` mutation.
      #
      # The document's own `meta` (in `arguments`) is the audit stamp for
      # the projection; the provenance columns on `mutations` are reserved
      # for mutation provenance, never duplicate the document payload.
      #
      # The `harness.mutation_search` GUC must be set before calling
      # this method (via `Document::Search.set_guc`).
      #
      # Returns the ULID of the mutation. Raises on DB errors.
      def self.create(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String = Util::ScriptHelpers.ulid,
        content : String = "{}",
        meta : String = "{}",
        actioner_id : String = "system",
        provenance : Provenance = Provenance.internal,
        cause : Cause? = nil,
        mutation_id : String? = nil,
      ) : String
        Facet::Telemetry.trace "mutation.client.create" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["action"] = "create"
          span["app"] = provenance.app if provenance.app
          args = %({"content": #{content}, "meta": #{meta}})
          id = mutation_id || Util::ScriptHelpers.ulid
          insert_mutation(db, "create", domain, doc_type, doc_id, actioner_id, args, provenance, cause, id)
        end
      end

      # Applies an incremental update to a document using the JsonDiff format.
      #
      # `diff_json` should be a JSON string containing `{"set": [...], "unset": [...]}``
      # as produced by `Mutation::JsonDiff.diff`.
      #
      # The `harness.mutation_search` GUC must be set before calling
      # this method (via `Document::Search.set_guc`).
      #
      # Returns the ULID of the mutation.
      def self.update(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        diff_json : String,
        meta_diff_json : String = "{}",
        actioner_id : String = "system",
        provenance : Provenance = Provenance.internal,
        cause : Cause? = nil,
        mutation_id : String? = nil,
      ) : String
        # Reject empty diffs — no point persisting a no-op mutation row.
        diff_parsed = JSON.parse(diff_json)
        set_arr = diff_parsed["set"]?.try(&.as_a?) || [] of JSON::Any
        unset_arr = diff_parsed["unset"]?.try(&.as_a?) || [] of JSON::Any
        if set_arr.empty? && unset_arr.empty?
          raise ArgumentError.new("Cannot apply an empty update diff: content diff has no set or unset entries")
        end

        Facet::Telemetry.trace "mutation.client.update" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["action"] = "update"
          span["app"] = provenance.app if provenance.app
          args = %({"diff": #{diff_json}, "meta_diff": #{meta_diff_json}})
          id = mutation_id || Util::ScriptHelpers.ulid
          insert_mutation(db, "update", domain, doc_type, doc_id, actioner_id, args, provenance, cause, id)
        end
      end

      # Inserts a `snapshot` mutation that fully overwrites the projection.
      #
      # The `arguments` format:
      #   {
      #     "content":    {...},
      #     "version":    int,
      #     "meta":       {...},
      #     "created_at": "ISO-8601"
      #   }
      #
      # Returns the ULID of the mutation.
      def self.snapshot_mutation(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        content : String = "{}",
        meta : String = "{}",
        version : Int32 = 1,
        created_at : String? = nil,
        actioner_id : String = "system",
        provenance : Provenance = Provenance.internal,
        cause : Cause? = nil,
        mutation_id : String? = nil,
      ) : String
        Facet::Telemetry.trace "mutation.client.snapshot" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["action"] = "snapshot"
          span["app"] = provenance.app if provenance.app
          now = created_at || Time.utc.to_rfc3339
          args = %({"content": #{content}, "version": #{version}, "meta": #{meta}, "created_at": "#{now}"})
          id = mutation_id || Util::ScriptHelpers.ulid
          insert_mutation(db, "snapshot", domain, doc_type, doc_id, actioner_id, args, provenance, cause, id)
        end
      end

      # Inserts the synthetic `snapshot` row written by
      # `Cron::MutationCompaction` — the retention boundary below the
      # kept history. Unlike `snapshot_mutation`, the row lands at an
      # explicit `idx` (the cut row's position, staged on the
      # `harness.explicit_mutation_idx` GUC so `stamp_mutation_insert` keeps
      # it) and keeps the cut row's `emitted_at`, so the audit timeline
      # stays truthful. The caller must stage
      # `harness.bypass_projection_triggers` — compaction never touches the
      # projection.
      #
      # Must run inside a transaction: the GUC is transaction-local.
      # Returns the ULID of the mutation.
      def self.compaction_snapshot(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        idx : Int32,
        emitted_at : Time,
        content : String = "{}",
        meta : String = "{}",
        version : Int32 = 1,
        created_at : String? = nil,
        actioner_id : String = "system:compaction",
        provenance : Provenance = Provenance.internal,
        cause : Cause? = nil,
        mutation_id : String? = nil,
      ) : String
        Facet::Telemetry.trace "mutation.client.compaction_snapshot" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["action"] = "snapshot"
          span["idx"] = idx.to_s
          now = created_at || Time.utc.to_rfc3339
          args = %({"content": #{content}, "version": #{version}, "meta": #{meta}, "created_at": "#{now}"})
          id = mutation_id || Util::ScriptHelpers.ulid
          resolved = (cause || Cause.root(CauseKind::Compaction)).resolve(id)
          db.exec("SELECT set_config($1, $2, true)", "harness.explicit_mutation_idx", idx.to_s)
          db.query_one(
            <<-SQL,
              INSERT INTO mutations (
                domain, doc_type, id, doc_id, action, actioner_id, arguments,
                channel, app, api_key, acting_role,
                cause_kind, cause_name, cause_event, cause_source, cause_parent, cause_trace,
                idx, emitted_at
              )
              VALUES (
                $1, $2, $3, $4, 'snapshot', $5, $6::jsonb,
                $7, $8, $9, $10,
                $11, $12, $13, $14, $15, $16,
                $17, $18
              )
              RETURNING id
            SQL
            domain, doc_type, id, doc_id, actioner_id, args,
            provenance.channel.json_value, provenance.app, provenance.api_key, provenance.acting_role,
            resolved.kind.json_value, resolved.name, resolved.event, resolved.source,
            resolved.parent, resolved.trace,
            idx, emitted_at,
            as: String
          )
        end
      end

      # Soft-deletes a document by inserting a `delete` mutation.
      #
      # Returns the ULID of the mutation.
      def self.delete(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String = "system",
        provenance : Provenance = Provenance.internal,
        cause : Cause? = nil,
        mutation_id : String? = nil,
      ) : String
        Facet::Telemetry.trace "mutation.client.delete" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["action"] = "delete"
          span["app"] = provenance.app if provenance.app
          args = "{}"
          id = mutation_id || Util::ScriptHelpers.ulid
          insert_mutation(db, "delete", domain, doc_type, doc_id, actioner_id, args, provenance, cause, id)
        end
      end

      # Fetches only the content of a projection (for diffing purposes).
      def self.fetch_content(db : DB::Connection, domain : String, doc_type : String, id : String) : JSON::Any
        db.query_one(
          "SELECT content FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
          domain, doc_type, id,
          as: JSON::Any
        )
      end

      # Fetches the full projection for a document.
      def self.fetch_projection(db : DB::Connection, domain : String, doc_type : String, id : String) : Projection
        db.query_one(
          <<-SQL,
            SELECT domain, doc_type, id, content, version, links, meta, state, display_name, deleted_at, updated_at, created_at
            FROM projections
            WHERE domain = $1 AND doc_type = $2 AND id = $3
          SQL
          domain, doc_type, id
        ) do |rs|
          Projection.new(
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
            created_at: rs.read(Time)
          )
        end
      end

      # Returns `true` if a projection exists for the given document.
      def self.projection_exists?(db : DB::Connection, domain : String, doc_type : String, id : String) : Bool
        result = db.query_one?(
          "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3",
          domain, doc_type, id,
          as: Int32
        )
        !result.nil?
      end

      # Fetches a projection and maps a missing row to a `404`
      # `ServiceError`. `not_found_message` is the exact error text the
      # caller surfaces — the read path uses the bare doc id, the write
      # paths use the qualified `domain.doc_type#id` form.
      def self.fetch_projection_or_404(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        id : String,
        not_found_message : String,
      ) : Projection | Facet::ServiceError
        fetch_projection(db, domain, doc_type, id)
      rescue PG::Error | DB::NoResultsError
        Facet::ServiceError.new(404, not_found_message)
      end

      # Returns the ids of the live (non-tombstoned) owned children of a
      # parent: rows of `doc_type` in `domain` whose `meta.parent_id`
      # equals `parent_id`. Shared by the delete cascade and the deep-copy
      # walker. `order_by_id` sorts by id (the copy path wants stable
      # order); the delete path keeps the un-ordered form.
      def self.owned_child_ids(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        parent_id : String,
        order_by_id : Bool = false,
      ) : Array(String)
        sql = String.build do |io|
          io << "SELECT id FROM projections\n"
          io << "WHERE domain = $1 AND doc_type = $2\n"
          io << "  AND meta->>'parent_id' = $3\n"
          io << "  AND deleted_at IS NULL\n"
          io << "ORDER BY id ASC\n" if order_by_id
        end
        db.query_all(sql, domain, doc_type, parent_id, as: String)
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Mints a mutation ULID client-side. Callers that drive Lua
      # `document.*` writes pre-generate their mutation id so the nested
      # writes can stamp it as their `cause.parent`. Same algorithm as the
      # PG `ulid()` default.
      def self.new_id : String
        Util::ScriptHelpers.ulid
      end

      # Inserts a mutation row and returns its ULID. The `action` literal
      # is interpolated by this module only (never caller input).
      # `mutation_id` is pre-resolved by the caller (minted there when not
      # pinned) so the cause trace and the row id are the same ULID.
      private def self.insert_mutation(
        db : DB::Connection,
        action : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        args : String,
        provenance : Provenance,
        cause : Cause?,
        mutation_id : String,
      ) : String
        resolved = (cause || Cause.root(CauseKind::Request)).resolve(mutation_id)
        # Stage the snapshot interval the `periodic_snapshot` trigger reads.
        # The YAML config is the single source of truth; a writer that does
        # not stage the GUC (raw SQL, the seed) falls back to the
        # DB-level `facet.snapshot_interval`, then to 10 in the trigger.
        db.exec(
          "SELECT set_config($1, $2, true)",
          "harness.snapshot_every", Facet::Config.instance.snapshot_every.to_s,
        )
        db.query_one(
          <<-SQL,
            INSERT INTO mutations (
              domain, doc_type, id, doc_id, action, actioner_id, arguments,
              channel, app, api_key, acting_role,
              cause_kind, cause_name, cause_event, cause_source, cause_parent, cause_trace
            )
            VALUES (
              $1, $2, $3, $4, '#{action}', $5, $6::jsonb,
              $7, $8, $9, $10,
              $11, $12, $13, $14, $15, $16
            )
            RETURNING id
          SQL
          domain, doc_type, mutation_id, doc_id, actioner_id, args,
          provenance.channel.json_value, provenance.app, provenance.api_key, provenance.acting_role,
          resolved.kind.json_value, resolved.name, resolved.event, resolved.source,
          resolved.parent, resolved.trace,
          as: String
        )
      end
    end
  end
end
