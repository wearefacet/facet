# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"
require "pg"
require "../database"
require "../config"
require "./uploader"

module Facet
  module Artifact
    # Reconcile for the artifact object store.
    #
    # The uploader deletes its own object best-effort on a rolled-back
    # transaction (failures swallowed, logged). A crash between the shrine
    # put and the DB commit leaves a hanging object with no `artifacts` row.
    # `artifacts:reconcile` sweeps those: it lists the bucket and deletes
    # every object that (a) has no `artifacts` row and (b) is older than an
    # hour. The hour window protects an in-flight upload whose row has not
    # committed yet. Manual, dry-run by default.
    module Reconcile
      # The age threshold below which an object is never a reconcile
      # candidate, regardless of whether it has an `artifacts` row. An
      # object younger than this may be mid-upload (row not yet committed).
      ORPHAN_AGE = 1.hour

      # Returns the set of shrine keys (`artifacts.path` values) currently
      # referenced by the database. Objects whose key is not in this set are
      # reconcile candidates (subject to the age gate).
      def self.referenced_keys(db : DB::Connection) : Set(String)
        Set(String).new(db.query_all("SELECT path FROM artifacts", as: String))
      end

      # Returns the storage-native key for a shrine `path` (the value stored
      # in `artifacts.path`). Used to compare listed objects against the DB
      # set — the shrine `Storage::Base` has no shared key-computation
      # method, so this dispatches on the concrete storage.
      def self.storage_key_for(path : String) : String
        storage = ::Facet::Artifact::Uploader.storage
        case storage
        when Shrine::Storage::FileSystem
          storage.path(path)
        when Shrine::Storage::S3
          storage.object_key(path)
        else
          raise "Unsupported storage for reconcile: #{storage.class}"
        end
      end

      # Returns a human-readable description of the resolved bucket and
      # prefix, printed in the reconcile header. For filesystem storage this
      # is the expanded directory; for S3 it is `bucket/prefix`.
      def self.describe_storage : String
        storage = ::Facet::Artifact::Uploader.storage
        case storage
        when Shrine::Storage::FileSystem
          storage.expanded_directory
        when Shrine::Storage::S3
          prefix = storage.object_key("").chomp("/")
          prefix.empty? ? storage.bucket : "#{storage.bucket}/#{prefix}"
        else
          storage.class.to_s
        end
      end

      # Collects every orphan candidate key (a storage object older than
      # `ORPHAN_AGE` with no `artifacts` row). Exposed for tests.
      def self.candidates(db : DB::Connection) : Array(String)
        referenced = referenced_keys(db)
        cutoff = Time.utc - ORPHAN_AGE
        keys = [] of String

        ::Facet::Artifact::Uploader.each_object do |key, last_modified|
          next if referenced.includes?(key)
          next unless last_modified < cutoff
          keys << key
        end

        keys.sort!
      end
    end

    # CLI subcommand for reconciling the artifact object store.
    #
    # Usage:
    #   facet artifacts:reconcile
    #   facet artifacts:reconcile --dry-run
    module ReconcileCLI
      def self.run(args : Array(String))
        dry_run = false
        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet artifacts:reconcile [--dry-run]"

          parser.on("--dry-run", "Print what would be deleted without deleting") do
            dry_run = true
          end

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end
        end

        Database.with_db(:read_write) do |db|
          puts "Reconciling artifact storage: #{::Facet::Artifact::Reconcile.describe_storage}"
          keys = ::Facet::Artifact::Reconcile.candidates(db)

          if keys.empty?
            puts "No orphan objects found."
            return
          end

          keys.each { |key| puts "  #{key}" }

          if dry_run
            puts "\nDry-run — #{keys.size} orphan object(s) would be deleted."
            return
          end

          keys.each do |key|
            ::Facet::Artifact::Uploader.delete(key)
          end
          puts "\nDeleted #{keys.size} orphan object(s)."
        end
      end
    end
  end
end
