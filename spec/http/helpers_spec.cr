# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/http/helpers"
require "../support/http_helper"

HTTPTest.init

describe Facet::HTTP::Helpers do
  describe ".json_error" do
    it "returns a JSON string with error message" do
      json = Facet::HTTP::Helpers.json_error(422, "Bad request")
      parsed = JSON.parse(json)
      parsed["error"].as_s.should eq("Bad request")
    end

    it "includes details when provided" do
      details = [
        Facet::ValidationError.new(message: "field x is required", field: "x", code: "required"),
        Facet::ValidationError.new(message: "field y is invalid", field: "y", code: "invalid_type"),
      ]
      json = Facet::HTTP::Helpers.json_error(422, "Bad request", details)
      parsed = JSON.parse(json)
      parsed["error"].as_s.should eq("Bad request")
      parsed["details"].as_a.size.should eq(2)
      parsed["details"].as_a[0]["message"].as_s.should eq("field x is required")
      parsed["details"].as_a[0]["field"].as_s.should eq("x")
      parsed["details"].as_a[0]["code"].as_s.should eq("required")
      parsed["details"].as_a[1]["message"].as_s.should eq("field y is invalid")
    end

    it "omits details when the array is empty" do
      json = Facet::HTTP::Helpers.json_error(404, "Not found", [] of Facet::ValidationError)
      parsed = JSON.parse(json)
      parsed["error"].as_s.should eq("Not found")
      parsed["details"]?.should be_nil
    end

    it "omits details when nil" do
      json = Facet::HTTP::Helpers.json_error(404, "Not found")
      parsed = JSON.parse(json)
      parsed["details"]?.should be_nil
    end

    it "serializes params next to field, message, and code when stamped" do
      details = [
        Facet::ValidationError.new(
          message: "has invalid enum value 'archived' (allowed: active, inactive)",
          field: "status",
          code: "invalid_format",
          params: {"value" => "archived", "allowed" => "active, inactive", "format" => "one of: active, inactive"},
        ),
      ]
      json = Facet::HTTP::Helpers.json_error(422, "Document validation failed", details)
      parsed = JSON.parse(json)
      detail = parsed["details"].as_a[0]
      detail["params"]["value"].as_s.should eq("archived")
      detail["params"]["allowed"].as_s.should eq("active, inactive")
      detail["params"]["format"].as_s.should eq("one of: active, inactive")
      detail["message"].as_s.should eq("has invalid enum value 'archived' (allowed: active, inactive)")
    end

    it "omits params when not stamped" do
      details = [
        Facet::ValidationError.new(message: "is missing", field: "subject", code: "required"),
      ]
      json = Facet::HTTP::Helpers.json_error(422, "Document validation failed", details)
      parsed = JSON.parse(json)
      detail = parsed["details"].as_a[0]
      detail["params"]?.should be_nil
      detail["code"].as_s.should eq("required")
    end
  end

  describe ".resolve_aggregate_root" do
    it "returns self for aggregate root" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Employee", domain: "hr", aggregate_root: true
      )
      domain, doc_type, doc_id, is_self = Facet::HTTP::Helpers.resolve_aggregate_root(defn, "hr", "e1")
      domain.should eq("hr")
      doc_type.should eq("Employee")
      doc_id.should eq("e1")
      is_self.should be_true
    end

    it "returns parent for member_of" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "CareerEvent", domain: "hr", member_of: "Employee"
      )
      domain, doc_type, doc_id, is_self = Facet::HTTP::Helpers.resolve_aggregate_root(defn, "hr", "ce1")
      domain.should eq("hr")
      doc_type.should eq("Employee")
      doc_id.should eq("ce1")
      is_self.should be_false
    end

    describe "lock_parent_for_share" do
      it "locks only the specific parent document, not any document of the same type" do
        with_temp_doctype("hr") do |db, domain, parent_dt|
          child_dt = "C#{unique_suffix(8)}"

          # Ensure the domain exists
          ensure_domain(db, domain)

          # Register parent doctype (aggregate root)
          parent_defn_json = %({
            "doctype": "#{parent_dt}",
            "domain": "#{domain}",
            "schema_version": 1,
            "aggregate_root": true,
            "search": "{{ display_name }}",
            "fields": {
              "name": { "type": "string", "required": true }
            }
          })
          parent_result = Facet::Document::Create.call(db, "core", "DocType", parent_defn_json, Facet::RBAC::AuthContext.system)
          expect_create_success(parent_result)

          # Register child doctype (member_of the parent)
          child_defn_json = %({
            "doctype": "#{child_dt}",
            "domain": "#{domain}",
            "schema_version": 1,
            "aggregate_root": false,
            "member_of": "#{parent_dt}",
            "fields": {
              "label": { "type": "string", "required": true }
            }
          })
          child_result = Facet::Document::Create.call(db, "core", "DocType", child_defn_json, Facet::RBAC::AuthContext.system)
          expect_create_success(child_result)

          # Create two parent documents — the lock must target the
          # requested one, not either.
          parent1 = Facet::Document::Create.call(db, domain, parent_dt, %({"name": "parent-one"}), Facet::RBAC::AuthContext.system)
          proj1 = expect_create_success(parent1)
          parent1_id = proj1.projection.id

          parent2 = Facet::Document::Create.call(db, domain, parent_dt, %({"name": "parent-two"}), Facet::RBAC::AuthContext.system)
          proj2 = expect_create_success(parent2)
          parent2_id = proj2.projection.id

          defn = Facet::Doctype::DoctypeDefinition.new(
            doctype: child_dt, domain: domain, member_of: parent_dt
          )

          # Use a second connection to probe locks.
          # Connection 1 (db) holds the lock from lock_parent_for_share inside a transaction.
          # Connection 2 (probe_db) tries FOR UPDATE NOWAIT on both parents —
          # the one locked by connection 1 will raise, the other won't.
          probe_db = db_open
          begin
            Facet::Database.with_transaction do |txn_db|
              Facet::HTTP::Helpers.lock_parent_for_share(txn_db, domain, defn, parent1_id)

              # Probe: try FOR UPDATE NOWAIT on both parents from connection 2.
              # The parent locked by conn1 will raise.
              locked_ids = [] of String
              [parent1_id, parent2_id].each do |pid|
                begin
                  probe_db.exec("SELECT id FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 FOR UPDATE NOWAIT", domain, parent_dt, pid)
                rescue PQ::PQError
                  locked_ids << pid
                end
              end

              # Exactly parent1 is locked; parent2 stays free.
              locked_ids.should eq([parent1_id])
            end
          ensure
            probe_db.close
          end
        end
      end
    end

    it "falls back to self when neither root nor member" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Person", domain: "identity"
      )
      domain, doc_type, doc_id, is_self = Facet::HTTP::Helpers.resolve_aggregate_root(defn, "identity", "p1")
      domain.should eq("identity")
      doc_type.should eq("Person")
      doc_id.should eq("p1")
      is_self.should be_true
    end
  end

  describe ".mutation_write_conflict?" do
    # Inserts one `create` mutation row. `idx` rides the statement, but the
    # BEFORE trigger recomputes it unless `harness.explicit_mutation_idx` is
    # set — so the caller controls whether the supplied idx is honored.
    insert_row = <<-SQL
      INSERT INTO mutations (
        domain, doc_type, id, doc_id, action, actioner_id, arguments,
        channel, cause_kind, cause_trace, idx
      )
      VALUES ('spec', 'IdxConflict', $1, $2, 'create', 'spec', '{}',
              'internal', 'request', $1, 1)
    SQL

    it "is true for a real 23505 on idx_mutations_doc_id_idx" do
      doc_id = "spec.idxconflict.#{unique_suffix(8)}"
      raised = nil
      with_db do |db|
        begin
          # Row 1 lands via the normal trigger path (MAX(idx) is NULL → 1).
          db.exec(insert_row, Facet::Util::ScriptHelpers.ulid, doc_id)

          # Pin idx = 1 for row 2 (the same slot row 1 took). The unique
          # index rejects it at once — the committed row 1 conflicts. This
          # is the same violation the concurrent-create race produces.
          db.exec("SELECT set_config('harness.explicit_mutation_idx', '1', false)")
          db.exec(insert_row, Facet::Util::ScriptHelpers.ulid, doc_id)
        rescue ex : PQ::PQError
          raised = ex
        ensure
          # The GUC is session-scoped on a pooled connection — always clear it.
          db.exec("SELECT set_config('harness.explicit_mutation_idx', '', false)")
        end
      end

      ex = raised.not_nil!
      Facet::Util::PgError.sqlstate(ex).should eq("23505")
      Facet::Util::PgError.constraint_name(ex).should eq("idx_mutations_doc_id_idx")
      Facet::HTTP::Helpers.mutation_write_conflict?(ex).should be_true
    end

    it "is false for a 23505 on a different constraint" do
      fixed_id = Facet::Util::ScriptHelpers.ulid
      doc_id = "spec.pkeyconflict.#{unique_suffix(8)}"
      raised = nil
      with_db do |db|
        begin
          db.exec(insert_row, fixed_id, doc_id)
          # Same mutation id → PRIMARY KEY (domain, doc_type, id) violation.
          db.exec(insert_row, fixed_id, doc_id)
        rescue ex : PQ::PQError
          raised = ex
        end
      end

      ex = raised.not_nil!
      Facet::Util::PgError.sqlstate(ex).should eq("23505")
      Facet::Util::PgError.constraint_name(ex).should_not eq("idx_mutations_doc_id_idx")
      Facet::HTTP::Helpers.mutation_write_conflict?(ex).should be_false
    end

    it "is false for a non-database error" do
      Facet::HTTP::Helpers.mutation_write_conflict?(ArgumentError.new("nope")).should be_false
    end
  end
end
