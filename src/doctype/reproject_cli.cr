# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"
require "uri"
require "../database"
require "./reproject"

module Facet
  module Doctype
    # CLI subcommand for re-projecting a doctype's derived columns.
    #
    # Usage:
    #   facet doctype:reproject <qualified_doctype>
    #   facet doctype:reproject crm.Company --workers 8
    #   facet doctype:reproject crm.Company --limit 10   # smoke test
    #
    # Re-stages the `search` / `links` / `display_name` GUCs for every live
    # document of the doctype and writes a content-preserving `snapshot`
    # mutation per row, so the projection trigger recomputes the derived
    # columns from the current doctype definition. See
    # `Facet::Doctype::Reproject` for the full contract.
    #
    # The producer + workers need `workers + 1` pooled connections (one for
    # the producer's keyset cursor, one per worker). The CLI sizes the pool
    # explicitly via the `max_pool_size` / `initial_pool_size` query
    # parameters on `DATABASE_URL` — crystal-db defaults to the CPU count,
    # which is usually too small.
    module ReprojectCLI
      def self.run(args : Array(String)) : Int32
        workers = Reproject::DEFAULT_WORKERS
        batch_size = Reproject::DEFAULT_BATCH_SIZE
        channel_cap = Reproject::DEFAULT_CHANNEL_CAP
        limit : Int32? = nil
        qualified : String? = nil

        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet doctype:reproject <qualified_doctype> [options]"

          parser.on("--workers N", "Number of parallel worker fibers (default #{Reproject::DEFAULT_WORKERS})") do |n|
            workers = n.to_i
            if workers < 1
              abort "Error: --workers must be >= 1"
            end
          end

          parser.on("--batch-size N", "Producer keyset page size (default #{Reproject::DEFAULT_BATCH_SIZE})") do |n|
            batch_size = n.to_i
            if batch_size < 1
              abort "Error: --batch-size must be >= 1"
            end
          end

          parser.on("--channel-cap N", "Bounded channel capacity (default #{Reproject::DEFAULT_CHANNEL_CAP})") do |n|
            channel_cap = n.to_i
            if channel_cap < 1
              abort "Error: --channel-cap must be >= 1"
            end
          end

          parser.on("--limit N", "Cap the number of documents re-projected (smoke test)") do |n|
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

        # Size the pool for the producer + workers. The producer runs on the
        # main fiber's pinned connection; each worker checks out its own.
        # We need at least `workers + 1` connections.
        Facet::Database.init(pool_size_url(Facet::Database.url_from_env, workers + 1))

        Facet::Database.with_db do |db|
          result = Reproject.call(
            db, qualified_doctype,
            batch_size: batch_size,
            workers: workers,
            channel_cap: channel_cap,
            limit: limit,
          ) { |_r| }
          case result
          in Reproject::Result
            stats = result.stats
            puts
            puts "Reproject #{qualified_doctype} (#{result.total} live document(s)):"
            puts "  processed:  #{stats.processed.get}"
            puts "  superseded: #{stats.superseded.get} (changed between enqueue and run — already re-projected)"
            puts "  skipped:    #{stats.skipped.get} (migration_error marker)"
            puts "  failed:     #{stats.failed.get}"
            unless stats.failed_ids.empty?
              puts "  failed ids:"
              stats.failed_ids.each { |id| puts "    - #{id}" }
            end
            stats.failed.get.zero? ? 0 : 1
          in Facet::ServiceError
            STDERR.puts "Error: #{result.message}"
            result.status
          end
        end
      end

      # Returns *url* with `initial_pool_size` and `max_pool_size` query params
      # set so the singleton pool holds at least *min_size* connections. This
      # avoids pool starvation when the producer + workers each need their
      # own connection. (Session settings — the UTC pin, the statement
      # timeout — travel through connection hooks inside `Database.init`,
      # never through URL parameters.)
      private def self.pool_size_url(url : String, min_size : Int32) : String
        uri = URI.parse(url)
        params = URI::Params.parse(uri.query || "")
        # Use the same value for initial and max so the pool is pre-warmed
        # at startup. crystal-db lazily creates connections on demand, but
        # pre-warming avoids a thundering-herd of checkouts at run start.
        params["initial_pool_size"] = min_size.to_s
        params["max_pool_size"] = min_size.to_s
        uri.query = params.to_s
        uri.to_s
      end

      private def self.banner : String
        "Usage: facet doctype:reproject <qualified_doctype> [options]"
      end
    end
  end
end
