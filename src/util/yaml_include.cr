# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"
require "./yaml_tag"

# YAML parsing with pluggable tag expansion.
#
# `YamlInclude` is a thin driver over `Facet::Util::YamlTag` handlers. The
# caller passes a list of handler instances (`tags:`) and the parser rewrites
# every scalar whose tag matches one of them; a scalar tagged with anything
# else is rejected. The caller's handler list *is* the policy — there are no
# presets, no defaults, and no per-tag conditionals inside the parser.
#
# ## Entry points
#
# - `parse_file(path, tags)` — parses a YAML file from disk. Handlers receive
#   a `Context` with the file's path and directory, so file-aware handlers
#   (e.g. `ReadFileTag`) can resolve relative references.
# - `parse_string(raw, tags, source_file)` — parses an in-memory string.
#   Handlers receive `source_file` for error messages only; `base_dir` is
#   `nil`, so file-aware handlers refuse to expand.
#
# ## Callers and their tag sets
#
# | Caller | Tags passed | Rationale |
# |---|---|---|
# | `Facet::Config.load` | `[EnvTag.new, EnvOptTag.new]` | Config YAML is trusted; secrets come from the environment, and optional posture keys (`!env?`) collapse to null when their variable is unset. |
# | `Facet::Domain::Portable::Archive.read_entry_yaml` | `[ReadFileTag.new]` | Bundle YAML is untrusted authoring content; `!env` there would exfiltrate secrets. |
# | Spec fixture helpers | `[ReadFileTag.new]` | Same trust profile as bundles. |
#
# An `!env` scalar in a bundle entry is therefore rejected as an unknown tag
# rather than silently ignored — a bundle that relies on env expansion fails
# loudly instead of storing the raw tag string into the database.
#
# ## Unknown tags
#
# Any scalar whose tag is not declared by a handler in the caller's list
# raises `IncludeError`. This is fail-loud by design: a typo'd directive, or
# a tag that belongs to a different trust context (e.g. `!env` in a bundle),
# surfaces at parse time instead of leaking the raw tag into the parsed
# document.
module Facet::Util::YamlInclude
  # Raised when parsing fails: the file is missing or empty, a tag handler
  # rejects a scalar, or the document contains an unknown tag. Reported with
  # the including YAML file's path (when known) so authors can locate the
  # offending directive.
  #
  # This is an alias of `YamlTag::ExpandError` — the error class lives in
  # `YamlTag` because handlers raise it, and requiring this file from there
  # would be circular. One type for every parse-time failure.
  alias IncludeError = YamlTag::ExpandError

  # Parses the YAML file at *path*, expanding tagged scalars with *tags*.
  # Returns the document as `YAML::Any`, mirroring `YAML.parse`. The return
  # value contains no tags — every known tag has been replaced by its
  # expansion, and any unknown tag has raised.
  def self.parse_file(path : String, tags : Array(YamlTag::Handler)) : YAML::Any
    raise IncludeError.new(path, "file does not exist") unless File.exists?(path)
    parse_string(File.read(path), tags, source_file: path)
  end

  # Parses a raw YAML string, expanding tagged scalars with *tags*.
  #
  # *source_file* is optional context used only in error messages; pass the
  # YAML file's path when the string was read from disk.
  def self.parse_string(raw : String, tags : Array(YamlTag::Handler), source_file : String? = nil) : YAML::Any
    raise IncludeError.new(source_file, "no tag handlers given") if tags.empty?

    handlers = build_lookup(tags, source_file)
    doc = YAML::Nodes.parse(raw)
    expand(doc, handlers, source_file)
    root = doc.nodes.first?
    raise IncludeError.new(source_file, "empty YAML document") unless root
    YAML::Any.new(YAML::ParseContext.new, root)
  end

  # ── Internals ───────────────────────────────────────────────────────

  # Builds the tag → handler lookup and rejects duplicate tags. Two handlers
  # claiming the same tag is an authoring mistake — fail loud at parse time.
  private def self.build_lookup(tags : Array(YamlTag::Handler), source_file : String?) : Hash(String, YamlTag::Handler)
    lookup = {} of String => YamlTag::Handler
    tags.each do |handler|
      if lookup.has_key?(handler.tag)
        raise IncludeError.new(source_file, "duplicate tag handler for '#{handler.tag}'")
      end
      lookup[handler.tag] = handler
    end
    lookup
  end

  # Recursively walks *node*, rewriting every tagged scalar in place. A
  # scalar whose tag has no handler raises — unknown tags never pass through.
  private def self.expand(
    node : YAML::Nodes::Node,
    handlers : Hash(String, YamlTag::Handler),
    source_file : String?,
  ) : Nil
    case node
    when YAML::Nodes::Document
      node.nodes.each { |child| expand(child, handlers, source_file) }
    when YAML::Nodes::Mapping
      node.nodes.each { |child| expand(child, handlers, source_file) }
    when YAML::Nodes::Sequence
      node.each { |child| expand(child, handlers, source_file) }
    when YAML::Nodes::Scalar
      expand_scalar(node, handlers, source_file)
    end
  end

  # Rewrites a single tagged scalar in place. The handler owns the expansion;
  # the parser owns the bookkeeping (clear the tag, pick a scalar style that
  # survives re-emission of multi-line content). An expansion that resolves
  # to no value rewrites the scalar to a plain null instead — the containing
  # key then reads exactly like an explicit `null` in the file.
  private def self.expand_scalar(
    node : YAML::Nodes::Scalar,
    handlers : Hash(String, YamlTag::Handler),
    source_file : String?,
  ) : Nil
    tag = node.tag
    return unless tag

    handler = handlers[tag]?
    unless handler
      raise IncludeError.new(source_file, "unknown YAML tag '#{tag}' — no handler was passed for it")
    end

    ctx = YamlTag::Context.new(
      source_file: source_file,
      base_dir: source_file ? File.dirname(File.expand_path(source_file)) : nil,
    )
    if (value = handler.expand(node, ctx)).nil?
      # No value: rewrite the scalar to a plain null — the containing key
      # then reads exactly like an explicit `null` in the file.
      node.value = ""
      node.style = YAML::ScalarStyle::PLAIN
    else
      node.value = value
      node.style = YAML::ScalarStyle::LITERAL
    end
    node.tag = nil
  end
end
