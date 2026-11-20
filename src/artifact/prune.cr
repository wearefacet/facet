# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"
require "pg"
require "../database"
require "../config"
require "../system_settings/service"
require "./uploader"

module Facet
  module Artifact
    # Prune eligibility and deletion for the `artifacts` table.
    #
    # Eligibility is **join-derived** — never computed from `artifacts`
    # alone. An artifact is eligible when it is not soft-deleted AND has no
    # live owner row (an `artifact_owners` row pointing at a live document)
    # AND no recent reference row. Both `NOT EXISTS` clauses are required:
    # the owner clause needs the live-document join (an owner row pointing
    # at a tombstoned document must not keep bytes alive forever), and
    # checking references alone would miss artifacts that have owners but no
    # references, and vice versa. See `doc/backend/artifact.md` → Prune.
    module Prune
      # Returns the ids of every artifact eligible for prune, per the
      # join-derived eligibility query. `prune_after_days` is the reference
      # window from `Artifact::Config`. An artifact is eligible when all three
      # of the following hold:
      #
      #   1. It is not soft-deleted (`deleted_at IS NULL`).
      #
      #   2. No live document owner row exists — there is no `artifact_owners`
      #      row whose `(domain, doc_type, doc_id)` resolves to a non-tombstoned
      #      `projections` row. Account-scoped owner rows (`doc_type = '_account'`)
      #      never resolve against `projections`, so they fall through this
      #      clause; their protection, if any, comes from clause 3.
      #
      #   3. No recent `artifact_references` row exists — there is no reference
      #      whose `last_reference_at` is within the prune window. Account-uploaded
      #      artifacts that have never been linked into a document have no
      #      reference row at all, so this clause alone would prune them on the
      #      first sweep. The `created_at` floor below keeps a freshly-uploaded
      #      but unlinked artifact alive for at least the prune window so a user
      #      who uploads then drags the artifact into a longtext/file field has
      #      time to save before being swept.
      #
      # A window of 0 or less returns nothing — 0 means keep forever.
      def self.eligible_ids(db : DB::Connection, prune_after_days : Int32) : Array(String)
        return [] of String if prune_after_days <= 0

        db.query_all(
          <<-SQL,
              SELECT a.id
              FROM artifacts a
              WHERE a.deleted_at IS NULL
                AND NOT EXISTS (
                  SELECT 1 FROM artifact_owners o
                  JOIN projections p
                    ON p.domain = o.domain
                   AND p.doc_type = o.doc_type
                   AND p.id = o.doc_id
                   AND p.deleted_at IS NULL
                  WHERE o.artifact_id = a.id
                )
                AND NOT EXISTS (
                  SELECT 1 FROM artifact_references r
                  WHERE r.artifact_id = a.id
                    AND r.last_reference_at > now() - (($1)::text || ' days')::interval
                )
                -- Dangling-upload floor: an artifact with no live document owner
                -- and no recent reference is only eligible once its `created_at`
                -- is older than the prune window. This is the Option D sweep rule —
                -- a user who uploads and has not yet linked the artifact gets
                -- at least one prune window to do so.
                AND a.created_at <= now() - (($1)::text || ' days')::interval
            SQL
          prune_after_days,
          as: String,
        )
      end

      # Soft-deletes an artifact: sets `deleted_at`. The row stays on the
      # books (content facts preserved) but is excluded from dedup candidates
      # and the serve path. Idempotent — a no-op when already deleted.
      def self.soft_delete(db : DB::Connection, id : String) : Nil
        db.exec(
          "UPDATE artifacts SET deleted_at = now() WHERE id = $1 AND deleted_at IS NULL",
          id,
        )
      end
    end

    # CLI subcommand for pruning eligible artifacts.
    #
    # Usage:
    #   facet artifacts:prune
    #   facet artifacts:prune --hard
    #
    # `--hard` purges (row + object + `iam.ArtifactEvent` audit document)
    # through `Artifact::Purge.destroy_system` — the same destruction
    # primitive the operator force-delete route uses, so every hard
    # deletion is audited identically.
    module PruneCLI
      def self.run(args : Array(String))
        hard = false
        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet artifacts:prune [--hard]"

          parser.on("--hard", "Purge eligible artifacts (row + object + audit event) instead of soft-deleting") do
            hard = true
          end

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end
        end

        Database.with_db(:read_write) do |db|
          # The window resolves at run time from the runtime settings
          # (document → file → default), so an admin change applies to the
          # next CLI run without a restart. A window of 0 disables the
          # prune — keep forever.
          n = SystemSettings.int_at(db, "artifact.prune_after_days")
          if !n.nil? && n.zero?
            puts "Artifact prune is disabled (artifact.prune_after_days = 0 — keep forever)."
            return
          end
          prune_after_days =
            if n.nil? || n < 0
              ::Facet::Config.instance.artifact.prune_after_days
            else
              n.to_i32
            end
          ids = ::Facet::Artifact::Prune.eligible_ids(db, prune_after_days)

          if ids.empty?
            puts "No artifacts eligible for prune."
            return
          end

          puts "Found #{ids.size} artifact(s) eligible for prune (reference window: #{prune_after_days} days)."
          ids.each do |id|
            if hard
              case result = ::Facet::Artifact::Purge.destroy_system(db, id)
              in ::Facet::Artifact::Purge::Result
                puts "  HARD-DELETE #{id}"
              in Facet::ServiceError
                puts "  FAILED #{id} — #{result.status} #{result.message}"
              end
            else
              ::Facet::Artifact::Prune.soft_delete(db, id)
              puts "  SOFT-DELETE #{id}"
            end
          end
        end
      end
    end
  end
end
