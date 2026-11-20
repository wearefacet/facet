# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "file_utils"
require "../../src/database"
require "../../src/config"
require "../../src/doctype"
require "../../src/doctype/seed"
require "../../src/domain/scratch"
require "../../src/domain/portable"
require "../../src/mutation/client"
require "../../src/dev/domain_watcher"

# Specs for `Facet::Dev::DomainWatcher`. The watcher is driven synchronously
# through `sync_now` — one call
# is one poll tick — so the examples are deterministic without sleeping on
# the real poll loop. The fibre lifecycle (start/stop) is exercised once.
#
# Each example re-seeds the core doctypes (the global truncation wipes
# them) and builds its own watch root under the OS tempdir. Bundles are
# produced by exporting a small seeded live domain — the same round-trip
# the real workflow uses — so the on-disk layout is always the genuine
# export format.

# ── Log capture ─────────────────────────────────────────────────────────────

WATCHER_LOGS = [] of Log::Entry

private class WatcherLogBackend < ::Log::Backend
  # Synchronous dispatch: `write` must run on the emitting fiber — async
  # dispatch could land the cycle's last entry after the example already
  # asserted on the capture (the same rule `SyncLogBackend` and
  # `SpecLogCapture` hold).
  def initialize(@sink : Array(Log::Entry))
    super(::Log::DispatchMode::Sync)
  end

  def write(entry : Log::Entry) : Nil
    @sink << entry
  end
end

# Captures every `facet.dev.domain_watcher` log line for the suite. Bound
# in `Spec.before_suite` — the spec DSL's `log_setup` clears the builder
# after file load, so a file-load-time bind would be wiped. The source is
# watcher-only, so the binding never affects other specs.
Spec.before_suite do
  Log.builder.bind("facet.dev.domain_watcher", Log::Severity::Info, WatcherLogBackend.new(WATCHER_LOGS))
end

# ── Helpers ─────────────────────────────────────────────────────────────────

# Re-registers the core doctypes the global truncation wiped.
def watcher_reseed_core(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# Seeds a small live domain `name` with the given doctypes (one `name`
# string field each).
def watcher_seed_domain(db, domain, doctypes = ["Widget"])
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: domain,
    content: %({"description": "watch #{domain}", "color": "#123456"}),
    actioner_id: "system:test",
  )
  doctypes.each do |doctype|
    Facet::Mutation::Client.create(
      db, "core", "DocType",
      doc_id: "#{domain}.#{doctype}",
      content: %({"doctype": "#{doctype}", "domain": "#{domain}", "schema_version": 1, "aggregate_root": true, "search": "{{ name }}", "fields": {"name": {"type": "string"}}}),
      meta: %({"parent_id": "#{domain}"}),
      actioner_id: "system:test",
    )
  end
end

# Creates a document through the app path (direct mutation write) with a
# caller-chosen id, so examples can assert on it precisely.
def watcher_create_doc(db, domain, doctype, doc_id, content)
  Facet::Mutation::Client.create(
    db, domain, doctype,
    doc_id: doc_id,
    content: content,
    actioner_id: "system:test",
  )
end

# Exports the live domain `domain` as a bundle directory under `root` and
# returns the bundle path.
def watcher_write_bundle(db, domain, root) : String
  result = Facet::Domain::Portable::Export.call(db, domain, with_documents: true)
  result = result.as(Facet::Domain::Portable::Export::Result)
  path = File.join(root, domain)
  Facet::Domain::Portable::Archive.write(result.bundle, path)
  path
end

def watcher_build(root, documents : Facet::Config::DocumentsMode = Facet::Config::DocumentsMode::Preserve) : Facet::Dev::DomainWatcher
  Facet::Dev::DomainWatcher.new(
    Facet::Config::DomainWatchConfig.new(path: root, poll_ms: 100, documents: documents),
  )
end

# One poll tick. Two ticks are the minimum for a child to cycle (debounce).
def watcher_polls(watcher, times = 2) : Nil
  times.times { watcher.sync_now }
end

# Rewrites a bundle file. The watcher's fingerprint is content-addressed,
# so any content change is seen on the next poll — no mtime spacing needed.
def watcher_touch_file(path : String, content : String) : Nil
  File.write(path, content)
end

def watcher_mutations(db, domain, doc_type, doc_id) : Int64
  db.query_one(
    "SELECT count(*) FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3",
    domain, doc_type, doc_id, as: Int64)
end

def watcher_reproject_mutations(db, domain, doc_type, doc_id) : Int64
  db.query_one(
    "SELECT count(*) FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND actioner_id = 'system:reproject'",
    domain, doc_type, doc_id, as: Int64)
end

def watcher_live?(db, domain, doc_type, id) : Bool
  !db.query_one?(
    "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
    domain, doc_type, id, as: Int32).nil?
end

# Creates a fresh watch root for the example and removes it afterwards.
def with_watch_root(& : String ->) : Nil
  root = File.join(Dir.tempdir, "facet-dev-watch-#{unique_suffix}")
  Dir.mkdir_p(root)
  begin
    yield root
  ensure
    FileUtils.rm_r(root) if Dir.exists?(root)
  end
end

# Full YAML document for `Config.from_yaml_node` (the loader's required
# keys) with an optional `dev:` section appended.
def watcher_config_yaml(dev_section : String? = nil) : YAML::Any
  yaml = <<-YAML
    event:
      url: "redis://localhost:6379/1"
    artifact_base_url: "http://localhost:3001"
    artifact_grant_secret: "test-grant-secret"
    artifact:
      storage:
        type: filesystem
        directory: tmp/uploads/test/store
    secrets:
      master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
    YAML
  yaml += "\n" + dev_section if dev_section
  YAML.parse(yaml)
end

# ── Specs ───────────────────────────────────────────────────────────────────

module Facet
  describe Dev::DomainWatcher do
    before_each do
      WATCHER_LOGS.clear
    end
    describe ".allowed?" do
      it "refuses the production environment" do
        Dev::DomainWatcher.allowed?("production").should be_false
      end

      it "allows every non-production environment" do
        Dev::DomainWatcher.allowed?("dev").should be_true
        Dev::DomainWatcher.allowed?("test").should be_true
      end
    end

    describe "root scan and first sync" do
      it "discovers bundle children, applies them fresh on the second poll, and ignores children without a bundle.yml" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_seed_domain(db, "bcrm")
            watcher_write_bundle(db, "aorders", root)
            watcher_write_bundle(db, "bcrm", root)
            Dir.mkdir_p(File.join(root, "notes"))

            # The target domains must be absent: the first sync is a fresh
            # import, not a replace.
            Facet::Domain::Scratch.dispose!(db, "aorders")
            Facet::Domain::Scratch.dispose!(db, "bcrm")

            watcher = watcher_build(root)

            # First poll — debounce holds, nothing cycles yet.
            watcher.sync_now
            watcher_live?(db, "core", "Domain", "aorders").should be_false
            watcher_live?(db, "core", "Domain", "bcrm").should be_false

            # Second poll — the fingerprint is stable, both children cycle.
            watcher.sync_now
            watcher_live?(db, "core", "Domain", "aorders").should be_true
            watcher_live?(db, "core", "Domain", "bcrm").should be_true
            watcher_live?(db, "core", "DocType", "aorders.Widget").should be_true
            watcher_live?(db, "core", "DocType", "bcrm.Widget").should be_true
          end
        end
      end

      it "warns and skips polling when the watch root is gone" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")
            FileUtils.rm_r(root)

            watcher = watcher_build(root)
            watcher.sync_now

            watcher_live?(db, "core", "Domain", "aorders").should be_false
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("watch root '#{root}' is gone")) }.should be_true
          end
        end
      end
    end

    describe "change detection" do
      it "does not re-cycle an unchanged child" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            before = watcher_mutations(db, "core", "DocType", "aorders.Widget")
            watcher_polls(watcher, 3)
            watcher_mutations(db, "core", "DocType", "aorders.Widget").should eq(before)
          end
        end
      end

      it "debounces a change until the fingerprint is stable on two consecutive polls" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            before = watcher_mutations(db, "core", "DocType", "aorders.Widget")
            watcher_touch_file(File.join(a_path, "domain.yml"),
              "content:\n  description: \"edited\"\n  color: \"#654321\"\n")

            watcher.sync_now
            watcher_mutations(db, "core", "DocType", "aorders.Widget").should eq(before)

            watcher.sync_now
            watcher_mutations(db, "core", "DocType", "aorders.Widget").should eq(before + 1)
          end
        end
      end

      it "syncs only the changed child; sibling domains do not cycle" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_seed_domain(db, "bcrm")
            a_path = watcher_write_bundle(db, "aorders", root)
            watcher_write_bundle(db, "bcrm", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")
            Facet::Domain::Scratch.dispose!(db, "bcrm")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            before_a = watcher_mutations(db, "core", "DocType", "aorders.Widget")
            before_b = watcher_mutations(db, "core", "DocType", "bcrm.Widget")

            watcher_touch_file(File.join(a_path, "domain.yml"),
              "content:\n  description: \"edited\"\n  color: \"#654321\"\n")
            watcher_polls(watcher)

            watcher_mutations(db, "core", "DocType", "aorders.Widget").should eq(before_a + 1)
            watcher_mutations(db, "core", "DocType", "bcrm.Widget").should eq(before_b)
          end
        end
      end

      it "keeps a failing child's previous state and does not block its sibling's cycle" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_seed_domain(db, "bcrm")
            a_path = watcher_write_bundle(db, "aorders", root)
            b_path = watcher_write_bundle(db, "bcrm", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")
            Facet::Domain::Scratch.dispose!(db, "bcrm")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # Break sibling B's bundle: the entry file the reader requires
            # is gone, so `Archive.read` fails for THIS child only.
            File.delete(File.join(b_path, "domain.yml"))

            before_a = watcher_mutations(db, "core", "DocType", "aorders.Widget")
            watcher_touch_file(File.join(a_path, "domain.yml"),
              "content:\n  description: \"edited\"\n  color: \"#654321\"\n")
            watcher_polls(watcher)

            # A cycled despite B's failure.
            watcher_mutations(db, "core", "DocType", "aorders.Widget").should eq(before_a + 1)
            # B kept its last synced state.
            watcher_live?(db, "core", "Domain", "bcrm").should be_true
            watcher_live?(db, "core", "DocType", "bcrm.Widget").should be_true
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("could not read bundle for 'bcrm'")) }.should be_true
          end
        end
      end
    end

    describe "duplicate source_domain" do
      it "syncs only the alphabetically first child and warns every cycle" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "dupe")
            first_path = watcher_write_bundle(db, "dupe", root)
            second_path = File.join(root, "zzz_late")
            FileUtils.cp_r(first_path, second_path)
            Facet::Domain::Scratch.dispose!(db, "dupe")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # One seed mutation (the domain was live before the watcher
            # existed) plus one import cycle wrote the doctype, despite two
            # changed children — the loser child never cycles.
            watcher_mutations(db, "core", "DocType", "dupe.Widget").should eq(2)
            watcher_live?(db, "core", "DocType", "dupe.Widget").should be_true

            # A change in the loser child never cycles.
            watcher_touch_file(File.join(second_path, "domain.yml"),
              "content:\n  description: \"edited\"\n  color: \"#654321\"\n")
            watcher_polls(watcher)
            watcher_mutations(db, "core", "DocType", "dupe.Widget").should eq(2)

            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("duplicate source_domain 'dupe'")) }.should be_true
          end
        end
      end
    end

    describe "documents mode: preserve" do
      it "keeps documents created through the app across a definition rebuild" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_create_doc(db, "aorders", "Widget", "seed1", %({"name": "seeded"}))
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            watcher_create_doc(db, "aorders", "Widget", "app1", %({"name": "app-made"}))
            watcher_touch_file(File.join(a_path, "domain.yml"),
              "content:\n  description: \"edited\"\n  color: \"#654321\"\n")
            watcher_polls(watcher)

            watcher_live?(db, "aorders", "Widget", "app1").should be_true
            watcher_live?(db, "aorders", "Widget", "seed1").should be_true
          end
        end
      end

      it "replays bundle documents into gaps only (idempotent skip of existing rows)" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # A new document file lands in the bundle: the next cycle
            # creates the missing row.
            doc_dir = File.join(a_path, "documents", "aorders.Widget")
            Dir.mkdir_p(doc_dir)
            watcher_touch_file(File.join(doc_dir, "new1.yml"),
              "content:\n  name: \"from bundle\"\nmeta: {}\n")
            watcher_polls(watcher)

            watcher_live?(db, "aorders", "Widget", "new1").should be_true
            watcher_mutations(db, "aorders", "Widget", "new1").should eq(1)

            # Another cycle skips the existing row — no second create.
            watcher_polls(watcher)
            watcher_mutations(db, "aorders", "Widget", "new1").should eq(1)
          end
        end
      end

      it "discards the documents of a doctype that leaves the bundle and warns for structurally changed survivors" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders", doctypes: ["Widget", "Extra"])
            watcher_create_doc(db, "aorders", "Widget", "seed1", %({"name": "seeded"}))
            watcher_create_doc(db, "aorders", "Extra", "extra1", %({"name": "seeded"}))
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            watcher_create_doc(db, "aorders", "Widget", "app1", %({"name": "app-made"}))

            # Extra's definition file is deleted; Widget's fields change
            # structurally (name → other) while carrying live documents. The
            # change carries a version bump so the merge gate accepts it; the
            # search template names `display_name` because the `name` field
            # it used to read is gone.
            File.delete(File.join(a_path, "doctypes", "aorders.Extra.yml"))
            watcher_touch_file(File.join(a_path, "doctypes", "aorders.Widget.yml"),
              "content:\n  doctype: Widget\n  domain: aorders\n  schema_version: 2\n  search: \"{{ display_name }}\"\n  fields:\n    other:\n      type: string\nmeta:\n  parent_id: aorders\n")
            watcher_polls(watcher)

            # The removed doctype's data is discarded with it.
            watcher_live?(db, "aorders", "Extra", "extra1").should be_false
            watcher_live?(db, "core", "DocType", "aorders.Extra").should be_false
            # The surviving doctype's documents are kept.
            watcher_live?(db, "aorders", "Widget", "app1").should be_true
            watcher_live?(db, "aorders", "Widget", "seed1").should be_true
            # The structure change warned.
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("aorders.Widget' changed structure")) }.should be_true
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("stale derived columns possible")) }.should be_true
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("aorders.Extra' left the bundle")) }.should be_true
          end
        end
      end
    end

    describe "documents mode: discard" do
      it "discards app-created documents and reseeds the bundle every cycle" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_create_doc(db, "aorders", "Widget", "seed1", %({"name": "seeded"}))
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root, Facet::Config::DocumentsMode::Discard)
            watcher_polls(watcher)

            watcher_create_doc(db, "aorders", "Widget", "app1", %({"name": "app-made"}))
            watcher_touch_file(File.join(a_path, "domain.yml"),
              "content:\n  description: \"edited\"\n  color: \"#654321\"\n")
            watcher_polls(watcher)

            # The app-created document is gone; the bundle's own row is
            # reseeded from scratch. Three create mutations: the seed, the
            # first import, and the rebuild after the edit.
            watcher_live?(db, "aorders", "Widget", "app1").should be_false
            watcher_live?(db, "aorders", "Widget", "seed1").should be_true
            watcher_mutations(db, "aorders", "Widget", "seed1").should eq(3)
          end
        end
      end
    end

    describe "replace and removal policy" do
      it "warns once when replacing a domain this process did not create" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            # The domain exists before the watcher ever saw it.
            watcher_seed_domain(db, "aorders")
            watcher_write_bundle(db, "aorders", root)

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # The pre-existing domain was replaced, not duplicated.
            watcher_live?(db, "core", "Domain", "aorders").should be_true
            watcher_mutations(db, "core", "DocType", "aorders.Widget").should eq(2)
            WATCHER_LOGS.count { |e| e.message.try(&.includes?("was not created by this watcher")) }.should eq(1)
          end
        end
      end

      it "keeps a removed bundle's domain and warns once per removal" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "bcrm")
            b_path = watcher_write_bundle(db, "bcrm", root)
            Facet::Domain::Scratch.dispose!(db, "bcrm")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            FileUtils.rm_r(b_path)
            watcher.sync_now

            # The last synced state is kept — nothing deletes a live domain.
            watcher_live?(db, "core", "Domain", "bcrm").should be_true
            watcher_live?(db, "core", "DocType", "bcrm.Widget").should be_true
            WATCHER_LOGS.count { |e| e.message.try(&.includes?("'#{b_path}' was removed")) }.should eq(1)

            # Further polls do not repeat the warning.
            watcher.sync_now
            WATCHER_LOGS.count { |e| e.message.try(&.includes?("'#{b_path}' was removed")) }.should eq(1)
          end
        end
      end
    end

    describe "event flush" do
      it "flushes the pending event queue after a successful cycle" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher.sync_now
            # The import enqueued events on this fibre; the second tick
            # (the cycle) must have flushed them.
            watcher.sync_now
            Facet::Event::Publisher.pending_count.should eq(0)
          end
        end
      end
    end

    describe "post-sync diagnostics" do
      it "logs a check summary after a cycle with a known reference issue" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            # Rewrite the doctype file so the bundle carries a reference
            # field whose target is not a registered doctype — authoring
            # time does not enforce cross-doctype targets, so the import
            # succeeds and `Doctype::Check` reports the reference warning.
            watcher_touch_file(File.join(a_path, "doctypes", "aorders.Widget.yml"),
              "content:\n  doctype: Widget\n  domain: aorders\n  schema_version: 1\n  aggregate_root: true\n  search: \"{{ name }}\"\n  fields:\n    name:\n      type: string\n    owner:\n      doctype: aorders.Missing\nmeta:\n  parent_id: aorders\n")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            watcher_live?(db, "core", "DocType", "aorders.Widget").should be_true
            # The reference issue counts, plus the missing display_name
            # :info notice (`check_defaults`). The 5 missing standard view
            # kinds (view, form, quickView, inline, card) are `:info`
            # notices and do not join the issue count.
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("check for 'aorders': 1 issue(s)")) }.should be_true
            # The summary line carries only the first message; the full
            # report records the reference issue.
            report = Facet::Dev::CheckReport.fetch("aorders")
            report.should_not be_nil
            report.not_nil!.as(Facet::Dev::CheckReport::Report).doctypes.flat_map(&.issues.map(&.message))
              .any?(&.includes?("Reference field 'owner' targets doctype 'aorders.Missing'")).should be_true
          end
        end
      end

      it "reprojects a structurally changed doctype with preserved documents and skips unchanged ones" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders", doctypes: ["Widget", "Extra"])
            watcher_create_doc(db, "aorders", "Widget", "seed1", %({"name": "seeded"}))
            watcher_create_doc(db, "aorders", "Extra", "extra1", %({"name": "seeded"}))
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # Widget's structure changes while carrying a live document;
            # Extra stays as authored. The kept row's derived columns are
            # re-projected; the untouched doctype's row is not touched. The
            # edit carries a version bump so the merge gate accepts the
            # field change, and the search template names `display_name`
            # because the `name` field it read is gone.
            watcher_touch_file(File.join(a_path, "doctypes", "aorders.Widget.yml"),
              "content:\n  doctype: Widget\n  domain: aorders\n  schema_version: 2\n  search: \"{{ display_name }}\"\n  fields:\n    other:\n      type: string\nmeta:\n  parent_id: aorders\n")
            watcher_polls(watcher)

            watcher_reproject_mutations(db, "aorders", "Widget", "seed1").should eq(1)
            watcher_reproject_mutations(db, "aorders", "Extra", "extra1").should eq(0)
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("reprojected 'aorders.Widget'")) }.should be_true
          end
        end
      end

      it "reprojects a search-template edit with preserved documents (the pre-sync gap)" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_create_doc(db, "aorders", "Widget", "seed1", %({"name": "seeded"}))
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # Only the derived surface changes: the `search` template. The
            # fields are untouched, yet the kept rows' search column is
            # now stale — this edit must warn and re-project. The seed
            # already declares `{{ name }}`, so the edit widens the corpus.
            watcher_touch_file(File.join(a_path, "doctypes", "aorders.Widget.yml"),
              "content:\n  doctype: Widget\n  domain: aorders\n  schema_version: 1\n  fields:\n    name:\n      type: string\n  search: \"{{ name }} {{ name }}\"\nmeta:\n  parent_id: aorders\n")
            watcher_polls(watcher)

            watcher_reproject_mutations(db, "aorders", "Widget", "seed1").should eq(1)
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("aorders.Widget' changed structure or derived surface")) }.should be_true
            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("reprojected 'aorders.Widget'")) }.should be_true
          end
        end
      end

      it "stays silent on an actions-only edit" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_create_doc(db, "aorders", "Widget", "seed1", %({"name": "seeded"}))
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # Runtime-only surface: stored documents never embed actions,
            # and no derived column depends on them.
            watcher_touch_file(File.join(a_path, "doctypes", "aorders.Widget.yml"),
              "content:\n  doctype: Widget\n  domain: aorders\n  schema_version: 1\n  search: \"{{ name }}\"\n  fields:\n    name:\n      type: string\n  actions:\n    go: {}\nmeta:\n  parent_id: aorders\n")
            watcher_polls(watcher)

            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("changed structure")) }.should be_false
            watcher_reproject_mutations(db, "aorders", "Widget", "seed1").should eq(0)
          end
        end
      end

      it "stays silent on a member_of-only edit" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "aorders")
            watcher_create_doc(db, "aorders", "Widget", "seed1", %({"name": "seeded"}))
            a_path = watcher_write_bundle(db, "aorders", root)
            Facet::Domain::Scratch.dispose!(db, "aorders")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # Composition-only: no derived column depends on member_of.
            watcher_touch_file(File.join(a_path, "doctypes", "aorders.Widget.yml"),
              "content:\n  doctype: Widget\n  domain: aorders\n  schema_version: 1\n  fields:\n    name:\n      type: string\n  member_of: Company\nmeta:\n  parent_id: aorders\n")
            watcher_polls(watcher)

            WATCHER_LOGS.any? { |e| e.message.try(&.includes?("changed structure")) }.should be_false
            watcher_reproject_mutations(db, "aorders", "Widget", "seed1").should eq(0)
          end
        end
      end
    end

    describe "import failure diagnostics (B-365)" do
      after_each do
        Facet::Dev::CheckReport.clear
      end

      it "records an import-failure marker and logs the formatted details when the import fails" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "afail")
            a_path = watcher_write_bundle(db, "afail", root)
            Facet::Domain::Scratch.dispose!(db, "afail")

            # A field name that fails identifier validation: the definition
            # parses, and the authoring gate's schema validation rejects it
            # with a structured detail — the fresh import returns a
            # `ServiceError` carrying that detail.
            watcher_touch_file(File.join(a_path, "doctypes", "afail.Widget.yml"),
              "content:\n  doctype: Widget\n  domain: afail\n  schema_version: 1\n  aggregate_root: true\n  search: \"{{ name }}\"\n  fields:\n    name:\n      type: string\n    Bad-Name:\n      type: string\nmeta:\n  parent_id: afail\n")

            watcher = watcher_build(root)
            watcher_polls(watcher)

            # The import rolled back: the domain stays absent. The failure
            # is still visible as the stored marker.
            watcher_live?(db, "core", "Domain", "afail").should be_false
            failure = Facet::Dev::CheckReport.fetch("afail").as(Facet::Dev::CheckReport::ImportFailure)
            failure.status.should eq(422)
            failure.message.should contain("afail.Widget: schema validation failed")
            failure.doctypes.should eq(["afail.Widget"])
            failure.details.any? { |d| d.field == "Bad-Name" && d.message.includes?("is not a valid identifier") }.should be_true

            # The log carries the CLI-formatted details block: the summary
            # line, then one indented line per structured detail.
            WATCHER_LOGS.any? do |e|
              message = e.message
              message.try(&.includes?("import for 'afail'")) &&
                message.try(&.includes?("keeping previous state")) &&
                message.try(&.includes?("\n  details:")) &&
                message.try(&.includes?("- Bad-Name: is not a valid identifier")) &&
                message.try(&.includes?("[schema]"))
            end.should be_true
          end
        end
      end

      it "overwrites the import-failure marker with the check report when a later cycle imports the bundle" do
        with_watch_root do |root|
          Facet::Database.with_db do |db|
            watcher_reseed_core(db)
            watcher_seed_domain(db, "afail")
            a_path = watcher_write_bundle(db, "afail", root)
            Facet::Domain::Scratch.dispose!(db, "afail")

            broken = "content:\n  doctype: Widget\n  domain: afail\n  schema_version: 1\n  aggregate_root: true\n  search: \"{{ name }}\"\n  fields:\n    name:\n      type: string\n    Bad-Name:\n      type: string\nmeta:\n  parent_id: afail\n"
            fixed = "content:\n  doctype: Widget\n  domain: afail\n  schema_version: 1\n  aggregate_root: true\n  search: \"{{ name }}\"\n  fields:\n    name:\n      type: string\nmeta:\n  parent_id: afail\n"
            doctype_path = File.join(a_path, "doctypes", "afail.Widget.yml")

            watcher = watcher_build(root)

            watcher_touch_file(doctype_path, broken)
            watcher_polls(watcher)
            Facet::Dev::CheckReport.fetch("afail").as(Facet::Dev::CheckReport::ImportFailure)

            watcher_touch_file(doctype_path, fixed)
            watcher_polls(watcher)

            watcher_live?(db, "core", "Domain", "afail").should be_true
            report = Facet::Dev::CheckReport.fetch("afail").as(Facet::Dev::CheckReport::Report)
            report.domain.should eq("afail")
          end
        end
      end
    end

    describe "fibre lifecycle" do
      it "starts, runs, and stops the poll fibre" do
        with_watch_root do |root|
          watcher = watcher_build(root)
          watcher.running?.should be_false

          watcher.start
          watcher.running?.should be_true

          watcher.stop
          assert_eventually { !watcher.running? }
        end
      end
    end
  end

  describe Config do
    describe "dev.domain_watch" do
      it "is nil when the dev section is absent" do
        cfg = Config.from_yaml_node(watcher_config_yaml)
        cfg.dev.domain_watch.should be_nil
      end

      it "loads path, poll_ms, and the preserve default" do
        with_watch_root do |root|
          cfg = Config.from_yaml_node(watcher_config_yaml(
            <<-YAML
              dev:
                domain_watch:
                  path: #{root}
              YAML
          ))
          watch = cfg.dev.domain_watch
          watch.should_not be_nil
          watch = watch.as(Config::DomainWatchConfig)
          watch.path.should eq(root)
          watch.poll_ms.should eq(500)
          watch.documents.should eq(Config::DocumentsMode::Preserve)
        end
      end

      it "loads the discard documents mode" do
        with_watch_root do |root|
          cfg = Config.from_yaml_node(watcher_config_yaml(
            <<-YAML
              dev:
                domain_watch:
                  path: #{root}
                  poll_ms: 250
                  documents: discard
              YAML
          ))
          watch = cfg.dev.domain_watch
          watch.should_not be_nil
          watch = watch.as(Config::DomainWatchConfig)
          watch.poll_ms.should eq(250)
          watch.documents.should eq(Config::DocumentsMode::Discard)
        end
      end

      it "raises on an unknown documents value" do
        with_watch_root do |root|
          expect_raises(ArgumentError, /documents/) do
            Config.from_yaml_node(watcher_config_yaml(
              <<-YAML
                dev:
                  domain_watch:
                    path: #{root}
                    documents: sometimes
                YAML
            ))
          end
        end
      end

      it "raises on a poll_ms below the lower bound" do
        with_watch_root do |root|
          expect_raises(ArgumentError, /poll_ms/) do
            Config.from_yaml_node(watcher_config_yaml(
              <<-YAML
                dev:
                  domain_watch:
                    path: #{root}
                    poll_ms: 50
                YAML
            ))
          end
        end
      end

      it "raises on a missing path" do
        expect_raises(ArgumentError, /path is required/) do
          Config.from_yaml_node(watcher_config_yaml(
            <<-YAML
              dev:
                domain_watch:
                  poll_ms: 500
              YAML
          ))
        end
      end

      it "raises on a path that is not a readable directory" do
        expect_raises(ArgumentError, /not a readable directory/) do
          Config.from_yaml_node(watcher_config_yaml(
            <<-YAML
              dev:
                domain_watch:
                  path: /nonexistent/facet-watch-root-#{unique_suffix}
              YAML
          ))
        end
      end
    end
  end
end
