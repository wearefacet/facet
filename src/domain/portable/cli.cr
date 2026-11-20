# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"

require "../../database"
require "../../event"
require "../../index"
require "../../rbac"

require "./archive"
require "./export"
require "./import"
require "./service_error_format"

module Facet
  module Domain
    module Portable
      # CLI for `facet domain:export` and `facet domain:import`.
      #
      # Bypasses RBAC (`AuthContext.system`) like every other CLI
      # subcommand — it is an operator-grade tool, not a user surface.
      # Wraps `Export` and `Import` with database lifecycle and event
      # flushing, mirroring `Domain::Publish`'s HTTP path.
      module CLI
        # `facet domain:export <domain>[,domain,...] [--output-dir DIR]
        #                       [--with-documents]`.
        #
        # Writes one bundle per requested domain. Multiple domains are
        # declared comma-separated (`a,b,c`) or whitespace-separated
        # (`a b c`). `--output PATH` is a single-domain shortcut — passing
        # it with more than one domain is a usage error. Use
        # `--output-dir DIR` to fan out every bundle into one shared
        # directory. Default output path is `./{domain}.facet-domain` per
        # domain (CWD when `--output-dir` is omitted). Refuses to export a
        # draft domain. `--with-documents` also captures every non-deleted
        # document of every user doctype in the source domain.
        def self.run_export(args : Array(String)) : Int32
          domains, output, output_dir, with_documents = parse_export_args(args)
          paths = resolve_export_outputs(domains, output, output_dir)

          Facet::Index::Manager.synchronous = true
          Facet::Database.init
          Facet::Database.with_db do |db|
            domains.each_with_index do |domain, i|
              result = Export.call(db, domain, with_documents: with_documents)
              case result
              in Export::Result
                written = Archive.write(result.bundle, paths[i])
                print_export_summary(result, written, label: domain)
              in Facet::ServiceError
                # Stop on the first failure — partial export is acceptable,
                # but the operator must see which domain broke the chain.
                abort ServiceErrorFormat.format("Error exporting '#{domain}'", result)
              end
            end
          end
          drain_index_ddl_and_close
          0
        end

        # `facet domain:import <path>[,path,...] [--into <domain>[,domain,...]]
        #                       [--merge]`.
        #
        # Reads the bundle from each `path` (directory or `.tar.gz`), then
        # applies it via `Import.call`. Multiple paths are declared
        # comma-separated or whitespace-separated. `--into` accepts a
        # comma-separated list when given alongside multiple paths — the
        # counts must align (single `--into` + many paths is a usage error).
        # `--merge` is applied to every domain; a merge against a target
        # that does not exist yet falls back to a fresh create. A one-shot
        # CLI run has no event subscribers, so the manager is an
        # `InProcessManager` — the post-commit flush drops the enqueued
        # events instead of requiring Redis. First failure aborts the chain.
        def self.run_import(args : Array(String)) : Int32
          paths, into_list, merge = parse_import_args(args)

          Facet::Event::Publisher.manager = Event::InProcessManager.new
          Facet::Index::Manager.synchronous = true
          Facet::Database.init
          Facet::Database.with_db do |db|
            paths.each_with_index do |path, i|
              # Operator-grade failure modes stay operator-grade: a broken
              # bundle or a conflicting document aborts with a named file
              # and a one-line reason — never a Crystal backtrace (B-26).
              begin
                bundle = Archive.read(path)
              rescue ex : Archive::Error
                abort "Error reading '#{path}': #{ex.message}"
              end
              into = into_list[i]?
              result = begin
                Import.call(db, bundle, merge: merge, into: into)
              rescue ex : PQ::PQError
                abort import_db_error(path, ex)
              end
              case result
              in Import::Result
                print_import_summary(result, label: import_label(bundle, into))
              in Facet::ServiceError
                abort ServiceErrorFormat.format("Error importing '#{path}'", result)
              end
            end
            Facet::Event::Publisher.flush
          end
          drain_index_ddl_and_close
          0
        end

        # Formats a database failure from `Import.call` for the operator.
        # A unique-constraint violation (SQLSTATE 23505 — the unique-field
        # indexes, e.g. on `iam.Account.email`) reports the constraint name
        # plus the server's own `Detail:` line, which names the field and
        # the conflicting value. No string surgery on constraint names.
        private def self.import_db_error(path : String, ex : PQ::PQError) : String
          prefix = "Error importing '#{path}'"
          if Util::PgError.sqlstate(ex) == "23505"
            message = "#{prefix}: a value conflicts with a uniqueness rule"
            if constraint = Util::PgError.constraint_name(ex)
              message += " (constraint #{constraint})"
            end
            if detail = Util::PgError.detail(ex)
              message += " — #{detail}"
            end
            message
          else
            "#{prefix}: database error: #{ex.message}"
          end
        end

        # ── Argument parsing ──────────────────────────────────────────────

        # Parses `domain:export` arguments. Returns `{domains, output,
        # output_dir, with_documents}` and aborts with a usage message on
        # bad input. `domains` is the de-duplicated list of domains to
        # export (whitespace- and comma-separated forms are both accepted).
        # `output` is mutually exclusive with multi-domain: the single-domain
        # operator passes one domain plus `--output PATH`; the multi-domain
        # operator passes multiple domains plus `--output-dir DIR`.
        private def self.parse_export_args(args : Array(String)) : {Array(String), String?, String?, Bool}
          output : String? = nil
          output_dir : String? = nil
          with_documents = false
          positional = [] of String
          banner = "Usage: facet domain:export <domain>[,domain,...] [--output PATH | --output-dir DIR] [--with-documents]"
          OptionParser.parse(args) do |parser|
            parser.banner = banner
            parser.on("-o", "--output PATH", "Destination directory or .tar.gz (single-domain only; default: ./{domain}.facet-domain)") do |p|
              output = p
            end
            parser.on("--output-dir DIR", "Destination directory for every bundle (multi-domain: DIR/{domain}.facet-domain)") do |d|
              output_dir = d
            end
            parser.on("--with-documents", "Also export every document of every user doctype in the domain") do
              with_documents = true
            end
            parser.on("-h", "--help", "Show help") do
              puts parser
              exit 0
            end
            parser.unknown_args do |pos|
              positional.concat(pos)
            end
          end
          domains = expand_comma_list(positional)
          if domains.empty?
            abort "Error: at least one domain is required.\n#{banner}"
          end
          if output && domains.size > 1
            abort "Error: --output is single-domain only; pass multiple domains with --output-dir DIR.\n#{banner}"
          end
          if output && output_dir
            abort "Error: --output and --output-dir are mutually exclusive.\n#{banner}"
          end
          {domains, output, output_dir, with_documents}
        end

        # Resolves the per-domain output paths from `domains`, `--output`,
        # and `--output-dir`. Used to fan out the single `--output` shortcut
        # to one path or expand `--output-dir` (or the default `./`) into
        # one path per domain.
        private def self.resolve_export_outputs(
          domains : Array(String),
          output : String?,
          output_dir : String?,
        ) : Array(String)
          # Single-domain explicit `--output PATH` shortcut. Pulled through
          # a typed local so the compiler narrows without `not_nil!`.
          if explicit = output
            return [explicit]
          end

          base = output_dir || "."
          Dir.mkdir_p(base) if output_dir
          domains.map { |domain| File.join(base, "#{domain}.facet-domain") }
        end

        # Parses `domain:import` arguments. Returns
        # `{paths, into_list, merge}`. `paths` is the list of bundle paths
        # (whitespace- and comma-separated forms are both accepted).
        # `into_list` is `nil` per slot when `--into` was absent, an aligned
        # list of target domain names when `--into` was passed with the
        # same number of slots, or rejected when the count is mismatched.
        private def self.parse_import_args(args : Array(String)) : {Array(String), Array(String?), Bool}
          into_raw : String? = nil
          merge = false
          positional = [] of String
          banner = "Usage: facet domain:import <path>[,path,...] [--into <domain>[,domain,...]] [--merge]"
          OptionParser.parse(args) do |parser|
            parser.banner = banner
            parser.on("--into DOMAINS", "Target domain name(s); comma-separated when multiple paths are passed (counts must align)") do |d|
              into_raw = d
            end
            parser.on("--merge", "Allow importing over an existing domain (creates the domain when missing; the version gate applies to existing doctypes)") do
              merge = true
            end
            parser.on("-h", "--help", "Show help") do
              puts parser
              exit 0
            end
            parser.unknown_args do |pos|
              positional.concat(pos)
            end
          end
          paths = expand_comma_list(positional)
          if paths.empty?
            abort "Error: at least one bundle path is required.\n#{banner}"
          end
          into_list = parse_into_list(into_raw, paths.size, banner)
          {paths, into_list, merge}
        end

        # Resolves `--into` to a per-slot aligned list of target domain
        # names (or `nil` per slot when `--into` was absent). Rejects a
        # single `--into` value combined with multiple paths — the operator
        # must either omit `--into` or pass a comma-separated list whose
        # count matches the number of paths.
        private def self.parse_into_list(
          into_raw : String?,
          path_count : Int32,
          banner : String,
        ) : Array(String?)
          return Array(String?).new(path_count, nil) unless into_raw

          into_values = into_raw.split(',').map(&.strip).reject(&.empty?)
          if into_values.size != path_count
            abort "Error: --into has #{into_values.size} value(s) but #{path_count} path(s) were given — counts must align.\n#{banner}"
          end
          into_values.map { |v| v.as(String?) }
        end

        # Expands `positional` into the de-duplicated list of values. Each
        # positional may carry one value or a comma-separated list; both
        # forms may be mixed. Whitespace around each token is stripped.
        # Made module-level-instead-of-private and exposed as a public
        # class method so the spec can unit-test the comma expansion
        # without constructing a full CLI run.
        def self.expand_comma_list(positional : Array(String)) : Array(String)
          expanded = [] of String
          positional.each do |token|
            token.split(',').each do |part|
              trimmed = part.strip
              expanded << trimmed unless trimmed.empty?
            end
          end
          expanded.uniq!
          expanded
        end

        # ── Output ─────────────────────────────────────────────────────────

        private def self.print_export_summary(result : Export::Result, written : String, *, label : String) : Nil
          puts "[#{label}] Exported to #{written}"
          puts "  doctypes:          #{result.doctype_count}"
          puts "  document views:    #{result.document_view_count}"
          puts "  collection views:  #{result.collection_view_count} (general only; personal excluded)"
          puts "  documents:         #{result.document_count}" if result.document_count > 0
        end

        private def self.print_import_summary(result : Import::Result, *, label : String) : Nil
          verb = result.created ? "Created" : "Merged"
          puts "[#{label}] #{verb} domain '#{result.domain}'"
          puts "  doctypes:          #{result.doctypes_created} created, #{result.doctypes_updated} updated, #{result.doctypes_unchanged} unchanged"
          if result.created
            puts "  document views:    #{result.document_views_created} created"
            puts "  collection views:  #{result.collection_views_created} created (general)"
          else
            puts "  document views:    #{result.document_views_created} created, #{result.document_views_updated} updated, #{result.document_views_deleted} deleted"
            puts "  collection views:  #{result.collection_views_created} created, #{result.collection_views_updated} updated (general; target views left alone)"
          end
          puts "  documents:         #{result.documents_created} created" if result.documents_created > 0
          result.grant_tickets.each do |t|
            state = t.active ? "active" : "inactive — awaiting the producer's acceptance"
            action = t.filed ? "filed" : "merged"
            puts "  grant ticket:      #{t.producer} #{action} (#{state})"
          end
        end

        # Pretty label for an import summary line — uses the `--into` target
        # when given, otherwise the bundle's source domain.
        private def self.import_label(bundle : Archive::Bundle, into : String?) : String
          into || bundle.source_domain
        end

        # Drains `Index::Manager` background DDL fibers before closing the
        # singleton pool. Mirrors `Facet::CLI#drain_index_ddl_and_close` in
        # `src/main.cr` so a CLI run does not hang on a checked-out
        # connection holding a background fiber. The retry pass runs
        # quiet: it prints nothing when no row is retryable.
        private def self.drain_index_ddl_and_close : Nil
          unless Facet::Index::Manager.wait_for_pending_fibers
            Log.for("facet.cli").warn do
              "Background index fibers did not drain within the timeout — " \
              "some indexes may be left in 'pending' status; run `facet index:retry` to finish them."
            end
          end

          Facet::Database.with_db do |db|
            Facet::Index::RetryCLI.retry_all(db, quiet: true)
          end

          Facet::Database.close
        end
      end
    end
  end
end
