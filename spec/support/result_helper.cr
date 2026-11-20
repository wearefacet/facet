# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Result unwrapping helpers ────────────────────────────────────────────
#
# Shortcuts for asserting success or error on the union result types used
# by Document::Create, Document::Action, etc.

require "../../src/document/action"
require "../../src/rbac"

# Document::Create result helpers
def expect_create_success(result : Facet::Document::Create::Result | Facet::ServiceError) : Facet::Document::Create::Result
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result)
end

def expect_create_error(result : Facet::Document::Create::Result | Facet::ServiceError, status : Int32? = nil) : Facet::ServiceError
  result.should be_a(Facet::ServiceError)
  err = result.as(Facet::ServiceError)
  err.status.should eq(status) if status
  err
end

# Helper: create a Person document via the service and return its id.
#
# `email` defaults to `nil`. When not provided, a unique email is synthesized
# from the freshly-generated Person ULID. The previous default of
# `"alice@example.com"` would collide if a test ever created two Persons
# (the `identity.Person.email` unique index is real once
# `data/fixtures/identity.Person/definition.yml` is loaded by
# `register_hr_doctypes`). Tests that care about a specific email value can
# still pass one explicitly.
def create_person_via_service(db, full_name = "Alice Smith", email : String? = nil)
  person_id = Facet::Util::ScriptHelpers.ulid
  actual_email = email || "#{person_id}@example.com"
  person_body = %({
    "full_name": "#{full_name}",
    "email": "#{actual_email}",
    "date_of_birth": "1990-06-15",
    "kind": "internal"
  })
  result = Facet::Document::Create.call(db, "identity", "Person", person_body, Facet::RBAC::AuthContext.system)
  expect_create_success(result).projection.id
end

# Helper: create an Employee document via the service and return its id
def create_employee_via_service(db, person_id : String,
                                status = "active",
                                job_title = "Software Engineer",
                                event_type = "hired",
                                event_seq = 1)
  employee_body = %({
    "status": "#{status}",
    "hire_date": "2024-01-15",
    "job_title": "#{job_title}",
    "department": "Engineering",
    "salary": #{money_json("80000", "USD")},
    "remote": true,
    "person": "#{person_id}"
  })
  result = Facet::Document::Create.call(db, "hr", "Employee", employee_body, Facet::RBAC::AuthContext.system)
  expect_create_success(result).projection.id
end

# Document::Action result helpers
def expect_action_success(result : Facet::Document::Action::Result | Facet::ServiceError) : Facet::Document::Action::Result
  result.should be_a(Facet::Document::Action::Result)
  result.as(Facet::Document::Action::Result)
end

def expect_action_error(result : Facet::Document::Action::Result | Facet::ServiceError, status : Int32? = nil) : Facet::ServiceError
  result.should be_a(Facet::ServiceError)
  err = result.as(Facet::ServiceError)
  err.status.should eq(status) if status
  err
end

# Document::Update result helpers
def expect_update_success(result : Facet::Document::Update::Result | Facet::ServiceError) : Facet::Document::Update::Result
  result.should be_a(Facet::Document::Update::Result)
  result.as(Facet::Document::Update::Result)
end

def expect_update_error(result : Facet::Document::Update::Result | Facet::ServiceError, status : Int32? = nil) : Facet::ServiceError
  result.should be_a(Facet::ServiceError)
  err = result.as(Facet::ServiceError)
  err.status.should eq(status) if status
  err
end
