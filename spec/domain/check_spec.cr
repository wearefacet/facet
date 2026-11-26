# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/domain"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/mutation/json_diff"
require "../../src/rbac"

# Persists a doctype definition via direct Mutation::Client.create. The draft
# domain name starts with `_` (rejected by `Doctype::Create`'s domain-name
# regex), so the spec bypasses the service layer exactly like `Domain::Copy`
# does on the publish path.
def persist_doctype_in_domain(db, defn : Facet::Doctype::DoctypeDefinition) : String
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

# Persists a `core.DocumentView` child for a doctype in a draft domain.
def persist_view_in_domain(db, domain : String, doctype : String, kind : String) : String
  doc_id = "#{domain}.#{doctype}.document_view.#{kind}"
  Facet::Mutation::Client.create(
    db, "core", "DocumentView",
    doc_id: doc_id,
    content: %({"parent_doctype": "#{domain}.#{doctype}", "kind": "#{kind}"}),
    meta: %({"parent_id": "#{domain}.#{doctype}"}),
    actioner_id: "system:test",
  )
  doc_id
end

# Re-registers the core.DocType and core.Domain definitions after the
# global TRUNCATE wipes them. `Document::Delete` on a core.* document
# resolves the doctype definition via `DefinitionStore.fetch`, which would
# otherwise 404 with "Unknown doctype".
def seed_core_meta_doctypes(db)
  ["core.DocType", "core.Domain"].each do |qualified|
    parts = qualified.split('.')
    path = File.join(__DIR__, "..", "..", "data", "seeds", qualified, "definition.yml")
    yaml = YAML.parse(File.read(path))
    json_any = Facet::Doctype::YamlHelper.to_json_any(yaml)
    defn = Facet::Doctype::DoctypeDefinition.from_json(json_any)
    Facet::Mutation::Client.create(
      db, parts[0], parts[1],
      doc_id: qualified,
      content: defn.to_json,
      actioner_id: "system",
    )
    Facet::Doctype::DefinitionStore.invalidate(qualified)
  end
end

# Creates an empty draft domain via the Draft module and returns its id.
def create_draft(db) : String
  result = Facet::Domain::Draft.create(db, "{}", "system:test")
  result.should be_a(Facet::Domain::Draft::Result)
  result.as(Facet::Domain::Draft::Result).projection.id
end

# Persists an `iam.Roles` document via the raw mutation client — the same
# path `seed_test_roles` uses. The authoring validator does not run here, so
# the content may carry any permission shape. Private: owned by this file.
private def seed_role_for_check(db, name : String, permissions : String) : Nil
  Facet::Mutation::Client.create(
    db, "iam", "Roles",
    doc_id: "iam.Roles.#{name}",
    content: %({"name": "#{name}", "level": 10, "permissions": #{permissions}}),
    actioner_id: "system:test",
  )
end

module Facet::Domain
  describe Check do
    it "returns a 404 Error when the domain does not exist" do
      with_db do |db|
        result = Check.call(db, "does_not_exist")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(404)
        err.message.should contain("does_not_exist")
      end
    end

    it "surfaces a :no_doctypes domain issue for a draft with no doctypes" do
      with_db do |db|
        draft = create_draft(db)

        result = Check.call(db, draft).as(Check::Result)
        result.domain.should eq(draft)
        result.doctypes.should be_empty
        result.domain_issues.size.should eq(1)
        di = result.domain_issues.first
        di.category.should eq(:no_doctypes)
        di.message.should contain(draft)
      end
    end

    it "aggregates issues across all doctypes of the draft domain" do
      with_db do |db|
        draft = create_draft(db)

        # `Order` references `identity.Person` which is NOT registered → produces
        # a `:reference` warning.
        order_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
          "doctype": "Order",
          "domain": "#{draft}",
          "schema_version": 1,
          "search": "{{ name }}",
          "fields": {
            "name": {"type": "string"},
            "customer": {"type": "reference", "doctype": "identity.Person"}
          }
        }))
        persist_doctype_in_domain(db, order_defn)

        # `LineItem` is clean — no issues.
        line_item_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
          "doctype": "LineItem",
          "domain": "#{draft}",
          "schema_version": 1,
          "aggregate_root": true,
          "fields": {"sku": {"type": "string"}}
        }))
        persist_doctype_in_domain(db, line_item_defn)
        # Ship the standard views so `LineItem` stays clean — a missing
        # standard kind is an `:info` notice under Doctype::Check (B-304).
        %w[view form quickView inline card].each do |kind|
          persist_view_in_domain(db, draft, "LineItem", kind)
        end

        result = Check.call(db, draft).as(Check::Result)
        # No domain-level issue now that doctypes exist.
        result.domain_issues.should be_empty
        result.doctypes.size.should eq(2)

        by_id = result.doctypes.index_by(&.doctype_id)
        order_res = by_id["#{draft}.Order"]
        ref_issues = order_res.issues.select { |i| i.category == :reference }
        ref_issues.size.should eq(1)
        ref_issues.first.field.should eq("customer")

        # `Order` carries one `:defaults` info notice (no display_name
        # template — search is declared), the five missing standard view
        # kinds, and the zero-collection-views notice — all `:info`, in
        # `notices`, not `issues`.
        order_res.notices.size.should eq(7)
        order_res.notices.all?(&.severity.==(:info)).should be_true

        line_item_res = by_id["#{draft}.LineItem"]
        # `LineItem` has no broken config — one issue: the B-296 template
        # gate on an aggregate root that declares neither template. It is an
        # `:error`. Two `:info` notices stay in `notices`: the display_name
        # notice and the zero-collection-views notice (its standard
        # DocumentView kinds exist, but no collection view does).
        line_item_res.issues.size.should eq(1)
        line_item_res.issues.first.category.should eq(:defaults)
        line_item_res.issues.first.severity.should eq(:error)
        line_item_res.notices.size.should eq(2)
      end
    end

    it "keeps :defaults notices out of the per-doctype issue list" do
      with_db do |db|
        draft = create_draft(db)

        # A doctype with a broken reference AND no display_name/search: both
        # land in `issues` (the reference warning and the B-296 error), the
        # `:info` notices in `notices`.
        defn = Facet::Doctype::DoctypeDefinition.from_json(%({
          "doctype": "Order",
          "domain": "#{draft}",
          "schema_version": 1,
          "fields": {
            "name": {"type": "string"},
            "customer": {"type": "reference", "doctype": "identity.Person"}
          }
        }))
        persist_doctype_in_domain(db, defn)

        result = Check.call(db, draft).as(Check::Result)
        res = result.doctypes.first
        res.issues.any? { |i| i.category == :reference && i.severity == :warning }.should be_true
        # The B-296 both-templates-missing finding carries the `:defaults`
        # category, severity `:error`, and counts as an issue; only the
        # `:info` notices are kept out of the issue list.
        defaults_issues = res.issues.select { |i| i.category == :defaults }
        defaults_issues.size.should eq(1)
        defaults_issues.first.severity.should eq(:error)
        res.notices.all?(&.severity.==(:info)).should be_true
        res.notices.any? { |i| i.category == :defaults }.should be_true
        res.notices.any? { |i| i.category == :reference }.should be_false
      end
    end

    it "tolerates a corrupt doctype definition by surfacing it as a :composition warning" do
      with_db do |db|
        draft = create_draft(db)

        # Persist a doctype with an unparseable body — its `content` JSON is
        # well-formed at the SQL level but does not deserialize into a
        # `DoctypeDefinition`. `Doctype::Check.call` returns a `:Error` for
        # this id and the aggregate must convert it to a single warning rather
        # than hard-failing.
        doc_id = "#{draft}.Broken"
        Facet::Mutation::Client.create(
          db, "core", "DocType",
          doc_id: doc_id,
          content: %({"doctype": "Broken", "domain": "#{draft}", "schema_version": "not_an_integer", "fields": {}}),
          actioner_id: "system:test",
        )
        Facet::Doctype::DefinitionStore.invalidate(doc_id)

        result = Check.call(db, draft).as(Check::Result)
        broken = result.doctypes.find { |d| d.doctype_id == doc_id }
        broken.should_not be_nil
        issues = broken.not_nil!.issues
        issues.size.should eq(1)
        issues.first.category.should eq(:composition)
        issues.first.message.should contain(doc_id)
      end
    end

    it "ignores doctypes that have been soft-deleted" do
      with_db do |db|
        draft = create_draft(db)

        defn = Facet::Doctype::DoctypeDefinition.from_json(%({
          "doctype": "Ghost",
          "domain": "#{draft}",
          "schema_version": 1,
          "fields": {"name": {"type": "string"}}
        }))
        doc_id = persist_doctype_in_domain(db, defn)

        # Soft-delete the doctype via the standard Document::Delete path.
        # Requires the `core.DocType` metadoctype to be registered (the
        # global TRUNCATE wipes it) so `DefinitionStore.fetch` can resolve it.
        seed_core_meta_doctypes(db)
        del_result = Facet::Document::Delete.call(db, "core", "DocType", doc_id, Facet::RBAC::AuthContext.system)
        del_result.should be_a(Facet::Document::Delete::Result)

        # Confirm the projection row has `deleted_at` set — `Check` filters on
        # this column, so we assert it here to localise the failure if the
        # delete ever stops marking the row.
        deleted = db.query_one?(
          "SELECT deleted_at FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1",
          doc_id,
          as: Time?
        )
        deleted.should_not be_nil

        result = Check.call(db, draft).as(Check::Result)
        result.doctypes.should be_empty
        # No doctypes → :no_doctypes warning fires again.
        result.domain_issues.first.category.should eq(:no_doctypes)
      end
    end

    describe "publish_gate diagnostics" do
      it "surfaces a :publish_gate issue when structure changed and schema_version is not live + 1" do
        with_db do |db|
          ensure_domain(db, "orders")
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: "orders.Widget",
            content: %({"doctype": "Widget", "domain": "orders", "schema_version": 1, "search": "{{ name }}", "fields": {"name": {"type": "string"}}}),
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("orders.Widget")

          draft_result = Facet::Domain::Draft.create_from(db, "orders", "user-1")
          draft_result.should be_a(Facet::Domain::Draft::Result)
          draft = draft_result.as(Facet::Domain::Draft::Result).projection.id

          # Draft changes structure but keeps schema_version = 1 (should be 2).
          Facet::Mutation::Client.update(
            db, "core", "DocType", "#{draft}.Widget",
            diff_json: Facet::Mutation::JsonDiff.diff(
              Facet::Mutation::Client.fetch_content(db, "core", "DocType", "#{draft}.Widget"),
              JSON.parse(%({"doctype": "Widget", "domain": "#{draft}", "schema_version": 1, "fields": {"name": {"type": "string"}, "age": {"type": "integer"}}})),
            ).to_json,
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("#{draft}.Widget")

          result = Check.call(db, draft).as(Check::Result)
          widget = result.doctypes.find { |d| d.doctype_id == "#{draft}.Widget" }
          widget.should_not be_nil
          pub = widget.not_nil!.issues.find { |i| i.category == :publish_gate }
          pub.should_not be_nil
          pub.not_nil!.message.should contain("schema_version must be 2")
        end
      end

      it "surfaces a :publish_gate issue when the migration entry is missing" do
        with_db do |db|
          ensure_domain(db, "orders")
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: "orders.Widget",
            content: %({"doctype": "Widget", "domain": "orders", "schema_version": 1, "search": "{{ name }}", "fields": {"name": {"type": "string"}}}),
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("orders.Widget")

          draft_result = Facet::Domain::Draft.create_from(db, "orders", "user-1")
          draft_result.should be_a(Facet::Domain::Draft::Result)
          draft = draft_result.as(Facet::Domain::Draft::Result).projection.id

          # Draft changes structure, bumps version, but no migrations.
          Facet::Mutation::Client.update(
            db, "core", "DocType", "#{draft}.Widget",
            diff_json: Facet::Mutation::JsonDiff.diff(
              Facet::Mutation::Client.fetch_content(db, "core", "DocType", "#{draft}.Widget"),
              JSON.parse(%({"doctype": "Widget", "domain": "#{draft}", "schema_version": 2, "search": "{{ name }}", "fields": {"name": {"type": "string"}, "age": {"type": "integer"}}})),
            ).to_json,
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("#{draft}.Widget")

          result = Check.call(db, draft).as(Check::Result)
          widget = result.doctypes.find { |d| d.doctype_id == "#{draft}.Widget" }
          widget.should_not be_nil
          pub = widget.not_nil!.issues.find { |i| i.category == :publish_gate }
          pub.should_not be_nil
          pub.not_nil!.message.should contain("Migration from v1 to v2 is missing")
        end
      end

      it "does not surface a :publish_gate issue when structure is identical" do
        with_db do |db|
          ensure_domain(db, "orders")
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: "orders.Widget",
            content: %({"doctype": "Widget", "domain": "orders", "schema_version": 1, "search": "{{ name }}", "fields": {"name": {"type": "string"}}}),
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("orders.Widget")

          draft_result = Facet::Domain::Draft.create_from(db, "orders", "user-1")
          draft_result.should be_a(Facet::Domain::Draft::Result)
          draft = draft_result.as(Facet::Domain::Draft::Result).projection.id

          result = Check.call(db, draft).as(Check::Result)
          widget = result.doctypes.find { |d| d.doctype_id == "#{draft}.Widget" }
          widget.should_not be_nil
          widget.not_nil!.issues.any? { |i| i.category == :publish_gate }.should be_false
        end
      end

      it "does not surface a :publish_gate issue when only non-structural attributes changed (operators, title)" do
        with_db do |db|
          ensure_domain(db, "orders")
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: "orders.Widget",
            content: %({"doctype": "Widget", "domain": "orders", "schema_version": 1, "search": "{{ name }}", "fields": {"name": {"type": "string"}}}),
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("orders.Widget")

          draft_result = Facet::Domain::Draft.create_from(db, "orders", "user-1")
          draft_result.should be_a(Facet::Domain::Draft::Result)
          draft = draft_result.as(Facet::Domain::Draft::Result).projection.id

          # Draft only adds operators / a title — non-structural under
          # `Doctype::Structure`. schema_version stays at 1 (live) — no bump
          # should be required.
          Facet::Mutation::Client.update(
            db, "core", "DocType", "#{draft}.Widget",
            diff_json: Facet::Mutation::JsonDiff.diff(
              Facet::Mutation::Client.fetch_content(db, "core", "DocType", "#{draft}.Widget"),
              JSON.parse(%({"doctype": "Widget", "domain": "#{draft}", "schema_version": 1, "fields": {"name": {"type": "string", "title": "Name", "filters": ["comparison"]}}})),
            ).to_json,
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("#{draft}.Widget")

          result = Check.call(db, draft).as(Check::Result)
          widget = result.doctypes.find { |d| d.doctype_id == "#{draft}.Widget" }
          widget.should_not be_nil
          widget.not_nil!.issues.any? { |i| i.category == :publish_gate }.should be_false
        end
      end

      it "does not surface :publish_gate issues for a freestanding draft (no source_domain)" do
        with_db do |db|
          draft = create_draft(db)
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: "#{draft}.Widget",
            content: %({"doctype": "Widget", "domain": "#{draft}", "schema_version": 1, "fields": {"name": {"type": "string"}}}),
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("#{draft}.Widget")

          result = Check.call(db, draft).as(Check::Result)
          widget = result.doctypes.find { |d| d.doctype_id == "#{draft}.Widget" }
          widget.should_not be_nil
          widget.not_nil!.issues.any? { |i| i.category == :publish_gate }.should be_false
        end
      end

      it "surfaces both :publish_gate and existing :reference issues on the same doctype" do
        with_db do |db|
          ensure_domain(db, "orders")
          Facet::Mutation::Client.create(
            db, "core", "DocType",
            doc_id: "orders.Widget",
            content: %({"doctype": "Widget", "domain": "orders", "schema_version": 1, "fields": {"name": {"type": "string"}, "customer": {"type": "reference", "doctype": "identity.Person"}}}),
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("orders.Widget")

          draft_result = Facet::Domain::Draft.create_from(db, "orders", "user-1")
          draft_result.should be_a(Facet::Domain::Draft::Result)
          draft = draft_result.as(Facet::Domain::Draft::Result).projection.id

          # Draft adds a field, bumps version, but no migration.
          Facet::Mutation::Client.update(
            db, "core", "DocType", "#{draft}.Widget",
            diff_json: Facet::Mutation::JsonDiff.diff(
              Facet::Mutation::Client.fetch_content(db, "core", "DocType", "#{draft}.Widget"),
              JSON.parse(%({"doctype": "Widget", "domain": "#{draft}", "schema_version": 2, "fields": {"name": {"type": "string"}, "customer": {"type": "reference", "doctype": "identity.Person"}, "age": {"type": "integer"}}})),
            ).to_json,
            actioner_id: "system:test",
          )
          Facet::Doctype::DefinitionStore.invalidate("#{draft}.Widget")

          result = Check.call(db, draft).as(Check::Result)
          widget = result.doctypes.find { |d| d.doctype_id == "#{draft}.Widget" }
          widget.should_not be_nil
          issues = widget.not_nil!.issues
          issues.any? { |i| i.category == :reference }.should be_true
          issues.any? { |i| i.category == :publish_gate }.should be_true
        end
      end
    end

    # ── Role-permission lint (:rbac domain issues on the iam check) ──────

    describe "role permission lint" do
      it "surfaces an :rbac warning for a role with a scoped create line" do
        with_db do |db|
          ensure_domain(db, "iam")
          seed_role_for_check(db, "linty", %([{"action": "create", "on": "core.Domain", "scope": ["$domain_editor"]}]))

          result = Check.call(db, "iam").as(Check::Result)
          rbac_issues = result.domain_issues.select { |i| i.category == :rbac }
          rbac_issues.size.should eq(1)
          issue = rbac_issues.first
          issue.severity.should eq(:warning)
          issue.message.should contain("Role 'iam.Roles.linty'")
          issue.message.should contain("Permission #0")
          issue.message.should contain("not enforced")
        end
      end

      it "surfaces one warning per offending line and names the index" do
        with_db do |db|
          ensure_domain(db, "iam")
          seed_role_for_check(db, "linty2", %([
            {"action": "create", "on": "core.DocType", "scope": ["$domain_editor"]},
            {"action": "create", "on": "core.Domain"},
            {"action": "create", "on": "core.SchematicLayout", "scope": ["$domain_editor"]}
          ]))

          result = Check.call(db, "iam").as(Check::Result)
          rbac_issues = result.domain_issues.select { |i| i.category == :rbac }
          rbac_issues.size.should eq(2)
          rbac_issues.any?(&.message.includes?("Permission #0")).should be_true
          rbac_issues.any?(&.message.includes?("Permission #2")).should be_true
        end
      end

      it "surfaces no :rbac issue when roles hold no scoped create lines" do
        with_db do |db|
          ensure_domain(db, "iam")
          seed_role_for_check(db, "clean", %([
            {"action": "create", "on": "core.Domain"},
            {"action": "read", "on": "core.Comment", "scope": ["$mine"]}
          ]))

          result = Check.call(db, "iam").as(Check::Result)
          result.domain_issues.none? { |i| i.category == :rbac }.should be_true
        end
      end

      it "does not surface the role lint on a non-iam domain check" do
        with_db do |db|
          ensure_domain(db, "iam")
          seed_role_for_check(db, "linty3", %([{"action": "create", "on": "core.Domain", "scope": ["$domain_editor"]}]))

          draft = create_draft(db)
          result = Check.call(db, draft).as(Check::Result)
          result.domain_issues.none? { |i| i.category == :rbac }.should be_true
        end
      end
    end
  end
end
