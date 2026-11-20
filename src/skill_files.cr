# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"
require "json"
require "sync"
require "sync/exclusive"

module Facet
  # Generic loader for skill markdown files (`.md` with YAML front-matter)
  # that live in one fixed directory. Each agent surface owns a corpus
  # directory and exposes it through `SkillFiles`; the front-matter rules
  # stay defined once, here.
  #
  # A skill file:
  # ```
  # ---
  # title: Filter Grammar
  # description: The field__op filter grammar, per field type.
  # tags: [filters]
  # surfaces: [workspace, mcp]
  # ---
  # # Filter Grammar
  # ...
  # ```
  #
  # `surfaces` is the skill's agent-surface allow-list — the surfaces whose
  # `read_skill` serves the file. A corpus whose consumers do not filter by
  # surface (the domain builder's) may omit the field: the unfiltered
  # `list` / `read` / `names` API serves it whole, the surface-filtered
  # `list_for` / `read_for` API serves the tagged corpora.
  #
  # A directory loads on first read and never reloads — a new or edited
  # skill file shows up only after a process restart. Skill corpora are
  # static, checked-in reference documents, so there is no invalidation.
  module SkillFiles
    record Skill,
      name : String, # filename without `.md`
      title : String,
      description : String,
      tags : Array(String),
      surfaces : Array(String), # agent surfaces whose `read_skill` serves the file
      body : String

    @@loaded : Sync::Exclusive(Hash(String, Hash(String, Skill)))
    @@loaded = Sync::Exclusive(Hash(String, Hash(String, Skill))).new({} of String => Hash(String, Skill))

    # All skills of `dir`, sorted alphabetically by name. The corpus is
    # read once per directory and held in memory.
    def self.list(dir : String) : Array(Skill)
      values = loaded(dir).values
      values.sort_by!(&.name)
      values
    end

    # The skills of `dir` whose `surfaces` front-matter includes `surface`,
    # sorted alphabetically by name. The filter is hard: a file without a
    # `surfaces` field, or tagged for other surfaces only, serves no
    # filtered surface — indistinguishable from a missing file.
    def self.list_for(dir : String, surface : String) : Array(Skill)
      skills = loaded(dir).values.select(&.surfaces.includes?(surface))
      skills.sort_by!(&.name)
      skills
    end

    # The skill named `name`, or `nil` when no such file exists.
    def self.read(dir : String, name : String) : Skill?
      loaded(dir)[name]?
    end

    # The skill named `name` when its `surfaces` front-matter includes
    # `surface`, else `nil` — an untagged or differently tagged file is
    # indistinguishable from a missing one.
    def self.read_for(dir : String, surface : String, name : String) : Skill?
      skill = loaded(dir)[name]?
      skill if skill && skill.surfaces.includes?(surface)
    end

    # The skill names of `dir` — used to list the corpus in prompts.
    def self.names(dir : String) : Array(String)
      names = loaded(dir).keys
      names.sort!
      names
    end

    # ── Internals ─────────────────────────────────────────────────────

    private def self.loaded(dir : String) : Hash(String, Skill)
      @@loaded.lock do |cache|
        cached = cache[dir]?
        next cached if cached

        fresh = load_dir(dir)
        cache[dir] = fresh
        fresh
      end
    end

    private def self.load_dir(dir : String) : Hash(String, Skill)
      skills = {} of String => Skill
      Dir.glob(File.join(dir, "*.md")).each do |path|
        name = File.basename(path, ".md")
        skill = parse_file(path, name)
        skills[name] = skill if skill
      end
      skills
    end

    private def self.parse_file(path : String, name : String) : Skill?
      raw = File.read(path)
      front_matter, body = split_front_matter(raw)
      front = parse_front_matter(front_matter)

      Skill.new(
        name: name,
        title: front["title"]?.try(&.to_s) || name.capitalize,
        description: front["description"]?.try(&.to_s) || "",
        tags: parse_tags(front["tags"]?),
        surfaces: parse_surfaces(front["surfaces"]?),
        body: body,
      )
    rescue File::NotFoundError
      nil
    end

    private def self.split_front_matter(raw : String) : {String, String}
      return {"", raw} unless raw.starts_with?("---\n") || raw.starts_with?("---\r\n")

      lines = raw.lines
      # lines[0] is the opening `---`; find the closing one on its own line.
      close_idx = (1...lines.size).find { |i| lines[i].strip == "---" }
      return {"", raw} unless close_idx

      front = lines[1...close_idx].join('\n')
      body = lines[(close_idx + 1)..].join('\n').lstrip
      {front, body}
    end

    # A malformed or empty front-matter is non-fatal: the body loads
    # unchanged, title falls back to the file name.
    private def self.parse_front_matter(yaml_str : String) : Hash(String, YAML::Any)
      return {} of String => YAML::Any if yaml_str.strip.empty?

      parsed = YAML.parse(yaml_str)
      h = parsed.as_h?
      return transform_yaml_hash(h) if h
      {} of String => YAML::Any
    rescue YAML::ParseException
      {} of String => YAML::Any
    end

    private def self.transform_yaml_hash(h : Hash(YAML::Any, YAML::Any)) : Hash(String, YAML::Any)
      out_h = {} of String => YAML::Any
      h.each do |k, v|
        out_h[k.to_s] = v
      end
      out_h
    end

    private def self.parse_tags(raw : YAML::Any?) : Array(String)
      return [] of String unless raw
      arr = raw.as_a?
      return [] of String unless arr
      arr.map(&.as_s)
    end

    private def self.parse_surfaces(raw : YAML::Any?) : Array(String)
      return [] of String unless raw
      arr = raw.as_a?
      return [] of String unless arr
      arr.map(&.as_s)
    end
  end
end
