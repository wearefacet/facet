# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/reconcile"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "digest/sha256"
require "json"

# Step 6 of the artifact system: reconcile.
#
# Files covered:
#   - src/artifact/reconcile.cr — `Artifact::Reconcile` (bucket listing,
#     orphan detection, age gate) plus the `ReconcileCLI` subcommand.
#   - src/artifact/uploader.cr — the `each_object` storage enumeration.
#
# Specs walk every documented rule:
#   1. an object with no `artifacts` row and older than an hour is a
#      candidate.
#   2. an object with an `artifacts` row is kept (referenced).
#   3. an object younger than an hour is kept (in-flight upload protection).
#   4. the CLI deletes candidates by default and lists them under --dry-run.

DOMAIN_REC = "artrec"

def truncate_reconcile_tables
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Clears every object from the shrine store. The store is shared across
# specs (uploader_spec uploads objects that are never cleaned), so a
# reconcile spec must start from an empty bucket to observe only the
# objects it creates.
def clear_reconcile_store
  storage = Facet::Artifact::Uploader.storage
  case storage
  when Shrine::Storage::FileSystem
    root = storage.expanded_directory
    Dir.glob(File.join(root, "**", "*")).each do |full|
      File.delete(full) if File.file?(full)
    end
  else
    Facet::Artifact::Uploader.each_object do |key, _mtime|
      Facet::Artifact::Uploader.delete(key)
    end
  end
end

# Uploads a real object via the uploader (so a shrine file exists) and
# returns its shrine path.
def upload_reconcile_object(db, content = "hello world\n")
  ensure_domain(db, DOMAIN_REC)
  file_type = Facet::Doctype::FieldType.parse("file")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: "Asset",
    domain: DOMAIN_REC,
    fields: {
      "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
    } of String => Facet::Doctype::FieldDefinition,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
  doc_id = Facet::Document::Create.call(
    db, DOMAIN_REC, "Asset", %({}), Facet::RBAC::AuthContext.system,
  ).as(Facet::Document::Create::Result).projection.id
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new(content), "a.txt",
    Facet::RBAC::AuthContext.system,
    DOMAIN_REC, "Asset", doc_id, "file", nil,
  )
  result.as(Facet::Artifact::Uploader::Result).path
end

# Writes a raw object directly into the shrine store (no `artifacts` row),
# returning its shrine path. `mtime` is set to the given time so the age
# gate can be exercised deterministically.
def write_orphan_object(db, mtime : Time, content = "orphan")
  storage = Facet::Artifact::Uploader.storage
  path = "orphan-#{Random::Secure.hex(8)}"
  storage.upload(IO::Memory.new(content), path)
  full = Facet::Artifact::Reconcile.storage_key_for(path)
  File.utime(mtime, mtime, full)
  path
end

describe Facet::Artifact::Reconcile do
  before_each do
    truncate_reconcile_tables
    clear_reconcile_store
  end

  describe ".candidates" do
    it "flags an object with no artifacts row that is older than an hour" do
      with_db do |db|
        path = write_orphan_object(db, Time.utc - 2.hours)
        Facet::Artifact::Reconcile.candidates(db).should eq([path])
      end
    end

    it "keeps an object that has an artifacts row" do
      with_db do |db|
        upload_reconcile_object(db)
        Facet::Artifact::Reconcile.candidates(db).should be_empty
      end
    end

    it "keeps an object younger than an hour even with no artifacts row" do
      with_db do |db|
        write_orphan_object(db, Time.utc - 30.minutes)
        Facet::Artifact::Reconcile.candidates(db).should be_empty
      end
    end

    it "returns candidates sorted" do
      with_db do |db|
        a = write_orphan_object(db, Time.utc - 2.hours, "a")
        b = write_orphan_object(db, Time.utc - 3.hours, "b")
        Facet::Artifact::Reconcile.candidates(db).should eq([a, b].sort)
      end
    end
  end

  describe ".referenced_keys" do
    it "returns every artifacts.path in the database" do
      with_db do |db|
        path = upload_reconcile_object(db)
        Facet::Artifact::Reconcile.referenced_keys(db).should contain(path)
      end
    end
  end

  describe Facet::Artifact::ReconcileCLI do
    it "deletes orphan objects by default" do
      with_db do |db|
        path = write_orphan_object(db, Time.utc - 2.hours)
        silence_stdout { Facet::Artifact::ReconcileCLI.run([] of String) }
        Facet::Artifact::Uploader.exists?(path).should be_false
      end
    end

    it "lists candidates without deleting under --dry-run" do
      with_db do |db|
        path = write_orphan_object(db, Time.utc - 2.hours)
        silence_stdout { Facet::Artifact::ReconcileCLI.run(["--dry-run"]) }
        Facet::Artifact::Uploader.exists?(path).should be_true
      end
    end
  end
end
