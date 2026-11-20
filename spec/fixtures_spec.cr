# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Fixture validation spec ──────────────────────────────────────────────────
#
# Validates that every document in `data/fixtures/` conforms to its doctype
# definition. Documents from core-only fixtures (those without a fixture
# definition file) are validated against the seed definition.
#
# This spec catches schema drift — if a fixture document has a field that
# doesn't exist in the definition, or a required field is missing, or a
# type mismatch exists, the spec fails.

require "./spec_helper"
require "./support/db_helper"
require "./support/doctype_helper"
require "./support/fixture_helper"
require "../src/doctype/script_validator"

# ── Helpers ─────────────────────────────────────────────────────────────────

private def validate_document(
  definition : Facet::Doctype::DoctypeDefinition,
  doc_content : String,
  qualified_name : String,
  doc_id : String,
) : Array(String)
  content = JSON.parse(doc_content)
  errors = Facet::Document::Validation.validate(content, definition)
  errors.map { |e| "[#{qualified_name} / #{doc_id}] #{e.message}" }
end

# Runs ScriptValidator on a fixture definition's embedded script. In the
# portable-domain bundle format, the Lua `script` is embedded in the
# doctype definition's `content` (no separate `script.lua` file), so the
# validator runs against the already-parsed `definition.script`.
private def validate_fixture_script(qualified_name : String, definition : Facet::Doctype::DoctypeDefinition) : Array(String)
  script = definition.script
  return [] of String if script.nil? || script.empty?

  Facet::Doctype::ScriptValidator.validate(script, definition).map { |e| "[#{qualified_name}] #{e.message}" }
end

# Maps qualified names that have a fixture definition to their definition.
private FIXTURE_DEFS = {
  "hr.Candidate"           => load_fixture_definition("hr", "Candidate"),
  "hr.CandidateExperience" => load_fixture_definition("hr", "CandidateExperience"),
  "hr.CandidateEducation"  => load_fixture_definition("hr", "CandidateEducation"),
  "hr.CandidateSkill"      => load_fixture_definition("hr", "CandidateSkill"),
  "hr.InterviewFeedback"   => load_fixture_definition("hr", "InterviewFeedback"),
  "hr.Employee"            => load_fixture_definition("hr", "Employee"),
  "hr.CareerEvent"         => load_fixture_definition("hr", "CareerEvent"),
  "identity.Person"        => load_fixture_definition("identity", "Person"),
  "crm.Company"            => load_fixture_definition("crm", "Company"),
  "crm.Contact"            => load_fixture_definition("crm", "Contact"),
  "crm.Deal"               => load_fixture_definition("crm", "Deal"),
  "crm.Activity"           => load_fixture_definition("crm", "Activity"),
  "crm.Customer"           => load_fixture_definition("crm", "Customer"),
  "crm.PipelineStage"      => load_fixture_definition("crm", "PipelineStage"),
  "crm.Prospect"           => load_fixture_definition("crm", "Prospect"),
  "production.Team"        => load_fixture_definition("production", "Team"),
  "production.TeamMember"  => load_fixture_definition("production", "TeamMember"),
  "production.Project"     => load_fixture_definition("production", "Project"),
  "production.Task"        => load_fixture_definition("production", "Task"),
}

# Core-only fixtures (definition lives in seeds, not fixtures).
# Documents from these are validated against the seed definition.
private CORE_FIXTURES = {
  "core.Domain"         => load_seed_definition("core", "Domain"),
  "core.DocumentView"   => load_seed_definition("core", "DocumentView"),
  "core.CollectionView" => load_seed_definition("core", "CollectionView"),
  "iam.Account"         => load_seed_definition("iam", "Account"),
}

# ── Spec ────────────────────────────────────────────────────────────────────

describe "Fixture validation" do
  # Validate each fixture that has its own definition + documents
  FIXTURE_DEFS.each do |qualified_name, definition|
    domain, doctype = qualified_name.split(".", 2)
    documents = load_fixture_documents(domain, doctype)

    documents.each do |doc|
      it "validates #{qualified_name}/#{doc[:id]}" do
        errors = validate_document(definition, doc[:content], qualified_name, doc[:id])
        unless errors.empty?
          fail(errors.join("\n"))
        end
      end
    end
  end

  # Validate core-only fixtures (definition from seeds). Documents for these
  # live in the fixture bundle tree, not in a `documents/core.*/` directory:
  #   - core.Domain         → each bundle's `domain.yml`
  #   - core.DocumentView   → each bundle's `views/*/document_views/*.yml`
  #   - core.CollectionView → each bundle's `views/*/collection_views/*.yml`
  #   - iam.Account          → the iam bundle's `documents/iam.Account/*.yml`
  CORE_FIXTURES.each do |qualified_name, definition|
    documents =
      case qualified_name
      when "core.Domain"         then load_fixture_domains
      when "core.DocumentView"   then load_fixture_document_views
      when "core.CollectionView" then load_fixture_collection_views
      else
        domain, doctype = qualified_name.split(".", 2)
        load_fixture_documents(domain, doctype)
      end

    documents.each do |doc|
      it "validates #{qualified_name}/#{doc[:id]}" do
        errors = validate_document(definition, doc[:content], qualified_name, doc[:id])
        unless errors.empty?
          fail(errors.join("\n"))
        end
      end
    end
  end

  # Validate Lua scripts for fixture definitions that have one
  FIXTURE_DEFS.each do |qualified_name, definition|
    it "validates Lua script for #{qualified_name} fixture" do
      errors = validate_fixture_script(qualified_name, definition)
      unless errors.empty?
        fail(errors.join("\n"))
      end
    end
  end

  # Guard against duplicate (parent_doctype, kind) pairs in core.DocumentView
  # fixtures. The HTTP route's `core.DocumentView/script.lua` rejects duplicate
  # kinds per parent on create/update, but the portable-domain import bypasses
  # the route (`Mutation::Client.create`), so a duplicate would silently land
  # in the database. Catch it here.
  it "has no duplicate (parent_doctype, kind) pairs in core.DocumentView fixtures" do
    docs = load_fixture_document_views
    docs.should_not be_empty
    seen = {} of {String, String} => Array(String)
    docs.each do |doc|
      content = JSON.parse(doc[:content])
      parent = content["parent_doctype"]?.try(&.as_s)
      kind = content["kind"]?.try(&.as_s)
      next if parent.nil? || kind.nil?
      key = {parent, kind}
      seen[key] ||= [] of String
      seen[key] << doc[:id]
    end

    duplicates = seen.select { |_, ids| ids.size > 1 }
    duplicates.should be_empty, <<-MSG
      Duplicate (parent_doctype, kind) pairs found in core.DocumentView fixtures:
      #{duplicates.map { |(p, k), ids| "  #{p} / #{k}: #{ids.join(", ")}" }.join("\n")}
    MSG
  end
end
