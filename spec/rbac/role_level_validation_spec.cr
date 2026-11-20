# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"
require "../../src/document/create"
require "../../src/document/update"
require "../support/iam_helper"

# Role-definition coverage for the required `level` field (execution plan
# Phase 1): role creation without a level fails validation, the boundary
# values 0 and 100 pass, and out-of-range values fail.
private def create_level_role(db, body : String)
  Facet::Document::Create.call(db, "iam", "Roles", body, Facet::RBAC::AuthContext.system)
end

describe "iam.Roles level validation" do
  before_each do
    # The iam.Roles document seed validates permission scopes against the
    # registered core doctypes. Re-ensure the referenced definitions (in
    # dependency order, iam.Roles last) instead of a full-corpus re-seed.
    with_db do |db|
      ensure_seed_roles_with_dependencies(db)
      Facet::Doctype::DefinitionStore.cache.clear
    end
  end

  it "fails validation when level is missing" do
    with_db do |db|
      result = create_level_role(db, %({"name": "no_level", "permissions": []}))
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      detail = err.details.try(&.first?)
      detail.should_not be_nil
      detail.as(Facet::ValidationError).field.should eq("level")
      detail.as(Facet::ValidationError).code.should eq("required")
    end
  end

  it "accepts the boundary level 0" do
    with_db do |db|
      create_level_role(db, %({"name": "level_zero", "level": 0, "permissions": []}))
        .should be_a(Facet::Document::Create::Result)
    end
  end

  it "accepts the boundary level 100" do
    with_db do |db|
      create_level_role(db, %({"name": "level_hundred", "level": 100, "permissions": []}))
        .should be_a(Facet::Document::Create::Result)
    end
  end

  it "rejects level -1" do
    with_db do |db|
      result = create_level_role(db, %({"name": "level_negative", "level": -1, "permissions": []}))
      result.should be_a(Facet::ServiceError)
      detail = result.as(Facet::ServiceError).details.try(&.first?)
      detail.should_not be_nil
      detail.as(Facet::ValidationError).field.should eq("level")
    end
  end

  it "rejects level 101" do
    with_db do |db|
      result = create_level_role(db, %({"name": "level_over", "level": 101, "permissions": []}))
      result.should be_a(Facet::ServiceError)
      detail = result.as(Facet::ServiceError).details.try(&.first?)
      detail.should_not be_nil
      detail.as(Facet::ValidationError).field.should eq("level")
    end
  end

  it "rejects a non-integer level" do
    with_db do |db|
      result = create_level_role(db, %({"name": "level_text", "level": "high", "permissions": []}))
      result.should be_a(Facet::ServiceError)
      detail = result.as(Facet::ServiceError).details.try(&.first?)
      detail.should_not be_nil
      detail.as(Facet::ValidationError).field.should eq("level")
    end
  end

  it "keeps the level on the stored role content" do
    with_db do |db|
      result = create_level_role(db, %({"name": "level_kept", "level": 42, "permissions": []}))
      result.should be_a(Facet::Document::Create::Result)
      result.as(Facet::Document::Create::Result).projection.content["level"].as_i.should eq(42)
    end
  end
end
