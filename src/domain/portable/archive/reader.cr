# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "compress/zip"
require "json"
require "yaml"
require "file"
require "file_utils"
require "../../../util/yaml_include"

module Facet
  module Domain
    module Portable
      module Archive
        # ── Readers ────────────────────────────────────────────────────────

        # Reads a bundle from `path`. Auto-detects directory, zip, and
        # tarball forms — a zip by extension or `PK` magic bytes.
        def self.read(path : String) : Bundle
          unless File.exists?(path)
            raise Error.new("Bundle path does not exist: #{path}")
          end
          if File.directory?(path)
            read_directory(path)
          elsif zip?(path)
            read_zip(path)
          else
            read_tarball(path)
          end
        end

        # Reads a bundle from a directory tree.
        private def self.read_directory(path : String) : Bundle
          meta, format_version = parse_bundle_yml(File.join(path, "bundle.yml"))
          source_domain = meta["source_domain"].as_s
          exported_at = meta["exported_at"].as_s
          facet_version = meta["facet_version"].as_s

          entry_ext = entry_extension(format_version)
          domain = read_entry(File.join(path, "domain#{entry_ext}"), format_version)

          doctypes = [] of {doctype: String, entry: Entry}
          dt_dir = File.join(path, "doctypes")
          if Dir.exists?(dt_dir)
            Dir.glob(File.join(dt_dir, "*#{entry_ext}")).sort!.each do |f|
              name = File.basename(f, entry_ext)
              doctypes << {doctype: name, entry: read_entry(f, format_version)}
            end
          end

          document_views = {} of String => Array({kind: String, entry: Entry})
          collection_views = {} of String => Array(CollectionView)
          views = File.join(path, "views")
          if Dir.exists?(views)
            traverse_views(views, document_views, collection_views, format_version)
          end

          documents = {} of String => Array(DocumentEntry)
          documents_root = File.join(path, "documents")
          if Dir.exists?(documents_root)
            traverse_documents(documents_root, documents, format_version)
          end

          Bundle.new(source_domain, exported_at, facet_version, domain, doctypes, document_views, collection_views, documents)
        end

        # Reads a bundle from a `.tar.gz` by extracting it into a temp
        # directory and delegating to `read_directory`.
        private def self.read_tarball(path : String) : Bundle
          scratch = File.tempname("facet-domain-bundle-extract")
          Dir.mkdir_p(scratch)
          begin
            run_tar(["-xzf", File.expand_path(path)], scratch, "tar extract")

            root = find_bundle_root(scratch)
            read_directory(root)
          ensure
            FileUtils.rm_r(scratch) if Dir.exists?(scratch)
          end
        end

        # Reads a zip archive by extracting every entry into a temp
        # directory and delegating to `read_directory`. Entry names are
        # validated before any byte lands on disk: a name that would
        # escape the extraction root (absolute, or carrying a `..`
        # segment) aborts the whole read — an archive arriving over HTTP
        # is untrusted input.
        private def self.read_zip(path : String) : Bundle
          scratch = File.tempname("facet-domain-bundle-extract")
          Dir.mkdir_p(scratch)
          begin
            Compress::Zip::File.open(path) do |zip|
              zip.entries.each do |entry|
                name = safe_entry_name(entry.filename)
                target = File.join(scratch, name)
                if entry.dir?
                  Dir.mkdir_p(target)
                else
                  Dir.mkdir_p(File.dirname(target))
                  File.open(target, "wb") do |f|
                    entry.open { |io| IO.copy(io, f) }
                  end
                end
              end
            end

            root = find_bundle_root(scratch)
            read_directory(root)
          rescue ex : Compress::Zip::Error
            raise Error.new("Unreadable zip archive: #{ex.message}")
          ensure
            FileUtils.rm_r(scratch) if Dir.exists?(scratch)
          end
        end

        # Validates one zip entry name and returns it in normalised form.
        # Raises `Error` when the name would escape the extraction root:
        # empty, an absolute path, or any `..` path segment. Backslashes
        # normalise to forward slashes first — some Windows tools write
        # separators that way.
        private def self.safe_entry_name(name : String) : String
          normalised = name.gsub('\\', '/')
          if normalised.empty? || normalised.starts_with?('/') || normalised.split('/').includes?("..")
            raise Error.new("Unsafe zip entry name: #{name.inspect}")
          end
          normalised
        end

        # Walks the `views/` tree and populates the `document_views` and
        # `collection_views` maps. `document_views` are keyed by qualified
        # doctype and enumerated by `kind`; `collection_views` are keyed by
        # qualified doctype and enumerated by slug basename.
        private def self.traverse_views(
          views_root : String,
          document_views : Hash(String, Array({kind: String, entry: Entry})),
          collection_views : Hash(String, Array(CollectionView)),
          format_version : Int32,
        ) : Nil
          entry_ext = entry_extension(format_version)
          Dir.glob(File.join(views_root, "*", "*")).each do |view_kind_dir|
            next unless Dir.exists?(view_kind_dir)
            qualified = File.basename(File.dirname(view_kind_dir))
            kind = File.basename(view_kind_dir)
            next unless kind == "document_views" || kind == "collection_views"

            files = Dir.glob(File.join(view_kind_dir, "*#{entry_ext}")).sort!
            case kind
            when "document_views"
              arr = document_views[qualified] ||= [] of {kind: String, entry: Entry}
              files.each do |f|
                name = File.basename(f, entry_ext)
                arr << {kind: name, entry: read_entry(f, format_version)}
              end
            when "collection_views"
              arr = collection_views[qualified] ||= [] of CollectionView
              files.each do |f|
                name = File.basename(f, entry_ext)
                arr << CollectionView.new(name, read_entry(f, format_version))
              end
            end
          end
        end

        # Walks the `documents/` tree and populates the `documents` map.
        # Each `documents/{qualified}/{doc_id}.yml` file becomes a
        # `DocumentEntry` keyed by qualified doctype id. The on-disk
        # `doc_id` slug is recovered by stripping the entry extension —
        # the original id is preserved as long as it contains no path-
        # separator characters (the writer sanitises through
        # `document_slug`, which is reversible for the slug grammar).
        private def self.traverse_documents(
          documents_root : String,
          documents : Hash(String, Array(DocumentEntry)),
          format_version : Int32,
        ) : Nil
          entry_ext = entry_extension(format_version)
          Dir.glob(File.join(documents_root, "*")).sort!.each do |qualified_dir|
            next unless Dir.exists?(qualified_dir)
            qualified = File.basename(qualified_dir)
            arr = documents[qualified] ||= [] of DocumentEntry
            Dir.glob(File.join(qualified_dir, "*#{entry_ext}")).sort!.each do |f|
              doc_id = File.basename(f, entry_ext)
              arr << DocumentEntry.new(doc_id, read_entry(f, format_version))
            end
          end
        end

        # Searches `scratch` (one or two levels deep) for a `bundle.yml`
        # and returns its containing directory. Raises if none is found.
        private def self.find_bundle_root(scratch : String) : String
          direct = File.join(scratch, "bundle.yml")
          return scratch if File.exists?(direct)

          Dir.glob(File.join(scratch, "*")).each do |child|
            next unless Dir.exists?(child)
            return child if File.exists?(File.join(child, "bundle.yml"))
          end

          raise Error.new("No bundle.yml found inside tarball")
        end

        # Parses `bundle.yml`. Hand-rolled schema validation so the
        # reader does not silently accept unknown or future formats.
        # Returns the coerced field map and the validated `format_version`
        # integer so the reader can dispatch the entry-file decoder
        # (YAML for v2+, JSON for the legacy v1).
        private def self.parse_bundle_yml(path : String) : {Hash(String, YAML::Any), Int32}
          unless File.exists?(path)
            raise Error.new("Missing bundle.yml — not a portable-domain bundle")
          end
          parsed = begin
            YAML.parse(File.read(path))
          rescue ex : YAML::ParseException
            # Name the file — a bare YAML backtrace is useless to the
            # operator hand-editing a bundle (B-26).
            raise Error.new("#{path}: line #{ex.line_number}: #{ex.message}")
          end
          begin
            hash = parsed.as_h
          rescue TypeCastError
            raise Error.new("#{path}: the document must be a YAML mapping")
          end

          format_version_any = hash["format_version"]?
          unless format_version_any && (raw = format_version_any.raw) && raw.is_a?(Int64)
            raise Error.new("Unsupported bundle format_version (expected #{FORMAT_VERSION} or #{LEGACY_FORMAT_VERSION}, got #{format_version_any.try(&.raw).inspect})")
          end
          format_version = raw.as(Int64).to_i
          unless format_version == FORMAT_VERSION || format_version == LEGACY_FORMAT_VERSION
            raise Error.new("Unsupported bundle format_version (expected #{FORMAT_VERSION} or #{LEGACY_FORMAT_VERSION}, got #{format_version})")
          end

          %w[source_domain exported_at facet_version].each do |k|
            unless hash[k]?.try(&.raw).is_a?(String)
              raise Error.new("bundle.yml is missing required string field: #{k}")
            end
          end

          coerced = {} of String => YAML::Any
          hash.each do |k, v|
            # YAML::Any hash keys are themselves `YAML::Any` whose `.raw`
            # is the underlying scalar. Anything other than a String key
            # (e.g. an int or bool from a malformed YAML) is skipped.
            if k.raw.is_a?(String)
              coerced[k.as_s] = v
            end
          end
          {coerced, format_version}
        end

        # File extension used by entry files for the given bundle
        # `format_version`. v2+ uses `.yml`; the legacy v1 used `.json`.
        private def self.entry_extension(format_version : Int32) : String
          format_version >= FORMAT_VERSION ? ".yml" : ".json"
        end

        # Reads a `{content, meta}` entry file into an `Entry`. Dispatches
        # by `format_version`: YAML for v2+, JSON for v1.
        private def self.read_entry(path : String, format_version : Int32) : Entry
          if format_version >= FORMAT_VERSION
            read_entry_yaml(path)
          else
            read_entry_json(path)
          end
        end

        # Reads a YAML entry file (`content: …\nmeta: …`). Crystal's
        # `YAML.parse` returns `YAML::Any`, but the rest of the portable-
        # domain code works in `JSON::Any`. Round-tripping through JSON
        # preserves value types (Int64 → Int64, etc.) for the
        # `content_identical?` canonical comparison.
        #
        # Parsing goes through `Util::YamlInclude.parse_file`, which resolves the
        # `!read_file <relative-path>` directive against the entry file's own
        # directory. The expansion is jail-restricted to that directory and its
        # descendants (no `..` traversal, no absolute paths, no symlinks pointing
        # outside), so a fixture YAML cannot reach outside its own folder. See
        # `src/util/yaml_include.cr`.
        private def self.read_entry_yaml(path : String) : Entry
          parsed = begin
            Facet::Util::YamlInclude.parse_file(path, [Facet::Util::YamlTag::ReadFileTag.new])
          rescue ex : YAML::ParseException
            # `YAML::ParseException` knows line/column but not the file —
            # the reader is the only place that can name it (B-26).
            raise Error.new("#{path}: line #{ex.line_number}: #{ex.message}")
          rescue ex : Facet::Util::YamlInclude::IncludeError
            # A missing entry file (or a missing `!read_file` sidecar)
            # arrives as an `ExpandError` naming the path — re-wrap it as
            # the reader's own error type so the CLI and the import job
            # render a clean line instead of a backtrace (B-26 residual).
            raise Error.new(ex.message || "#{path}: unreadable entry")
          end
          hash = parsed.as_h?
          content_any = hash && hash["content"]?
          meta_any = hash && hash["meta"]?
          content = content_any ? yaml_to_json_any(content_any) : JSON::Any.new(nil)
          meta = meta_any ? yaml_to_json_any(meta_any) : JSON::Any.new(nil)
          Entry.new(content, meta)
        end

        # Reads a v1 legacy `{"content", "meta"}` JSON entry file.
        private def self.read_entry_json(path : String) : Entry
          raw = begin
            JSON.parse(File.read(path)).as_h
          rescue ex : JSON::ParseException
            raise Error.new("#{path}: line #{ex.line_number}: #{ex.message}")
          rescue File::NotFoundError
            raise Error.new("#{path}: file does not exist")
          end
          content = raw["content"]? || JSON::Any.new(nil)
          meta = raw["meta"]? || JSON::Any.new(nil)
          Entry.new(content, meta)
        end

        # ── Helpers ────────────────────────────────────────────────────────

        # Runs the system `tar` binary with `args` from `chdir`. Raises
        # `Error`, labelled with `what`, when the process exits non-zero.
        private def self.run_tar(args : Array(String), chdir : String, what : String) : Nil
          stderr = IO::Memory.new
          stdout = IO::Memory.new
          status = Process.run(
            "tar",
            args,
            output: stdout,
            error: stderr,
            chdir: chdir,
          )
          unless status.success?
            raise Error.new("#{what} failed with status #{status.exit_code}: #{stderr.to_s.empty? ? "(no stderr)" : stderr.to_s}")
          end
        end

        # True when `path` ends in `.tar.gz` or `.tgz`.
        def self.tarball?(path : String) : Bool
          down = path.downcase
          down.ends_with?(".tar.gz") || down.ends_with?(".tgz")
        end

        # Zip local-file header signatures: a normal archive, an empty
        # archive (end-of-central-directory only), and a spanned archive.
        ZIP_MAGICS = ["PK\x03\x04", "PK\x05\x06", "PK\x07\x08"].map(&.to_slice)

        # True when `path` looks like a zip container: the `.zip`
        # extension, or a file whose first four bytes carry one of the
        # `PK` magic signatures. The magic check is what lets an HTTP
        # upload be identified by content when no filename rides along.
        def self.zip?(path : String) : Bool
          return true if path.downcase.ends_with?(".zip")
          return false unless File.file?(path)

          header = Bytes.new(4)
          File.open(path, "rb") do |f|
            return false unless f.read_fully?(header)
          end
          ZIP_MAGICS.includes?(header)
        end

        # Constructs a slug for a `core.CollectionView` on disk. Uses the
        # view's `id` (the projection id) when present, otherwise falls
        # back to a sanitised `name`. The slug is opaque to the import —
        # it exists only to give the file a stable, reviewable name.
        def self.collection_view_slug(id : String?, name : String?) : String
          if id && !id.empty?
            return id.gsub(/[^A-Za-z0-9_.-]/, '_')
          end
          base = (name && !name.empty?) ? name : "view"
          base.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/^_|_$/, "")
        end

        # Constructs a slug for a document's on-disk filename. Mirrors the
        # `collection_view_slug` policy: sanitise anything that is not
        # `[A-Za-z0-9_.-]` to `_` so the file name round-trips through
        # `File.basename`. The import recovers the original id from the
        # slug — this is reversible only when the source id stays inside
        # the slug grammar. Dev fixture ids (`crm.Company.1`, `exp_a1`,
        # `iam.Account.account_admin`) all qualify.
        def self.document_slug(id : String) : String
          id.gsub(/[^A-Za-z0-9_.-]/, '_')
        end
      end
    end
  end
end
