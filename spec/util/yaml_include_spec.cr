# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "file_utils"
require "../../src/util/yaml_include"
require "../../src/util/yaml_tag"

# `Facet::Util::YamlInclude` parses YAML with a caller-supplied list of tag
# handlers. The `!read_file` handler (`Facet::Util::YamlTag::ReadFileTag`)
# resolves a relative path against the YAML file's own directory,
# jail-restricted to that directory and its descendants (no `..` traversal,
# no absolute paths, no symlinks pointing outside). The `!env` handler
# (`Facet::Util::YamlTag::EnvTag`) expands to an environment variable's
# value. Unknown tags are rejected — the caller's handler list is the policy.
# This spec exercises the resolution on the spec-side parsing path (the same
# module is also used by the production archive reader).

# Builds a temp directory that stands in for a YAML file's home directory.
# A `bundle.yml` is written only so the layout mirrors a real fixture bundle;
# the jail is the YAML file's own directory, not the bundle root.
def with_yaml_dir(& : String ->)
  dir = File.join(Dir.tempdir, "facet-yaml-include-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "bundle.yml"), "format_version: 2\nsource_domain: x\nexported_at: x\nfacet_version: x\n")
  yield dir
ensure
  FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
end

READ_FILE_TAGS = [Facet::Util::YamlTag::ReadFileTag.new] of Facet::Util::YamlTag::Handler
ENV_TAGS       = [Facet::Util::YamlTag::EnvTag.new] of Facet::Util::YamlTag::Handler
ENV_OPT_TAGS   = [Facet::Util::YamlTag::EnvOptTag.new] of Facet::Util::YamlTag::Handler
# The pair `Config.load` passes: mandatory expansion plus the optional tier.
CONFIG_TAGS = [Facet::Util::YamlTag::EnvTag.new, Facet::Util::YamlTag::EnvOptTag.new] of Facet::Util::YamlTag::Handler

describe Facet::Util::YamlInclude do
  it "expands a plain !read_file into the file's literal contents" do
    with_yaml_dir do |dir|
      File.write(File.join(dir, "fragment.lua"), "local x = 1\n")
      entry = File.join(dir, "entry.yml")
      File.write(entry, "---\nscript: !read_file fragment.lua\n")
      parsed = Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      parsed["script"].as_s.should eq("local x = 1\n")
    end
  end

  it "resolves a reference inside a descendant subdirectory" do
    with_yaml_dir do |dir|
      sub = File.join(dir, "sub")
      Dir.mkdir_p(sub)
      File.write(File.join(sub, "child.lua"), "-- child\n")
      entry = File.join(dir, "entry.yml")
      File.write(entry, "---\nscript: !read_file sub/child.lua\n")
      parsed = Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      parsed["script"].as_s.should eq("-- child\n")
    end
  end

  it "rejects any reference that contains a '..' segment" do
    with_yaml_dir do |dir|
      sub = File.join(dir, "sub")
      Dir.mkdir_p(sub)
      File.write(File.join(dir, "shared.lua"), "-- shared\n")
      entry = File.join(sub, "entry.yml")
      # Even though ../shared.lua resolves inside the bundle root, the new
      # jail rule forbids any `..` traversal outright — the YAML directory
      # (here `sub/`) is the root of the reachable tree.
      File.write(entry, "---\nscript: !read_file ../shared.lua\n")
      expect_raises(Facet::Util::YamlInclude::IncludeError, /escapes the YAML directory/) do
        Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      end
    end
  end

  it "rejects an absolute path" do
    with_yaml_dir do |dir|
      entry = File.join(dir, "entry.yml")
      File.write(entry, "---\nscript: !read_file /etc/hostname\n")
      expect_raises(Facet::Util::YamlInclude::IncludeError, /is absolute/) do
        Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      end
    end
  end

  it "rejects a symlink that points outside the YAML directory" do
    with_yaml_dir do |dir|
      secret_path = File.join(Dir.tempdir, "facet-yaml-include-symlink-secret-#{Random::Secure.hex(8)}.lua")
      File.write(secret_path, "-- secret\n")
      begin
        link_path = File.join(dir, "leak.lua")
        File.symlink(secret_path, link_path)
        entry = File.join(dir, "entry.yml")
        File.write(entry, "---\nscript: !read_file leak.lua\n")
        expect_raises(Facet::Util::YamlInclude::IncludeError, /escapes the YAML directory/) do
          Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
        end
      ensure
        File.delete(secret_path) if File.exists?(secret_path)
        File.delete(File.join(dir, "leak.lua")) if File.exists?(File.join(dir, "leak.lua"))
      end
    end
  end

  it "reports the including YAML file in the error message" do
    with_yaml_dir do |dir|
      entry = File.join(dir, "entry.yml")
      File.write(entry, "---\nscript: !read_file missing.lua\n")
      err = expect_raises(Facet::Util::YamlInclude::IncludeError, /not found/) do
        Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      end
      err.source_file.should eq(entry)
      err.message.as(String).should contain(entry)
    end
  end

  it "treats a referenced file as plain text, not YAML" do
    with_yaml_dir do |dir|
      # The Lua file contains text that would be ambiguous as YAML (`:` inside
      # a comment) — the file should never be parsed as YAML.
      lua = "function export.create(ctx)\n  ctx.root.x = 1 -- key: value\nend\n"
      File.write(File.join(dir, "script.lua"), lua)
      entry = File.join(dir, "entry.yml")
      File.write(entry, "script: !read_file script.lua\n")
      parsed = Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      parsed["script"].as_s.should eq(lua)
    end
  end

  it "leaves untagged scalars untouched" do
    with_yaml_dir do |dir|
      File.write(File.join(dir, "plain.lua"), "ignored\n")
      entry = File.join(dir, "entry.yml")
      File.write(entry, "---\nscript: !read_file plain.lua\nplain: hello\n")
      parsed = Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      parsed["script"].as_s.should eq("ignored\n")
      parsed["plain"].as_s.should eq("hello")
    end
  end

  it "raises when the YAML file does not exist" do
    expect_raises(Facet::Util::YamlInclude::IncludeError, /does not exist/) do
      Facet::Util::YamlInclude.parse_file("/nonexistent/path/entry.yml", READ_FILE_TAGS)
    end
  end

  it "preserves multi-line content verbatim" do
    with_yaml_dir do |dir|
      lua = <<-LUA
        local export = {}

        function export.create(ctx)
          ctx.root.x = 1
        end

        return export
      LUA
      File.write(File.join(dir, "script.lua"), lua)
      entry = File.join(dir, "entry.yml")
      File.write(entry, "script: !read_file script.lua\n")
      parsed = Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      parsed["script"].as_s.should eq(lua)
    end
  end

  it "expands references inside every mapping value, not just the first" do
    with_yaml_dir do |dir|
      File.write(File.join(dir, "one.lua"), "-- one\n")
      File.write(File.join(dir, "two.lua"), "-- two\n")
      entry = File.join(dir, "entry.yml")
      File.write(entry, <<-YML
        ---
        content:
          a: !read_file one.lua
          b: !read_file two.lua
        YML
      )
      parsed = Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
      parsed["content"]["a"].as_s.should eq("-- one\n")
      parsed["content"]["b"].as_s.should eq("-- two\n")
    end
  end

  describe "!env" do
    it "expands a !env scalar to the environment variable's value" do
      ENV["FACET_TEST_ENV_VAR"] = "hello"
      begin
        parsed = Facet::Util::YamlInclude.parse_string("key: !env FACET_TEST_ENV_VAR\n", ENV_TAGS)
        parsed["key"].as_s.should eq("hello")
      ensure
        ENV.delete("FACET_TEST_ENV_VAR")
      end
    end

    it "raises when the referenced variable is not set" do
      ENV.delete("FACET_TEST_ENV_MISSING")
      err = expect_raises(Facet::Util::YamlInclude::IncludeError, /is not set in the environment/) do
        Facet::Util::YamlInclude.parse_string("key: !env FACET_TEST_ENV_MISSING\n", ENV_TAGS)
      end
      (err.message || "").should contain("FACET_TEST_ENV_MISSING")
    end

    it "raises when the variable name is empty" do
      expect_raises(Facet::Util::YamlInclude::IncludeError, /empty variable name/) do
        Facet::Util::YamlInclude.parse_string("key: !env \"\"\n", ENV_TAGS)
      end
    end

    it "expands !env inside nested mappings and sequences" do
      ENV["FACET_TEST_ENV_A"] = "a-value"
      ENV["FACET_TEST_ENV_B"] = "b-value"
      begin
        parsed = Facet::Util::YamlInclude.parse_string(<<-YAML, ENV_TAGS
          outer:
            inner: !env FACET_TEST_ENV_A
          list:
            - !env FACET_TEST_ENV_B
            - plain
          YAML
        )
        parsed["outer"]["inner"].as_s.should eq("a-value")
        parsed["list"][0].as_s.should eq("b-value")
        parsed["list"][1].as_s.should eq("plain")
      ensure
        ENV.delete("FACET_TEST_ENV_A")
        ENV.delete("FACET_TEST_ENV_B")
      end
    end

    it "leaves plain scalars untouched" do
      parsed = Facet::Util::YamlInclude.parse_string("key: hello\nnum: 42\n", ENV_TAGS)
      parsed["key"].as_s.should eq("hello")
      parsed["num"].as_i.should eq(42)
    end

    it "reports the source file in the error when one is given" do
      ENV.delete("FACET_TEST_ENV_MISSING")
      expect_raises(Facet::Util::YamlInclude::IncludeError, /entry\.yml/) do
        Facet::Util::YamlInclude.parse_string("key: !env FACET_TEST_ENV_MISSING\n", ENV_TAGS, source_file: "entry.yml")
      end
    end
  end

  describe "!env?" do
    it "expands a !env? scalar to the environment variable's value" do
      ENV["FACET_TEST_ENV_VAR"] = "hello"
      begin
        parsed = Facet::Util::YamlInclude.parse_string("key: !env? FACET_TEST_ENV_VAR\n", ENV_OPT_TAGS)
        parsed["key"].as_s.should eq("hello")
      ensure
        ENV.delete("FACET_TEST_ENV_VAR")
      end
    end

    it "reads an unset variable as nil, not an error" do
      ENV.delete("FACET_TEST_ENV_MISSING")
      parsed = Facet::Util::YamlInclude.parse_string("key: !env? FACET_TEST_ENV_MISSING\n", ENV_OPT_TAGS)
      parsed["key"]?.try(&.as_s?).should be_nil
    end

    it "reads the unset case exactly like an explicit null in the file" do
      ENV.delete("FACET_TEST_ENV_MISSING")
      tagged = Facet::Util::YamlInclude.parse_string("key: !env? FACET_TEST_ENV_MISSING\n", ENV_OPT_TAGS)
      literal = Facet::Util::YamlInclude.parse_string("key: null\n", ENV_OPT_TAGS)
      tagged["key"].raw.should eq(literal["key"].raw)
    end

    it "reads nested unset variables as nil" do
      ENV.delete("FACET_TEST_ENV_MISSING")
      parsed = Facet::Util::YamlInclude.parse_string(<<-YAML, ENV_OPT_TAGS
            outer:
              inner: !env? FACET_TEST_ENV_MISSING
            list:
              - !env? FACET_TEST_ENV_MISSING
            YAML
      )
      parsed["outer"]["inner"]?.try(&.as_s?).should be_nil
      parsed["list"][0]?.try(&.as_s?).should be_nil
    end

    it "raises when the variable name is empty" do
      expect_raises(Facet::Util::YamlInclude::IncludeError, /empty variable name/) do
        Facet::Util::YamlInclude.parse_string("key: !env? \"\"\n", ENV_OPT_TAGS)
      end
    end

    it "coexists with !env when both handlers are passed" do
      ENV["FACET_TEST_ENV_VAR"] = "hello"
      ENV.delete("FACET_TEST_ENV_MISSING")
      begin
        parsed = Facet::Util::YamlInclude.parse_string(<<-YAML, CONFIG_TAGS
              set: !env FACET_TEST_ENV_VAR
              unset: !env? FACET_TEST_ENV_MISSING
              YAML
        )
        parsed["set"].as_s.should eq("hello")
        parsed["unset"]?.try(&.as_s?).should be_nil
      ensure
        ENV.delete("FACET_TEST_ENV_VAR")
      end
    end

    it "is rejected as an unknown tag when no EnvOptTag handler is passed" do
      with_yaml_dir do |dir|
        entry = File.join(dir, "entry.yml")
        File.write(entry, "---\nkey: !env? FACET_TEST_ENV_VAR\n")
        expect_raises(Facet::Util::YamlInclude::IncludeError, /unknown YAML tag/) do
          Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
        end
      end
    end
  end

  describe "unknown tags" do
    it "rejects !env in bundle YAML parsed without an EnvTag handler" do
      with_yaml_dir do |dir|
        entry = File.join(dir, "entry.yml")
        File.write(entry, "---\nscript: !env FACET_TEST_ENV_VAR\n")
        err = expect_raises(Facet::Util::YamlInclude::IncludeError, /unknown YAML tag/) do
          Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
        end
        (err.message || "").should contain(entry)
      end
    end

    it "rejects !env nested inside a bundle mapping" do
      with_yaml_dir do |dir|
        entry = File.join(dir, "entry.yml")
        File.write(entry, "---\ncontent:\n  fields:\n    secret: !env FACET_TEST_ENV_VAR\n")
        expect_raises(Facet::Util::YamlInclude::IncludeError, /unknown YAML tag/) do
          Facet::Util::YamlInclude.parse_file(entry, READ_FILE_TAGS)
        end
      end
    end

    it "rejects !read_file when only an EnvTag handler is given" do
      with_yaml_dir do |dir|
        File.write(File.join(dir, "fragment.lua"), "local x = 1\n")
        entry = File.join(dir, "entry.yml")
        File.write(entry, "---\nscript: !read_file fragment.lua\n")
        expect_raises(Facet::Util::YamlInclude::IncludeError, /unknown YAML tag/) do
          Facet::Util::YamlInclude.parse_file(entry, ENV_TAGS)
        end
      end
    end

    it "rejects a tag no handler declares" do
      expect_raises(Facet::Util::YamlInclude::IncludeError, /unknown YAML tag '!nope'/) do
        Facet::Util::YamlInclude.parse_string("key: !nope value\n", ENV_TAGS)
      end
    end
  end

  describe "handler list validation" do
    it "rejects two handlers claiming the same tag" do
      tags = [Facet::Util::YamlTag::EnvTag.new, Facet::Util::YamlTag::EnvTag.new]
      expect_raises(Facet::Util::YamlInclude::IncludeError, /duplicate tag handler/) do
        Facet::Util::YamlInclude.parse_string("key: value\n", tags)
      end
    end

    it "rejects an empty handler list" do
      expect_raises(Facet::Util::YamlInclude::IncludeError, /no tag handlers given/) do
        Facet::Util::YamlInclude.parse_string("key: value\n", [] of Facet::Util::YamlTag::Handler)
      end
    end
  end

  describe "combined handler lists" do
    it "expands both tags when both handlers are passed" do
      ENV["FACET_TEST_ENV_COMBINED"] = "combined"
      begin
        with_yaml_dir do |dir|
          File.write(File.join(dir, "fragment.lua"), "local x = 1\n")
          entry = File.join(dir, "entry.yml")
          File.write(entry, "---\nscript: !read_file fragment.lua\nname: !env FACET_TEST_ENV_COMBINED\n")
          both = [Facet::Util::YamlTag::ReadFileTag.new, Facet::Util::YamlTag::EnvTag.new]
          parsed = Facet::Util::YamlInclude.parse_file(entry, both)
          parsed["script"].as_s.should eq("local x = 1\n")
          parsed["name"].as_s.should eq("combined")
        end
      ensure
        ENV.delete("FACET_TEST_ENV_COMBINED")
      end
    end
  end

  describe "ReadFileTag without a file context" do
    it "refuses to expand in in-memory YAML" do
      expect_raises(Facet::Util::YamlTag::ExpandError, /requires a file context/) do
        Facet::Util::YamlInclude.parse_string("key: !read_file x.lua\n", READ_FILE_TAGS)
      end
    end
  end
end
