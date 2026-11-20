# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"
require "../database"
require "./migration_retry"

module Facet
  module Doctype
    # CLI subcommand for recovering documents blocked by a
    # `meta.migration_error` marker.
    #
    # Usage:
    #   facet doctype:migrate-retry <qualified_doctype>
    #   facet doctype:migrate-retry crm.Company --limit 10   # smoke test
    #
    # Clears the marker on every live document of the doctype and re-runs
    # the lazy migration in the same pass. Run it after the doctype
    # definition is fixed (script restored, migration entries carried).
    # A document whose migration still fails keeps its marker — nothing is
    # written for it — so the command is safe to re-run. See
    # `Facet::Doctype::MigrationRetry` for the full contract.
    module MigrationRetryCLI
      def self.run(args : Array(String)) : Int32
        limit : Int32? = nil
        qualified : String? = nil

        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet doctype:migrate-retry <qualified_doctype> [options]"

          parser.on("--limit N", "Cap the number of documents processed (smoke test)") do |n|
            limit = n.to_i
          end

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end

          parser.unknown_args do |pos|
            qualified = pos.first?
          end
        end

        # `qualified` is `String | Nil` here. The `abort` below guarantees the
        # branch returns, but the compiler cannot infer that, so we rebind to
        # a guaranteed-non-nil local for the remainder. Crystal narrows the
        # type to `String` after the `if` returns on the nil branch.
        qualified_doctype = case q = qualified
                            when String then q
                            else
                              abort "Error: a qualified doctype (e.g. 'crm.Company') is required.\n#{banner}"
                            end

        Facet::Database.init

        Facet::Database.with_db do |db|
          result = MigrationRetry.call(db, qualified_doctype, limit: limit)
          case result
          in MigrationRetry::Result
            stats = result.stats
            puts
            puts "Migration retry #{qualified_doctype}:"
            puts "  scanned:  #{stats.scanned} (documents carrying a migration_error marker)"
            puts "  migrated: #{stats.migrated}"
            puts "  failed:   #{stats.failed} (marker kept — fix the definition and re-run)"
            puts "  skipped:  #{stats.skipped} (row gone or marker already cleared)"
            unless stats.failed_ids.empty?
              puts "  failed ids:"
              stats.failed_ids.each { |id| puts "    - #{id}" }
            end
            stats.failed.zero? ? 0 : 1
          in Facet::ServiceError
            STDERR.puts "Error: #{result.message}"
            result.status
          end
        end
      end

      private def self.banner : String
        "Usage: facet doctype:migrate-retry <qualified_doctype> [options]"
      end
    end
  end
end
