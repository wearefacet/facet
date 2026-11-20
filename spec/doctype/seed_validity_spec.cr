# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "yaml"
require "../../src/doctype/seed"
require "../../src/doctype/doctype_definition"
require "../../src/doctype/script_validator"
require "../../src/doctype/yaml_helper"
require "../support/doctype_helper"

SEEDS_DIR = File.join(__DIR__, "..", "..", "data", "seeds")

# Find the first existing definition file in a directory.
private def definition_file(dir : String) : String?
  %w[definition.yaml definition.yml definition.json].each do |f|
    path = File.join(dir, f)
    return path if File.exists?(path)
  end
  nil
end

# Find the first existing documents file in a directory.
private def documents_file(dir : String) : String?
  %w[documents.yaml documents.yml documents.json].each do |f|
    path = File.join(dir, f)
    return path if File.exists?(path)
  end
  nil
end

# Loads seed content, normalizing YAML to JSON. Injects optional script.
private def load_seed_content(dir : String) : String
  defn_path = definition_file(dir)
  defn_raw = if defn_path.nil?
               raise "Missing definition file in #{dir}"
             else
               raw = File.read(defn_path)
               case File.extname(defn_path)
               when ".yml", ".yaml"
                 yaml = YAML.parse(raw)
                 Facet::Doctype::YamlHelper.to_json_any(yaml).to_json
               else
                 raw
               end
             end

  script_path = File.join(dir, "script.lua")
  if File.exists?(script_path)
    script = File.read(script_path)
    parsed = JSON.parse(defn_raw)
    parsed.as_h["script"] = JSON::Any.new(script)
    parsed.to_json
  else
    defn_raw
  end
end

# Attempts to parse a seed as DoctypeDefinition. Returns nil if the seed
# uses an unregistered field type (e.g. "type": "any" in core.Domain).
private def try_parse_seed(dir : String) : Facet::Doctype::DoctypeDefinition?
  content = load_seed_content(dir)
  Facet::Doctype::DoctypeDefinition.from_json(content)
rescue ArgumentError
  nil
end

# Parses a directory name like "core.Domain" into {"core", "Domain"}
private def parse_seed_dir(dir_name : String) : {String?, String?}
  parts = dir_name.split(".", 2)
  parts.size == 2 ? {parts[0], parts[1]} : {nil, nil}
end

# Returns all seed directories sorted
private def seed_dirs : Array(String)
  Dir.glob(File.join(SEEDS_DIR, "*"))
    .select { |path| File.directory?(path) && !definition_file(path).nil? }
    .sort!
end

module Facet::Doctype
  describe "core.Comment seed" do
    dir = File.join(SEEDS_DIR, "core.Comment")

    it "parses as a DoctypeDefinition" do
      defn = try_parse_seed(dir)
      defn.should_not be_nil
    end

    it "is flagged sidecar: true" do
      defn = try_parse_seed(dir).not_nil!
      defn.sidecar.should be_true
    end

    it "has a target field of type reference, required, read_only, no default" do
      defn = try_parse_seed(dir).not_nil!
      target = defn.fields["target"]?
      target.should_not be_nil
      target.not_nil!.reference?.should be_true
      target.not_nil!.required.should be_true
      target.not_nil!.read_only?.should be_true
      target.not_nil!.default.should be_nil
    end

    it "has a body field of type longtext, required" do
      defn = try_parse_seed(dir).not_nil!
      body = defn.fields["body"]?
      body.should_not be_nil
      body.not_nil!.type.not_nil!.type_name.should eq("longtext")
      body.not_nil!.required.should be_true
    end

    it "has an author field of type reference to iam.Account, read_only, not required" do
      defn = try_parse_seed(dir).not_nil!
      author = defn.fields["author"]?
      author.should_not be_nil
      author.not_nil!.reference?.should be_true
      author.not_nil!.qualified_doctype.should eq("iam.Account")
      author.not_nil!.read_only?.should be_true
      author.not_nil!.required.should be_false
    end

    it "declares a mine named scope resolving to author: $self" do
      defn = try_parse_seed(dir).not_nil!
      scope = defn.scopes["mine"]?
      scope.should_not be_nil
      scope.not_nil!.where.should eq({"author" => "$self"})
    end

    it "declares a search template on the body" do
      defn = try_parse_seed(dir).not_nil!
      defn.search.should eq("{{ body }}")
    end

    it "ships a script.lua with a create hook" do
      File.exists?(File.join(dir, "script.lua")).should be_true
      script = File.read(File.join(dir, "script.lua"))
      script.should contain("export.create")
      script.should contain("ctx.actor.id")
    end
  end

  describe "core.DocType seed" do
    dir = File.join(SEEDS_DIR, "core.DocType")

    it "parses as a DoctypeDefinition" do
      defn = try_parse_seed(dir)
      defn.should_not be_nil
    end

    # The reference picker's search rides the generic `search` filter. A
    # missing template yields an empty corpus, so every term matches
    # nothing (run-24 finding B-78). The template reads the `content`
    # namespace: `domain` / `doctype` are identity keys, not declared
    # fields, so a bare `{{ domain }}` renders empty over the row's
    # content (`Templating::Context` binds declared fields only). The
    # corpus carries the display label first (so the human name finds the
    # doctype) and the qualified id after (so the identity form still
    # matches). The fallback rides a `{% if %}` block: Crinja's `or`
    # operator yields a Bool, and the blank node is truthy to filters —
    # only the `{% if %}` branch takes the absent-label path.
    it "declares a search corpus over label, domain, and doctype" do
      defn = try_parse_seed(dir).not_nil!
      defn.search.should eq(
        "{% if content.label %}{{ content.label }} {% endif %}{{ content.domain }}.{{ content.doctype }}"
      )
    end
  end

  describe "Seed data validity" do
    it "all seed directories have parseable JSON definition files" do
      seed_dirs.each do |dir|
        dir_name = File.basename(dir)
        defn_path = definition_file(dir)
        defn_path.should_not be_nil, "#{dir_name}: missing definition file"
        raw = File.read(defn_path.not_nil!)
        case File.extname(defn_path.not_nil!)
        when ".yml", ".yaml"
          yaml = YAML.parse(raw)
          yaml.as_h?.should_not be_nil, "#{dir_name}: definition file must be a YAML mapping"
        else
          parsed = JSON.parse(raw)
          parsed.as_h?.should_not be_nil, "#{dir_name}: definition file must be a JSON object"
        end
      end
    end

    it "parses as DoctypeDefinition where supported (skips known unregistered types)" do
      seed_dirs.each do |dir|
        dir_name = File.basename(dir)
        defn = try_parse_seed(dir)
        next if defn.nil? # e.g. core.Domain uses "type": "any" which is not registered

        defn.doctype.should_not be_nil, "#{dir_name}: doctype is nil"
        defn.domain.should_not be_nil, "#{dir_name}: domain is nil"
        defn.schema_version.should be >= 1, "#{dir_name}: schema_version (#{defn.schema_version}) < 1"
        defn.schema_version.should be <= 9999, "#{dir_name}: schema_version (#{defn.schema_version}) > 9999"
      end
    end

    it "passes schema-level validation for all parseable seed definitions" do
      seed_dirs.each do |dir|
        dir_name = File.basename(dir)
        defn = try_parse_seed(dir)
        next if defn.nil?

        # core.DocType is exempt from the reserved-name rule by design: the
        # authoring gate (`Doctype::Validation`) rejects a field named
        # `search` on every user-authored definition, but the system seed
        # must declare it so the GET mask keeps the definition's `search`
        # template through a GET → PUT round-trip (B-101ext). The seed path
        # bypasses authoring validation; this suite-wide gate must too.
        # See the note in `core_doctype_seed_keys_guard_spec.cr`.
        next if dir_name == "core.DocType"

        # core.DomainGrant is exempt from the actions-require-script rule:
        # its `activate`/`deactivate` names exist for the RBAC manifest
        # only and are served by the dedicated grant routes, which run no
        # Lua. The seed has no script by design (B-299).
        next if dir_name == "core.DomainGrant"

        errors = Validation.validate(defn)
        errors.should be_empty, "#{dir_name} validation errors: #{errors.join("; ")}"
      end
    end

    it "has no migration entries on schema_version 1 seeds" do
      seed_dirs.each do |dir|
        dir_name = File.basename(dir)
        defn = try_parse_seed(dir)
        next if defn.nil?

        if defn.schema_version == 1
          defn.migrations.should be_empty, "#{dir_name}: schema_version is 1 but migrations are present"
        end
      end
    end

    it "has no YAML 1.1 boolean-coerced keys (e.g. 'on' → true)" do
      seed_dirs.each do |dir|
        dir_name = File.basename(dir)

        [definition_file(dir), documents_file(dir)].compact.each do |path|
          next unless File.extname(path).in?(".yml", ".yaml")
          begin
            raw = File.read(path)
            yaml = YAML.parse(raw)
            YamlHelper.to_json_any(yaml)
          rescue ex : ArgumentError
            fail "#{dir_name}: #{path}: #{ex.message}"
          end
        end
      end
    end

    it "has valid documents file (array of objects with id)" do
      seed_dirs.each do |dir|
        docs_path = documents_file(dir)
        dir_name = File.basename(dir)
        next if docs_path.nil?

        raw = File.read(docs_path)
        docs = case File.extname(docs_path)
               when ".yml", ".yaml"
                 yaml = YAML.parse(raw)
                 Facet::Doctype::YamlHelper.to_json_any(yaml)
               else
                 JSON.parse(raw)
               end

        docs_array = docs.as_a?
        docs_array.should_not be_nil, "#{dir_name}: documents file must be an array"

        docs_array.not_nil!.each_with_index do |doc, i|
          doc_obj = doc.as_h?
          doc_obj.should_not be_nil, "#{dir_name}: document at index #{i} is not an object"
          doc["id"]?.should_not be_nil, "#{dir_name}: document at index #{i} is missing 'id'"
          doc["id"].as_s?.should_not be_nil, "#{dir_name}: document at index #{i} 'id' must be a string"
        end
      end
    end

    it "passes ScriptValidator when a .lua script is present" do
      seed_dirs.each do |dir|
        script_path = File.join(dir, "script.lua")
        dir_name = File.basename(dir)
        next unless File.exists?(script_path)

        script = File.read(script_path)
        defn = try_parse_seed(dir)

        if defn.nil?
          # If we can't fully parse the definition, at minimum check that the
          # script has no syntax errors and follows the module pattern.
          engine = Lua::Engine.new
          result = engine.run(script)
          engine.close

          export = result.as?(Hash(String, Lua::Engine::Value))
          export.should_not be_nil, "#{dir_name}: script.lua must return a Lua table (use `local export = {}; ...; return export`)"
        else
          errors = ScriptValidator.validate(script, defn)
          errors.should be_empty, "#{dir_name} script errors: #{errors.join("; ")}"
        end
      end
    end
  end
end
