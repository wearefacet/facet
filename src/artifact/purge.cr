# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "json"
require "log"
require "../database"
require "../config"
require "../error"
require "../rbac"
require "../doctype/definition_store"
require "../document/projection_gucs"
require "./uploader"
require "../mutation/client"
require "../util/script_helpers"

module Facet
  module Artifact
    # Operator-initiated artifact destruction — the force delete behind
    # `DELETE /Api/Artifacts/:id` and the `artifacts:prune --hard` CLI.
    #
    # A purge is a **security deletion**: the bytes must become unreachable
    # immediately, dangling references in document content are accepted
    # (they render dead `urn:facet:artifact:` links and nothing more), and
    # the action is destructive and irreversible. Every purge therefore
    # writes an `iam.ArtifactEvent` audit document **in the same
    # transaction** as the delete — fail-closed, unlike the fail-silent
    # `iam.LoginEvent` writes. If the audit write fails, the purge rolls
    # back: no artifact leaves the system without a matching audit record.
    #
    # The `DELETE FROM artifacts` cascades to `artifact_owners`,
    # `artifact_grants`, and `artifact_references` (see
    # `db/migrations/0003_artifacts.sql`), so every signed URL stops
    # verifying the moment the row is gone (`Grants.verify` reads a missing
    # row as `Invalid`). The owner-row cascade is the third legitimate
    # removal path for the append-only provenance table — the artifact
    # itself is being destroyed (see `doc/backend/artifact.md` → Design
    # invariants).
    #
    # The storage object delete runs **after** the transaction commits and
    # is best-effort (failures logged, swept by `artifacts:reconcile`).
    module Purge
      # The operator action that authorizes a purge — deny-only-`Denied`,
      # the same rule the artifact admin listing applies (`read *.*`).
      PURGE_ACTION = "purge"

      record Result,
        artifact_id : String,
        owner_count : Int64,
        reference_count : Int64

      # Content facts snapshotted into the audit event before the row goes.
      private record Facts,
        filename : String,
        mime_type : String,
        size : Int64,
        sha256 : String,
        path : String

      # Purges one artifact on behalf of an authenticated caller. Answers
      # `404` when the artifact row does not exist, `403` when the caller
      # is neither system nor holds the `purge *.*` operator action
      # (deny-only-`Denied` — scoped results pass, the same non-doctype
      # rule as the admin listing).
      def self.destroy(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        artifact_id : String,
        details : String?,
      ) : Result | Facet::ServiceError
        unless auth_context.system?
          result = auth_context.can?(PURGE_ACTION, "*.*")
          return error(403, "Forbidden") if result.is_a?(::Facet::RBAC::CanResult::Denied)
        end

        destroy_unchecked(db, artifact_id, auth_context.account_id, details)
      end

      # Purges one artifact with no permission gate — the CLI path
      # (`artifacts:prune --hard`), attributed to `system`.
      def self.destroy_system(db : DB::Connection, artifact_id : String) : Result | Facet::ServiceError
        destroy_unchecked(db, artifact_id, "system", nil)
      end

      # ── Internal ────────────────────────────────────────────────────────

      private def self.destroy_unchecked(
        db : DB::Connection,
        artifact_id : String,
        actioner_id : String,
        details : String?,
      ) : Result | Facet::ServiceError
        # Content facts and child-table counts for the audit event, read
        # before the row goes away.
        facts = read_facts(db, artifact_id)
        return error(404, "Artifact not found") unless facts

        counts = child_counts(db, artifact_id)

        Database.with_transaction(db) do |txn|
          txn.exec("DELETE FROM artifacts WHERE id = $1", artifact_id)
          write_event(txn, artifact_id, facts, counts, actioner_id, details)
        end

        # After commit: the row is gone and the audit event is durable.
        # The object delete is best-effort — a miss is swept by
        # `artifacts:reconcile`.
        ::Facet::Artifact::Uploader.delete(facts.path)
        Result.new(artifact_id: artifact_id, owner_count: counts[:owners], reference_count: counts[:references])
      rescue ex
        Log.error { "Artifact purge failed for #{artifact_id}: #{ex.message}" }
        error(500, "Artifact purge failed")
      end

      private def self.read_facts(db : DB::Connection, artifact_id : String) : Facts?
        db.query_one?(
          <<-SQL,
            SELECT filename, mime_type, size, signature_sha256, path
            FROM artifacts
            WHERE id = $1
          SQL
          artifact_id,
          as: {String, String, Int64, String, String},
        ).try do |(filename, mime_type, size, sha256, path)|
          Facts.new(filename: filename, mime_type: mime_type, size: size, sha256: sha256, path: path)
        end
      end

      private def self.child_counts(db : DB::Connection, artifact_id : String) : NamedTuple(owners: Int64, references: Int64)
        owners = db.query_one(
          "SELECT COUNT(*) FROM artifact_owners WHERE artifact_id = $1", artifact_id, as: Int64)
        references = db.query_one(
          "SELECT COUNT(*) FROM artifact_references WHERE artifact_id = $1", artifact_id, as: Int64)
        {owners: owners, references: references}
      end

      # Writes the `iam.ArtifactEvent` audit document inside the caller's
      # transaction. Raises on failure — the caller's rescue rolls the
      # purge back (fail-closed audit, the deliberate contrast with the
      # fail-silent `IAM::Helpers.write_login_event`).
      private def self.write_event(
        txn : DB::Connection,
        artifact_id : String,
        facts : Facts,
        counts : NamedTuple(owners: Int64, references: Int64),
        actioner_id : String,
        details : String?,
      ) : Nil
        content = JSON.build do |json|
          json.object do
            json.field "artifact_id", artifact_id
            json.field "event", "purged"
            json.field "filename", facts.filename
            json.field "mime_type", facts.mime_type
            json.field "size", facts.size
            json.field "sha256", facts.sha256
            json.field "owner_count", counts[:owners]
            json.field "reference_count", counts[:references]
            json.field "details", details unless details.nil? || details.empty?
          end
        end

        # Stage the projection GUCs the trigger reads (search corpus,
        # links, display_name). The raw create below stages nothing on
        # its own, and an unstaged GUC stores NULL derived columns — the
        # audit event's `display_name` (the artifact filename) then
        # renders blank in every audit view. The templates come from the
        # stored `iam.ArtifactEvent` definition — the doctype this row is
        # written under; a missing definition takes the no-definition
        # branch, the pipeline fallback.
        defn = Doctype::DefinitionStore.fetch(txn, "iam.ArtifactEvent")
        if defn
          Document::ProjectionGucs.set_all(txn, defn, JSON.parse(content))
        else
          Document::ProjectionGucs.clear_all(txn)
        end

        ::Facet::Mutation::Client.create(
          txn,
          "iam",
          "ArtifactEvent",
          doc_id: ::Facet::Util::ScriptHelpers.ulid,
          content: content,
          actioner_id: actioner_id,
        )
      end

      private def self.error(status : Int32, message : String) : Facet::ServiceError
        Facet::ServiceError.new(status, message)
      end
    end
  end
end
