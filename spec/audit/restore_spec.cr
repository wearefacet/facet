# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/audit"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"

# Specs for `Audit::Restore.resolve_target` — the pure-read half of the
# restore workflow. The write half (`Audit::Rollback`) is covered by
# `spec/audit/audit_spec.cr`; the HTTP surface is covered by
# `spec/http/audit_routes_spec.cr`.
RESTORE_DOMAIN = "audit"

def restore_create_doc(db, doctype = "RTarget", content = %({"name": "initial", "count": 0}))
  ensure_domain(db, RESTORE_DOMAIN)

  string_type = Facet::Doctype::FieldType.parse("string")
  integer_type = Facet::Doctype::FieldType.parse("integer")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: RESTORE_DOMAIN,
    fields: {
      "name"  => Facet::Doctype::FieldDefinition.new(type: string_type),
      "count" => Facet::Doctype::FieldDefinition.new(type: integer_type),
    },
  )

  create_result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  create_result.should be_a(Facet::Document::Create::Result)

  doc_result = Facet::Document::Create.call(db, RESTORE_DOMAIN, doctype, content, Facet::RBAC::AuthContext.system)
  doc_result.should be_a(Facet::Document::Create::Result)
  doc = doc_result.as(Facet::Document::Create::Result)

  {id: doc.projection.id, mut_id: doc.mutation_id}
end

def restore_update_doc(db, doctype, doc_id, patch)
  result = Facet::Document::Update.call(db, RESTORE_DOMAIN, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Update::Result)
  result.as(Facet::Document::Update::Result).mutation_id
end

def restore_delete_doc(db, doctype, doc_id)
  result = Facet::Document::Delete.call(db, RESTORE_DOMAIN, doctype, doc_id, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Delete::Result)
  result.as(Facet::Document::Delete::Result).mutation_id
end

describe Facet::Audit::Restore do
  describe ".resolve_target" do
    it "returns the mutation immediately before the delete (prior history)" do
      with_db do |db|
        doc = restore_create_doc(db, "RTargetHist")
        mut2 = restore_update_doc(db, "RTargetHist", doc[:id], %({"name": "updated", "count": 1}))
        restore_delete_doc(db, "RTargetHist", doc[:id])

        result = Facet::Audit::Restore.resolve_target(db, RESTORE_DOMAIN, "RTargetHist", doc[:id])
        result.should be_a(String)
        result.as(String).should eq(mut2)
      end
    end

    it "returns the create mutation id when the only preceding mutation is the create" do
      with_db do |db|
        doc = restore_create_doc(db, "RTargetCreate")
        restore_delete_doc(db, "RTargetCreate", doc[:id])

        result = Facet::Audit::Restore.resolve_target(db, RESTORE_DOMAIN, "RTargetCreate", doc[:id])
        result.should be_a(String)
        result.as(String).should eq(doc[:mut_id])
      end
    end

    it "returns the prior restore snapshot when the delete follows a restore" do
      with_db do |db|
        doc = restore_create_doc(db, "RTargetLoop")
        restore_delete_doc(db, "RTargetLoop", doc[:id])

        # Restore once — the rollback writes a `snapshot` mutation.
        target = Facet::Audit::Restore.resolve_target(db, RESTORE_DOMAIN, "RTargetLoop", doc[:id])
        rb = Facet::Audit::Rollback.call(db, target.as(String), Facet::RBAC::AuthContext.system)
        rb.should be_a(Facet::Audit::Rollback::Result)
        restore_mut_id = rb.as(Facet::Audit::Rollback::Result).mutation_id

        # Delete again — the resolver must now pick the restore snapshot,
        # so iterative delete/restore loops stay reachable.
        restore_delete_doc(db, "RTargetLoop", doc[:id])
        result = Facet::Audit::Restore.resolve_target(db, RESTORE_DOMAIN, "RTargetLoop", doc[:id])
        result.should be_a(String)
        result.as(String).should eq(restore_mut_id)
      end
    end

    it "returns 409 on a live document" do
      with_db do |db|
        doc = restore_create_doc(db, "RTargetLive")

        result = Facet::Audit::Restore.resolve_target(db, RESTORE_DOMAIN, "RTargetLive", doc[:id])
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq 409
      end
    end

    it "returns 404 on a document with no mutations" do
      with_db do |db|
        result = Facet::Audit::Restore.resolve_target(db, RESTORE_DOMAIN, "RTargetNone", "01NOSUCHDOCUMENTID")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq 404
      end
    end

    it "returns 422 when the only mutation is a delete with no preceding mutation" do
      with_db do |db|
        ensure_domain(db, RESTORE_DOMAIN)
        # Degenerate history: a delete mutation with no create before it.
        # Unreachable through the normal mutation flow; inserted directly so
        # the guard is exercised.
        doc_id = "deg_01DELETEONLYDOCID"
        db.exec(
          "INSERT INTO mutations (domain, doc_type, doc_id, idx, action, actioner_id, arguments, channel, cause_kind, cause_trace) VALUES ($1, $2, $3, 1, 'delete', 'system', '{}', 'internal', 'request', $3)",
          RESTORE_DOMAIN, "RTargetDeg", doc_id
        )

        result = Facet::Audit::Restore.resolve_target(db, RESTORE_DOMAIN, "RTargetDeg", doc_id)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq 422
      end
    end
  end
end
