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

# Specs for the B-207 atomic sync: the teardown and the import share one
# transaction, so a failed import leaves the previous domain state live —
# the doctypes answer, they do not answer 410. A good cycle re-imports
# normally. The watcher is driven synchronously through `sync_now` (one
# call is one poll tick), the same harness the sibling spec file uses.
#
# The examples re-seed the core doctypes (the global truncation wipes
# them) and build their own watch root under the OS tempdir. Bundles are
# hand-written minimal directory bundles — the on-disk layout
# `Archive.read` expects.

# ── Log capture ─────────────────────────────────────────────────────────────

SYNC_LOGS = [] of Log::Entry

private class SyncLogBackend < ::Log::Backend
  # Synchronous dispatch: `write` must run on the emitting fiber — async
  # dispatch could land the cycle's last entry after the example already
  # asserted on the capture (the same rule `SpecLogCapture` holds).
  def initialize(@sink : Array(Log::Entry))
    super(::Log::DispatchMode::Sync)
  end

  def write(entry : Log::Entry) : Nil
    @sink << entry
  end
end

# Bound in `Spec.before_suite` — the spec DSL's `log_setup` clears the
# builder after file load, so a file-load-time bind would be wiped. The
# source is watcher-only, so the binding never affects other specs.
Spec.before_suite do
  Log.builder.bind("facet.dev.domain_watcher", Log::Severity::Info, SyncLogBackend.new(SYNC_LOGS))
end

# ── Helpers ────────────────────────────────────────────────────────────────

private def sync_reseed_core(db) : Nil
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

# Seeds a live domain `domain` with one doctype (one `name` string field)
# and one document, through direct mutation writes.
private def sync_seed_domain(db, domain : String) : Nil
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: domain,
    content: %({"description": "watch #{domain}", "color": "#123456"}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "#{domain}.Widget",
    content: %({"doctype": "Widget", "domain": "#{domain}", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}}),
    meta: %({"parent_id": "#{domain}"}),
    actioner_id: "system:test",
  )
  Facet::Mutation::Client.create(
    db, domain, "Widget",
    doc_id: "#{domain}.Widget.seed1",
    content: %({"name": "seeded"}),
    actioner_id: "system:test",
  )
end

private def sync_build(root : String) : Facet::Dev::DomainWatcher
  Facet::Dev::DomainWatcher.new(
    Facet::Config::DomainWatchConfig.new(path: root, poll_ms: 100, documents: Facet::Config::DocumentsMode::Preserve),
  )
end

private def sync_write_bundle(root : String, domain : String, doctype_content : String) : String
  path = File.join(root, domain)
  Dir.mkdir_p(File.join(path, "doctypes"))
  File.write(File.join(path, "bundle.yml"),
    "format_version: 2\n" \
    "source_domain: #{domain}\n" \
    "exported_at: \"2026-01-01T00:00:00Z\"\n" \
    "facet_version: \"test\"\n")
  File.write(File.join(path, "domain.yml"),
    "content:\n" \
    "  description: \"#{domain} bundle\"\n" \
    "  color: \"#123456\"\n" \
    "meta: {}\n")
  File.write(File.join(path, "doctypes", "#{domain}.Widget.yml"),
    "content: #{doctype_content}\n" \
    "meta:\n" \
    "  parent_id: #{domain}\n")
  path
end

# A valid bundle for the domain: the same Widget shape the live domain
# carries (the import is a fresh re-apply after the teardown).
private def sync_valid_widget_content : String
  %({"doctype": "Widget", "domain": "PLACEHOLDER", "schema_version": 1, "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}})
end

private def sync_write_valid_bundle(root : String, domain : String) : String
  sync_write_bundle(root, domain, sync_valid_widget_content.gsub("PLACEHOLDER", domain))
end

# A bundle the import rejects: the Widget definition declares a `children`
# entry whose target is not defined in the bundle — a one-sided composition
# edge, a hard 422 in the fresh-import composition gate. The rejection
# fires after the teardown, which is the state the atomicity contract
# protects.
private def sync_write_broken_bundle(root : String, domain : String) : String
  broken = %({"doctype": "Widget", "domain": "PLACEHOLDER", "schema_version": 1, "aggregate_root": true, "fields": {"name": {"type": "string"}}, "children": {"gadget": {"doctype": "Gadget"}}})
  sync_write_bundle(root, domain, broken.gsub("PLACEHOLDER", domain))
end

private def sync_live?(db, domain : String, doc_type : String, id : String) : Bool
  !db.query_one?(
    "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
    domain, doc_type, id, as: Int32).nil?
end

private def sync_definition_resolves(db, qualified : String) : Bool
  Facet::Doctype::DefinitionStore.cache.clear
  !Facet::Doctype::DefinitionStore.fetch(db, qualified).nil?
end

# Two poll ticks are the minimum for a child to cycle (the debounce).
private def sync_polls(watcher : Facet::Dev::DomainWatcher, times = 2) : Nil
  times.times { watcher.sync_now }
end

private def sync_with_watch_root(& : String ->) : Nil
  root = File.join(Dir.tempdir, "facet-dev-sync-#{unique_suffix}")
  Dir.mkdir_p(root)
  begin
    yield root
  ensure
    FileUtils.rm_r(root) if Dir.exists?(root)
  end
end

# ── Specs ──────────────────────────────────────────────────────────────────

module Facet
  describe "Dev::DomainWatcher sync atomicity (B-207)" do
    before_each do
      SYNC_LOGS.clear
    end

    it "keeps the previous domain state live when the import fails" do
      sync_with_watch_root do |root|
        Facet::Database.with_db do |db|
          sync_reseed_core(db)
          sync_seed_domain(db, "b207w")
          sync_write_broken_bundle(root, "b207w")

          watcher = sync_build(root)
          sync_polls(watcher)

          # The failed cycle logged the import refusal...
          SYNC_LOGS.any? { |e| e.message.try(&.includes?("import for 'b207w'")) && e.message.try(&.includes?("failed")) }.should be_true

          # ...and the previous state stayed live: the domain, the doctype
          # definition (the registry answers, never a 410), and the app
          # document all survive the rolled-back teardown.
          sync_live?(db, "core", "Domain", "b207w").should be_true
          sync_live?(db, "core", "DocType", "b207w.Widget").should be_true
          sync_live?(db, "b207w", "Widget", "b207w.Widget.seed1").should be_true
          sync_definition_resolves(db, "b207w.Widget").should be_true
        end
      end
    end

    it "re-imports normally on a good cycle" do
      sync_with_watch_root do |root|
        Facet::Database.with_db do |db|
          sync_reseed_core(db)
          sync_seed_domain(db, "b207g")
          sync_write_valid_bundle(root, "b207g")

          watcher = sync_build(root)
          sync_polls(watcher)

          SYNC_LOGS.any? { |e| e.message.try(&.includes?("synced 'b207g'")) }.should be_true
          sync_live?(db, "core", "Domain", "b207g").should be_true
          sync_live?(db, "core", "DocType", "b207g.Widget").should be_true
          sync_definition_resolves(db, "b207g.Widget").should be_true

          # The preserve-mode kept document survives the rebuild.
          sync_live?(db, "b207g", "Widget", "b207g.Widget.seed1").should be_true
        end
      end
    end
  end
end
