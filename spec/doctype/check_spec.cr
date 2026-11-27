# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/doctype"
require "../../src/doctype/check"
require "../../src/document"
require "../../src/domain"
require "../../src/mutation/client"
require "../../src/mutation/json_diff"
require "../../src/replication"
require "../../src/rbac"
require "../replication/validator_spec" # brings this spec's describe blocks

# ── Helpers ─────────────────────────────────────────────────────────────────

# Persists a doctype definition via direct Mutation::Client.create, bypassing
# Doctype::Create. Used here to set up doctypes that the Check service reads
# back — keeps the spec focused on the diagnostics, not the create path.
def persist_doctype_for_check(db, defn : Facet::Doctype::DoctypeDefinition) : String
  doc_id = "#{defn.domain}.#{defn.doctype}"
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: doc_id,
    content: defn.to_json,
    actioner_id: "system:test",
  )
  Facet::Doctype::DefinitionStore.invalidate(doc_id)
  doc_id
end

# Persists a `core.DocumentView` child projection for the Check service to
# read back. `meta.parent_id` is what `check_views` queries on.
def persist_view_for_check(db, parent_id : String, kind : String, template_json : String? = nil) : String
  content = %({"parent_doctype": "#{parent_id}", "kind": "#{kind}"})
  content = content.sub(/\}\z/, ", \"template\": #{template_json}}") if template_json
  Facet::Mutation::Client.create(
    db, "core", "DocumentView",
    doc_id: "#{parent_id}.document_view.#{kind}",
    content: content,
    meta: %({"parent_id": "#{parent_id}"}),
    actioner_id: "system:test",
  )
  "#{parent_id}.document_view.#{kind}"
end

# Persists a parent doctype whose fields back the CollectionView capability
# checks, then returns its qualified id. `fields` is the `fields` object of
# the definition, as raw JSON.
def persist_collection_view_parent(db, domain : String, fields : String) : String
  ensure_domain(db, domain)
  defn = Facet::Doctype::DoctypeDefinition.from_json(%({
    "doctype": "Task",
    "domain": "#{domain}",
    "schema_version": 1,
    "aggregate_root": true,
    "fields": #{fields}
  }))
  persist_doctype_for_check(db, defn)
end

# Persists a `core.CollectionView` child projection for the Check service.
# `meta.parent_id` is what the collection-view check queries on.
def persist_collection_view_for_check(
  db,
  parent_id : String,
  name : String,
  surface : String,
  config_json : String,
) : String
  doc_id = "#{parent_id}.collection_view.#{name.downcase}"
  Facet::Mutation::Client.create(
    db, "core", "CollectionView",
    doc_id: doc_id,
    content: %({"name": "#{name}", "surface": "#{surface}", "config": #{config_json}}),
    meta: %({"parent_id": "#{parent_id}"}),
    actioner_id: "system:test",
  )
  doc_id
end

module Facet::Doctype
  describe Check do
    describe ".call" do
      it "returns no non-view issues for a doctype with no broken references or replicate fields" do
        with_db do |db|
          ensure_domain(db, "clean")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Widget",
            "domain": "clean",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"name": {"type": "string", "required": true}},
            "search": "{{ name }}",
            "display_name": "{{ name }}"
          }))
          doc_id = persist_doctype_for_check(db, defn)
          persist_view_for_check(db, doc_id, "view")
          persist_view_for_check(db, doc_id, "form")
          persist_view_for_check(db, doc_id, "quickView")
          persist_view_for_check(db, doc_id, "inline")
          persist_view_for_check(db, doc_id, "card")
          # At least one valid collection view — a viewless doctype gets
          # its own :info notice (asserted below).
          persist_collection_view_for_check(db, doc_id, "All", "table", %({"columns":[{"key":"name"}]}))

          result = Check.call(db, doc_id)
          result.should be_a(Check::Result)
          res = result.as(Check::Result)
          res.issues.should be_empty
        end
      end

      it "emits an :info notice when the doctype has no collection views" do
        with_db do |db|
          ensure_domain(db, "viewless")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Naked",
            "domain": "viewless",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"name": {"type": "string", "required": true}},
            "search": "{{ name }}",
            "display_name": "{{ name }}"
          }))
          doc_id = persist_doctype_for_check(db, defn)
          persist_view_for_check(db, doc_id, "view")
          persist_view_for_check(db, doc_id, "form")
          persist_view_for_check(db, doc_id, "quickView")
          persist_view_for_check(db, doc_id, "inline")
          persist_view_for_check(db, doc_id, "card")

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          notices = res.issues.select { |i| i.category == :view && i.severity == :info }
          notices.size.should eq(1)
          notices.first.message.should contain("No CollectionView defined for viewless.Naked")
          notices.first.message.should contain("starter")
        end
      end

      it "emits :defaults info notices when display_name and search are not declared" do
        with_db do |db|
          ensure_domain(db, "plain")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Plain",
            "domain": "plain",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"name": {"type": "string"}}
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          defaults = res.issues.select { |i| i.category == :defaults }
          # Two findings: the B-296 error for the aggregate root that
          # declares neither template, plus the display_name :info notice.
          # The error replaces the old both-missing pair of notices.
          defaults.size.should eq(2)
          errors = defaults.select(&.severity.==(:error))
          errors.size.should eq(1)
          errors.first.message.should contain("No display_name and no search template")
          errors.first.message.should contain("declare display_name (search defaults to it)")
          # The search notice no longer claims a document-id-only corpus: it
          # states that search defaults to the display_name corpus.
          search_notice = defaults.find!(&.message.starts_with?("No display_name and no search template"))
          search_notice.severity.should eq(:error)
        end
      end

      it "reports a template-less owned child as a notice, not an error" do
        with_db do |db|
          ensure_domain(db, "kids")
          parent = DoctypeDefinition.from_json(%({
            "doctype": "Order",
            "domain": "kids",
            "schema_version": 1,
            "aggregate_root": true,
            "search": "{{ name }}",
            "fields": {"name": {"type": "string"}},
            "children": {"lines": {"doctype": "Line", "collection": true}}
          }))
          persist_doctype_for_check(db, parent)
          child = DoctypeDefinition.from_json(%({
            "doctype": "Line",
            "domain": "kids",
            "schema_version": 1,
            "member_of": "Order",
            "fields": {"label": {"type": "string"}}
          }))
          child_id = persist_doctype_for_check(db, child)

          res = Check.call(db, child_id).as(Check::Result)
          defaults = res.issues.select { |i| i.category == :defaults }
          # display_name :info + the child-specific both-missing :info.
          defaults.size.should eq(2)
          defaults.any?(&.severity.==(:error)).should be_false
          child_notice = defaults.find!(&.message.includes?("the child is not searchable on its own"))
          child_notice.severity.should eq(:info)
        end
      end

      it "emits only the display_name :info notice when the search template is declared" do
        with_db do |db|
          ensure_domain(db, "labelsearch")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "LabelSearch",
            "domain": "labelsearch",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "search": "{{ name }}"
          }))
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          defaults = res.issues.select { |i| i.category == :defaults }
          defaults.size.should eq(1)
          defaults.first.severity.should eq(:info)
          defaults.first.message.should contain("display_name template")
        end
      end

      it "emits only the search :info notice when the display_name template is declared" do
        with_db do |db|
          ensure_domain(db, "labelonly")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "LabelOnly",
            "domain": "labelonly",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "display_name": "{{ name }}"
          }))
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          defaults = res.issues.select { |i| i.category == :defaults }
          defaults.size.should eq(1)
          defaults.first.severity.should eq(:info)
          defaults.first.message.should contain("the cross-doctype search endpoint skips this doctype")
          defaults.first.message.should contain("search defaults to the display_name corpus")
        end
      end

      it "emits no :defaults notices when display_name and search are declared" do
        with_db do |db|
          ensure_domain(db, "labelled")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Labelled",
            "domain": "labelled",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "search": "{{ name }}",
            "display_name": "{{ name }}"
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          res.issues.select { |i| i.category == :defaults }.should be_empty
        end
      end

      it "warns when a search or display_name template has no variable (B-115)" do
        with_db do |db|
          ensure_domain(db, "literal")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Literal",
            "domain": "literal",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "search": "$name",
            "display_name": "Fixed label"
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          template_issues = res.issues.select { |i| i.category == :template }
          template_issues.size.should eq(2)
          template_issues.all?(&.severity.==(:warning)).should be_true
          template_issues.map(&.field).should eq(["search", "display_name"])
          template_issues.all?(&.message.includes?("no '{{' variable")).should be_true
        end
      end

      it "does not warn when a template declares a variable (B-115)" do
        with_db do |db|
          ensure_domain(db, "templated")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Templated",
            "domain": "templated",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "search": "{{ name }}",
            "display_name": "{{ name }}"
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          res.issues.select { |i| i.category == :template }.should be_empty
        end
      end

      it "returns 404 for an unknown doctype" do
        with_db do |db|
          result = Check.call(db, "nope.NoSuch")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(404)
          err.message.should contain("not found")
        end
      end

      it "flags a reference field whose target doctype is not registered" do
        with_db do |db|
          ensure_domain(db, "orders")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Order",
            "domain": "orders",
            "schema_version": 1,
            "fields": {
              "name": {"type": "string", "required": true},
              "customer": {"type": "reference", "doctype": "identity.Person"}
            }
          }))
          # identity.Person is NOT registered in this DB
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          ref_issues = res.issues.select { |i| i.category == :reference }
          ref_issues.size.should eq(1)
          ref_issues[0].field.should eq("customer")
          ref_issues[0].message.should contain("identity.Person")
          ref_issues[0].message.should contain("not a registered doctype")
        end
      end

      it "flags an array-of-reference item whose target doctype is not registered, naming the flat PATCH remedy" do
        with_db do |db|
          ensure_domain(db, "orders")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Specimen",
            "domain": "orders",
            "schema_version": 1,
            "fields": {
              "name": {"type": "string", "required": true},
              "refs": {"type": "array", "items": {"type": "reference", "doctype": "orders.Partner"}}
            }
          }))
          # orders.Partner is NOT registered in this DB
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          ref_issues = res.issues.select { |i| i.category == :reference }
          ref_issues.size.should eq(1)
          ref_issues[0].severity.should eq(:warning)
          ref_issues[0].field.should eq("refs.items")
          ref_issues[0].message.should contain("orders.Partner")
          ref_issues[0].message.should contain("not a registered doctype")
          # The remedy names the flat authoring PATCH, not a PUT round-trip.
          ref_issues[0].message.should contain("PATCH /Api/core/DocType/orders.Specimen")
          ref_issues[0].message.should contain("\"fields\"")
        end
      end

      it "flags a bare reference target as an error, naming the qualified form (B-27)" do
        with_db do |db|
          ensure_domain(db, "orders")
          # The documented-but-broken shape: a bare doctype name. No value
          # can ever satisfy the qualified-reference check, so the issue is
          # an error, not a warning.
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Order",
            "domain": "orders",
            "schema_version": 1,
            "fields": {
              "name": {"type": "string", "required": true},
              "customer": {"type": "reference", "doctype": "Client"}
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          ref_issues = res.issues.select { |i| i.category == :reference }
          ref_issues.size.should eq(1)
          ref_issues[0].severity.should eq(:error)
          ref_issues[0].field.should eq("customer")
          ref_issues[0].message.should contain("bare doctype name 'Client'")
          ref_issues[0].message.should contain("orders.Client")
        end
      end

      it "surfaces the display_name fallback notice for a doctype without a template" do
        with_db do |db|
          ensure_domain(db, "unnamed")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Order",
            "domain": "unnamed",
            "schema_version": 1,
            "fields": {
              "name": {"type": "string", "required": true},
              "customer": {"type": "reference", "doctype": "identity.Person"}
            },
            "search": "{{ name }}"
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          dn_issue = res.issues.find { |i| i.category == :defaults && i.message.includes?("display_name") }
          dn_issue.should_not be_nil
          dn_issue.not_nil!.severity.should eq(:info)
          dn_issue.not_nil!.message.should contain("name/title/label")
          dn_issue.not_nil!.message.should contain("raw document id")
        end
      end

      it "does not flag a self-reference" do
        with_db do |db|
          ensure_domain(db, "tree")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Node",
            "domain": "tree",
            "schema_version": 1,
            "fields": {
              "label": {"type": "string", "required": true},
              "parent": {"type": "reference", "doctype": "tree.Node"}
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          res.issues.select { |i| i.category == :reference }.should be_empty
        end
      end

      it "flags a children declaration whose target doctype is not registered" do
        with_db do |db|
          ensure_domain(db, "hr")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "hr",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "children": {"career_events": {"doctype": "CareerEvent", "collection": true}}
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          child_issues = res.issues.select { |i| i.category == :children }
          child_issues.size.should eq(1)
          child_issues[0].message.should contain("hr.CareerEvent")
          child_issues[0].message.should contain("not a registered doctype")
        end
      end

      it "flags a replicate field whose via reference target is not registered" do
        with_db do |db|
          ensure_domain(db, "hr")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "hr",
            "schema_version": 1,
            "fields": {
              "person": {"type": "reference", "doctype": "identity.Person"},
              "person_full_name": {
                "type": "string",
                "replicate": {"via": "person", "field": "full_name"}
              }
            }
          }))
          # identity.Person is NOT registered; Replication::Validator
          # should surface the "source doctype not found" issue.
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          rep_issues = res.issues.select { |i| i.category == :replication }
          rep_issues.size.should be >= 1
          # The Validator emits one of:
          # - "source doctype 'identity.Person' not found"
          rep_issues.any?(&.message.includes?("identity.Person")).should be_true
        end
      end

      it "flags a replicate field against a registered source doctype but without a grant" do
        with_db do |db|
          ensure_domain(db, "identity")
          # Source doctype registered...
          person_defn = DoctypeDefinition.from_json(%({
            "doctype": "Person",
            "domain": "identity",
            "schema_version": 1,
            "fields": {"full_name": {"type": "string", "required": true}}
          }))
          persist_doctype_for_check(db, person_defn)
          # ...but no grants on the identity domain.

          ensure_domain(db, "hr")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "hr",
            "schema_version": 1,
            "fields": {
              "person": {"type": "reference", "doctype": "identity.Person"},
              "person_full_name": {
                "type": "string",
                "replicate": {"via": "person", "field": "full_name"}
              }
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          rep_issues = res.issues.select { |i| i.category == :replication }
          rep_issues.size.should be >= 1
          rep_issues.any?(&.message.includes?("DomainGrant")).should be_true
        end
      end

      it "reports no replication issues for a valid replicate edge with grant" do
        with_db do |db|
          ensure_domain(db, "identity")
          upsert_domain_with_grants(db, "identity", %([
            {"to": "hr", "doctype": "Person", "fields": ["full_name"]}
          ]))
          person_defn = DoctypeDefinition.from_json(%({
            "doctype": "Person",
            "domain": "identity",
            "schema_version": 1,
            "fields": {"full_name": {"type": "string", "required": true}}
          }))
          persist_doctype_for_check(db, person_defn)

          ensure_domain(db, "hr")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "hr",
            "schema_version": 1,
            "fields": {
              "person": {"type": "reference", "doctype": "identity.Person"},
              "person_full_name": {
                "type": "string",
                "replicate": {"via": "person", "field": "full_name"}
              }
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          # The reference field `person` should NOT be flagged — identity.Person is registered.
          # The replicate edge should NOT be flagged — grant is present, source field exists, types match.
          res.issues.select { |i| i.category == :reference }.should be_empty
          res.issues.select { |i| i.category == :replication }.should be_empty
        end
      end

      it "flags a replicate edge whose source domain is a draft" do
        with_db do |db|
          # Set up a live consumer domain.
          ensure_domain(db, "hr")

          # Create a draft source domain with a Person doctype.
          draft = Facet::Domain::Draft.create(db, "{}", "system:test")
            .as(Facet::Domain::Draft::Result).projection.id
          person_defn = DoctypeDefinition.from_json(%({
            "doctype": "Person",
            "domain": "#{draft}",
            "schema_version": 1,
            "fields": {"full_name": {"type": "string", "required": true}}
          }))
          # Drafts bypass the domain-name regex on create — persist directly.
          doc_id_src = "#{draft}.Person"
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: doc_id_src,
            content: person_defn.to_json,
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate(doc_id_src)

          # Grant from the draft to hr (allowed in principle; the issue is draft-vs-live).
          # We can't use upsert_domain_with_grants here — it replaces the domain
          # content wholesale and would drop the `draft: true` flag that Draft.create
          # set. Patch grants directly into the projection content while preserving draft.
          old_content = Facet::Mutation::Client.fetch_projection(db, "core", "Domain", draft).content
          new_content = old_content.as_h.dup
          new_content["grants"] = JSON.parse(%([
            {"to": "hr", "doctype": "Person", "fields": ["full_name"]}
          ]))
          Facet::Mutation::Client.update(
            db, "core", "Domain", draft,
            diff_json: Facet::Mutation::JsonDiff.diff(old_content, JSON::Any.new(new_content)).to_json,
            actioner_id: "system:test",
          )

          # Live consumer with a replicate field pointing at the draft source.
          employee_defn = DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "hr",
            "schema_version": 1,
            "fields": {
              "person": {"type": "reference", "doctype": "#{draft}.Person"},
              "person_full_name": {
                "type": "string",
                "replicate": {"via": "person", "field": "full_name"}
              }
            }
          }))
          doc_id = persist_doctype_for_check(db, employee_defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          rep_issues = res.issues.select { |i| i.category == :replication }
          rep_issues.any?(&.message.includes?("draft")).should be_true
        end
      end

      it "flags a replica field that does not carry a tag of its source field" do
        with_db do |db|
          ensure_domain(db, "hr")
          # Same-domain edge: the grant diagnostic stays out of the
          # assertion, so the tag-coverage warning must fire on its own.
          # The tag-less replica is the B-271 shape — a stored consumer
          # that predates a producer-side tag addition.
          person_defn = DoctypeDefinition.from_json(%({
            "doctype": "Person",
            "domain": "hr",
            "schema_version": 1,
            "fields": {"full_name": {"type": "string", "required": true, "tags": ["pay"]}}
          }))
          persist_doctype_for_check(db, person_defn)

          defn = DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "hr",
            "schema_version": 1,
            "fields": {
              "person": {"type": "reference", "doctype": "hr.Person"},
              "person_full_name": {
                "type": "string",
                "replicate": {"via": "person", "field": "full_name"}
              }
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          rep_issues = res.issues.select { |i| i.category == :replication }
          rep_issues.any?(&.message.includes?("person_full_name")).should be_true
          rep_issues.any?(&.message.includes?("pay")).should be_true
        end
      end

      it "reports no replication issues when the replica carries the source field's tags" do
        with_db do |db|
          ensure_domain(db, "hr")
          person_defn = DoctypeDefinition.from_json(%({
            "doctype": "Person",
            "domain": "hr",
            "schema_version": 1,
            "fields": {"full_name": {"type": "string", "required": true, "tags": ["pay"]}}
          }))
          persist_doctype_for_check(db, person_defn)

          defn = DoctypeDefinition.from_json(%({
            "doctype": "Employee",
            "domain": "hr",
            "schema_version": 1,
            "fields": {
              "person": {"type": "reference", "doctype": "hr.Person"},
              "person_full_name": {
                "type": "string",
                "tags": ["pay"],
                "replicate": {"via": "person", "field": "full_name"}
              }
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)

          result = Check.call(db, doc_id)
          res = result.as(Check::Result)
          res.issues.select { |i| i.category == :replication }.should be_empty
        end
      end

      # ── :composition diagnostics ──────────────────────────────────

      it "reports no composition issues for a mutual parent/child pair" do
        with_db do |db|
          ensure_domain(db, "comp")

          parent = DoctypeDefinition.from_json(%({
            "doctype": "Project",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"name": {"type": "string"}},
            "children": {"tasks": {"doctype": "Task", "collection": true}}
          }))
          child = DoctypeDefinition.from_json(%({
            "doctype": "Task",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": false,
            "member_of": "Project",
            "fields": {"title": {"type": "string"}}
          }))
          persist_doctype_for_check(db, parent)
          persist_doctype_for_check(db, child)

          # Checking the parent must find no composition issues.
          parent_res = Check.call(db, "comp.Project").as(Check::Result)
          parent_res.issues.select { |i| i.category == :composition }.should be_empty

          # Checking the child must also find none.
          child_res = Check.call(db, "comp.Task").as(Check::Result)
          child_res.issues.select { |i| i.category == :composition }.should be_empty
        end
      end

      it "errors when a parent's children entry is not reciprocated by member_of on the child" do
        with_db do |db|
          ensure_domain(db, "comp")

          parent = DoctypeDefinition.from_json(%({
            "doctype": "Box",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"name": {"type": "string"}},
            "children": {"items": {"doctype": "Item", "collection": true}}
          }))
          # Child has NO member_of — the one-sided (hybrid) spelling.
          child = DoctypeDefinition.from_json(%({
            "doctype": "Item",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"label": {"type": "string"}}
          }))
          persist_doctype_for_check(db, parent)
          persist_doctype_for_check(db, child)

          # The parent's children entry is flagged — the child does not
          # declare member_of back.
          parent_res = Check.call(db, "comp.Box").as(Check::Result)
          comp = parent_res.issues.select { |i| i.category == :composition }
          comp.size.should eq(1)
          comp[0].severity.should eq(:error)
          comp[0].message.should contain("comp.Item")
          comp[0].message.should contain("member_of")

          # The child itself is clean — it declares no member_of and is
          # flagged as a root mislabel only if it also omits aggregate_root.
          child_res = Check.call(db, "comp.Item").as(Check::Result)
          child_res.issues.select { |i| i.category == :composition }.should be_empty
        end
      end

      it "warns on a standalone doctype that declares neither member_of nor aggregate_root" do
        with_db do |db|
          ensure_domain(db, "comp")

          # No other doctype in the domain owns this one.
          loner = DoctypeDefinition.from_json(%({
            "doctype": "Lookup",
            "domain": "comp",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}}
          }))
          persist_doctype_for_check(db, loner)

          res = Check.call(db, "comp.Lookup").as(Check::Result)
          comp = res.issues.select { |i| i.category == :composition }
          comp.size.should eq(1)
          comp[0].severity.should eq(:warning)
          comp[0].message.should contain("aggregate_root: true")
        end
      end

      it "reports no root mislabel when aggregate_root is declared" do
        with_db do |db|
          ensure_domain(db, "comp")

          loner = DoctypeDefinition.from_json(%({
            "doctype": "Lookup",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"name": {"type": "string"}}
          }))
          persist_doctype_for_check(db, loner)

          res = Check.call(db, "comp.Lookup").as(Check::Result)
          res.issues.select { |i| i.category == :composition }.should be_empty
        end
      end

      it "warns when a child declares member_of but the parent has no matching children:" do
        with_db do |db|
          ensure_domain(db, "comp")

          # Parent declares NO children.
          parent = DoctypeDefinition.from_json(%({
            "doctype": "Container",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"name": {"type": "string"}}
          }))
          child = DoctypeDefinition.from_json(%({
            "doctype": "Thing",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": false,
            "member_of": "Container",
            "fields": {"label": {"type": "string"}}
          }))
          persist_doctype_for_check(db, parent)
          persist_doctype_for_check(db, child)

          res = Check.call(db, "comp.Thing").as(Check::Result)
          comp = res.issues.select { |i| i.category == :composition }
          comp.size.should eq(1)
          comp[0].severity.should eq(:error)
          comp[0].message.should contain("comp.Container")
          comp[0].message.should contain("member_of")
        end
      end

      it "warns when a reference field targets the doctype's own child" do
        with_db do |db|
          ensure_domain(db, "comp")

          parent = DoctypeDefinition.from_json(%({
            "doctype": "Widget",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {
              "name": {"type": "string"},
              "featured_part": {"type": "reference", "doctype": "comp.Part"}
            },
            "children": {"parts": {"doctype": "Part", "collection": true}}
          }))
          child = DoctypeDefinition.from_json(%({
            "doctype": "Part",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": false,
            "member_of": "Widget",
            "fields": {"name": {"type": "string"}}
          }))
          persist_doctype_for_check(db, parent)
          persist_doctype_for_check(db, child)

          res = Check.call(db, "comp.Widget").as(Check::Result)
          comp = res.issues.select { |i| i.category == :composition }
          comp.size.should eq(1)
          comp[0].field.should eq("featured_part")
          comp[0].message.should contain("children")
          comp[0].message.should contain("comp.Part")
        end
      end

      it "does not flag a reference field targeting an unrelated aggregate root" do
        with_db do |db|
          ensure_domain(db, "comp")

          parent = DoctypeDefinition.from_json(%({
            "doctype": "Gadget",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {
              "name": {"type": "string"},
              "supplier": {"type": "reference", "doctype": "comp.Supplier"}
            },
            "children": {"widgets": {"doctype": "Widget", "collection": true}}
          }))
          # Child is mutual with the parent (no reciprocity warning).
          child = DoctypeDefinition.from_json(%({
            "doctype": "Widget",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": false,
            "member_of": "Gadget",
            "fields": {"name": {"type": "string"}}
          }))
          # Unrelated aggregate root — not a child, no member_of.
          supplier = DoctypeDefinition.from_json(%({
            "doctype": "Supplier",
            "domain": "comp",
            "schema_version": 1,
            "aggregate_root": true,
            "fields": {"name": {"type": "string"}}
          }))
          persist_doctype_for_check(db, parent)
          persist_doctype_for_check(db, child)
          persist_doctype_for_check(db, supplier)

          res = Check.call(db, "comp.Gadget").as(Check::Result)
          res.issues.select { |i| i.category == :composition }.should be_empty
        end
      end

      # ── :sidecar diagnostics ─────────────────────────────────────

      it "flags a sidecars entry pointing at a non-registered doctype" do
        with_db do |db|
          ensure_domain(db, "hosts")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Ticket",
            "domain": "hosts",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "sidecars": {"comments": {"doctype": "core.Comment"}}
          }))
          # core.Comment is NOT registered in this DB
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          sidecar_issues = res.issues.select { |i| i.category == :sidecar }
          sidecar_issues.size.should eq(1)
          sidecar_issues[0].severity.should eq(:warning)
          sidecar_issues[0].field.should eq("sidecars.comments")
          sidecar_issues[0].message.should contain("core.Comment")
          sidecar_issues[0].message.should contain("not registered")
        end
      end

      it "flags a sidecars entry pointing at a doctype not flagged sidecar: true" do
        with_db do |db|
          ensure_domain(db, "hosts")
          ensure_domain(db, "core")
          plain = DoctypeDefinition.from_json(%({
            "doctype": "Remark",
            "domain": "core",
            "schema_version": 1,
            "fields": {
              "target": {"type": "reference", "doctype": "hosts.Ticket", "required": true, "read_only": true}
            }
          }))
          host = DoctypeDefinition.from_json(%({
            "doctype": "Ticket",
            "domain": "hosts",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "sidecars": {"remarks": {"doctype": "core.Remark"}}
          }))
          persist_doctype_for_check(db, plain)
          doc_id = persist_doctype_for_check(db, host)

          res = Check.call(db, doc_id).as(Check::Result)
          sidecar_issues = res.issues.select { |i| i.category == :sidecar }
          sidecar_issues.size.should eq(1)
          sidecar_issues[0].message.should contain("not flagged as sidecar: true")
        end
      end

      it "flags a sidecars entry whose column does not exist on the target" do
        with_db do |db|
          ensure_domain(db, "hosts")
          ensure_domain(db, "core")
          sidecar = DoctypeDefinition.from_json(%({
            "doctype": "Remark",
            "domain": "core",
            "schema_version": 1,
            "sidecar": true,
            "fields": {
              "target": {"type": "reference", "doctype": "hosts.Ticket", "required": true, "read_only": true},
              "body":   {"type": "longtext", "required": true}
            }
          }))
          host = DoctypeDefinition.from_json(%({
            "doctype": "Ticket",
            "domain": "hosts",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "sidecars": {"remarks": {"doctype": "core.Remark", "column": "subject"}}
          }))
          persist_doctype_for_check(db, sidecar)
          doc_id = persist_doctype_for_check(db, host)

          res = Check.call(db, doc_id).as(Check::Result)
          sidecar_issues = res.issues.select { |i| i.category == :sidecar }
          sidecar_issues.size.should eq(1)
          sidecar_issues[0].message.should contain("no reference field named 'subject'")
        end
      end

      it "emits no :sidecar issues for a valid sidecars entry" do
        with_db do |db|
          ensure_domain(db, "hosts")
          ensure_domain(db, "core")
          sidecar = DoctypeDefinition.from_json(%({
            "doctype": "Remark",
            "domain": "core",
            "schema_version": 1,
            "sidecar": true,
            "fields": {
              "target": {"type": "reference", "doctype": "hosts.Ticket", "required": true, "read_only": true},
              "body":   {"type": "longtext", "required": true}
            }
          }))
          host = DoctypeDefinition.from_json(%({
            "doctype": "Ticket",
            "domain": "hosts",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "sidecars": {"remarks": {"doctype": "core.Remark"}}
          }))
          persist_doctype_for_check(db, sidecar)
          doc_id = persist_doctype_for_check(db, host)

          res = Check.call(db, doc_id).as(Check::Result)
          res.issues.select { |i| i.category == :sidecar }.should be_empty
        end
      end
    end

    describe "views" do
      it "reports the missing standard view kinds as :info notices (B-304)" do
        with_db do |db|
          ensure_domain(db, "viewless")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Gadget",
            "domain": "viewless",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}}
          }))
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          view_issues = res.issues.select(&.category.==(:view))
          kinds = view_issues.compact_map(&.field)
          kinds.sort.should eq(%w[card form inline quickView view])
          view_issues.all?(&.severity.==(:info)).should be_true
        end
      end

      it "expects the standard view kinds on child doctypes as well" do
        with_db do |db|
          ensure_domain(db, "compose")
          host_defn = DoctypeDefinition.from_json(%({
            "doctype": "Order",
            "domain": "compose",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "children": {"lines": {"doctype": "OrderLine"}}
          }))
          child_defn = DoctypeDefinition.from_json(%({
            "doctype": "OrderLine",
            "domain": "compose",
            "schema_version": 1,
            "aggregate_root": false,
            "member_of": "Order",
            "fields": {"sku": {"type": "string"}}
          }))
          host_id = persist_doctype_for_check(db, host_defn)
          child_id = persist_doctype_for_check(db, child_defn)

          host_res = Check.call(db, host_id).as(Check::Result)
          host_view = host_res.issues.select(&.category.==(:view)).compact_map(&.field)
          host_view.sort.should eq(%w[card form inline quickView view])

          child_res = Check.call(db, child_id).as(Check::Result)
          child_view = child_res.issues.select(&.category.==(:view)).compact_map(&.field)
          child_view.sort.should eq(%w[card form inline quickView view])
        end
      end

      it "reports malformed view templates as :view warnings with the node path" do
        with_db do |db|
          ensure_domain(db, "viewbroken")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "BrokenView",
            "domain": "viewbroken",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}}
          }))
          doc_id = persist_doctype_for_check(db, defn)
          persist_view_for_check(db, doc_id, "form", %({
            "type": "col",
            "children": [{"type": "input-text", "label": "Name"}]
          }))

          res = Check.call(db, doc_id).as(Check::Result)
          template_issues = res.issues.select(&.category.==(:view)).select(&.severity.==(:warning))
          template_issues.size.should eq(1)
          template_issues.first.field.should eq("template.children.0.field")
          template_issues.first.message.should contain("'form'")
          template_issues.first.message.should contain("missing required 'field'")
        end
      end

      it "warns when the view template does not show every field" do
        with_db do |db|
          ensure_domain(db, "viewgap")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Gadget",
            "domain": "viewgap",
            "schema_version": 1,
            "fields": {
              "name":  {"type": "string"},
              "notes": {"type": "longtext"},
              "stock": {"type": "integer"}
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)
          persist_view_for_check(db, doc_id, "view", %({
            "type": "col",
            "children": [{"type": "field", "value": "$name"}]
          }))

          res = Check.call(db, doc_id).as(Check::Result)
          coverage = res.issues.select(&.category.==(:view)).select(&.severity.==(:warning))
            .select(&.field.==("view"))
          coverage.size.should eq(1)
          coverage.first.message.should contain("does not list every field")
          coverage.first.message.should contain("notes, stock")
          coverage.first.message.should_not contain("name")
        end
      end

      it "warns when the form template omits editable fields but skips computed, read-only, and dictionary ones" do
        with_db do |db|
          ensure_domain(db, "formgap")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Gadget",
            "domain": "formgap",
            "schema_version": 1,
            "fields": {
              "name":  {"type": "string"},
              "notes": {"type": "longtext"},
              "total": {"type": "data"},
              "ref":   {"type": "string", "read_only": true},
              "tags":  {"type": "dictionary", "values": {"type": "string"}}
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)
          persist_view_for_check(db, doc_id, "form", %({
            "type": "col",
            "children": [{"type": "input-text", "field": "name", "label": "Name"}]
          }))

          res = Check.call(db, doc_id).as(Check::Result)
          coverage = res.issues.select(&.category.==(:view)).select(&.severity.==(:warning))
            .select(&.field.==("form"))
          coverage.size.should eq(1)
          coverage.first.message.should contain("notes")
          coverage.first.message.should_not contain("total")
          coverage.first.message.should_not contain("tags")
        end
      end

      it "counts wrapper-bound and interpolated references as coverage" do
        with_db do |db|
          ensure_domain(db, "viewcover")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Gadget",
            "domain": "viewcover",
            "schema_version": 1,
            "fields": {
              "name":    {"type": "string"},
              "address": {
                "type": "object",
                "properties": {"street": {"type": "string"}}
              }
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)
          persist_view_for_check(db, doc_id, "view", %({
            "type": "col",
            "children": [
              {"type": "label", "value": "Hello $name"},
              {"type": "object", "field": "address", "children": [
                {"type": "field", "value": "$street"}
              ]}
            ]
          }))

          res = Check.call(db, doc_id).as(Check::Result)
          coverage = res.issues.select(&.category.==(:view)).select(&.severity.==(:warning))
            .select(&.field.==("view"))
          coverage.size.should eq(0)
        end
      end
    end

    describe "collection views" do
      it "warns when a kanban group_by cannot serve the equality filter (F10-10)" do
        with_db do |db|
          doc_id = persist_collection_view_parent(db, "cvsurf", %({
            "status": {"type": "enum", "values": [{"key": "draft"}], "filters": ["equality"]},
            "state": {"type": "enum", "values": [{"key": "open"}]}
          }))
          persist_collection_view_for_check(db, doc_id, "Board", "kanban", %({
            "kanban": {"mode": "values", "group_by": "state"}
          }))

          res = Check.call(db, doc_id).as(Check::Result)
          view_warnings = res.issues.select { |i| i.category == :view && i.severity == :warning }
          view_warnings.size.should eq(1)
          view_warnings.first.field.should eq("config.kanban.group_by")
          view_warnings.first.message.should contain("CollectionView 'Board'")
          view_warnings.first.message.should contain("'state'")
          view_warnings.first.message.should contain("equality")
        end
      end

      it "accepts a kanban group_by that serves the equality filter" do
        with_db do |db|
          doc_id = persist_collection_view_parent(db, "cvok", %({
            "status": {"type": "enum", "values": [{"key": "draft"}], "filters": ["equality"]}
          }))
          persist_collection_view_for_check(db, doc_id, "Board", "kanban", %({
            "kanban": {"mode": "values", "group_by": "status"}
          }))

          res = Check.call(db, doc_id).as(Check::Result)
          res.issues.select { |i| i.category == :view && i.severity == :warning }.should be_empty
        end
      end

      it "warns when a calendar discriminator cannot serve the window filter (F10-10)" do
        with_db do |db|
          doc_id = persist_collection_view_parent(db, "cvcal", %({
            "started_on": {"type": "date"},
            "scheduled_on": {"type": "date", "filters": ["comparison"]}
          }))
          persist_collection_view_for_check(db, doc_id, "Schedule", "calendar", %({
            "calendar": {"discriminator": "started_on", "week_start": "monday"}
          }))

          res = Check.call(db, doc_id).as(Check::Result)
          view_warnings = res.issues.select { |i| i.category == :view && i.severity == :warning }
          view_warnings.size.should eq(1)
          view_warnings.first.field.should eq("config.calendar.discriminator")
          view_warnings.first.message.should contain("'started_on'")
          view_warnings.first.message.should contain("gte")
          view_warnings.first.message.should contain("lte")
        end
      end

      it "accepts a calendar discriminator that serves the window filter" do
        with_db do |db|
          doc_id = persist_collection_view_parent(db, "cvcalok", %({
            "scheduled_on": {"type": "date", "filters": ["comparison"]}
          }))
          persist_collection_view_for_check(db, doc_id, "Schedule", "calendar", %({
            "calendar": {"discriminator": "scheduled_on", "week_start": "monday"}
          }))

          res = Check.call(db, doc_id).as(Check::Result)
          res.issues.select { |i| i.category == :view && i.severity == :warning }.should be_empty
        end
      end
    end

    describe "actions" do
      it "warns when actions are declared but no script is defined (B-299)" do
        with_db do |db|
          ensure_domain(db, "scriptless")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Gadget",
            "domain": "scriptless",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "actions": {"release": {"args": {}}}
          }))
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          action_issues = res.issues.select(&.category.==(:actions))
          action_issues.size.should eq(1)
          action_issues.first.severity.should eq(:warning)
          action_issues.first.message.should contain("no script is defined")
        end
      end

      it "emits no :actions warning when a script implements the actions" do
        with_db do |db|
          ensure_domain(db, "scripted")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Gadget",
            "domain": "scripted",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}},
            "actions": {"release": {"args": {}}},
            "script": "local export = {}; function export.release(args) end; return export"
          }))
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          res.issues.select(&.category.==(:actions)).should be_empty
        end
      end

      it "exempts the route-served system doctypes" do
        with_db do |db|
          # The global truncation wipes the seed projections, so persist a
          # definition shaped like the system seed: core.DomainGrant
          # declares activate/deactivate, served by the dedicated grant
          # routes that run no Lua.
          defn = DoctypeDefinition.from_json(%({
            "doctype": "DomainGrant",
            "domain": "core",
            "schema_version": 1,
            "aggregate_root": false,
            "member_of": "Domain",
            "fields": {"active": {"type": "boolean"}},
            "actions": {
              "activate": {"args": {}},
              "deactivate": {"args": {}}
            }
          }))
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          res.issues.select(&.category.==(:actions)).should be_empty
        end
      end
    end

    describe "computed fields" do
      it "warns when computed fields are declared but no script is defined (B-274)" do
        with_db do |db|
          ensure_domain(db, "compute_scriptless")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Meter",
            "domain": "computless",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}, "progress": {"type": "data", "compute": "meter_progress"}}
          }))
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          compute_issues = res.issues.select(&.category.==(:compute))
          compute_issues.size.should eq(1)
          compute_issues.first.severity.should eq(:warning)
          compute_issues.first.message.should contain("no script is defined")
        end
      end

      it "emits no :compute warning when a script implements the computes" do
        with_db do |db|
          ensure_domain(db, "compute_scripted")
          defn = DoctypeDefinition.from_json(%({
            "doctype": "Meter",
            "domain": "computesd",
            "schema_version": 1,
            "fields": {"name": {"type": "string"}, "progress": {"type": "data", "compute": "meter_progress"}},
            "script": "local export = {}; function export.compute_meter_progress(ctx) end; return export"
          }))
          doc_id = persist_doctype_for_check(db, defn)

          res = Check.call(db, doc_id).as(Check::Result)
          res.issues.select(&.category.==(:compute)).should be_empty
        end
      end
    end
  end
end
