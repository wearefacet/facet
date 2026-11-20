# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/access"
require "../../src/artifact/owners"
require "../../src/document"
require "../../src/document/copy"
require "../../src/doctype"
require "../../src/mutation/client"
require "../../src/rbac"

# Step 5 of the artifact system: owner-append flows.
#
# Files covered:
#   - src/artifact/owners.cr — `Artifact::Owners.append` /
#     `append_for_document`.
#   - src/document/copy.cr — `Document::Copy.deep_copy` appends owner rows
#     for copied artifacts.
#
# Specs walk every documented rule:
#   1. `Document::Copy` appends an owner row for a copied `file` field.
#   2. copy without read on the artifact fails loud (403).
#   3. `append` is idempotent (duplicate collapses to a no-op).
#   4. re-attach appends for `file` fields and for longtext URN links the
#      actor can read (silent skip otherwise, fabricated ids skipped).

DOMAIN_OWN = "artown"

def truncate_owners_tables
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

def setup_owners_doctype(db, domain, doctype)
  ensure_domain(db, domain)
  file_type = Facet::Doctype::FieldType.parse("file")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: domain,
    fields: {
      "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
    } of String => Facet::Doctype::FieldDefinition,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
end

def setup_owners_note_doctype(db, domain, tags : Array(String)? = nil)
  ensure_domain(db, domain)
  longtext_type = Facet::Doctype::FieldType.parse("longtext")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: "Note",
    domain: domain,
    fields: {
      "body" => Facet::Doctype::FieldDefinition.new(type: longtext_type, tags: tags),
    } of String => Facet::Doctype::FieldDefinition,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
end

def owners_png_bytes : Bytes
  Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAvCBxjw=")
end

# Uploads a file into a document and returns `{artifact_id, doc_id}`.
def upload_into(db, domain, doctype, doc_id)
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new(owners_png_bytes), "a.png",
    Facet::RBAC::AuthContext.system,
    domain, doctype, doc_id, "file", nil,
  )
  result.should be_a(Facet::Artifact::Uploader::Result)
  result.as(Facet::Artifact::Uploader::Result).artifact_id
end

describe Facet::Artifact::Owners do
  before_each { truncate_owners_tables }

  describe ".append" do
    it "is idempotent — a duplicate append collapses to a no-op" do
      with_db do |db|
        setup_owners_doctype(db, DOMAIN_OWN, "Asset")
        doc_id = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id
        artifact_id = upload_into(db, DOMAIN_OWN, "Asset", doc_id)

        # The upload already recorded one owner row. Appending again for the
        # same artifact + doc + field must not create a duplicate.
        Facet::Artifact::Owners.append(
          db, artifact_id, DOMAIN_OWN, "Asset", doc_id, "file", nil, "system:copy",
        )
        Facet::Artifact::Owners.append(
          db, artifact_id, DOMAIN_OWN, "Asset", doc_id, "file", nil, "system:copy",
        )

        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        owners.size.should eq(1)
      end
    end
  end

  describe "Document::Copy owner-append" do
    it "appends an owner row for a copied file field in the target domain" do
      with_db do |_db|
        Facet::Database.with_transaction do |txn|
          setup_owners_doctype(txn, "src", "Asset")
          setup_owners_doctype(txn, "dst", "Asset")
          src_doc = Facet::Document::Create.call(
            txn, "src", "Asset", %({}), Facet::RBAC::AuthContext.system,
          ).as(Facet::Document::Create::Result).projection.id
          artifact_id = upload_into(txn, "src", "Asset", src_doc)

          # The multipart flow substitutes the artifact id into the document
          # content; mirror that here so the source doc carries the file field.
          Facet::Document::Update.call(
            txn, "src", "Asset", src_doc, %({"file": "#{artifact_id}"}),
            Facet::RBAC::AuthContext.system,
          ).should be_a(Facet::Document::Update::Result)

          new_id = Facet::Document::Copy.deep_copy(
            txn,
            from_domain: "src",
            to_domain: "dst",
            doc_type: "Asset",
            doc_id: src_doc,
            actioner_id: "system:copy",
          )
          new_id.should be_a(String)
          new_id = new_id.as(String)

          # The copied document's file field holds the same artifact id.
          copied = Facet::Mutation::Client.fetch_content(txn, "dst", "Asset", new_id)
          copied.as_h["file"].as_s.should eq(artifact_id)

          # An owner row now exists for the artifact against the dst document.
          owners = Facet::Artifact::Store.find_owner_rows(txn, artifact_id)
          dst_owner = owners.find { |o| o.domain == "dst" && o.doc_id == new_id }
          dst_owner.should_not be_nil
          dst_owner.not_nil!.field_path.should eq("file")
        end
      end
    end

    it "fails loud when the actor cannot read the artifact" do
      with_db do |_db|
        Facet::Database.with_transaction do |txn|
          setup_owners_doctype(txn, "src", "Asset")
          setup_owners_doctype(txn, "dst", "Asset")
          src_doc = Facet::Document::Create.call(
            txn, "src", "Asset", %({}), Facet::RBAC::AuthContext.system,
          ).as(Facet::Document::Create::Result).projection.id
          artifact_id = upload_into(txn, "src", "Asset", src_doc)
          Facet::Document::Update.call(
            txn, "src", "Asset", src_doc, %({"file": "#{artifact_id}"}),
            Facet::RBAC::AuthContext.system,
          ).should be_a(Facet::Document::Update::Result)

          # A principal with no read access on the artifact. Build a role with
          # read on dst.Asset only (not src), so `can_read?` fails closed.
          role_content = JSON::Any.new({
            "name"        => JSON::Any.new("copy_role"),
            "permissions" => JSON::Any.new([
              JSON::Any.new({"action" => JSON::Any.new("read"), "on" => JSON::Any.new("dst.Asset")}),
            ]),
            "visible_tags" => JSON::Any.new([JSON::Any.new("default")]),
          })
          Facet::Mutation::Client.create(
            txn, "iam", "Role", doc_id: "copy_role",
            content: role_content.to_json, actioner_id: "system",
          )
          account_content = JSON::Any.new({"roles" => JSON::Any.new([JSON::Any.new("copy_role")])})
          Facet::Mutation::Client.create(
            txn, "iam", "Account", doc_id: "bob",
            content: account_content.to_json, actioner_id: "system",
          )
          role = Facet::RBAC::ActiveRole.from_projection_content(
            Facet::Mutation::Client.fetch_content(txn, "iam", "Role", "copy_role"),
          )
          bob = Facet::RBAC::AuthContext.authenticated("bob", role)

          result = Facet::Document::Copy.deep_copy(
            txn,
            from_domain: "src",
            to_domain: "dst",
            doc_type: "Asset",
            doc_id: src_doc,
            actioner_id: "bob",
            auth_context: bob,
          )
          result.should be_a(Facet::ServiceError)
          result.as(Facet::ServiceError).status.should eq(403)

          # No dst document was created (the copy rolled back).
          count = txn.query_one(
            "SELECT COUNT(*) FROM projections WHERE domain = 'dst' AND doc_type = 'Asset'",
            as: Int64)
          count.should eq(0)
        end
      end
    end
  end

  describe ".append_readable_for_document — re-attach" do
    it "appends an owner row when a JSON update puts a readable artifact id into a file field" do
      with_db do |db|
        setup_owners_doctype(db, DOMAIN_OWN, "Asset")
        src_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id
        artifact_id = upload_into(db, DOMAIN_OWN, "Asset", src_doc)

        target_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id

        # alice can read the artifact (through the source owner row) and can
        # update the target document.
        create_role_projection(db, "alice_role",
          [permission_json("read", "#{DOMAIN_OWN}.Asset"),
           permission_json("update", "#{DOMAIN_OWN}.Asset")],
          visible_tags: ["default"])
        create_account_projection(db, "alice", ["alice_role"])
        role = Facet::RBAC::ActiveRole.from_projection_content(
          Facet::Mutation::Client.fetch_content(db, "iam", "Role", "alice_role"),
        )
        alice = Facet::RBAC::AuthContext.authenticated("alice", role)

        # Sanity: alice can read the artifact through the source owner row.
        Facet::Artifact::Access.can_read?(db, alice, artifact_id).should be_true

        Facet::Document::Update.call(
          db, DOMAIN_OWN, "Asset", target_doc, %({"file": "#{artifact_id}"}), alice,
        ).should be_a(Facet::Document::Update::Result)

        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        target_owner = owners.find { |o| o.doc_id == target_doc }
        target_owner.should_not be_nil
        target_owner.not_nil!.field_path.should eq("file")
      end
    end

    it "appends an owner row when a JSON create puts a readable artifact id into a file field" do
      with_db do |db|
        setup_owners_doctype(db, DOMAIN_OWN, "Asset")
        src_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id
        artifact_id = upload_into(db, DOMAIN_OWN, "Asset", src_doc)

        create_role_projection(db, "dave_role",
          [permission_json("read", "#{DOMAIN_OWN}.Asset"),
           permission_json("create", "#{DOMAIN_OWN}.Asset")],
          visible_tags: ["default"])
        create_account_projection(db, "dave", ["dave_role"])
        role = Facet::RBAC::ActiveRole.from_projection_content(
          Facet::Mutation::Client.fetch_content(db, "iam", "Role", "dave_role"),
        )
        dave = Facet::RBAC::AuthContext.authenticated("dave", role)

        new_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({"file": "#{artifact_id}"}), dave,
        ).as(Facet::Document::Create::Result).projection.id

        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        owners.any? { |o| o.doc_id == new_doc }.should be_true
      end
    end

    it "does not append an owner row when the actor cannot read the artifact" do
      with_db do |db|
        setup_owners_doctype(db, DOMAIN_OWN, "Asset")
        src_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id
        artifact_id = upload_into(db, DOMAIN_OWN, "Asset", src_doc)

        target_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id

        # bob can update the target doc but has no read on the doctype, so he
        # cannot read the artifact through the source owner row. Knowing an id
        # must never confer ownership.
        create_role_projection(db, "bob_role",
          [permission_json("update", "#{DOMAIN_OWN}.Asset")],
          visible_tags: ["default"])
        create_account_projection(db, "bob", ["bob_role"])
        role = Facet::RBAC::ActiveRole.from_projection_content(
          Facet::Mutation::Client.fetch_content(db, "iam", "Role", "bob_role"),
        )
        bob = Facet::RBAC::AuthContext.authenticated("bob", role)

        Facet::Artifact::Access.can_read?(db, bob, artifact_id).should be_false

        Facet::Document::Update.call(
          db, DOMAIN_OWN, "Asset", target_doc, %({"file": "#{artifact_id}"}), bob,
        ).should be_a(Facet::Document::Update::Result)

        # No owner row appended against the target doc.
        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        owners.any? { |o| o.doc_id == target_doc }.should be_false
      end
    end

    it "appends an owner row when a JSON update embeds a readable artifact URN in a longtext field" do
      with_db do |db|
        setup_owners_doctype(db, DOMAIN_OWN, "Asset")
        setup_owners_note_doctype(db, DOMAIN_OWN)
        src_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id
        artifact_id = upload_into(db, DOMAIN_OWN, "Asset", src_doc)

        target_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Note", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id

        # carol can read the artifact (through the source owner row) and can
        # update the target note. Embedding the URN shares the artifact with
        # every reader of the note.
        create_role_projection(db, "carol_role",
          [permission_json("read", "#{DOMAIN_OWN}.Asset"),
           permission_json("update", "#{DOMAIN_OWN}.Note")],
          visible_tags: ["default"])
        create_account_projection(db, "carol", ["carol_role"])
        role = Facet::RBAC::ActiveRole.from_projection_content(
          Facet::Mutation::Client.fetch_content(db, "iam", "Role", "carol_role"),
        )
        carol = Facet::RBAC::AuthContext.authenticated("carol", role)

        Facet::Document::Update.call(
          db, DOMAIN_OWN, "Note", target_doc,
          %({"body": "see [a.png](urn:facet:artifact:#{artifact_id})"}), carol,
        ).should be_a(Facet::Document::Update::Result)

        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        target_owner = owners.find { |o| o.doc_id == target_doc }
        target_owner.should_not be_nil
        target_owner.not_nil!.field_path.should eq("body")
      end
    end

    it "appending for a longtext URN is idempotent across re-saves" do
      with_db do |db|
        setup_owners_doctype(db, DOMAIN_OWN, "Asset")
        setup_owners_note_doctype(db, DOMAIN_OWN)
        src_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id
        artifact_id = upload_into(db, DOMAIN_OWN, "Asset", src_doc)

        target_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Note", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id

        Facet::Document::Update.call(
          db, DOMAIN_OWN, "Note", target_doc,
          %({"body": "see urn:facet:artifact:#{artifact_id}"}),
          Facet::RBAC::AuthContext.system,
        ).should be_a(Facet::Document::Update::Result)
        Facet::Document::Update.call(
          db, DOMAIN_OWN, "Note", target_doc,
          %({"body": "see [again](urn:facet:artifact:#{artifact_id})"}),
          Facet::RBAC::AuthContext.system,
        ).should be_a(Facet::Document::Update::Result)

        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        owners.count { |o| o.doc_id == target_doc }.should eq(1)
      end
    end

    it "does not append an owner row when the actor cannot read the artifact referenced from a longtext field" do
      with_db do |db|
        setup_owners_doctype(db, DOMAIN_OWN, "Asset")
        setup_owners_note_doctype(db, DOMAIN_OWN)
        src_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Asset", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id
        artifact_id = upload_into(db, DOMAIN_OWN, "Asset", src_doc)

        target_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Note", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id

        # bob can update the note but has no read on the doctype, so he
        # cannot read the artifact through the source owner row. Knowing an
        # id must never confer ownership. The save still succeeds (silent
        # skip) — a document may link files its editor cannot read.
        create_role_projection(db, "bob_role",
          [permission_json("update", "#{DOMAIN_OWN}.Note")],
          visible_tags: ["default"])
        create_account_projection(db, "bob", ["bob_role"])
        role = Facet::RBAC::ActiveRole.from_projection_content(
          Facet::Mutation::Client.fetch_content(db, "iam", "Role", "bob_role"),
        )
        bob = Facet::RBAC::AuthContext.authenticated("bob", role)

        Facet::Artifact::Access.can_read?(db, bob, artifact_id).should be_false

        Facet::Document::Update.call(
          db, DOMAIN_OWN, "Note", target_doc,
          %({"body": "see urn:facet:artifact:#{artifact_id}"}), bob,
        ).should be_a(Facet::Document::Update::Result)

        owners = Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        owners.any? { |o| o.doc_id == target_doc }.should be_false
      end
    end

    it "does not append an owner row for a fabricated longtext URN" do
      with_db do |db|
        setup_owners_note_doctype(db, DOMAIN_OWN)
        target_doc = Facet::Document::Create.call(
          db, DOMAIN_OWN, "Note", %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id

        # A well-formed ULID with no `artifacts` row — the skip is lossless
        # (no bytes to own) and must not abort the caller's transaction.
        fabricated = "01AAAAAAAAAAAAAAAAAAAAAAAA"
        Facet::Document::Update.call(
          db, DOMAIN_OWN, "Note", target_doc,
          %({"body": "see urn:facet:artifact:#{fabricated}"}),
          Facet::RBAC::AuthContext.system,
        ).should be_a(Facet::Document::Update::Result)

        Facet::Artifact::Store.find_owner_rows(db, fabricated).size.should eq(0)
      end
    end
  end
end
