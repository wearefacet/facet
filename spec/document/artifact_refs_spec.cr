# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/document"
require "../../src/doctype"
require "../../src/audit"
require "../../src/mutation/client"
require "../../src/rbac"

# Step 2 of the artifact system: `file`-field type + reference tracking.
#
# Files covered:
#   - src/doctype/field_types/file_type.cr (the `file` field type)
#   - src/document/artifact_refs.cr (the recursive walker + reconcile)
#   - src/document/{create,update,delete}.cr (transaction integration)
#   - src/audit/rollback.cr (rebuild on snapshot replay)
#
# `artifact_references` is a prune-only projection: it is rebuilt from the
# mutation log so a truncate-and-rebuild replay (rollback snapshot)
# repopulates it. The specs walk every documented rule:
#
#   1. refs insert on field set; drop on field unset.
#   2. array entries produce distinct normalized paths.
#   3. longtext inline `urn:facet:artifact:<id>` links counted.
#   4. duplicate links in one field collapse (ON CONFLICT).
#   5. document delete drops its refs.
#   6. projection rebuild (rollback snapshot) repopulates.
#   7. update touches `last_reference_at`.
#   8. object / dictionary path normalization.

DOMAIN_ARTREFS = "artrefs"

# Valid 26-char ULIDs used as artifact ids in these specs.
# (Crockford Base32: 0-9A-Z minus I, L, O, U.)
ART_1 = "01ARTR0TEST0ART0FACT00000A"
ART_2 = "01ARTR0TEST0ART0FACT00000B"
ART_3 = "01ARTR0TEST0ART0FACT00000C"

# Builds and persists a doctype definition with the given raw `fields` map
# (mirrors the inline helpers in spec/audit/audit_spec.cr). Returns the
# doctype id (`DOMAIN_ARTREFS.<Doctype>`).
def register_artrefs_doctype(db, doctype, fields : Hash(String, Facet::Doctype::FieldDefinition))
  ensure_domain(db, DOMAIN_ARTREFS)

  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: DOMAIN_ARTREFS,
    fields: fields,
  )
  create_result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  create_result.should be_a(Facet::Document::Create::Result)
  "#{DOMAIN_ARTREFS}.#{doctype}"
end

def create_artrefs_doc(db, doctype, content = "{}")
  result = Facet::Document::Create.call(db, DOMAIN_ARTREFS, doctype, content, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result)
end

def refs_for(db, doc_id)
  db.query_all(<<-SQL, DOMAIN_ARTREFS, doc_id, as: {String, String, Time})
    SELECT artifact_id, resource_field, last_reference_at
    FROM artifact_references
    WHERE domain = $1 AND resource_id = $2
    ORDER BY resource_field, artifact_id
  SQL
end

def refs_count(db, doc_id)
  db.query_one(<<-SQL, DOMAIN_ARTREFS, doc_id, as: Int64)
    SELECT COUNT(*) FROM artifact_references WHERE domain = $1 AND resource_id = $2
  SQL
end

# Truncates the artifact_references table so each spec starts from a
# known-empty state — the global per-example TRUNCATE in spec_helper.cr
# does not cover the artifact tables.
def truncate_artifact_refs
  with_db(&.exec("TRUNCATE artifact_references"))
end

# `artifact_references.artifact_id` references `artifacts.id`, so test
# fixtures need an `artifacts` row for every id we put into a `file` field.
# Inserts are idempotent — safe to call per-spec.
def seed_artifact(db, artifact_id, sha = artifact_id)
  db.exec(<<-SQL, artifact_id, sha, artifact_id)
    INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path)
    VALUES ($1, 'test.bin', 'application/octet-stream', 1, $2, $3 || '/' || $1)
    ON CONFLICT (id) DO NOTHING
  SQL
end

# Seeds a set of artifact ids at once so each spec declares its full fixture
# in one line.
def seed_artifacts(db, *ids)
  ids.each { |id| seed_artifact(db, id) }
end

describe Facet::Document::ArtifactRefs do
  before_each do
    truncate_artifact_refs
    with_db { |db| seed_artifacts(db, ART_1, ART_2, ART_3) }
  end

  # ── Spec 1: file field inserts/drops on set/unset ─────────────────────

  it "inserts a reference on file-field set, drops on unset" do
    with_db do |db|
      file_type = Facet::Doctype::FieldType.parse("file")
      register_artrefs_doctype(db, "Single", {
        "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
      })

      doc = create_artrefs_doc(db, "Single", %({"file": "#{ART_1}"}))
      rows = refs_for(db, doc.projection.id)
      rows.size.should eq(1)
      rows[0][0].should eq(ART_1)
      rows[0][1].should eq("file")

      # Update to unset the field — reference must disappear.
      Facet::Document::Update.call(db, DOMAIN_ARTREFS, "Single", doc.projection.id,
        %({"file": null}), Facet::RBAC::AuthContext.system)
      refs_count(db, doc.projection.id).should eq(0)
    end
  end

  # ── Spec 1b: nonexistent artifact ids are skipped, not a 500 ─────────

  it "skips a reference to an artifact that does not exist" do
    with_db do |db|
      file_type = Facet::Doctype::FieldType.parse("file")
      register_artrefs_doctype(db, "Ghost", {
        "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
      })

      # A fabricated id pasted into a `file` field. No `artifacts` row backs
      # it, so the FK would otherwise raise and turn the mutation into a 500.
      ghost = "01ARTR0TEST0ART0FACT00000Z"
      doc = create_artrefs_doc(db, "Ghost", %({"file": "#{ghost}"}))

      # The mutation succeeds and no reference row is recorded — a
      # nonexistent artifact has no bytes to prune, so dropping it is lossless.
      refs_count(db, doc.projection.id).should eq(0)

      # A later update that swaps in a real artifact records the reference.
      Facet::Document::Update.call(db, DOMAIN_ARTREFS, "Ghost", doc.projection.id,
        %({"file": "#{ART_1}"}), Facet::RBAC::AuthContext.system)
      rows = refs_for(db, doc.projection.id)
      rows.size.should eq(1)
      rows[0][0].should eq(ART_1)
    end
  end

  it "skips a longtext URN pointing at a nonexistent artifact" do
    with_db do |db|
      longtext_type = Facet::Doctype::FieldType.parse("longtext")
      register_artrefs_doctype(db, "GhostBody", {
        "body" => Facet::Doctype::FieldDefinition.new(type: longtext_type),
      })

      ghost = "01ARTR0TEST0ART0FACT00000Y"
      doc = create_artrefs_doc(db, "GhostBody",
        %({"body": "see urn:facet:artifact:#{ghost}"}))

      refs_count(db, doc.projection.id).should eq(0)
    end
  end

  # ── Spec 2: array entries produce distinct normalized paths ──────────

  it "emits distinct normalized paths for array entries" do
    with_db do |db|
      file_type = Facet::Doctype::FieldType.parse("file")
      object_type = Facet::Doctype::FieldType.parse("object")
      array_type = Facet::Doctype::FieldType.parse("array")
      register_artrefs_doctype(db, "Arr", {
        "items" => Facet::Doctype::FieldDefinition.new(
          type: array_type,
          items: Facet::Doctype::FieldDefinition.new(
            type: object_type,
            properties: {
              "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
            } of String => Facet::Doctype::FieldDefinition,
          ),
        ),
      })

      doc = create_artrefs_doc(db, "Arr", %({"items": [{"file": "#{ART_1}"}, {"file": "#{ART_2}"}]}))
      rows = refs_for(db, doc.projection.id)
      rows.size.should eq(2)
      paths = rows.map(&.[1])
      paths.should contain("items[0].file")
      paths.should contain("items[1].file")
    end
  end

  # ── Spec 3: longtext links counted ───────────────────────────────────

  it "counts longtext inline artifact links as references" do
    with_db do |db|
      longtext_type = Facet::Doctype::FieldType.parse("longtext")
      register_artrefs_doctype(db, "Body", {
        "body" => Facet::Doctype::FieldDefinition.new(type: longtext_type),
      })

      two_distinct = %({"body": "see [a](urn:facet:artifact:#{ART_1}) and urn:facet:artifact:#{ART_2} too"})
      doc = create_artrefs_doc(db, "Body", two_distinct)
      rows = refs_for(db, doc.projection.id)
      rows.size.should eq(2)
      artifact_ids = rows.map(&.[0])
      artifact_ids.should contain(ART_1)
      artifact_ids.should contain(ART_2)
      rows.all? { |r| r[1] == "body" }.should be_true
    end
  end

  # ── Spec 4: duplicate links in one field collapse ────────────────────

  it "collapses duplicate longtext links in one field to a single row" do
    with_db do |db|
      longtext_type = Facet::Doctype::FieldType.parse("longtext")
      register_artrefs_doctype(db, "Dup", {
        "body" => Facet::Doctype::FieldDefinition.new(type: longtext_type),
      })

      dup = %({"body": "first urn:facet:artifact:#{ART_1} plus urn:facet:artifact:#{ART_1} again"})
      doc = create_artrefs_doc(db, "Dup", dup)
      rows = refs_for(db, doc.projection.id)
      rows.size.should eq(1)
      rows[0][0].should eq(ART_1)
    end
  end

  # ── Spec 5: document delete drops its refs ──────────────────────────

  it "drops references when the document is deleted" do
    with_db do |db|
      file_type = Facet::Doctype::FieldType.parse("file")
      register_artrefs_doctype(db, "Del", {
        "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
      })

      doc = create_artrefs_doc(db, "Del", %({"file": "#{ART_1}"}))
      refs_count(db, doc.projection.id).should eq(1)

      result = Facet::Document::Delete.call(db, DOMAIN_ARTREFS, "Del", doc.projection.id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Delete::Result)
      refs_count(db, doc.projection.id).should eq(0)
    end
  end

  # ── Spec 6: projection rebuild (rollback) repopulates ────────────────

  it "repopulates references when a rollback snapshot is written" do
    with_db do |db|
      file_type = Facet::Doctype::FieldType.parse("file")
      register_artrefs_doctype(db, "Rb", {
        "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
      })

      # Initial create with file=ART_1, then update to file=ART_2.
      doc = create_artrefs_doc(db, "Rb", %({"file": "#{ART_1}"}))
      update_artrefs_doc(db, "Rb", doc.projection.id, %({"file": "#{ART_2}"}))

      # Pre-rollback: refs should point at ART_2.
      rows = refs_for(db, doc.projection.id)
      rows.size.should eq(1)
      rows[0][0].should eq(ART_2)

      # Rollback to the create mutation: snapshot content is file=ART_1.
      result = Facet::Audit::Rollback.call(db, doc.mutation_id, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Audit::Rollback::Result)

      rows = refs_for(db, doc.projection.id)
      rows.size.should eq(1)
      rows[0][0].should eq(ART_1)
    end
  end

  # ── Spec 7: update touches last_reference_at ─────────────────────────

  it "touches last_reference_at when an unchanged reference is re-walked" do
    with_db do |db|
      file_type = Facet::Doctype::FieldType.parse("file")
      register_artrefs_doctype(db, "Touch", {
        "file"        => Facet::Doctype::FieldDefinition.new(type: file_type),
        "description" => Facet::Doctype::FieldDefinition.new(
          type: Facet::Doctype::FieldType.parse("string"),
        ),
      })

      doc = create_artrefs_doc(db, "Touch", %({"file": "#{ART_1}", "description": "v1"}))
      before = refs_for(db, doc.projection.id)
      before.size.should eq(1)
      first_ts = before[0][2]

      # Backdate the reference row so the touch must advance it. Never rely
      # on write ordering: two writes in the same millisecond can get the
      # same ULID timestamp.
      db.exec(
        "UPDATE artifact_references SET last_reference_at = now() - interval '1 hour' WHERE domain = $1 AND resource_id = $2",
        DOMAIN_ARTREFS, doc.projection.id,
      )

      # Touch an unrelated field — `file` stays the same but the projection
      # gets reconciled from the updated content; last_reference_at must
      # advance past the backdated value.
      update_artrefs_doc(db, "Touch", doc.projection.id, %({"description": "v2"}))

      after = refs_for(db, doc.projection.id)
      after.size.should eq(1)
      after[0][0].should eq(ART_1)
      after[0][2].should be > first_ts
    end
  end

  # ── Spec 8: object / dictionary path normalization ───────────────────

  it "normalizes object, dictionary, and array paths distinctly" do
    with_db do |db|
      file_type = Facet::Doctype::FieldType.parse("file")
      object_type = Facet::Doctype::FieldType.parse("object")
      dictionary_type = Facet::Doctype::FieldType.parse("dictionary")
      register_artrefs_doctype(db, "Shapes", {
        "nested" => Facet::Doctype::FieldDefinition.new(
          type: object_type,
          properties: {
            "image" => Facet::Doctype::FieldDefinition.new(type: file_type),
          } of String => Facet::Doctype::FieldDefinition,
        ),
        "lookup" => Facet::Doctype::FieldDefinition.new(
          type: dictionary_type,
          dictionary_value: Facet::Doctype::FieldDefinition.new(type: file_type),
        ),
        "list" => Facet::Doctype::FieldDefinition.new(
          type: Facet::Doctype::FieldType.parse("array"),
          items: Facet::Doctype::FieldDefinition.new(type: file_type),
        ),
      })

      doc = create_artrefs_doc(db, "Shapes", %({
        "nested": {"image": "#{ART_1}"},
        "lookup": {"avatar": "#{ART_2}"},
        "list": ["#{ART_3}"]
      }))
      rows = refs_for(db, doc.projection.id)
      paths = rows.map(&.[1]).sort!
      paths.should eq(["list[0]", "lookup[avatar]", "nested.image"])
    end
  end

  # ── Spec 9: FileType validation absorbs ULID shape ───────────────────

  it "FileType validates artifact ids are 26-char Crockford Base32" do
    file_type = Facet::Doctype::FieldType.parse("file")
    field = Facet::Doctype::FieldDefinition.new(type: file_type)
    errors = [] of Facet::ValidationError

    # Accepts a valid ULID.
    file_type.validate(JSON::Any.new(ART_1), field, "file", errors)
    errors.should be_empty

    # Rejects a non-ULID string.
    errors.clear
    file_type.validate(JSON::Any.new("not-a-ulid"), field, "file", errors)
    errors.size.should eq(1)
    errors[0].code.should eq("invalid_format")

    # Rejects a non-string.
    errors.clear
    file_type.validate(JSON::Any.new(123_i64), field, "file", errors)
    errors.size.should eq(1)
    errors[0].code.should eq("invalid_type")
  end
end

def update_artrefs_doc(db, doctype, doc_id, patch)
  result = Facet::Document::Update.call(db, DOMAIN_ARTREFS, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Update::Result)
  result.as(Facet::Document::Update::Result).mutation_id
end
