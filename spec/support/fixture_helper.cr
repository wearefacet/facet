# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Fixture helpers ──────────────────────────────────────────────────────────
#
# Helpers for loading fixture data from `data/fixtures/` (portable-domain
# bundles) and `data/seeds/` (legacy per-doctype directories). These are
# top-level functions available in every spec.
#
# Fixtures live as portable-domain bundles (the format produced by
# `facet domain:export --with-documents`). Each bundle directory is
# `data/fixtures/{domain}.facet-domain/` and contains:
#   bundle.yml                       # format metadata (not consulted here)
#   domain.yml                       # { content, meta } — core.Domain document
#   doctypes/{Qualified}.yml         # { content, meta } — content IS the definition
#   views/{qualified}/
#     document_views/{kind}.yml      # { content, meta } — core.DocumentView children
#     collection_views/{slug}.yml    # { content, meta } — core.CollectionView children
#   documents/{qualified}/{doc_id}.yml  # { content, meta } — one per user document
#
# Seeds keep the legacy per-doctype directory format:
#   data/seeds/{domain}.{Doctype}/
#     definition.yml  — the doctype schema
#     script.lua      — optional Lua script, injected into the definition
#     documents file(s) — optional arrays of { id, content } seed documents

require "json"
require "yaml"
require "../../src/util/yaml_include"

# Resolves the project root relative to this file's location.
# This file lives at spec/support/fixture_helper.cr, so we traverse up.
private FIXTURES_DIR = File.join(__DIR__, "..", "..", "data", "fixtures")
private SEEDS_DIR    = File.join(__DIR__, "..", "..", "data", "seeds")

# ── Seed path helpers (legacy per-doctype directory format) ─────────────────

# Returns the path to a seed directory, or raises if it doesn't exist.
def seed_path(domain : String, doctype : String) : String
  dir = File.join(SEEDS_DIR, "#{domain}.#{doctype}")
  raise "Seed directory not found: #{dir}" unless Dir.exists?(dir)
  dir
end

# Reads and parses a definition file from a seed directory.
def load_seed_definition(domain : String, doctype : String) : Facet::Doctype::DoctypeDefinition
  dir = seed_path(domain, doctype)
  path = definition_file_in(dir)
  raise "No definition file found in #{dir}" unless path
  raw = File.read(path)
  defn = case File.extname(path)
         when ".yml", ".yaml"
           Facet::Doctype::DoctypeDefinition.from_yaml(raw)
         else
           Facet::Doctype::DoctypeDefinition.from_json(raw)
         end

  # Inject script.lua if it exists alongside the definition. The bundle
  # format already embeds the script in the doctype content, so this only
  # applies to seed definitions.
  script_path = File.join(dir, "script.lua")
  if File.exists?(script_path)
    script = File.read(script_path)
    defn = Facet::Doctype::DoctypeDefinition.new(
      doctype: defn.doctype,
      domain: defn.domain,
      schema_version: defn.schema_version,
      aggregate_root: defn.aggregate_root,
      member_of: defn.member_of,
      fields: defn.fields,
      children: defn.children,
      actions: defn.actions,
      script: script
    )
  end
  defn
end

# Reads and parses a documents file from a seed directory.
def load_seed_documents(domain : String, doctype : String) : Array(NamedTuple(id: String, content: String))
  dir = seed_path(domain, doctype)
  paths = documents_files_in(dir)
  return [] of NamedTuple(id: String, content: String) if paths.empty?

  out = [] of NamedTuple(id: String, content: String)
  paths.each do |path|
    raw = File.read(path)
    json_raw = case File.extname(path)
               when ".yml", ".yaml"
                 YAML.parse(raw).to_json
               else
                 raw
               end

    docs = JSON.parse(json_raw).as_a
    docs.each do |doc|
      out << {
        id:      doc["id"].as_s,
        content: doc["content"]?.try(&.to_json) || "{}",
      }
    end
  end
  out
end

# ── Fixture helpers (portable-domain bundles) ───────────────────────────────

# Returns the path to a fixture bundle directory, or raises if it doesn't exist.
def fixture_bundle_path(domain : String) : String
  dir = File.join(FIXTURES_DIR, "#{domain}.facet-domain")
  raise "Fixture bundle not found: #{dir}" unless Dir.exists?(dir)
  dir
end

# Reads and parses a doctype definition from a fixture bundle. The bundle
# stores the definition as the `content` field of
# `doctypes/{Qualified}.yml`; the `script` is either embedded inline in the
# content or pulled in from `doctypes/{Qualified}.lua` via the `!read_file`
# directive. Either way `parse_bundle_entry` expands the directive first, so
# the resulting definition carries the script with no separate injection step.
def load_fixture_definition(domain : String, doctype : String) : Facet::Doctype::DoctypeDefinition
  qualified = "#{domain}.#{doctype}"
  path = File.join(fixture_bundle_path(domain), "doctypes", "#{qualified}.yml")
  raise "Fixture definition not found: #{path}" unless File.exists?(path)

  entry = parse_bundle_entry(path)
  content_json = entry["content"].to_json
  Facet::Doctype::DoctypeDefinition.from_json(content_json)
end

# Reads and parses every user document of a fixture doctype. Each document
# lives at `documents/{Qualified}/{doc_id}.yml`; the document id is the
# filename stem (the bundle does not embed the id in the entry's content or
# meta). Returns `[]` when the doctype has no documents directory.
def load_fixture_documents(domain : String, doctype : String) : Array(NamedTuple(id: String, content: String))
  qualified = "#{domain}.#{doctype}"
  docs_dir = File.join(fixture_bundle_path(domain), "documents", qualified)
  return [] of NamedTuple(id: String, content: String) unless Dir.exists?(docs_dir)

  paths = Dir.children(docs_dir)
    .select { |name| name.ends_with?(".yml") || name.ends_with?(".yaml") }
    .sort!
    .map { |name| File.join(docs_dir, name) }

  paths.map do |path|
    entry = parse_bundle_entry(path)
    doc_id = File.basename(path, File.extname(path))
    {
      id:      doc_id,
      content: entry["content"]?.try(&.to_json) || "{}",
    }
  end
end

# Reads every `core.Domain` fixture document across all bundles. Each
# bundle carries its domain row at `domain.yml` as a `{ content, meta }`
# entry whose projection id is the bundle's source domain name.
def load_fixture_domains : Array(NamedTuple(id: String, content: String))
  out = [] of NamedTuple(id: String, content: String)
  bundle_dirs = Dir.glob(File.join(FIXTURES_DIR, "*.facet-domain")).sort!

  bundle_dirs.each do |bundle|
    path = File.join(bundle, "domain.yml")
    next unless File.exists?(path)
    entry = parse_bundle_entry(path)
    # The bundle directory name is `{domain}.facet-domain`.
    domain_id = File.basename(bundle, ".facet-domain")
    out << {
      id:      domain_id,
      content: entry["content"]?.try(&.to_json) || "{}",
    }
  end
  out
end

# Reads every `core.DocumentView` fixture document across all bundles. Each
# bundle carries its DocumentView children under
# `views/{qualified}/document_views/{kind}.yml`; the id is not embedded in
# the entry, so it is reconstructed as `{qualified}.document_view.{kind}` to
# match the backend's child-id convention (mirrors `Document::Copy` and the
# frontend mock driver's child-prefix resolution).
def load_fixture_document_views : Array(NamedTuple(id: String, content: String))
  aggregate_view_documents("document_views")
end

# Reads every `core.CollectionView` fixture document across all bundles. Each
# bundle carries its general CollectionView children under
# `views/{qualified}/collection_views/{slug}.yml`; the filename stem IS the
# full projection id (the export sanitises the slug from the id).
def load_fixture_collection_views : Array(NamedTuple(id: String, content: String))
  aggregate_view_documents("collection_views")
end

# ── Private helpers ─────────────────────────────────────────────────────────

# Parses a bundle entry file (`{ content, meta }` YAML mapping) into a
# `JSON::Any` tree so the caller can pluck `content` / `meta` as JSON.
# Honours the `!read_file <relative-path>` directive (see
# `Facet::Util::YamlInclude`): any referenced file is expanded against the
# entry file's own directory, jail-restricted to that directory and its
# descendants.
private def parse_bundle_entry(path : String) : JSON::Any
  parsed = Facet::Util::YamlInclude.parse_file(path, [Facet::Util::YamlTag::ReadFileTag.new])
  # YAML → JSON round-trip so the caller gets `JSON::Any`. The bundle uses
  # YAML for human-readability; the wire format of these records is JSON.
  JSON.parse(parsed.to_json)
end

# Walks every bundle's `views/{qualified}/{subdir}/*.yml` and returns the
# aggregated `{ id, content }` entries. The id reconstruction differs per
# subdir (document_views prepend `{qualified}.document_view.`; collection_views
# use the filename stem as-is).
private def aggregate_view_documents(subdir : String) : Array(NamedTuple(id: String, content: String))
  out = [] of NamedTuple(id: String, content: String)
  bundle_dirs = Dir.glob(File.join(FIXTURES_DIR, "*.facet-domain")).sort!

  bundle_dirs.each do |bundle|
    views_root = File.join(bundle, "views")
    next unless Dir.exists?(views_root)

    # Each child directory under `views/` is a parent qualified doctype.
    Dir.children(views_root).sort!.each do |parent_qualified|
      parent_views = File.join(views_root, parent_qualified, subdir)
      next unless Dir.exists?(parent_views)

      Dir.children(parent_views).sort!.each do |filename|
        next unless filename.ends_with?(".yml") || filename.ends_with?(".yaml")
        path = File.join(parent_views, filename)
        entry = parse_bundle_entry(path)
        kind = File.basename(filename, File.extname(filename))
        id =
          case subdir
          when "document_views" then "#{parent_qualified}.document_view.#{kind}"
          else                       kind # collection_views: filename stem is the full id
          end
        out << {
          id:      id,
          content: entry["content"]?.try(&.to_json) || "{}",
        }
      end
    end
  end
  out
end

# ── Seed-directory file helpers (unchanged) ──────────────────────────────────

private def definition_file_in(dir : String) : String?
  %w[definition.yaml definition.yml definition.json].each do |f|
    path = File.join(dir, f)
    return path if File.exists?(path)
  end
  nil
end

# Returns every documents file in a seed directory, sorted by filename for
# deterministic loading order. A documents file is any *.yml/*.yaml/*.json
# file that is not `definition.*` or `script.lua`.
private def documents_files_in(dir : String) : Array(String)
  Dir.children(dir).select do |name|
    next false if name.starts_with?(".")
    next false if name == "script.lua"
    next false if name.starts_with?("definition.")
    ext = File.extname(name)
    ext.in?(".yml", ".yaml", ".json")
  end.sort!.map { |name| File.join(dir, name) }
end
