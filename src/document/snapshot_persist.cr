# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../error"
require "../mutation/client"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "./projection_gucs"
require "./artifact_refs"

module Facet
  module Document
    # Shared write primitive for a snapshot mutation.
    #
    # Three services write a snapshot whose payload describes a full
    # document state: `Document::Migrate` (lazy migration), `Doctype::Reproject`
    # (derived-column back-fill), and `Audit::Rollback` (replay + restore).
    # All three run the same persist sequence — stage the transaction-local
    # projection GUCs from the content, insert the snapshot mutation, and
    # (rollback only) reconcile `artifact_references`. This module owns that
    # sequence so the three paths cannot drift again.
    #
    # Runs inside the caller's transaction: the GUCs are transaction-local,
    # and the snapshot's trigger reads them in the same transaction. See
    # `Document::Migrate` for the transaction rationale.
    #
    # `definition` is the doctype definition used to stage the GUCs. Pass
    # `nil` when the caller cannot promise one exists (a rollback replay can
    # hit a document whose doctype is gone). The store then resolves it;
    # when it still comes back nil, GUC staging falls back to
    # `ProjectionGucs.clear_all` and artifact reconciliation is skipped.
    def self.persist_snapshot_mutation(
      db : DB::Connection,
      domain : String,
      doc_type : String,
      doc_id : String,
      content : JSON::Any,
      meta : JSON::Any,
      *,
      actioner_id : String,
      cause : Mutation::Cause,
      definition : Doctype::DoctypeDefinition?,
      version : Int32 = 1,
      created_at : String? = nil,
      provenance : Mutation::Provenance = Mutation::Provenance.internal,
      mutation_id : String? = nil,
      reconcile_artifact_refs : Bool = false,
    ) : String
      resolved = definition || Doctype::DefinitionStore.fetch(db, "#{domain}.#{doc_type}")

      if defn = resolved
        ProjectionGucs.set_all(db, defn, content)
      else
        ProjectionGucs.clear_all(db)
      end

      ArtifactRefs.set_guc(db, content, defn, domain, doc_id) if defn && reconcile_artifact_refs

      Mutation::Client.snapshot_mutation(
        db, domain, doc_type, doc_id,
        content: content.to_json,
        meta: meta.to_json,
        version: version,
        created_at: created_at,
        actioner_id: actioner_id,
        provenance: provenance,
        cause: cause,
        mutation_id: mutation_id,
      )
    end
  end
end
