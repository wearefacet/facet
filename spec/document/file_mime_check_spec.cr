# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "spec"
require "../spec_helper"
require "../support/db_helper"
require "../../src/doctype"
require "../../src/document/file_mime_check"

# Tests for Document::FileMimeCheck.
#
# Verifies the runtime MIME gate that runs at document create / update
# time against the `artifacts.mime_type` column. The companion pure-logic
# coverage lives in `spec/util/mime_matcher_spec.cr`; here we only exercise
# the orchestration that ties a field's `accept` allow-list to a DB lookup.

# Seeds a bare `artifacts` row with the given id and mime_type. The
# `artifact_owners` rows are not needed — `FileMimeCheck` only reads
# `find_artifact`, which selects from the `artifacts` table directly.
#
# Named distinctly to avoid colliding with the top-level `seed_artifact`
# helper defined in `spec/document/artifact_refs_spec.cr`: Crystal does
# not overload top-level `def`s by arity, so two files defining
# `seed_artifact` in the same program cause the later definition to win
# for every call site in the suite.
def seed_file_mime_artifact(db, id, mime_type)
  db.exec(
    "INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path) " \
    "VALUES ($1, 'test.bin', $2, 1, $1, $1) " \
    "ON CONFLICT (id) DO UPDATE SET mime_type = $2",
    id, mime_type,
  )
end

module Facet
  describe Document::FileMimeCheck do
    describe ".check" do
      it "passes when no field declares an accept list" do
        with_db do |conn|
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Asset",
            domain: "test",
            fields: {
              "file" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("file")),
            },
          )
          doc = JSON.parse(%({"file": "01HZ00ARTIFACTTHATDNE0001"}))

          errors = Document::FileMimeCheck.check(conn, defn, doc)
          errors.should be_empty
        end
      end

      it "passes when the artifact mime matches the accept list" do
        with_db do |conn|
          seed_file_mime_artifact(conn, "01HZ00ARTIFACTTHATDNE0002", "image/png")

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Asset",
            domain: "test",
            fields: {
              "logo" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("file"),
                accept: ["image/*"],
              ),
            },
          )
          doc = JSON.parse(%({"logo": "01HZ00ARTIFACTTHATDNE0002"}))

          errors = Document::FileMimeCheck.check(conn, defn, doc)
          errors.should be_empty
        end
      end

      it "fails when the artifact mime does not match the accept list" do
        with_db do |conn|
          seed_file_mime_artifact(conn, "01HZ00ARTIFACTTHATDNE0003", "application/pdf")

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Asset",
            domain: "test",
            fields: {
              "logo" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("file"),
                accept: ["image/*"],
              ),
            },
          )
          doc = JSON.parse(%({"logo": "01HZ00ARTIFACTTHATDNE0003"}))

          errors = Document::FileMimeCheck.check(conn, defn, doc)
          errors.should_not be_empty
          errors.first.code.should eq("invalid_mime")
          errors.first.message.should contain("application/pdf")
          errors.first.message.should contain("image/*")
        end
      end

      it "passes when the field value is null (skipped)" do
        with_db do |conn|
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Asset",
            domain: "test",
            fields: {
              "logo" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("file"),
                accept: ["image/*"],
              ),
            },
          )
          doc = JSON.parse(%({"logo": null}))

          errors = Document::FileMimeCheck.check(conn, defn, doc)
          errors.should be_empty
        end
      end

      it "passes when the field is absent" do
        with_db do |conn|
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Asset",
            domain: "test",
            fields: {
              "logo" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("file"),
                accept: ["image/*"],
              ),
            },
          )
          doc = JSON.parse(%({}))

          errors = Document::FileMimeCheck.check(conn, defn, doc)
          errors.should be_empty
        end
      end

      it "passes when the artifact row is missing" do
        # A missing artifact row is a referential concern handled by the
        # reconcile pass — `FileMimeCheck` does not block the mutation when
        # it cannot read a row, only when the row carries a wrong MIME.
        with_db do |conn|
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Asset",
            domain: "test",
            fields: {
              "logo" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("file"),
                accept: ["image/*"],
              ),
            },
          )
          doc = JSON.parse(%({"logo": "0123456789ABCDEFGHIJKLMNP"}))

          errors = Document::FileMimeCheck.check(conn, defn, doc)
          errors.should be_empty
        end
      end

      it "matches against a concrete accept pattern" do
        with_db do |conn|
          seed_file_mime_artifact(conn, "01HZ00ARTIFACTTHATDNE0004", "application/pdf")

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Asset",
            domain: "test",
            fields: {
              "contract" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("file"),
                accept: ["application/pdf"],
              ),
            },
          )
          doc = JSON.parse(%({"contract": "01HZ00ARTIFACTTHATDNE0004"}))

          errors = Document::FileMimeCheck.check(conn, defn, doc)
          errors.should be_empty
        end
      end
    end
  end
end
