# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "compress/zip"
require "json"
require "yaml"
require "file"
require "file_utils"
require "../externalize"

module Facet
  module Domain
    module Portable
      module Archive
        # ── Writers ────────────────────────────────────────────────────────

        # Writes the bundle to `path`. A path ending in `.zip` produces a
        # zip archive; `.tar.gz` (or `.tgz`) produces a tarball; any other
        # path is treated as a directory and created if absent. Returns
        # the absolute path written.
        def self.write(bundle : Bundle, path : String) : String
          if zip?(path) && !Dir.exists?(path)
            write_zip(bundle, path)
          elsif tarball?(path)
            write_tarball(bundle, path)
          else
            write_directory(bundle, path)
          end
          File.expand_path(path)
        end

        # Writes the bundle as a directory tree.
        private def self.write_directory(bundle : Bundle, path : String) : Nil
          Dir.mkdir_p(path)
          sanity_check_directory(path)

          File.write(File.join(path, "bundle.yml"), bundle_yml(bundle))
          write_entry(File.join(path, "domain.yml"), bundle.domain, Externalize.domain_policy(bundle.domain.content))

          dir = File.join(path, "doctypes")
          Dir.mkdir_p(dir)
          bundle.doctypes.each do |entry|
            write_entry(File.join(dir, "#{entry[:doctype]}.yml"), entry[:entry], Externalize.doctype_policy(entry[:doctype]))
          end

          views = File.join(path, "views")
          Dir.mkdir_p(views)
          bundle.document_views.each do |qualified, dviews|
            view_dir = File.join(views, qualified, "document_views")
            Dir.mkdir_p(view_dir)
            dviews.each do |dv|
              write_entry(File.join(view_dir, "#{dv[:kind]}.yml"), dv[:entry])
            end
          end
          bundle.collection_views.each do |qualified, cviews|
            next if cviews.empty?
            view_dir = File.join(views, qualified, "collection_views")
            Dir.mkdir_p(view_dir)
            cviews.each do |cv|
              write_entry(File.join(view_dir, "#{cv.slug}.yml"), cv.entry)
            end
          end

          documents_dir = File.join(path, "documents")
          bundle.documents.each do |qualified, docs|
            next if docs.empty?
            doc_dir = File.join(documents_dir, qualified)
            Dir.mkdir_p(doc_dir)
            docs.each do |doc|
              write_entry(File.join(doc_dir, "#{document_slug(doc.id)}.yml"), doc.entry)
            end
          end
        end

        # Writes the bundle to a temp directory, then invokes the system
        # `tar` binary to produce a gzip tarball at `path`. The temp
        # directory is removed on completion. Unix-only by design (see
        # `doc/backend/portable-domains.md` → Tarball handling).
        private def self.write_tarball(bundle : Bundle, path : String) : Nil
          parent = File.dirname(File.expand_path(path))
          Dir.mkdir_p(parent)

          scratch = File.tempname("facet-domain-bundle")
          Dir.mkdir_p(scratch)
          begin
            write_directory(bundle, scratch)

            # `tar` runs in `scratch` so archive entries are relative.
            # `-czf` gzip-compresses; the destination is an absolute
            # path so the chdir does not change where the file lands.
            run_tar(["-czf", File.expand_path(path), "."], scratch, "tar")
          ensure
            FileUtils.rm_r(scratch) if Dir.exists?(scratch)
          end
        end

        # Writes the bundle as a zip archive. The bundle tree is built in
        # a temp directory (the same layout `write_directory` produces),
        # then every file is added to the archive under its path relative
        # to the tree root. Pure stdlib (`Compress::Zip::Writer`) — the
        # HTTP surface needs no external binary. The temp directory is
        # removed on completion.
        private def self.write_zip(bundle : Bundle, path : String) : Nil
          parent = File.dirname(File.expand_path(path))
          Dir.mkdir_p(parent)

          scratch = File.tempname("facet-domain-bundle")
          Dir.mkdir_p(scratch)
          begin
            write_directory(bundle, scratch)

            Compress::Zip::Writer.open(path) do |zip|
              tree_files(scratch).each do |file|
                relative = file[(scratch.size + 1)..]
                zip.add(relative, File.open(file))
              end
            end
          ensure
            FileUtils.rm_r(scratch) if Dir.exists?(scratch)
          end
        end

        # Every file under `root`, sorted, so the archive entry order is
        # deterministic across runs.
        private def self.tree_files(root : String) : Array(String)
          Dir.glob(File.join(root, "**", "*")).select { |p| File.file?(p) }.sort!
        end

        # Refuses to write into an existing directory that does not look
        # like a bundle. A stale directory from an interrupted run is fine
        # (no trailing guardrails prevent that).
        private def self.sanity_check_directory(path : String) : Nil
          return unless Dir.exists?(path)
          # An empty directory is acceptable. Anything that looks like a
          # bundle (has `bundle.yml`) is acceptable (overwrite). A
          # non-empty directory without `bundle.yml` is rejected so we do
          # not silently clobber a user's working folder.
          return if Dir.empty?(path) || File.exists?(File.join(path, "bundle.yml"))
          raise Error.new("Refusing to overwrite non-bundle directory: #{path}")
        end

        # Serialises the bundle metadata as YAML. Hand-rolled rather than
        # via `to_yaml` so the field order is deterministic and the file
        # reads as a flat YAML document (no `---` markers, no nested
        # document preamble).
        #
        # String fields are emitted with `yaml_string`, which only quotes
        # when the value would otherwise be ambiguous to a YAML parser
        # (e.g. starts with a special character, looks like a number or
        # boolean). A simple value like `crm` renders as `crm`, not
        # `"crm"` — keeping the file reviewer-friendly.
        private def self.bundle_yml(bundle : Bundle) : String
          String.build do |io|
            io << "format_version: " << FORMAT_VERSION << '\n'
            io << "source_domain: " << yaml_string(bundle.source_domain) << '\n'
            io << "exported_at: " << yaml_string(bundle.exported_at) << '\n'
            io << "facet_version: " << yaml_string(bundle.facet_version) << '\n'
          end
        end

        # Returns `value` as a YAML-safe plain scalar, quoting only when
        # necessary. A string that starts with a reserved YAML character
        # (``: - ? { } [ ] , & * # ! | > ' \" % @ ` ``) or that parses as
        # something other than a string (number, boolean, null) is
        # double-quoted. Otherwise it is emitted unquoted and unescaped
        # for maximum readability.
        private def self.yaml_string(value : String) : String
          if value.empty? || needs_yaml_quoting?(value)
            value.inspect # Crystal String#inspect yields a Ruby-style "…" literal
          else
            value
          end
        end

        # True when `value` must be double-quoted to round-trip through a
        # YAML parser unambiguously. Covers: leading colons / dashes,
        # reserved-indicator characters at start, anything that parses as
        # a number / boolean / null / timestamp, and embedded newlines
        # (block scalars would otherwise require indentation).
        private def self.needs_yaml_quoting?(value : String) : Bool
          return true if value.empty?
          # Leading whitespace or reserved indicator chars.
          first = value[0]
          return true if first.in?("-?:,[]{}#&*!|>'\"%@`")
          return true if value[0]? == ' '
          return true if value.includes?('\n')
          # Looks-like-a-number / boolean / null.
          case value.downcase
          when "true", "false", "yes", "no", "on", "off", "null", "~", ""
            return true
          end
          # Integer, float, or timestamp pattern.
          return true if value.matches?(/^[-+]?\d+$/)
          return true if value.matches?(/^[-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?$/)
          return true if value.matches?(/^\d{4}-\d{2}-\d{2}/)
          false
        end

        # Writes an `Entry` to a YAML file as a single YAML mapping
        # `{content: …, meta: …}`.
        #
        # Uses the `YAML::Nodes::Builder` API directly (rather than
        # `Hash#to_yaml`) so string scalars containing `\n` emit as
        # YAML `|` literal block scalars —Crystal's default emitter
        # emits such strings as escaped double-quoted single-line
        # values, which is unreadable for the doctype's embedded Lua
        # `script`. Every string scalar passes through
        # `emit_string_scalar`, which chooses plain / literal style.
        # Non-string leaves delegate to the default emitter.
        #
        # When `externalize` is non-nil, string scalars at a path the policy
        # names are written to a co-located sidecar file and emitted as
        # `!read_file <filename>` instead of inline. The sidecar lives next
        # to the entry YAML (same directory), so the reference stays inside
        # the `!read_file` jail on re-import.
        private def self.write_entry(path : String, entry : Entry, externalize : Externalize::Policy? = nil) : Nil
          builder = YAML::Nodes::Builder.new
          builder.mapping do
            builder.scalar("content")
            emit_any(builder, entry.content, externalize, File.dirname(path), [] of String)
            builder.scalar("meta")
            emit_any(builder, entry.meta, nil, File.dirname(path), [] of String)
          end
          File.open(path, "w") do |io|
            YAML.build(io) { |yaml| builder.document.to_yaml(yaml) }
          end
        end

        # Emits a `JSON::Any` value as a YAML node tree. Mappings emit
        # as a YAML mapping (key insertion order preserved — `JSON::Any`
        # wraps a `Hash(String, JSON::Any)` whose iteration is insertion
        # order in Crystal, so the on-disk field order matches the
        # original doctype definition).
        #
        # *externalize* is the active policy (nil = inline). *base_dir* is
        # the directory of the entry YAML — the sidecar's home. *path* is
        # the JSON key path from the content root to the current node; when
        # a string scalar's path matches the policy, it is externalized.
        private def self.emit_any(
          builder : YAML::Nodes::Builder,
          value : JSON::Any,
          externalize : Externalize::Policy?,
          base_dir : String,
          path : Array(String),
        ) : Nil
          case raw = value.raw
          when Hash(String, JSON::Any)
            builder.mapping do
              raw.each do |k, v|
                emit_any(builder, JSON::Any.new(k), nil, base_dir, path)
                emit_any(builder, v, externalize, base_dir, path + [k])
              end
            end
          when Array(JSON::Any)
            builder.sequence do
              raw.each_with_index do |v, i|
                emit_any(builder, v, externalize, base_dir, path + [i.to_s])
              end
            end
          when String
            emit_string_scalar(builder, raw, externalize, base_dir, path)
          when Bool
            builder.scalar(raw.to_s)
          when Int64
            builder.scalar(raw.to_s)
          when Float64
            builder.scalar(raw.to_s)
          when Nil
            builder.scalar("")
          else
            # Should not happen for well-formed entries — fallback to
            # the default emitter for any unexpected JSON::Any leaf type.
            builder.scalar(raw.to_s)
          end
        end

        # Emits a string scalar. When the scalar sits at a path the
        # *externalize* policy names, its contents are written to the
        # sidecar file and the scalar is emitted as `!read_file <filename>`
        # (a tagged scalar). Otherwise multi-line strings use the YAML
        # literal block style (`|`), preserving every embedded newline and
        # indentation. Single-line strings are quoted when
        # `needs_yaml_quoting?` flags them as YAML-reserved words that the
        # reader would otherwise coerce to a bool / number / null — the YAML
        # 1.1 core schema (which Crystal's reader uses) treats the bare
        # tokens `yes`, `no`, `on`, `off`, `true`, `false`, `null` as their
        # typed counterparts, so an enum value like `key: no` would
        # round-trip back as `false` and break `EnumValue.from_json`.
        #
        # The literal block style requires the value to end with a newline
        # (the YAML spec treats a `|` block as ending at the last non-empty
        # line). A trailing `\n` is appended when the string does not already
        # end with one; on read the YAML parser returns the string with the
        # trailing newline, which is semantically equal to the original for
        # the doctype's Lua script (a trailing newline is the Lua convention
        # for a final `return export`) and for any other multi-line content.
        private def self.emit_string_scalar(
          builder : YAML::Nodes::Builder,
          value : String,
          externalize : Externalize::Policy?,
          base_dir : String,
          path : Array(String),
        ) : Nil
          if (filename = externalize.try(&.filename_for(path))) && !value.empty?
            write_sidecar(base_dir, filename, value)
            builder.scalar(filename, tag: READ_FILE_TAG)
            return
          end

          if value.includes?('\n')
            literal = value.ends_with?('\n') ? value : value + '\n'
            builder.scalar(literal, style: YAML::ScalarStyle::LITERAL)
          elsif needs_yaml_quoting?(value)
            builder.scalar(value, style: YAML::ScalarStyle::DOUBLE_QUOTED)
          else
            builder.scalar(value)
          end
        end

        # Writes *value* to the sidecar file at `base_dir/filename`. The
        # parent directory is created if absent (e.g. the `hooks/` folder).
        # The file is written verbatim — no trailing newline is added, so
        # the round-trip preserves the exact script bytes.
        private def self.write_sidecar(base_dir : String, filename : String, value : String) : Nil
          target = File.join(base_dir, filename)
          parent = File.dirname(target)
          Dir.mkdir_p(parent) unless Dir.exists?(parent)
          File.write(target, value)
        end
      end
    end
  end
end
