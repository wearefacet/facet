# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"
require "pg"
require "../database"
require "../config"
require "./grants"

module Facet
  module Artifact
    # CLI subcommand for revoking every signed URL issued for an artifact.
    #
    # Revoke is the coarse, artifact-scoped kill switch. It bumps the `epoch`
    # on every `artifact_grants` row for the artifact, so every URL minted
    # against any of its owner rows stops verifying immediately — without
    # needing the individual grant ids. The grant rows themselves are kept
    # (revoking is not deleting), so a mistaken bump can only invalidate
    # URLs, never destroy data. Contrast with `Grants.revoke`, which removes
    # a single grant row by id.
    #
    # Usage:
    #   facet artifacts:revoke <artifact-id>
    module RevokeCLI
      def self.run(args : Array(String))
        artifact_id : String? = nil

        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet artifacts:revoke <artifact-id>"

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end
        end

        artifact_id = args[0]?
        if artifact_id.nil? || artifact_id.empty?
          puts "Error: an artifact id is required."
          puts "Usage: facet artifacts:revoke <artifact-id>"
          exit 1
        end

        Database.with_db(:read_write) do |db|
          unless ::Facet::Artifact::Store.find_artifact(db, artifact_id)
            puts "Error: artifact '#{artifact_id}' not found."
            exit 1
          end

          ::Facet::Artifact::Grants.bump_epoch(db, artifact_id)
          puts "Revoked every signed URL for artifact #{artifact_id}."
        end
      end
    end
  end
end
