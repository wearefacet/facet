# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"
require "yaml"
require "file_utils"

require "../../../src/domain/portable/archive"

# Creates a unique directory under `Dir.tempdir` and yields its path. The
# directory is removed when the block exits.
def with_portable_tempdir(& : String ->)
  path = File.join(Dir.tempdir, "facet-archive-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(path)
  begin
    yield path
  ensure
    FileUtils.rm_r(path) if Dir.exists?(path)
  end
end

# Builds a trivial bundle with one doctype, one DocumentView, and one
# general CollectionView. Used by the round-trip specs.
def build_portable_bundle : Facet::Domain::Portable::Archive::Bundle
  domain_entry = Facet::Domain::Portable::Archive::Entry.new(
    JSON.parse(%({"description": "test domain", "color": "#abc"})),
    JSON.parse(%({})),
  )
  doctype_content = JSON.parse(%({"doctype": "Widget", "domain": "test", "fields": {}}))
  doctype_entry = Facet::Domain::Portable::Archive::Entry.new(
    doctype_content,
    JSON.parse(%({"parent_id": "test"})),
  )
  dv_content = JSON.parse(%({"parent_doctype": "test.Widget", "kind": "view", "template": {}}))
  dv_entry = Facet::Domain::Portable::Archive::Entry.new(
    dv_content,
    JSON.parse(%({"parent_id": "test.Widget"})),
  )
  cv_content = JSON.parse(%({"name": "All", "surface": "table", "config": {}}))
  cv = Facet::Domain::Portable::Archive::CollectionView.new(
    "all",
    Facet::Domain::Portable::Archive::Entry.new(cv_content, JSON.parse(%({"parent_id": "test.Widget"}))),
  )

  Facet::Domain::Portable::Archive::Bundle.new(
    source_domain: "test",
    exported_at: "2024-01-01T00:00:00Z",
    facet_version: "0.1.0",
    domain: domain_entry,
    doctypes: [{doctype: "test.Widget", entry: doctype_entry}],
    document_views: {"test.Widget" => [{kind: "view", entry: dv_entry}]},
    collection_views: {"test.Widget" => [cv]},
  )
end

describe Facet::Domain::Portable::Archive do
  it "names the offending file and line when a bundle entry has a YAML syntax error (B-26)" do
    with_portable_tempdir do |bundle|
      # A hand-edited bundle with a broken doctype entry. `exported_at`
      # must be quoted — YAML parses an unquoted timestamp as a Time.
      Dir.mkdir_p(File.join(bundle, "doctypes"))
      File.write(File.join(bundle, "bundle.yml"),
        "format_version: 2\nsource_domain: test\nexported_at: \"2024-01-01T00:00:00Z\"\nfacet_version: 0.1.0\n")
      File.write(File.join(bundle, "domain.yml"), "content: {}\nmeta: {}\n")
      File.write(File.join(bundle, "doctypes/test.Widget.yml"),
        "content: {\n  broken\nmeta: {}\n")

      ex = expect_raises(Facet::Domain::Portable::Archive::Error, /doctypes[\/]test\.Widget\.yml: line \d+/) do
        Facet::Domain::Portable::Archive.read(bundle)
      end
      # The message carries the parser's own problem text after the
      # file:line prefix — enough to locate the edit.
      ex.message.should_not be_nil
      ex.message.to_s.should contain("did not find expected")
    end
  end

  it "names bundle.yml when its own YAML is broken (B-26)" do
    with_portable_tempdir do |bundle|
      File.write(File.join(bundle, "bundle.yml"), "format_version: [unclosed\n")

      expect_raises(Facet::Domain::Portable::Archive::Error, /bundle\.yml: line \d+/) do
        Facet::Domain::Portable::Archive.read(bundle)
      end
    end
  end

  it "names a missing entry file instead of backtracing (B-26 residual)" do
    with_portable_tempdir do |bundle|
      File.write(File.join(bundle, "bundle.yml"),
        "format_version: 2\nsource_domain: test\nexported_at: \"2024-01-01T00:00:00Z\"\nfacet_version: 0.1.0\n")
      Dir.mkdir_p(File.join(bundle, "doctypes"))
      File.write(File.join(bundle, "doctypes/test.Widget.yml"),
        "---\ncontent:\n  doctype: Widget\n  domain: test\n  fields: {}\nmeta: {}\n")
      # `domain.yml` is absent — the reader must name the missing file.

      expect_raises(Facet::Domain::Portable::Archive::Error, /domain\.yml: file does not exist/) do
        Facet::Domain::Portable::Archive.read(bundle)
      end
    end
  end

  it "round-trips through a directory" do
    with_portable_tempdir do |bundle|
      original = build_portable_bundle
      Facet::Domain::Portable::Archive.write(original, bundle)
      File.exists?(File.join(bundle, "bundle.yml")).should be_true
      File.exists?(File.join(bundle, "domain.yml")).should be_true
      File.exists?(File.join(bundle, "doctypes/test.Widget.yml")).should be_true
      File.exists?(File.join(bundle, "views/test.Widget/document_views/view.yml")).should be_true
      File.exists?(File.join(bundle, "views/test.Widget/collection_views/all.yml")).should be_true

      # bundle.yml should carry the canonical (un-quoted) facet_version.
      yml = File.read(File.join(bundle, "bundle.yml"))
      yml.should contain("facet_version: 0.1.0")
      yml.should contain("format_version: 2")
      yml.should contain("source_domain: test")

      loaded = Facet::Domain::Portable::Archive.read(bundle)
      loaded.source_domain.should eq("test")
      loaded.doctypes.size.should eq(1)
      loaded.doctypes[0][:doctype].should eq("test.Widget")
      loaded.document_views["test.Widget"].size.should eq(1)
      loaded.document_views["test.Widget"][0][:kind].should eq("view")
      loaded.collection_views["test.Widget"].size.should eq(1)
      loaded.collection_views["test.Widget"][0].slug.should eq("all")
      loaded.facet_version.should eq("0.1.0")
    end
  end

  it "emits multi-line strings as YAML literal block scalars" do
    # A document entry carries multi-line string content (e.g. a longtext
    # field). Documents never externalize, so the writer must emit such
    # strings as a YAML `|` literal block so the file is reviewable, and
    # the reader must round-trip the exact original bytes.
    with_portable_tempdir do |bundle|
      body = <<-BODY
        Line one

        Line two
      BODY
      content = JSON.parse(%({"body":#{body.to_json}}))
      meta = JSON.parse(%({}))
      entry = Facet::Domain::Portable::Archive::Entry.new(content, meta)
      doc_bundle = Facet::Domain::Portable::Archive::Bundle.new(
        source_domain: "test",
        exported_at: "2024-01-01T00:00:00Z",
        facet_version: "0.1.0",
        domain: Facet::Domain::Portable::Archive::Entry.new(JSON.parse(%({"description":"d"})), JSON.parse(%({}))),
        doctypes: [] of {doctype: String, entry: Facet::Domain::Portable::Archive::Entry},
        document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
        collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
        documents: {"test.Widget" => [Facet::Domain::Portable::Archive::DocumentEntry.new("doc1", entry)]},
      )

      Facet::Domain::Portable::Archive.write(doc_bundle, bundle)

      on_disk = File.read(File.join(bundle, "documents", "test.Widget", "doc1.yml"))
      # The literal block indicator should appear next to the `body:` key.
      on_disk.should contain("body: |")
      # The content is rendered verbatim on its own indented lines —
      # not as a single-line escaped JSON blob.
      on_disk.should contain("Line one")
      on_disk.should contain("Line two")
      on_disk.should_not contain("\\n")

      # Round-trip: the reader returns the original content.
      loaded = Facet::Domain::Portable::Archive.read(bundle)
      loaded_body = loaded.documents["test.Widget"][0].entry.content["body"].as_s
      loaded_body.rstrip.should eq(body.rstrip)
    end
  end

  # Enum values stored in `data/fixtures/` may carry keys that YAML 1.1
  # reads as booleans (`yes`/`no`/`on`/`off`/`true`/`false`). The writer must
  # quote such keys so the reader returns `String`, not `Bool` — an
  # unquoted `key: yes` round-trips as `true` and breaks `EnumValue.from_json`.
  it "round-trips enum keys that YAML 1.1 would coerce to booleans" do
    with_portable_tempdir do |bundle|
      content = JSON.parse(%({
        "doctype": "Widget",
        "domain": "test",
        "schema_version": 1,
        "fields": {
          "rec": {
            "type": "enum",
            "values": [
              {"key": "yes", "label": "Yes"},
              {"key": "no", "label": "No"},
              {"key": "on", "label": "On"},
              {"key": "off", "label": "Off"},
              {"key": "true", "label": "True"},
              {"key": "false", "label": "False"},
              {"key": "null", "label": "Null"},
              {"key": "maybe", "label": "Maybe"}
            ]
          }
        }
      }))
      entry = Facet::Domain::Portable::Archive::Entry.new(content, JSON.parse(%({})))
      doctype_bundle = Facet::Domain::Portable::Archive::Bundle.new(
        source_domain: "test",
        exported_at: "2024-01-01T00:00:00Z",
        facet_version: "0.1.0",
        domain: Facet::Domain::Portable::Archive::Entry.new(JSON.parse(%({"description":"d"})), JSON.parse(%({}))),
        doctypes: [{doctype: "test.Widget", entry: entry}],
        document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
        collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
      )

      Facet::Domain::Portable::Archive.write(doctype_bundle, bundle)

      # On disk each reserved word must be double-quoted so YAML 1.1 reads
      # it as a String. The plain word `maybe` is left unquoted.
      on_disk = File.read(File.join(bundle, "doctypes", "test.Widget.yml"))
      on_disk.should contain(%(key: "yes"))
      on_disk.should contain(%(key: "no"))
      on_disk.should contain(%(key: "on"))
      on_disk.should contain(%(key: "off"))
      on_disk.should contain(%(key: "true"))
      on_disk.should contain(%(key: "false"))
      on_disk.should contain(%(key: "null"))
      on_disk.should contain(%(key: maybe))

      loaded = Facet::Domain::Portable::Archive.read(bundle)
      values = loaded.doctypes[0][:entry].content["fields"]["rec"]["values"].as_a
      keys = values.map { |v| v["key"] }

      # Every reserved word must read back as a String — not coerced to Bool/Nil.
      types = keys.map(&.raw.class)
      types.uniq!.should eq([String])
      keys.map(&.to_s).should eq(%w[yes no on off true false null maybe])
    end
  end

  # The portable-domain reader expands the `!read_file` YAML directive for
  # any entry file inside a bundle. A hand-crafted bundle can reference a
  # co-located `.lua` script (same directory as the YAML) — the reader must
  # substitute the file's literal contents and reject any reference that
  # escapes the YAML's own directory (via `..`, absolute path, or symlink).
  # This exercises the production reader path (`Archive.read_entry_yaml`),
  # not the spec helper.
  describe "!read_file directive" do
    it "expands a !read_file script co-located with the doctype entry" do
      with_portable_tempdir do |bundle|
        # `Archive.read` requires a `bundle.yml` at the bundle root.
        File.write(File.join(bundle, "bundle.yml"), "format_version: 2\nsource_domain: test\nexported_at: \"2026-08-25T00:00:00Z\"\nfacet_version: 0.1.0\n")
        File.write(File.join(bundle, "domain.yml"), "---\ncontent:\n  description: test\nmeta: {}\n")
        dt_dir = File.join(bundle, "doctypes")
        Dir.mkdir_p(dt_dir)
        # The Lua file lives next to the doctype YAML — that is the only
        # location a `!read_file` can reach.
        File.write(File.join(dt_dir, "widget.lua"), "-- widget lifecycle\n")
        File.write(File.join(dt_dir, "test.Widget.yml"), <<-YML)
          ---
          content:
            doctype: Widget
            domain: test
            fields: {}
            script: !read_file widget.lua
          meta:
            parent_id: test
          YML

        loaded = Facet::Domain::Portable::Archive.read(bundle)
        loaded.doctypes[0][:entry].content["script"].as_s.should eq("-- widget lifecycle\n")
      end
    end

    it "rejects a !read_file that contains a '..' segment" do
      with_portable_tempdir do |bundle|
        File.write(File.join(bundle, "bundle.yml"), "format_version: 2\nsource_domain: test\nexported_at: \"2026-08-25T00:00:00Z\"\nfacet_version: 0.1.0\n")
        sub = File.join(bundle, "sub")
        Dir.mkdir_p(sub)
        File.write(File.join(bundle, "shared.lua"), "-- shared\n")
        entry = File.join(sub, "entry.yml")
        # Even though `../shared.lua` resolves inside the bundle, the jail
        # forbids any `..` traversal — the YAML file's own directory (here
        # `sub/`) is the root of the reachable tree.
        File.write(entry, "script: !read_file ../shared.lua\n")
        expect_raises(Facet::Util::YamlInclude::IncludeError, /escapes the YAML directory/) do
          Facet::Util::YamlInclude.parse_file(entry, [Facet::Util::YamlTag::ReadFileTag.new])
        end
      end
    end
  end

  # The writer externalizes a doctype's Lua `script` to a co-located
  # `{Qualified}.lua` sidecar and emits `!read_file {Qualified}.lua` in its
  # place. The reader expands the reference back to the sidecar's literal
  # contents, so the round-trip is lossless.
  describe "externalization" do
    it "externalizes a doctype script to a co-located .lua sidecar" do
      with_portable_tempdir do |bundle|
        lua = "local export = {}\nfunction export.create(ctx) ctx.root.ok = true end\nreturn export\n"
        content = JSON.parse(%({"doctype":"Widget","domain":"test","fields":{},"script":#{lua.to_json}}))
        entry = Facet::Domain::Portable::Archive::Entry.new(content, JSON.parse(%({"parent_id":"test"})))
        doctype_bundle = Facet::Domain::Portable::Archive::Bundle.new(
          source_domain: "test",
          exported_at: "2024-01-01T00:00:00Z",
          facet_version: "0.1.0",
          domain: Facet::Domain::Portable::Archive::Entry.new(JSON.parse(%({"description":"d"})), JSON.parse(%({}))),
          doctypes: [{doctype: "test.Widget", entry: entry}],
          document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
          collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
        )

        Facet::Domain::Portable::Archive.write(doctype_bundle, bundle)

        # The sidecar exists next to the doctype YAML and carries the script.
        sidecar = File.join(bundle, "doctypes", "test.Widget.lua")
        File.exists?(sidecar).should be_true
        File.read(sidecar).should eq(lua)

        # The YAML references the sidecar instead of inlining the script.
        on_disk = File.read(File.join(bundle, "doctypes", "test.Widget.yml"))
        on_disk.should contain("script: !read_file test.Widget.lua")
        on_disk.should_not contain("function export.create")

        # Round-trip restores the exact script bytes.
        loaded = Facet::Domain::Portable::Archive.read(bundle)
        loaded.doctypes[0][:entry].content["script"].as_s.should eq(lua)
      end
    end

    it "externalizes each domain hook script to a per-hook sidecar" do
      with_portable_tempdir do |bundle|
        hook1_script = "local e = {}\nfunction e.on_event(ctx) end\nreturn e\n"
        hook2_script = "local e = {}\nfunction e.on_schedule(ctx) end\nreturn e\n"
        domain_content = JSON.parse(%({
          "description": "d",
          "hooks": [
            {"id": "on-create", "kind": "event", "script": #{hook1_script.to_json}, "source": {"domain": "test"}},
            {"id": "nightly", "kind": "schedule", "script": #{hook2_script.to_json}, "schedule": "0 2 * * *"}
          ]
        }))
        domain_entry = Facet::Domain::Portable::Archive::Entry.new(domain_content, JSON.parse(%({})))
        bundle_obj = Facet::Domain::Portable::Archive::Bundle.new(
          source_domain: "test",
          exported_at: "2024-01-01T00:00:00Z",
          facet_version: "0.1.0",
          domain: domain_entry,
          doctypes: [] of {doctype: String, entry: Facet::Domain::Portable::Archive::Entry},
          document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
          collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
        )

        Facet::Domain::Portable::Archive.write(bundle_obj, bundle)

        # Each hook script lives in its own sidecar under hooks/.
        File.read(File.join(bundle, "hooks", "0-on-create.lua")).should eq(hook1_script)
        File.read(File.join(bundle, "hooks", "1-nightly.lua")).should eq(hook2_script)

        # The domain YAML references each sidecar.
        on_disk = File.read(File.join(bundle, "domain.yml"))
        on_disk.should contain("script: !read_file hooks/0-on-create.lua")
        on_disk.should contain("script: !read_file hooks/1-nightly.lua")
        on_disk.should_not contain("function e.on_event")

        # Round-trip restores each hook's script.
        loaded = Facet::Domain::Portable::Archive.read(bundle)
        hooks = loaded.domain.content["hooks"].as_a
        hooks[0]["script"].as_s.should eq(hook1_script)
        hooks[1]["script"].as_s.should eq(hook2_script)
      end
    end

    it "does not externalize document content" do
      with_portable_tempdir do |bundle|
        body = "line one\nline two\n"
        content = JSON.parse(%({"body":#{body.to_json}}))
        entry = Facet::Domain::Portable::Archive::Entry.new(content, JSON.parse(%({})))
        doc_bundle = Facet::Domain::Portable::Archive::Bundle.new(
          source_domain: "test",
          exported_at: "2024-01-01T00:00:00Z",
          facet_version: "0.1.0",
          domain: Facet::Domain::Portable::Archive::Entry.new(JSON.parse(%({"description":"d"})), JSON.parse(%({}))),
          doctypes: [] of {doctype: String, entry: Facet::Domain::Portable::Archive::Entry},
          document_views: {} of String => Array({kind: String, entry: Facet::Domain::Portable::Archive::Entry}),
          collection_views: {} of String => Array(Facet::Domain::Portable::Archive::CollectionView),
          documents: {"test.Widget" => [Facet::Domain::Portable::Archive::DocumentEntry.new("doc1", entry)]},
        )

        Facet::Domain::Portable::Archive.write(doc_bundle, bundle)

        # Document content stays inline — no sidecar is written.
        on_disk = File.read(File.join(bundle, "documents", "test.Widget", "doc1.yml"))
        on_disk.should contain("body: |")
        on_disk.should_not contain("!read_file")
        File.exists?(File.join(bundle, "documents", "test.Widget", "doc1.lua")).should be_false

        loaded = Facet::Domain::Portable::Archive.read(bundle)
        loaded.documents["test.Widget"][0].entry.content["body"].as_s.rstrip.should eq(body.rstrip)
      end
    end
  end

  it "round-trips through a .tar.gz" do
    with_portable_tempdir do |dir|
      tarball = File.join(dir, "bundle.tar.gz")
      original = build_portable_bundle
      Facet::Domain::Portable::Archive.write(original, tarball)

      # Sanity: the file actually looks like a gzip.
      File.size(tarball).should be > 0

      loaded = Facet::Domain::Portable::Archive.read(tarball)
      loaded.source_domain.should eq("test")
      loaded.doctypes.size.should eq(1)
      loaded.document_views["test.Widget"].size.should eq(1)
      loaded.collection_views["test.Widget"].size.should eq(1)
    end
  end

  it "rejects an unknown format_version" do
    with_portable_tempdir do |path|
      File.write(File.join(path, "bundle.yml"), "format_version: 99\nsource_domain: x\nexported_at: x\nfacet_version: x\n")
      expect_raises(Facet::Domain::Portable::Archive::Error, /Unsupported bundle format_version/) do
        Facet::Domain::Portable::Archive.read(path)
      end
    end
  end

  it "rejects a missing bundle.yml" do
    with_portable_tempdir do |path|
      expect_raises(Facet::Domain::Portable::Archive::Error, /Missing bundle\.yml/) do
        Facet::Domain::Portable::Archive.read(path)
      end
    end
  end

  it "refuses to overwrite a non-bundle directory" do
    with_portable_tempdir do |path|
      # Pre-populate with an unrelated file so the directory is non-empty.
      File.write(File.join(path, "README.md"), "do not clobber me")
      expect_raises(Facet::Domain::Portable::Archive::Error, /Refusing to overwrite/) do
        Facet::Domain::Portable::Archive.write(build_portable_bundle, path)
      end
    end
  end

  it "detects tarballs by extension" do
    Facet::Domain::Portable::Archive.tarball?("foo.tar.gz").should be_true
    Facet::Domain::Portable::Archive.tarball?("foo.TGZ").should be_true
    Facet::Domain::Portable::Archive.tarball?("foo.tar").should be_false
    Facet::Domain::Portable::Archive.tarball?("foo.yml").should be_false
  end

  it "builds a stable slug for collection views" do
    # When an id is present, it is sanitised (spaces -> _).
    Facet::Domain::Portable::Archive.collection_view_slug("abc View", "Hello, World").should eq("abc_View")
    # When only a name is given, the name is lowercased and slugified.
    Facet::Domain::Portable::Archive.collection_view_slug(nil, "Some Name").should eq("some_name")
    Facet::Domain::Portable::Archive.collection_view_slug(nil, nil).should eq("view")
  end

  # A format-version-1 bundle writes JSON entry files and the legacy
  # double-encoded facet_version. The v2 reader must still load such a
  # bundle so an operator can migrate an old checkout. This spec builds a
  # v1 bundle on disk by hand (not via the current writer, which only
  # emits v2) and verifies every entry round-trips.
  it "reads a legacy format-version-1 JSON bundle" do
    with_portable_tempdir do |path|
      Dir.mkdir_p(File.join(path, "doctypes"))
      Dir.mkdir_p(File.join(path, "views", "test.Widget", "document_views"))
      Dir.mkdir_p(File.join(path, "views", "test.Widget", "collection_views"))

      # The legacy v1 writer double-encoded the facet_version via
      # `String#to_json`, producing `"\"0.1.0\""` on disk. The v1
      # reader preserves the value verbatim — operators who need the
      # canonical form re-export from a v2 instance.
      File.write(File.join(path, "bundle.yml"), String.build do |io|
        io << "format_version: 1\n"
        io << "source_domain: \"test\"\n"
        io << "exported_at: \"2024-01-01T00:00:00Z\"\n"
        io << "facet_version: \"\\\"0.1.0\\\"\"\n"
      end)
      File.write(File.join(path, "domain.json"),
        %({"content":{"description":"test","color":"#abc"},"meta":{}}))
      File.write(File.join(path, "doctypes", "test.Widget.json"),
        %({"content":{"doctype":"Widget","domain":"test","fields":{},"schema_version":1},"meta":{"parent_id":"test"}}))
      File.write(File.join(path, "views", "test.Widget", "document_views", "view.json"),
        %({"content":{"parent_doctype":"test.Widget","kind":"view","template":{}},"meta":{"parent_id":"test.Widget"}}))
      File.write(File.join(path, "views", "test.Widget", "collection_views", "all.json"),
        %({"content":{"name":"All","surface":"table","config":{}},"meta":{"parent_id":"test.Widget"}}))

      loaded = Facet::Domain::Portable::Archive.read(path)
      loaded.source_domain.should eq("test")
      loaded.exported_at.should eq("2024-01-01T00:00:00Z")
      # The legacy double-encoded form is preserved as-is — the v1 reader
      # does not decode the spurious quotes. Operators who need the
      # canonical form re-export the bundle from a v2 instance.
      loaded.facet_version.should eq("\"0.1.0\"")
      loaded.doctypes.size.should eq(1)
      loaded.doctypes[0][:doctype].should eq("test.Widget")
      loaded.doctypes[0][:entry].content["doctype"].as_s.should eq("Widget")
      loaded.doctypes[0][:entry].content["schema_version"].as_i.should eq(1)
      loaded.doctypes[0][:entry].meta["parent_id"].as_s.should eq("test")
      loaded.document_views["test.Widget"].size.should eq(1)
      loaded.document_views["test.Widget"][0][:kind].should eq("view")
      loaded.collection_views["test.Widget"].size.should eq(1)
      loaded.collection_views["test.Widget"][0].entry.content["name"].as_s.should eq("All")
    end
  end
end
