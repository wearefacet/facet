# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "json"
require "pg"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../../src/rbac"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# ── Load schemas once for the suite ──────────────────────────────────────
PERSON_DEFN      = load_doctype_schema("identity.Person/definition.yml")
EMPLOYEE_DEFN    = build_doctype_definition("hr.Employee/definition.yml", "hr.Employee/script.lua")
CAREEREVENT_DEFN = load_doctype_schema("hr.CareerEvent/definition.yml")

# Helper: register doctypes via the service and assert success
def register_hr_doctypes!
  results = register_hr_doctypes
  expect_create_success(results[:person])
  expect_create_success(results[:employee])
  expect_create_success(results[:career])
end

# Helper: upsert domain grants — lives in spec/support/doctype_helper.cr
# (single shared definition; the spec-defs gate forbids a second public copy).

# ────────────────────────────────────────────────────────────────────────────
# HR / Identity integration scenarios
#
# These tests exercise the full doctype lifecycle across the `identity.Person`
# and `hr.Employee` / `hr.CareerEvent` models. They cover:
#   - Schema parsing and validation
#   - Document-level field validation (types, enums, children, references)
#   - Composition and cardinality enforcement
#   - Custom action definitions and workflow rules
#   - Invariant enforcement (unique email, unique `person` reference, future dates)
#   - Computed field triggers
#   - Cross-domain replicated-field behaviour
#   - Event-log action recording
#   - Deletion cascade to child documents
# ────────────────────────────────────────────────────────────────────────────
describe "HR / Identity integration" do
  # ──────────────────────────────────────────────────────────────────────────
  # 1. Schema parsing and validation
  # ──────────────────────────────────────────────────────────────────────────
  describe "doctype schemas" do
    it "parses identity.Person" do
      defn = PERSON_DEFN
      defn.doctype.should eq("Person")
      defn.domain.should eq("identity")
      defn.schema_version.should eq(1)
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "parses hr.Employee" do
      defn = EMPLOYEE_DEFN
      defn.doctype.should eq("Employee")
      defn.domain.should eq("hr")
      defn.schema_version.should eq(1)
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      defn.actions.keys.should contain("promote")
      defn.actions.keys.should contain("change_salary")
      defn.actions.keys.should contain("terminate")
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "parses hr.CareerEvent" do
      defn = CAREEREVENT_DEFN
      defn.doctype.should eq("CareerEvent")
      defn.domain.should eq("hr")
      defn.aggregate_root.should be_false
      defn.member_of.should eq("Employee")
      Facet::Doctype::Validation.validate(defn).should be_empty
    end

    it "Person has expected fields" do
      fields = PERSON_DEFN.fields
      fields.has_key?("full_name").should be_true
      fields.has_key?("email").should be_true
      fields.has_key?("date_of_birth").should be_true
      fields.has_key?("contact").should be_true
      fields.has_key?("kind").should be_true

      fields["full_name"].type.not_nil!.type_name.should eq("string")
      fields["email"].type.not_nil!.type_name.should eq("string")
      fields["email"].unique.should be_true
      fields["date_of_birth"].type.not_nil!.type_name.should eq("date")
      fields["contact"].type.not_nil!.type_name.should eq("object")
      fields["kind"].type.not_nil!.type_name.should eq("enum")
      fields["kind"].values.not_nil!.map(&.key).should eq(["internal", "external"])
    end

    it "Employee has expected fields and references" do
      fields = EMPLOYEE_DEFN.fields
      fields.has_key?("status").should be_true
      fields.has_key?("hire_date").should be_true
      fields.has_key?("termination_date").should be_true
      fields.has_key?("job_title").should be_true
      fields.has_key?("department").should be_true
      fields.has_key?("salary").should be_true
      fields.has_key?("remote").should be_true
      fields.has_key?("tenure_days").should be_true
      fields.has_key?("current_title").should be_true
      fields.has_key?("person").should be_true
      fields.has_key?("manager").should be_true

      # Computed fields
      fields["tenure_days"].type.not_nil!.type_name.should eq("data")
      fields["tenure_days"].compute.should eq("employee_tenure_days")
      fields["current_title"].type.not_nil!.type_name.should eq("data")
      fields["current_title"].compute.should eq("employee_current_title")

      # Reference fields
      fields["person"].type.not_nil!.type_name.should eq("reference")
      fields["person"].doctype.should eq("identity.Person")
      fields["person"].required.should be_true

      fields["manager"].type.not_nil!.type_name.should eq("reference")
      fields["manager"].doctype.should eq("hr.Employee")

      # Children section
      children = EMPLOYEE_DEFN.children
      children.has_key?("career_events").should be_true
      children["career_events"].doctype.should eq("CareerEvent")
      children["career_events"].collection?.should be_true
    end

    it "CareerEvent has expected fields" do
      fields = CAREEREVENT_DEFN.fields
      fields.has_key?("seq").should be_true
      fields.has_key?("event_type").should be_true
      fields.has_key?("effective_date").should be_true
      fields.has_key?("new_title").should be_true
      fields.has_key?("new_salary").should be_true
      fields.has_key?("note").should be_true

      fields["seq"].type.not_nil!.type_name.should eq("integer")
      fields["event_type"].type.not_nil!.type_name.should eq("enum")
      fields["event_type"].values.not_nil!.map(&.key).should eq(["hired", "promoted", "transferred", "salary_changed", "terminated"])
      fields["effective_date"].type.not_nil!.type_name.should eq("date")
      fields["new_title"].type.not_nil!.type_name.should eq("string")
      fields["new_salary"].type.not_nil!.type_name.should eq("money")
      fields["note"].type.not_nil!.type_name.should eq("string")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 2. Document-level validation
  # ──────────────────────────────────────────────────────────────────────────
  describe "document validation" do
    it "accepts a valid Person document" do
      doc = JSON.parse(%({
        "full_name": "Alice Smith",
        "email": "alice@example.com",
        "date_of_birth": "1990-06-15",
        "contact": { "phone": "+66-2-123-4567", "city": "Bangkok" },
        "kind": "internal"
      }))
      Facet::Document::Validation.validate(doc, PERSON_DEFN).should be_empty
    end

    it "accepts a Person with default kind (external)" do
      doc = JSON.parse(%({
        "full_name": "Bob Jones",
        "email": "bob@example.com",
        "date_of_birth": "1985-03-20"
      }))
      Facet::Document::Validation.validate(doc, PERSON_DEFN).should be_empty
    end

    it "rejects a Person missing required fields" do
      doc = JSON.parse(%({}))
      errs = Facet::Document::Validation.validate(doc, PERSON_DEFN)
      errs.any? { |e| e.field == "full_name" && e.code == "required" }.should be_true
      errs.any? { |e| e.field == "email" && e.code == "required" }.should be_true
      errs.any? { |e| e.field == "date_of_birth" && e.code == "required" }.should be_true
    end

    it "rejects a Person with invalid enum kind" do
      doc = JSON.parse(%({
        "full_name": "Charlie",
        "email": "charlie@example.com",
        "date_of_birth": "1995-01-01",
        "kind": "vip"
      }))
      errs = Facet::Document::Validation.validate(doc, PERSON_DEFN)
      errs.any? { |e| e.field == "kind" && e.message.includes?("vip") }.should be_true
    end

    it "rejects a Person with non-object contact" do
      doc = JSON.parse(%({
        "full_name": "Diana",
        "email": "diana@example.com",
        "date_of_birth": "1992-07-01",
        "contact": "not-an-object"
      }))
      errs = Facet::Document::Validation.validate(doc, PERSON_DEFN)
      errs.any? { |e| e.field == "contact" && e.message.includes?("object") }.should be_true
    end

    it "accepts a valid Employee document" do
      doc = JSON.parse(%({
        "status": "active",
        "hire_date": "2024-01-15",
        "job_title": "Software Engineer",
        "department": "Engineering",
        "salary": #{money_json("80000", "USD")},
        "remote": true,
        "person": "identity.Person.01ARZ3NDEKTSV4RRFFQ69G5FAV"
      }))
      Facet::Document::Validation.validate(doc, EMPLOYEE_DEFN).should be_empty
    end

    it "accepts an Employee with null manager and no termination_date" do
      doc = JSON.parse(%({
        "status": "active",
        "hire_date": "2024-03-01",
        "job_title": "Designer",
        "department": "Design",
        "salary": #{money_json("65000", "USD")},
        "person": "identity.Person.01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "manager": null
      }))
      Facet::Document::Validation.validate(doc, EMPLOYEE_DEFN).should be_empty
    end

    it "rejects an Employee missing required person reference" do
      doc = JSON.parse(%({
        "hire_date": "2024-01-15",
        "job_title": "Engineer"
      }))
      errs = Facet::Document::Validation.validate(doc, EMPLOYEE_DEFN)
      errs.any? { |e| e.field == "person" && e.code == "required" }.should be_true
    end

    it "rejects an Employee with computed fields in input" do
      doc = JSON.parse(%({
        "status": "active",
        "hire_date": "2024-01-15",
        "job_title": "Engineer",
        "person": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "tenure_days": 100
      }))
      errs = Facet::Document::Validation.validate(doc, EMPLOYEE_DEFN)
      errs.any? { |e| e.field == "tenure_days" && e.message.includes?("computed") }.should be_true
    end

    it "rejects an Employee with career_events as field (now a child relationship, not a field)" do
      doc = JSON.parse(%({
        "hire_date": "2024-01-15",
        "job_title": "Engineer",
        "person": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "career_events": "not-an-array"
      }))
      errs = Facet::Document::Validation.validate(doc, EMPLOYEE_DEFN)
      errs.any? { |e| e.field == "career_events" && e.code == "unknown_field" }.should be_true
    end

    it "accepts a valid CareerEvent document" do
      doc = JSON.parse(%({
        "seq": 1,
        "event_type": "hired",
        "effective_date": "2024-01-15",
        "new_title": "Software Engineer",
        "new_salary": #{money_json("80000", "USD")},
        "note": "Initial position"
      }))
      Facet::Document::Validation.validate(doc, CAREEREVENT_DEFN).should be_empty
    end

    it "rejects a CareerEvent with unknown event_type" do
      doc = JSON.parse(%({
        "seq": 1,
        "event_type": "fired",
        "effective_date": "2024-01-15"
      }))
      errs = Facet::Document::Validation.validate(doc, CAREEREVENT_DEFN)
      errs.any? { |e| e.field == "event_type" && e.message.includes?("fired") }.should be_true
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 3. Composition and cardinality
  # ──────────────────────────────────────────────────────────────────────────
  describe "composition and cardinality" do
    it "career_events is a collection child relationship" do
      EMPLOYEE_DEFN.children.has_key?("career_events").should be_true
      EMPLOYEE_DEFN.children["career_events"].collection?.should be_true
    end

    it "person is a single reference (not a collection)" do
      EMPLOYEE_DEFN.fields["person"].collection.should be_false
    end

    it "manager is a single reference (not a collection)" do
      EMPLOYEE_DEFN.fields["manager"].collection.should be_false
    end

    it "CareerEvent is a member of Employee" do
      CAREEREVENT_DEFN.member_of.should eq("Employee")
    end

    it "CareerEvent is not an aggregate root" do
      CAREEREVENT_DEFN.aggregate_root.should be_false
    end

    it "Employee is an aggregate root" do
      EMPLOYEE_DEFN.aggregate_root.should be_true
    end

    it "Person is a standalone aggregate root (referenced by Employee)" do
      PERSON_DEFN.aggregate_root.should be_true
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 4. Actions and workflow (schema-level contracts)
  # ──────────────────────────────────────────────────────────────────────────
  describe "actions" do
    it "defines the expected actions" do
      actions = EMPLOYEE_DEFN.actions
      actions.keys.should contain("promote")
      actions.keys.should contain("change_salary")
      actions.keys.should contain("terminate")
      actions.size.should eq(3)
    end

    it "has no reserved action names" do
      EMPLOYEE_DEFN.actions.each_key do |action_name|
        Facet::Doctype::Validation::RESERVED_ACTIONS.includes?(action_name).should be_false
      end
    end

    it "CareerEvent has no actions (no independent lifecycle)" do
      CAREEREVENT_DEFN.actions.should be_empty
    end

    it "promote action declares new_title arg" do
      promote_args = EMPLOYEE_DEFN.actions["promote"].args
      promote_args.has_key?("new_title").should be_true, "promote action should declare new_title arg"
    end

    it "change_salary action declares new_salary arg" do
      change_salary_args = EMPLOYEE_DEFN.actions["change_salary"].args
      change_salary_args.has_key?("new_salary").should be_true, "change_salary action should declare new_salary arg"
    end

    it "terminate action declares effective_date arg" do
      terminate_args = EMPLOYEE_DEFN.actions["terminate"].args
      terminate_args.has_key?("effective_date").should be_true, "terminate action should declare effective_date arg"
    end
  end

  # ── Integration scenarios that need the mutation engine ──────────────────

  describe "promote action" do
    before_each do
      register_hr_doctypes!
    end

    it "promote action updates job_title" do
      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        args = %({"new_title": "Senior Software Engineer", "effective_date": "2025-03-01"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "promote", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        res = expect_action_success(result)
        content = res.projection.content
        content["job_title"].as_s.should eq("Senior Software Engineer")
      end
    end

    it "promote action rejects promote if new_title equals the current title" do
      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        args = %({"new_title": "Software Engineer"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "promote", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        err = expect_action_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("New title must differ from current title")
      end
    end

    it "promote action rejects promote if the employee is not active" do
      with_db do |db|
        person_id = create_person_via_service(db, "Inactive Employee", "inactive@example.com")
        employee_id = create_employee_via_service(db, person_id, status: "on_leave", job_title: "Engineer")

        args = %({"new_title": "Senior Engineer"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "promote", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        err = expect_action_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("Employee is not active")
      end
    end
  end

  describe "change_salary action" do
    before_each do
      register_hr_doctypes!
    end

    it "appends changes salary" do
      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        args = %({"new_salary": #{money_json("95000", "USD")}, "effective_date": "2025-06-01"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "change_salary", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        res = expect_action_success(result)
        content = res.projection.content
        content["salary"]["value"].as_s.should eq("95000")
        content["salary"]["currency"].as_s.should eq("USD")
      end
    end

    it "rejects change_salary if new_salary <= 0" do
      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        args = %({"new_salary": #{money_json("0", "USD")}})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "change_salary", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        err = expect_action_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("New salary must be greater than zero")
      end
    end

    it "rejects change_salary if new_salary equals current salary" do
      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        args = %({"new_salary": #{money_json("80000", "USD")}})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "change_salary", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        err = expect_action_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("New salary must differ from current salary")
      end
    end
  end

  describe "terminate action" do
    before_each do
      register_hr_doctypes!
    end

    it "sets status=terminated and sets termination_date" do
      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        args = %({"note": "Reduction in force", "effective_date": "2025-12-01"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "terminate", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        res = expect_action_success(result)
        content = res.projection.content
        content["status"].as_s.should eq("terminated")
        content["termination_date"].as_s.should eq("2025-12-01")
      end
    end

    it "rejects terminate if not currently active" do
      with_db do |db|
        person_id = create_person_via_service(db, "Inactive Person", "inactive2@example.com")
        employee_id = create_employee_via_service(db, person_id, status: "on_leave", job_title: "On Leave")

        args = %({"note": "Trying to terminate non-active"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "terminate", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        err = expect_action_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("Employee is not active")
      end
    end

    it "promote and change_salary reject after termination" do
      with_db do |db|
        person_id = create_person_via_service(db, "Will Be Fired", "fired@example.com")
        employee_id = create_employee_via_service(db, person_id)

        # Terminate first
        term_args = %({"note": "Fired", "effective_date": "2025-12-01"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "terminate", args_body: term_args, auth_context: Facet::RBAC::AuthContext.system)
        expect_action_success(result)

        # Promote should fail
        promote_args = %({"new_title": "Senior Engineer", "effective_date": "2025-12-02"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "promote", args_body: promote_args, auth_context: Facet::RBAC::AuthContext.system)
        err = expect_action_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("Employee is not active")

        # Change salary should also fail
        salary_args = %({"new_salary": #{money_json("100000", "USD")}})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "change_salary", args_body: salary_args, auth_context: Facet::RBAC::AuthContext.system)
        err = expect_action_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("Employee is not active")
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 5. Validation invariants
  # ──────────────────────────────────────────────────────────────────────────
  describe "validation invariants" do
    it "duplicate email on Person is rejected (unique constraint)" do
      register_hr_doctypes!

      with_db do |db|
        # Create the first Person — should succeed.
        person_body = %({
          "full_name": "Alice Smith",
          "email": "dupe@example.com",
          "date_of_birth": "1990-06-15",
          "kind": "internal"
        })
        result1 = Facet::Document::Create.call(db, "identity", "Person", person_body, Facet::RBAC::AuthContext.system)
        expect_create_success(result1)

        # Create a second Person with the same email — should fail.
        person_body2 = %({
          "full_name": "Bob Jones",
          "email": "dupe@example.com",
          "date_of_birth": "1985-03-20",
          "kind": "external"
        })
        result2 = Facet::Document::Create.call(db, "identity", "Person", person_body2, Facet::RBAC::AuthContext.system)
        err = expect_create_error(result2, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("unique")
      end
    end

    it "future hire_date on Employee is rejected" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db)

        # Attempt to create Employee with hire_date after now
        employee_body = %({
          "status": "active",
          "hire_date": "2099-01-15",
          "job_title": "Engineer",
          "department": "Engineering",
          "salary": #{money_json("80000", "USD")},
          "remote": true,
          "person": "#{person_id}"
        })
        result = Facet::Document::Create.call(db, "hr", "Employee", employee_body, Facet::RBAC::AuthContext.system)
        err = expect_create_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("hire_date cannot be in the future")
      end
    end

    it "second Employee for the same Person is rejected (unique reference)" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db)
        first = create_employee_via_service(db, person_id)
        first.should_not be_nil

        # A second Employee pointing at the same Person id is rejected because
        # the `person` reference is declared `unique: true`.
        result = Facet::Document::Create.call(
          db, "hr", "Employee",
          %({
            "status": "active",
            "hire_date": "2024-01-15",
            "job_title": "Engineer",
            "department": "Engineering",
            "salary": #{money_json("80000", "USD")},
            "remote": true,
            "person": "#{person_id}"
          }),
          Facet::RBAC::AuthContext.system,
        )
        err = expect_create_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("unique")
      end
    end

    it "manager reference set to self is rejected" do
      register_hr_doctypes!

      with_db do |db|
        person_boss_id = create_person_via_service(db)
        person_self_id = create_person_via_service(db, "Self Ref", "self@example.com")

        # An hr.Employee row whose opaque id equals the person's id — the
        # value the request below points `manager` at. The manager
        # reference must pass the existence check before the Lua hook
        # runs, so the row has to exist first.
        manager_body = %({
          "status": "active",
          "hire_date": "2024-01-15",
          "job_title": "Manager",
          "department": "Engineering",
          "salary": #{money_json("90000", "USD")},
          "remote": true,
          "person": "#{person_boss_id}"
        })
        manager_result = Facet::Document::Create.call(db, "hr", "Employee", manager_body, Facet::RBAC::AuthContext.system, doc_id: person_self_id)
        expect_create_success(manager_result)

        # Attempt to create Employee where the manager id segment equals
        # the person id segment (the hook's "reference to self" rule).
        employee_body = %({
          "status": "active",
          "hire_date": "2024-01-15",
          "job_title": "Engineer",
          "department": "Engineering",
          "salary": #{money_json("80000", "USD")},
          "remote": true,
          "person": "#{person_self_id}",
          "manager": "hr.Employee.#{person_self_id}"
        })
        result = Facet::Document::Create.call(db, "hr", "Employee", employee_body, Facet::RBAC::AuthContext.system)
        err = expect_create_error(result, status: 422)
        err.details.not_nil!.map(&.message).join(", ").should contain("manager cannot reference self")
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 6. Computed fields
  # ──────────────────────────────────────────────────────────────────────────
  describe "computed fields" do
    it "tenure_days is defined as computed" do
      field = EMPLOYEE_DEFN.fields["tenure_days"]
      field.computed?.should be_true
      field.compute.should eq("employee_tenure_days")
      field.compute_when.should eq(["hire_date", "termination_date"])
    end

    it "current_title is defined as computed" do
      field = EMPLOYEE_DEFN.fields["current_title"]
      field.computed?.should be_true
      field.compute.should eq("employee_current_title")
      field.compute_when.should eq(["job_title"])
    end

    it "tenure_days recomputes when termination_date is set" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        # Terminate the employee — this sets termination_date and triggers compute
        args = %({"note": "Reduction in force", "effective_date": "2025-12-01"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "terminate", args_body: args, auth_context: Facet::RBAC::AuthContext.system)

        res = expect_action_success(result)
        content = res.projection.content

        # termination_date was set
        content["termination_date"].as_s.should eq("2025-12-01")

        # tenure_days should be computed and present
        content["tenure_days"]?.should_not be_nil
        content["tenure_days"].as_i.should be > 0
      end
    end

    it "current_title returns job_title after a promote" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        # Promote the employee — job_title changes, which triggers compute
        args = %({"new_title": "Senior Software Engineer", "effective_date": "2025-03-01"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "promote", args_body: args, auth_context: Facet::RBAC::AuthContext.system)

        res = expect_action_success(result)
        content = res.projection.content

        # current_title should match the updated job_title
        content["current_title"]?.should_not be_nil
        content["current_title"].as_s.should eq("Senior Software Engineer")
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 7. Cross-domain behaviour
  # ──────────────────────────────────────────────────────────────────────────
  describe "cross-domain" do
    it "Employee can read Person's fields (full_name, email) but cannot write them" do
      register_hr_doctypes!

      with_db do |db|
        # Set up domain grants so hr can read from identity.
        upsert_domain_with_grants(db, "identity", %([
          {"to": "hr", "doctype": "Person", "fields": ["full_name", "email"]}
        ]))

        # Re-register hr.Employee with replicate fields.
        existing = Facet::Doctype::DefinitionStore.fetch(db, "hr.Employee")
        existing.should_not be_nil
        defn = existing.not_nil!

        fields = defn.fields.dup
        fields["person_full_name"] = Facet::Doctype::FieldDefinition.new(
          type: Facet::Doctype::FieldType.parse("string"),
          replicate: Facet::Doctype::ReplicateConfig.new(via: "person", field: "full_name"),
        )
        fields["person_email"] = Facet::Doctype::FieldDefinition.new(
          type: Facet::Doctype::FieldType.parse("string"),
          replicate: Facet::Doctype::ReplicateConfig.new(via: "person", field: "email"),
        )

        enhanced = Facet::Doctype::DoctypeDefinition.new(
          doctype: defn.doctype,
          domain: defn.domain,
          schema_version: defn.schema_version,
          aggregate_root: defn.aggregate_root,
          fields: fields,
          children: defn.children,
          actions: defn.actions,
          script: defn.script,
        )

        errors = Facet::Replication::Validator.validate(enhanced, db)
        unless errors.empty?
          fail "Test doctype invalid: #{errors.join(", ")}"
        end

        Facet::Mutation::Client.snapshot_mutation(
          db, "core", "DocType",
          doc_id: "hr.Employee",
          content: enhanced.to_json,
          actioner_id: "system",
        )

        Facet::Doctype::DefinitionStore.cache.clear

        person_id = create_person_via_service(db, "Alice Smith", "alice@example.com")
        employee_id = create_employee_via_service(db, person_id)

        # Verify replica fields are populated by SyncPull on create.
        content = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id)
        content["person_full_name"]?.try(&.as_s).should eq("Alice Smith")
        content["person_email"]?.try(&.as_s).should eq("alice@example.com")

        # Attempt to write to the replicate field directly — should be rejected.
        update_body = %({"person_full_name": "Hacked Name"})
        update_result = Facet::Document::Update.call(db, "hr", "Employee", employee_id, update_body, Facet::RBAC::AuthContext.system)
        update_result.should be_a(Facet::ServiceError)
        err = update_result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.details.not_nil!.map(&.message).join(", ").should contain("replicated")
      end
    end

    it "renaming the Person propagates to the hr replica (eventually consistent)" do
      register_hr_doctypes!

      with_db do |db|
        # Set up domain grants.
        upsert_domain_with_grants(db, "identity", %([
          {"to": "hr", "doctype": "Person", "fields": ["full_name"]}
        ]))

        # Re-register hr.Employee with a replicate field.
        existing = Facet::Doctype::DefinitionStore.fetch(db, "hr.Employee")
        existing.should_not be_nil
        defn = existing.not_nil!

        fields = defn.fields.dup
        fields["person_full_name"] = Facet::Doctype::FieldDefinition.new(
          type: Facet::Doctype::FieldType.parse("string"),
          replicate: Facet::Doctype::ReplicateConfig.new(via: "person", field: "full_name"),
        )

        enhanced = Facet::Doctype::DoctypeDefinition.new(
          doctype: defn.doctype,
          domain: defn.domain,
          schema_version: defn.schema_version,
          aggregate_root: defn.aggregate_root,
          fields: fields,
          children: defn.children,
          actions: defn.actions,
          script: defn.script,
        )

        errors = Facet::Replication::Validator.validate(enhanced, db)
        unless errors.empty?
          fail "Test doctype invalid: #{errors.join(", ")}"
        end

        Facet::Mutation::Client.snapshot_mutation(
          db, "core", "DocType",
          doc_id: "hr.Employee",
          content: enhanced.to_json,
          actioner_id: "system",
        )

        Facet::Doctype::DefinitionStore.cache.clear

        person_id = create_person_via_service(db, "Alice Smith", "alice@example.com")
        employee_id = create_employee_via_service(db, person_id)

        # Confirm initial replica was populated by SyncPull.
        content = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id)
        content["person_full_name"]?.try(&.as_s).should eq("Alice Smith")

        # Build registry + handler and dispatch the source event.
        registry = Facet::Replication::Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        # Mutate the Person's full_name.
        Facet::Mutation::Client.update(
          db, "identity", "Person", person_id,
          diff_json: %({"set": [{"path": ["full_name"], "value": "Alice Wonderland"}]}),
        )

        handler = Facet::Replication::Handler.new(registry)
        msg_headers = {
          "domain"   => JSON::Any.new("identity"),
          "doc_type" => JSON::Any.new("Person"),
          "event"    => JSON::Any.new("updated"),
        }
        msg = Facet::Event::Message.new(
          content: JSON::Any.new({"id" => JSON::Any.new(person_id)}),
          headers: msg_headers,
        )
        handler.call(msg)

        # Verify the replica was updated on the Employee.
        updated_content = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id)
        updated_content["person_full_name"]?.try(&.as_s).should eq("Alice Wonderland")
      end
    end
    it "deleting the Person does NOT delete the Employee (orphan-safe reference)" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db, "Alice Smith", "alice@example.com")
        employee_id = create_employee_via_service(db, person_id)

        # Delete the Person.
        result = Facet::Document::Delete.call(db, "identity", "Person", person_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Delete::Result)

        # Verify Employee is still readable and not tombstoned.
        read_result = Facet::Document::Read.call(db, "hr", "Employee", employee_id, Facet::RBAC::AuthContext.system)
        read_result.should be_a(Facet::Document::Read::Result)
        content = read_result.as(Facet::Document::Read::Result).projection.content
        content["person"]?.try(&.as_s).should eq("identity.Person.#{person_id}")
        content["status"]?.try(&.as_s).should eq("active")
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 8. Derived events
  # ──────────────────────────────────────────────────────────────────────────
  describe "derived events" do
    it "nothing custom is persisted beyond created/updated/deleted in the event log" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db, "Alice Smith", "alice@example.com")
        employee_id = create_employee_via_service(db, person_id)

        # Run a promote action.
        args = %({"new_title": "Senior Software Engineer", "effective_date": "2025-03-01"})
        result = Facet::Document::Action.call(db, "hr", "Employee", employee_id, "promote", args_body: args, auth_context: Facet::RBAC::AuthContext.system)
        expect_action_success(result)

        # Check that the mutation recorded for the Employee is an `update`
        # (not a custom action type), and that no `create` or `delete`
        # mutation was recorded by the action.
        actions = db.query_all(
          "SELECT action FROM mutations WHERE doc_id = $1 ORDER BY idx",
          employee_id,
          as: String
        )
        # The first entry is the initial `create`.
        actions.shift.should eq("create")

        # Every subsequent entry from the actions must be `update`.
        actions.all? { |a| a == "update" || a == "snapshot" }.should be_true,
          "Expected only update/snapshot actions in the mutation log, got: #{actions.inspect}"
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 10. Deletion and cascade
  # ──────────────────────────────────────────────────────────────────────────
  describe "deletion" do
    it "deleting an Employee tombstones it" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db)
        employee_id = create_employee_via_service(db, person_id)

        # Verify it exists before delete
        proj = Facet::Mutation::Client.fetch_projection(db, "hr", "Employee", employee_id)
        proj.deleted_at.should be_nil
        proj.id.should eq(employee_id)

        # Delete it
        result = Facet::Document::Delete.call(db, "hr", "Employee", employee_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Delete::Result)

        # Verify it's tombstoned
        proj = Facet::Mutation::Client.fetch_projection(db, "hr", "Employee", employee_id)
        proj.deleted_at.should_not be_nil

        # Verify Read returns 410 Gone with a notice it was deleted
        read_result = Facet::Document::Read.call(db, "hr", "Employee", employee_id, Facet::RBAC::AuthContext.system)
        read_result.should be_a(Facet::ServiceError)
        err = read_result.as(Facet::ServiceError)
        err.status.should eq(410)
        err.message.should contain("was deleted")
      end
    end

    it "deleting an Employee cascade-tombstones all its CareerEvents" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db, "Alice Smith", "alice@example.com")
        employee_id = create_employee_via_service(db, person_id)

        # Create two CareerEvent children owned by the Employee.
        parent_meta = {"parent_id" => JSON::Any.new(employee_id)}
        event_body = %({
          "seq": 1,
          "event_type": "hired",
          "effective_date": "2024-01-15"
        })
        event1 = Facet::Document::Create.call(db, "hr", "CareerEvent", event_body, Facet::RBAC::AuthContext.system, meta_overrides: parent_meta)
        event1_result = event1.as(Facet::Document::Create::Result)

        event_body2 = %({
          "seq": 2,
          "event_type": "promoted",
          "effective_date": "2025-03-01",
          "new_title": "Senior Engineer"
        })
        event2 = Facet::Document::Create.call(db, "hr", "CareerEvent", event_body2, Facet::RBAC::AuthContext.system, meta_overrides: parent_meta)
        event2_result = event2.as(Facet::Document::Create::Result)

        # Sanity: both children live before the cascade.
        Facet::Mutation::Client.fetch_projection(db, "hr", "CareerEvent", event1_result.projection.id).deleted_at.should be_nil
        Facet::Mutation::Client.fetch_projection(db, "hr", "CareerEvent", event2_result.projection.id).deleted_at.should be_nil

        # Delete the parent Employee.
        result = Facet::Document::Delete.call(db, "hr", "Employee", employee_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Delete::Result)

        # Cascade: both CareerEvents must be tombstoned.
        Facet::Mutation::Client.fetch_projection(db, "hr", "CareerEvent", event1_result.projection.id).deleted_at.should_not be_nil
        Facet::Mutation::Client.fetch_projection(db, "hr", "CareerEvent", event2_result.projection.id).deleted_at.should_not be_nil
      end
    end

    it "a CareerEvent cannot be created without a parent Employee" do
      register_hr_doctypes!

      # Direct POST /Api/hr/CareerEvent is rejected at the HTTP layer because
      # CareerEvent has `member_of: Employee`; it must be created via the
      # parent's nested route.
      body = %({
        "seq": 1,
        "event_type": "hired",
        "effective_date": "2024-01-15"
      })
      resp = create_document_http("hr", "CareerEvent", body)
      assert_http_status(resp, 422)
      parse_body(resp)["error"].to_s.should contain("belongs to")
    end
    it "deleting the Person leaves the Employee with an orphaned reference" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db, "Alice Smith", "alice@example.com")
        employee_id = create_employee_via_service(db, person_id)

        # Delete the Person.
        result = Facet::Document::Delete.call(db, "identity", "Person", person_id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Delete::Result)

        # Verify that the Employee still references the now-deleted Person id.
        read_result = Facet::Document::Read.call(db, "hr", "Employee", employee_id, Facet::RBAC::AuthContext.system)
        read_result.should be_a(Facet::Document::Read::Result)
        content = read_result.as(Facet::Document::Read::Result).projection.content
        # The `person` reference value is preserved as-is (dangling id).
        content["person"]?.try(&.as_s).should eq("identity.Person.#{person_id}")
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # 11. Field type round-trips
  # ──────────────────────────────────────────────────────────────────────────
  describe "field type round-trips" do
    it "round-trips enum, money, boolean, date, and integer values" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db)

        # Create Employee with all field types
        employee_body = %({
          "status": "active",
          "hire_date": "2024-06-15",
          "job_title": "Engineer",
          "department": "Engineering",
          "salary": #{money_json("75000", "USD")},
          "remote": true,
          "person": "#{person_id}"
        })
        result = Facet::Document::Create.call(db, "hr", "Employee", employee_body, Facet::RBAC::AuthContext.system)
        res = expect_create_success(result)
        employee_id = res.projection.id

        # Read back and verify all field types
        read_result = Facet::Document::Read.call(db, "hr", "Employee", employee_id, Facet::RBAC::AuthContext.system)
        read_result.should be_a(Facet::Document::Read::Result)
        content = read_result.as(Facet::Document::Read::Result).projection.content

        # enum
        content["status"].as_s.should eq("active")
        # money
        content["salary"]["value"].as_s.should eq("75000")
        content["salary"]["currency"].as_s.should eq("USD")
        # boolean
        content["remote"].as_bool.should be_true
        # datetime (round-trips as ISO 8601 string)
        content["hire_date"].as_s.should eq("2024-06-15")
        # string
        content["job_title"].as_s.should eq("Engineer")

        # Now create a CareerEvent and verify integer round-trips. The
        # doctype declares member_of — the create carries the parent link
        # (meta_overrides parent_id), the same one the nested route injects.
        career_body = %({
          "seq": 42,
          "event_type": "hired",
          "effective_date": "2024-06-15",
          "note": "Initial hire"
        })
        career_result = Facet::Document::Create.call(
          db, "hr", "CareerEvent", career_body, Facet::RBAC::AuthContext.system,
          meta_overrides: {"parent_id" => JSON::Any.new(employee_id)},
        )
        career_res = expect_create_success(career_result)
        career_id = career_res.projection.id

        read_career = Facet::Document::Read.call(db, "hr", "CareerEvent", career_id, Facet::RBAC::AuthContext.system)
        read_career.should be_a(Facet::Document::Read::Result)
        career_content = read_career.as(Facet::Document::Read::Result).projection.content

        # integer
        career_content["seq"].as_i64.should eq(42)
      end
    end

    it "setting a nested object path (contact.city) applies the set patch" do
      register_hr_doctypes!

      with_db do |db|
        # Create a Person with nested contact
        contact_person_body = %({
          "full_name": "Bob Smith",
          "email": "bob@example.com",
          "date_of_birth": "1985-03-20",
          "kind": "internal",
          "contact": {
            "city": "Portland",
            "zip": "97201"
          }
        })
        result = Facet::Document::Create.call(db, "identity", "Person", contact_person_body, Facet::RBAC::AuthContext.system)
        res = expect_create_success(result)

        # Update a nested path via PATCH (set a new nested key)
        patch_body = %({"contact": {"city": "Seattle", "state": "WA"}})
        update_result = Facet::Document::Update.call(db, "identity", "Person", res.projection.id, patch_body, Facet::RBAC::AuthContext.system)
        update_result.should be_a(Facet::Document::Update::Result)

        # Read back and verify deep merge: city replaced, zip preserved, state added
        read_result = Facet::Document::Read.call(db, "identity", "Person", res.projection.id, Facet::RBAC::AuthContext.system)
        read_result.should be_a(Facet::Document::Read::Result)
        content = read_result.as(Facet::Document::Read::Result).projection.content
        contact = content["contact"]
        contact["city"].as_s.should eq("Seattle")
        contact["zip"].as_s.should eq("97201")
        contact["state"].as_s.should eq("WA")
      end
    end

    it "a null patch removes the field (merge-patch unset), and it can be set again" do
      register_hr_doctypes!

      with_db do |db|
        person_id = create_person_via_service(db)
        manager_person_id = create_person_via_service(db, "Charlie Smith", "charlie@example.com")
        # `manager` targets hr.Employee, so the reference value is the
        # manager's employee row id (which must pass the existence check).
        manager_employee_id = create_employee_via_service(db, manager_person_id)

        # Create Employee with a manager reference to a different person
        employee_body = %({
          "status": "active",
          "hire_date": "2024-06-15",
          "job_title": "Engineer",
          "department": "Engineering",
          "salary": #{money_json("75000", "USD")},
          "remote": true,
          "person": "#{person_id}",
          "manager": "#{manager_employee_id}"
        })
        result = Facet::Document::Create.call(db, "hr", "Employee", employee_body, Facet::RBAC::AuthContext.system)
        res = expect_create_success(result)
        employee_id = res.projection.id

        # First verify manager is present
        orig_content = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id)
        orig_content["manager"]?.should_not be_nil

        # Unset manager via the merge-patch null
        nullify_body = %({"manager": null})
        null_update = Facet::Document::Update.call(db, "hr", "Employee", employee_id, nullify_body, Facet::RBAC::AuthContext.system)
        null_update.should be_a(Facet::Document::Update::Result)

        after_null = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id)
        # Merge-patch null removes the key from the stored content entirely
        after_null.as_h.has_key?("manager").should be_false

        # Now set manager back
        set_body = %({"manager": "#{manager_employee_id}"})
        set_update = Facet::Document::Update.call(db, "hr", "Employee", employee_id, set_body, Facet::RBAC::AuthContext.system)
        set_update.should be_a(Facet::Document::Update::Result)

        after_set = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id)
        after_set["manager"]?.should_not be_nil
        after_set["manager"].raw.should_not be_nil
      end
    end
  end
end

# ──────────────────────────────────────────────────────────────────────────
# 12. DocType registration via service
# ──────────────────────────────────────────────────────────────────────────
describe "Document::Create (via core.DocType)" do
  # No local before_each needed — global truncation handles data reset

  it "persists identity.Person via the service and returns its projection" do
    defn = load_doctype_schema("identity.Person/definition.yml")
    result = create_doctype(defn)

    res = expect_create_success(result)
    proj = res.projection

    proj.domain.should eq("core")
    proj.doc_type.should eq("DocType")
    proj.id.should eq("identity.Person")
    proj.content["doctype"].should eq(JSON.parse(%("Person")))
    proj.content["domain"].should eq(JSON.parse(%("identity")))
    proj.deleted_at.should be_nil
    proj.version.should eq(1)
  end

  it "persists hr.Employee via the service and returns its projection" do
    defn = build_doctype_definition("hr.Employee/definition.yml", "hr.Employee/script.lua")
    result = create_doctype(defn)

    res = expect_create_success(result)
    proj = res.projection

    proj.id.should eq("hr.Employee")
    proj.content["doctype"].should eq(JSON.parse(%("Employee")))
    proj.content["aggregate_root"].should eq(JSON.parse("true"))
    proj.content["actions"].should eq(JSON.parse(%({"promote":{"args":{"new_title":{"type":"string","required":true,"collection":false}}},"change_salary":{"args":{"new_salary":{"type":"money","required":true,"collection":false}}},"terminate":{"args":{"effective_date":{"type":"string","required":false,"collection":false}}}})))
    proj.deleted_at.should be_nil
  end

  it "persists hr.CareerEvent via the service and returns its projection" do
    defn = load_doctype_schema("hr.CareerEvent/definition.yml")
    result = create_doctype(defn)

    res = expect_create_success(result)
    proj = res.projection

    proj.id.should eq("hr.CareerEvent")
    proj.content["doctype"].should eq(JSON.parse(%("CareerEvent")))
    proj.content["domain"].should eq(JSON.parse(%("hr")))
    proj.content["member_of"].should eq(JSON.parse(%("Employee")))
    proj.deleted_at.should be_nil
  end

  it "rejects an invalid doctype definition and returns an error" do
    # Body parses OK but has empty field name → fails validation service
    body = %({"doctype": "Person", "domain": "identity", "fields": {"": {"type": "string"}}})
    result = create_doctype(Facet::Doctype::DoctypeDefinition.from_json(body))

    err = expect_create_error(result, status: 422)
    err.message.should contain("Doctype validation failed")
    err.details.should be_a(Array(Facet::ValidationError))
    err.details.try &.should_not be_empty
  end

  it "rejects malformed JSON and returns an error" do
    result = Facet::Database.with_db { |db| Facet::Document::Create.call(db, "core", "DocType", "this is not json") }

    err = expect_create_error(result, status: 422)
    err.message.should contain("Invalid doctype definition")
  end

  it "rejects document with invalid field values against the schema" do
    register_hr_doctypes!

    with_db do |db|
      # Body has unknown fields and missing required fields -> validation error.
      result = Facet::Document::Create.call(db, "hr", "Employee", %({"foo": "bar"}))

      err = expect_create_error(result, status: 422)
      err.message.should contain("Document validation failed")
      err.details.should be_a(Array(Facet::ValidationError))
    end
  end
end
