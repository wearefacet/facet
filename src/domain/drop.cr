# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "json"
require "../database"
require "../event"
require "../mutation/client"
require "../document/projection_gucs"
require "../error"
require "./scratch"

module Facet
  module Domain
    # Deletes a domain — the live-domain counterpart of `Scratch.drop`.
    #
    # Runs the full-scope teardown (`Scratch.dispose!`: doctype definitions,
    # views, data rows, personal collection views, `doctype_indexes`, artifact
    # provenance) and records a `delete` mutation on the `core.Domain`
    # document first, so the audit log shows who deleted the domain and when.
    # The `mutations` table is otherwise untouched — the domain's history
    # stays in the append-only log.
    #
    # ## Guard rails (fail-closed)
    #
    # - System domains (`core`, `iam`, `app` — the seeded bootstrap domains)
    #   are refused with 422.
    # - Refused with 409 while a draft branched from the domain still exists
    #   (the draft's `source_domain` points here) — discard the draft first.
    # - Unknown or already-deleted domains return 404.
    #
    # ## Ordering
    #
    # The `core.Domain` delete mutation is inserted **before** the SQL
    # teardown: the projection trigger tombstones the Domain row through the
    # normal path (bumps `state`, stages the tombstone), and `dispose!`'s own
    # Domain tombstone then becomes a no-op via its `deleted_at IS NULL`
    # guard. Everything runs in one transaction — either the whole domain
    # disappears or nothing does.
    module Drop
      # Bootstrap domains seeded by `data/seeds/core.Domain/documents.yml`.
      # Deleting one would break the application itself (schema system,
      # identity, app hosting).
      PROTECTED_DOMAINS = ["core", "iam", "app"]

      record Result, domain : String

      def self.call(
        db : DB::Connection,
        domain_id : String,
        actioner_id : String,
      ) : Result | Facet::ServiceError
        # 1. The domain must exist as a live `core.Domain` document.
        row = db.query_one?(
          "SELECT content FROM projections " \
          "WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 " \
          "AND deleted_at IS NULL",
          domain_id,
          as: JSON::Any,
        )
        return Facet::ServiceError.new(404, "Domain '#{domain_id}' not found") unless row

        # 2. System domains are not deletable.
        if PROTECTED_DOMAINS.includes?(domain_id)
          return Facet::ServiceError.new(
            422,
            "Domain '#{domain_id}' is a system domain and cannot be deleted"
          )
        end

        # 3. Refuse while a draft branched from this domain is still live —
        #    dropping the source under an open draft would orphan it
        #    (its `source_domain` would name a dead domain). Same predicate
        #    as `Draft.create_from`'s one-draft-per-source check.
        draft = db.query_one?(
          "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' " \
          "AND content->>'source_domain' = $1 AND content->>'draft' = 'true' " \
          "AND deleted_at IS NULL",
          domain_id,
          as: Int32,
        )
        if draft
          return Facet::ServiceError.new(
            409,
            "A draft branched from domain '#{domain_id}' still exists — discard it first"
          )
        end

        # 4. Teardown. Wrapped with `ignore_if_set: true` so the
        #    transaction-local GUCs survive when the caller already holds a
        #    transaction (the HTTP route wraps every handler).
        mut_id = Database.with_transaction(db, ignore_if_set: true) do |txn|
          # `core.Domain` has no doctype definition here — stage empty
          # links/search/display-name GUCs (see `ProjectionGucs.clear_all`).
          Document::ProjectionGucs.clear_all(txn)

          # Audit record first: the trigger tombstones the Domain row through
          # the normal delete path, so the tombstone carries the actor.
          this_mut_id = Mutation::Client.delete(
            txn,
            "core",
            "Domain",
            domain_id,
            actioner_id: actioner_id,
          )

          # Then the wholesale teardown. Its own Domain tombstone is a
          # no-op (the row is already deleted); everything else is cleaned.
          Scratch.dispose!(txn, domain_id)

          this_mut_id
        end

        Event::Publisher.enqueue(
          domain: "core", doc_type: "Domain", doc_id: domain_id,
          event: "deleted", mutation_id: mut_id, actioner_id: actioner_id,
        )

        Result.new(domain: domain_id)
      end
    end
  end
end
