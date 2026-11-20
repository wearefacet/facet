# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/doctype_definition"
require "../mutation/client"
require "./script_context"
require "./snapshot_persist"
require "../event"
require "../error"
require "opentelemetry"

module Facet
  module Document
    # Service for lazy-migrating a document to the current schema version.
    #
    # When a document's `meta.schema_version` is less than the doctype
    # definition's `schema_version`, this service runs the migration
    # functions defined in the doctype's Lua script, one version at a time.
    #
    # After migration, the result is persisted as a `snapshot` mutation
    # so that subsequent reads skip the migration.
    #
    # ## Flow
    #
    # 1. Compare doc schema_version vs definition schema_version
    # 2. For each version gap, run the migration function in Lua
    # 3. Persist the migrated document as a snapshot mutation
    # 4. Return the migrated projection
    module Migrate
      record Result,
        projection : Mutation::Client::Projection,
        migration_ids : Array(String)

      # Migrates a projection in-place if needed.
      #
      # Returns `Result` on success (even if no migration was needed),
      # `Error` on failure.
      def self.call(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        projection : Mutation::Client::Projection,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "document.migrate" do |span|
          span["domain"] = projection.domain
          span["doc_type"] = projection.doc_type
          span["doc_id"] = projection.id
          span["from_version"] = extract_schema_version(projection).to_s
          span["to_version"] = definition.schema_version.to_s

          doc_schema_version = extract_schema_version(projection)
          target_version = definition.schema_version

          # Fast path: document is already at the current schema version
          if doc_schema_version >= target_version
            span["migration_count"] = 0
            return Result.new(projection: projection, migration_ids: [] of String)
          end

          # Check that script + migrations are available
          script = definition.script
          if script.nil? || script.empty?
            return Telemetry.record_error(span, Facet::ServiceError.new(500, "Doctype #{definition.qualified_name} has schema_version #{target_version} but no script with migration functions"))
          end

          migrations = definition.migrations
          if migrations.empty?
            return Telemetry.record_error(span, Facet::ServiceError.new(500, "Doctype #{definition.qualified_name} has schema_version #{target_version} but no migration entries"))
          end

          current_content = projection.content
          current_meta = projection.meta
          migration_ids = [] of String

          # Run migrations for each version gap in order
          (doc_schema_version...target_version).each do |from_ver|
            key = from_ver.to_s
            func_name = migrations[key]?
            if func_name.nil?
              return Telemetry.record_error(span, Facet::ServiceError.new(500, "Missing migration entry from v#{from_ver} to v#{from_ver + 1} in doctype #{definition.qualified_name}"))
            end

            # Run the migration function in a Lua context. A thrown Lua
            # runtime error (or a script-load failure) raises as
            # `ScriptContext::Error`; convert it to the same 422 the
            # `ctx.error` collector produces so the read and list call
            # sites fall into the `Facet::ServiceError` branch, write the
            # `migration_error` marker, and serve the stale content
            # instead of unwinding to a generic 500. No structured
            # details: the message already carries the Lua reason, and
            # joined details would duplicate it on the marker.
            errors = [] of ValidationError
            begin
              ScriptContext::Migrate.new(script, func_name, current_content, "system:migration") do |ctx|
                migration_errors = ctx.run
                if migration_errors.empty?
                  current_content = ctx.root_document
                else
                  errors.concat(migration_errors)
                end
              end
            rescue ex : ScriptContext::Error
              return Telemetry.record_error(span, Facet::ServiceError.new(422, "Migration from v#{from_ver} raised: #{ex.message}"))
            end

            unless errors.empty?
              return Telemetry.record_error(span, Facet::ServiceError.new(422, "Migration from v#{from_ver} failed", details: errors))
            end
          end

          # Persist the migrated document as a snapshot mutation
          # Update the meta with the new schema_version
          new_meta = update_meta_schema_version(current_meta, target_version)

          # The shared persist primitive stages the search, links, and
          # display_name GUCs and writes the snapshot. The GUCs are
          # transaction-local, so the persist + projection fetch must run
          # inside one transaction.
          mut_id, updated_proj = Database.with_transaction(db, ignore_if_set: true) do |txn|
            this_mut_id = Document.persist_snapshot_mutation(
              txn, projection.domain, projection.doc_type, projection.id,
              content: current_content, meta: new_meta,
              actioner_id: "system:migration",
              cause: Mutation::Cause.root(Mutation::CauseKind::Migration, event: "migrated"),
              definition: definition,
              version: projection.version,
              created_at: projection.created_at.to_rfc3339,
            )

            this_proj = Mutation::Client.fetch_projection(txn, projection.domain, projection.doc_type, projection.id)
            {this_mut_id, this_proj}
          end
          migration_ids << mut_id

          Event::Publisher.enqueue(
            domain: projection.domain, doc_type: projection.doc_type,
            doc_id: projection.id,
            event: "migrated", mutation_id: mut_id,
            actioner_id: "system:migration",
            cause: Mutation::Cause.root(Mutation::CauseKind::Migration, event: "migrated").resolve(mut_id).to_json_any,
          )

          span["migration_count"] = migration_ids.size
          Result.new(projection: updated_proj, migration_ids: migration_ids)
        end
      end

      # Returns true if the projection's `meta.schema_version` is lower
      # than the doctype definition's current version, meaning migration
      # is needed. Shared by the read and list paths.
      def self.migration_needed?(
        projection : Mutation::Client::Projection,
        definition : Doctype::DoctypeDefinition,
      ) : Bool
        extract_schema_version(projection) < definition.schema_version
      end

      # Returns true if the projection has a `migration_error` in meta,
      # meaning a prior migration attempt failed and we should not retry.
      def self.migration_blocked?(projection : Mutation::Client::Projection) : Bool
        meta = projection.meta
        meta_h = meta.as_h?
        return false if meta_h.nil?
        meta_h.has_key?("migration_error") && meta_h["migration_error"]?.try(&.as_s?) != nil
      end

      # Extracts the schema_version from a projection's meta.
      # Defaults to 1 if not present.
      private def self.extract_schema_version(projection : Mutation::Client::Projection) : Int32
        meta = projection.meta
        meta_h = meta.as_h?
        return 1 if meta_h.nil?

        sv = meta_h["schema_version"]?
        return 1 if sv.nil?

        sv.as_i? || 1
      end

      # Returns a new meta JSON with schema_version updated to target_version.
      private def self.update_meta_schema_version(meta : JSON::Any, target_version : Int32) : JSON::Any
        h = meta.as_h?
        return JSON::Any.new({"schema_version" => JSON::Any.new(target_version.to_i64)}) if h.nil?

        new_h = h.dup
        new_h["schema_version"] = JSON::Any.new(target_version.to_i64)
        JSON::Any.new(new_h)
      end

      # Writes a snapshot mutation that marks the document with a migration
      # error so that subsequent reads/lists skip the broken migration.
      #
      # The stale content is preserved; only `meta.migration_error` is added.
      #
      # The marker is a human-readable string. When the source `Migrate::Error`
      # carries structured `details` (typically Lua `ctx.error` messages as
      # `ValidationError(code: "script")`), they are joined into the marker so
      # operators can see *why* migration failed without re-running it. The
      # structured form remains available on the returned `Migrate::Error`.
      def self.write_migration_error_marker(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        projection : Mutation::Client::Projection,
        error_message : String,
        details : Array(ValidationError)? = nil,
      ) : Mutation::Client::Projection
        new_meta = inject_meta_migration_error(projection.meta, error_message, details)
        # See migrate for the transaction rationale — GUCs are transaction-local.
        Database.with_transaction(db, ignore_if_set: true) do |txn|
          Document.persist_snapshot_mutation(
            txn, projection.domain, projection.doc_type, projection.id,
            content: projection.content, meta: new_meta,
            actioner_id: "system:migration",
            cause: Mutation::Cause.root(Mutation::CauseKind::Migration, name: "migration_error"),
            definition: definition,
            version: projection.version,
            created_at: projection.created_at.to_rfc3339,
          )
          Mutation::Client.fetch_projection(txn, projection.domain, projection.doc_type, projection.id)
        end
      end

      private def self.inject_meta_migration_error(
        meta : JSON::Any,
        error_message : String,
        details : Array(ValidationError)? = nil,
      ) : JSON::Any
        h = meta.as_h? || {} of String => JSON::Any
        new_h = h.dup
        new_h["migration_error"] = JSON::Any.new(format_migration_error(error_message, details))
        JSON::Any.new(new_h)
      end

      # Composes the `meta.migration_error` string. Joins structured details
      # (each rendered as `field: message` when field-scoped, otherwise just
      # `message`) so the Lua reason survives on the marker. The blocking check
      # (`migration_blocked?`) treats any non-nil string as a marker, so the
      # joined form preserves that contract.
      private def self.format_migration_error(message : String, details : Array(ValidationError)?) : String
        return message if details.nil? || details.empty?
        detail_text = details.map { |d| d.field ? "#{d.field}: #{d.message}" : d.message }.join("; ")
        "#{message}: #{detail_text}"
      end
    end
  end
end
