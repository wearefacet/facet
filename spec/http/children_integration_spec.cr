# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../../src/rbac"

# Initialize the HTTP handler chain once
HTTPTest.init

# ── Helpers ────────────────────────────────────────────────────────────

def j(str)
  str.gsub("'", "\"")
end

def create_doctype_with_children!(domain, doctype, children_json, fields_json = "{}", *, scopes = nil)
  scopes_json = if scopes
                  entries = scopes.map { |name, body| %("#{name}": #{body.to_json}) }
                  ", \"scopes\": {#{entries.join(", ")}}"
                else
                  ""
                end
  body = %({
    "doctype": "#{doctype}",
    "domain": "#{domain}",
    "aggregate_root": true,
    "search": "{{ display_name }}",
    "fields": #{fields_json},
    "children": #{children_json}#{scopes_json}
  })
  resp = create_doctype_http(body)
  assert_http_status(resp, 201)
  JSON.parse(resp.body)["meta"]["id"].as_s
end

def create_simple_doctype!(domain, doctype, member_of = nil, fields_json = "{}")
  member = member_of ? %("member_of": "#{member_of}",) : ""
  body = %({
    "doctype": "#{doctype}",
    "domain": "#{domain}",
    "aggregate_root": false,
    #{member}
    "fields": #{fields_json}
  })
  resp = create_doctype_http(body)
  assert_http_status(resp, 201)
  JSON.parse(resp.body)["meta"]["id"].as_s
end

# GETs a child-list path with an arbitrary query string (the shared
# `list_nested_http` helper takes no query parameters).
def child_list(path : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", path))
end

def setup_customer_domain!
  resp = create_domain_http("childtest")
  assert_http_status(resp, 201)
end

def setup_parent_and_child_doctypes!
  create_doctype_with_children!("childtest", "Customer",
    j(%({"contacts": {"doctype": "Contact", "collection": true}})),
    j(%({"name": {"type": "string"}}))
  )
  create_simple_doctype!("childtest", "Contact", "Customer", j(%({"name": {"type": "string"}})))
end

private def assert_error_contains(resp, text)
  body = parse_body(resp)
  combined = body["error"].as_s
  if details = body["details"]?
    # Details are structured `{field, message, code}` objects — extract the
    # `message` (and `field` when present) so substring assertions keep
    # matching the user-facing text.
    parts = details.as_a.map do |d|
      msg = d["message"]?.try(&.as_s).to_s
      field = d["field"]?
      field ? "#{field.as_s} #{msg}" : msg
    end
    combined += " " + parts.join(" ")
  end
  combined.downcase.should contain(text)
end

# Role: `read childtest.Customer` scoped to `{Customer: {owner_id: $self}}`,
# plus `read childtest.Contact` (unscoped) so children of readable parents are
# accessible. This is the canonical "read a subset of parents ⇒ read every
# active child of those parents" rule — without the parent gate, the child
# permission alone would leak contact data across non-owned parents.
def scoped_customer_reader(account_id)
  parent_perm = Facet::RBAC::Permission.from_json(JSON::Any.new({
    "action" => JSON::Any.new("read"),
    "on"     => JSON::Any.new("childtest.Customer"),
    "scope"  => JSON::Any.new("$mine"),
  }))
  # The nested child route authorizes on the composition path
  # (`childtest.Customer.Contact`) — the parent permission prefix-covers
  # it; the bare-child line stays for the flat route.
  child_perm = Facet::RBAC::Permission.from_json(JSON::Any.new({
    "action" => JSON::Any.new("read"),
    "on"     => JSON::Any.new("childtest.Contact"),
  }))
  nested_child_perm = Facet::RBAC::Permission.from_json(JSON::Any.new({
    "action" => JSON::Any.new("read"),
    "on"     => JSON::Any.new("childtest.Customer.Contact"),
  }))
  role = Facet::RBAC::ActiveRole.new(
    role_id: "scoped_customer_reader",
    visible_tags: Set{"default"},
    permissions: [parent_perm, child_perm, nested_child_perm],
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe "Children parent_id linkage" do
  before_each do
    setup_customer_domain!
    # Default to system bypass for non-RBAC tests. Individual RBAC specs
    # override by setting Fiber.current.auth_context in their own before_each.
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  # ──────────────────────────────────────────────────────────────────────
  # 1. Schema: parent_id as a protected field name
  # ──────────────────────────────────────────────────────────────────────
  describe "parent_id is protected" do
    it "rejects a doctype that declares a parent_id field" do
      body = %({
        "doctype": "BadDoc",
        "domain": "childtest",
        "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {
          "parent_id": { "type": "string" }
        }
      })
      resp = create_doctype_http(body)
      assert_http_status(resp, 422)
      assert_error_contains(resp, "parent_id")
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # 2. Creating a child stores parent_id in meta
  # ──────────────────────────────────────────────────────────────────────
  describe "creating children" do
    before_each do
      setup_parent_and_child_doctypes!
    end

    it "creates a child and stores parent_id in meta" do
      customer_id = create_doc_id_http("childtest", "Customer", j(%({"name": "ACME"})))
      child_body = j(%({"name": "John"}))
      resp = create_child_document_http("childtest", "Customer", customer_id, "contacts", child_body)
      assert_http_status(resp, 201)

      body = parse_body(resp)
      body["meta"]["parent_id"].should eq(customer_id)
    end

    it "creates a child and fetches it back with parent_id intact" do
      customer_id = create_doc_id_http("childtest", "Customer", j(%({"name": "ACME"})))
      child_body = j(%({"name": "Jane"}))
      resp = create_child_document_http("childtest", "Customer", customer_id, "contacts", child_body)
      assert_http_status(resp, 201)
      child_id = parse_body(resp)["meta"]["id"].as_s

      get_resp = read_nested_http("childtest", "Customer", customer_id, "contacts", child_id)
      assert_http_status(get_resp, 200)
      body = parse_body(get_resp)
      body["meta"]["parent_id"].should eq(customer_id)
    end

    it "rejects a child body that includes parent_id" do
      customer_id = create_doc_id_http("childtest", "Customer", j(%({"name": "ACME"})))
      child_body = j(%({"name": "Jane", "parent_id": "fake"}))
      resp = create_child_document_http("childtest", "Customer", customer_id, "contacts", child_body)
      assert_http_status(resp, 422)
      assert_error_contains(resp, "parent_id")
    end

    it "answers 404 and creates nothing when the parent id does not exist (B-276)" do
      create_doc_id_http("childtest", "Customer", j(%({"name": "ACME"})))
      resp = create_child_document_http("childtest", "Customer", "01FAKEPARENT000000000000", "contacts", j(%({"name": "John"})))
      assert_http_status(resp, 404)

      # The orphan must not exist anywhere — the flat list stays empty.
      list_resp = list_documents_http("childtest", "Contact")
      assert_http_status(list_resp, 200)
      parse_body(list_resp)["meta"]["count"].as_i.should eq(0)
    end

    it "answers 404 when the parent id names a live row of another doctype (B-276)" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "ACME"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "John"})))

      # contact_id is a live Contact row, but the route resolves a Customer.
      resp = create_child_document_http("childtest", "Customer", contact_id, "contacts", j(%({"name": "Jane"})))
      assert_http_status(resp, 404)
    end

    it "rejects creating a child directly via the flat endpoint" do
      child_body = j(%({"name": "Orphan"}))
      resp = create_document_http("childtest", "Contact", child_body)
      assert_http_status(resp, 422)
      assert_error_contains(resp, "belongs to")
    end

    it "names the valid relations in the unknown-relation error" do
      customer_id = create_doc_id_http("childtest", "Customer", j(%({"name": "ACME"})))
      resp = create_child_document_http("childtest", "Customer", customer_id, "ghosts", j(%({"name": "Boo"})))
      assert_http_status(resp, 404)
      error = parse_body(resp)["error"].as_s
      error.should contain("Unknown relation 'ghosts'")
      error.should contain("valid relations: contacts")
    end

    it "keeps relations and actions apart in the single-segment POST miss (F03-01)" do
      # A single-segment POST tries a sidecar, then an action, then a child.
      # A typo is answered with each vocabulary in its own list, so an
      # action typo never reads as a child typo.
      create_doctype_with_children!("childtest", "Ticked",
        j(%({"lines": {"doctype": "TicketLine", "collection": true}})),
        j(%({"title": {"type": "string"}}))
      )
      create_simple_doctype!("childtest", "TicketLine", "Ticked", j(%({"label": {"type": "string"}})))
      ticked_id = create_doc_id_http("childtest", "Ticked", j(%({"title": "T1"})))

      resp = create_child_document_http("childtest", "Ticked", ticked_id, "aprove", j(%({})))
      assert_http_status(resp, 404)
      error = parse_body(resp)["error"].as_s
      error.should contain("Unknown relation 'aprove'")
      error.should contain("valid relations: lines")
      error.should contain("unknown action 'aprove'")
      error.should contain("valid actions: none")
    end

    it "names the single-segment action route for POST .../actions/:action" do
      # The even-segment count would otherwise read 'actions' as a child
      # collection and answer a misleading 400 about child documents.
      customer_id = create_doc_id_http("childtest", "Customer", j(%({"name": "ACME"})))
      resp = create_child_document_http("childtest", "Customer", customer_id, "actions/rename", j(%({})))
      assert_http_status(resp, 400)
      body = parse_body(resp)
      body["error"].as_s.should contain("Named actions run at 'POST /Api/childtest/Customer/#{customer_id}/rename'")
      body["error"].as_s.should contain("drop the 'actions/' prefix")
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # 3. Listing children filters by parent
  # ──────────────────────────────────────────────────────────────────────
  describe "listing children" do
    before_each do
      setup_parent_and_child_doctypes!
    end

    it "lists only children belonging to the parent" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer A"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer B"})))

      c1c1_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))
      _c2c1_id = create_child_doc_id_http("childtest", "Customer", c2_id, "contacts", j(%({"name": "Bob"})))
      c1c2_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Charlie"})))

      resp = list_nested_http("childtest", "Customer", c1_id, "contacts")
      assert_http_status(resp, 200)
      body = parse_body(resp)
      body["meta"]["count"].as_i.should eq(2)
      ids = body["data"].as_a.map(&.["meta"]["id"].as_s)
      ids.should contain(c1c1_id)
      ids.should contain(c1c2_id)
      ids.should_not contain(_c2c1_id)
    end

    it "lists only children belonging to the other parent" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer A"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer B"})))
      create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))
      c2c1_id = create_child_doc_id_http("childtest", "Customer", c2_id, "contacts", j(%({"name": "Bob"})))

      resp = list_nested_http("childtest", "Customer", c2_id, "contacts")
      assert_http_status(resp, 200)
      body = parse_body(resp)
      body["meta"]["count"].as_i.should eq(1)
      body["data"].as_a[0]["meta"]["id"].as_s.should eq(c2c1_id)
    end

    it "returns empty list when parent has no children" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer A"})))
      c3_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer C"})))
      create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))

      resp = list_nested_http("childtest", "Customer", c3_id, "contacts")
      assert_http_status(resp, 200)
      body = parse_body(resp)
      body["meta"]["count"].as_i.should eq(0)
      body["data"].as_a.should be_empty
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # 4. Cross-parent access control
  # ──────────────────────────────────────────────────────────────────────
  describe "cross-parent access is blocked" do
    before_each do
      setup_parent_and_child_doctypes!
    end

    it "GET a child through the wrong parent returns 404" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer A"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer B"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))

      resp = read_nested_http("childtest", "Customer", c2_id, "contacts", contact_id)
      assert_http_status(resp, 404)
    end

    it "PATCH a child through the wrong parent returns 404" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer A"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer B"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))

      request = HTTP::Request.new("PATCH", "/Api/childtest/Customer/#{c2_id}/contacts/#{contact_id}", body: j(%({"name": "Hacker"})))
      resp = call_api(request)
      assert_http_status(resp, 404)
    end

    it "DELETE a child through the wrong parent returns 404" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer A"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer B"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))

      request = HTTP::Request.new("DELETE", "/Api/childtest/Customer/#{c2_id}/contacts/#{contact_id}")
      resp = call_api(request)
      assert_http_status(resp, 404)
    end
  end

  # ───────────────────────────────────────────────────────────────────────
  # 5. Updating a child cannot change parent_id
  # ───────────────────────────────────────────────────────────────────────
  describe "updating children preserves parent_id" do
    before_each do
      setup_parent_and_child_doctypes!
    end

    it "PATCH with parent_id in body is rejected" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer A"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))

      request = HTTP::Request.new("PATCH", "/Api/childtest/Customer/#{c1_id}/contacts/#{contact_id}", body: j(%({"parent_id": "fake"})))
      resp = call_api(request)
      assert_http_status(resp, 422)
      assert_error_contains(resp, "parent_id")
    end

    it "PATCH without parent_id succeeds and keeps parent_id intact" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Customer A"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))

      request = HTTP::Request.new("PATCH", "/Api/childtest/Customer/#{c1_id}/contacts/#{contact_id}", body: j(%({"name": "Alice Updated"})))
      resp = call_api(request)
      assert_http_status(resp, 200)
      body = parse_body(resp)
      body["data"]["name"].as_s.should eq("Alice Updated")
      body["meta"]["parent_id"].should eq(c1_id)
    end
  end

  # ───────────────────────────────────────────────────────────────────────
  # 6. Two-level nesting (children of children)
  # ───────────────────────────────────────────────────────────────────────
  describe "two-level nesting" do
    before_each do
      # Customer -> contacts -> Contact -> notes -> Note
      # (setup_customer_domain! already called by outer before_each)
      create_doctype_with_children!("childtest", "Customer",
        j(%({"contacts": {"doctype": "Contact", "collection": true}})),
        j(%({"name": {"type": "string"}}))
      )
      # Contact has both name field and notes children, is member_of Customer
      body = %({
        "doctype": "Contact",
        "domain": "childtest",
        "aggregate_root": false,
        "member_of": "Customer",
        "fields": {"name": {"type": "string"}},
        "children": {"notes": {"doctype": "Note", "collection": true}}
      })
      resp = create_doctype_http(body)
      assert_http_status(resp, 201)
      create_simple_doctype!("childtest", "Note", "Contact", j(%({"content": {"type": "string"}})))
    end

    it "creates a note under a contact with parent_id pointing to the contact" do
      c_id = create_doc_id_http("childtest", "Customer", j(%({"name": "A customer"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c_id, "contacts", j(%({"name": "John"})))

      note_body = j(%({"content": "Important note"}))
      resp = create_child_document_http("childtest", "Customer", c_id, "contacts/#{contact_id}/notes", note_body)
      assert_http_status(resp, 201)
      body = parse_body(resp)
      body["meta"]["parent_id"].should eq(contact_id)
    end

    it "lists notes scoped to the correct contact" do
      c_id = create_doc_id_http("childtest", "Customer", j(%({"name": "A customer"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Another"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c_id, "contacts", j(%({"name": "John"})))
      contact2_id = create_child_doc_id_http("childtest", "Customer", c2_id, "contacts", j(%({"name": "Jane"})))

      _note1_id = create_child_doc_id_http("childtest", "Customer", c_id, "contacts/#{contact_id}/notes", j(%({"content": "Note for John"})))
      note2_id = create_child_doc_id_http("childtest", "Customer", c2_id, "contacts/#{contact2_id}/notes", j(%({"content": "Note for Jane"})))

      resp = list_nested_http("childtest", "Customer", c2_id, "contacts/#{contact2_id}/notes")
      assert_http_status(resp, 200)
      body = parse_body(resp)
      body["meta"]["count"].as_i.should eq(1)
      body["data"].as_a[0]["meta"]["id"].as_s.should eq(note2_id)
    end

    it "rejects access to a deep child through the wrong parent chain" do
      c_id = create_doc_id_http("childtest", "Customer", j(%({"name": "A customer"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Another"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c_id, "contacts", j(%({"name": "John"})))
      contact2_id = create_child_doc_id_http("childtest", "Customer", c2_id, "contacts", j(%({"name": "Jane"})))

      note_id = create_child_doc_id_http("childtest", "Customer", c_id, "contacts/#{contact_id}/notes", j(%({"content": "Secret"})))

      # Try to read John's note through Jane's path
      resp = read_nested_http("childtest", "Customer", c2_id, "contacts/#{contact2_id}/notes", note_id)
      assert_http_status(resp, 404)
    end

    it "names the valid relations in the unknown-relation error on a deep create" do
      c_id = create_doc_id_http("childtest", "Customer", j(%({"name": "A customer"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c_id, "contacts", j(%({"name": "John"})))

      resp = create_child_document_http("childtest", "Customer", c_id, "contacts/#{contact_id}/ghosts", j(%({"content": "x"})))
      assert_http_status(resp, 404)
      error = parse_body(resp)["error"].as_s
      error.should contain("Unknown relation 'ghosts'")
      error.should contain("valid relations: notes")
    end

    it "answers 404 when the immediate parent id does not exist (B-276)" do
      c_id = create_doc_id_http("childtest", "Customer", j(%({"name": "A customer"})))
      resp = create_child_document_http("childtest", "Customer", c_id, "contacts/01FAKECONTACT00000000000/notes", j(%({"content": "n"})))
      assert_http_status(resp, 404)
    end

    it "answers 404 when an intermediate hop names a live row of another doctype (B-276)" do
      c_id = create_doc_id_http("childtest", "Customer", j(%({"name": "A customer"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Another"})))
      contact2_id = create_child_doc_id_http("childtest", "Customer", c2_id, "contacts", j(%({"name": "Jane"})))
      note_id = create_child_doc_id_http("childtest", "Customer", c2_id, "contacts/#{contact2_id}/notes", j(%({"content": "n2"})))

      # note_id is a live Note row, but the hop resolves a Contact.
      resp = create_child_document_http("childtest", "Customer", c_id, "contacts/#{note_id}/notes", j(%({"content": "n"})))
      assert_http_status(resp, 404)
    end

    it "answers 404 when the root id does not exist (B-276)" do
      c_id = create_doc_id_http("childtest", "Customer", j(%({"name": "A customer"})))
      contact_id = create_child_doc_id_http("childtest", "Customer", c_id, "contacts", j(%({"name": "John"})))

      # contact_id is real, but the URL traverses a root row that is not.
      resp = create_child_document_http("childtest", "Customer", "01FAKER00000000000000000", "contacts/#{contact_id}/notes", j(%({"content": "n"})))
      assert_http_status(resp, 404)
    end
  end

  # ───────────────────────────────────────────────────────────────────────
  # 7. RBAC: parent read authorization gates child access
  #
  # A scope on the parent doctype (e.g. `owner_id = $self`) must restrict
  # which parents' children are exposed via nested routes. A caller without
  # read access to a specific parent receives a non-disclosing 404 — both for
  # listing that parent's children and for reading a specific child under it.
  # ───────────────────────────────────────────────────────────────────────
  describe "parent read authorization gates child access" do
    before_each do
      # Customer has an owner_id reference field used by the `mine` named
      # scope. `$self` always qualifies into the storage form
      # (`iam.Account.<id>`), so the scoped field must be a reference
      # targeting `iam.Account` whose stored value is qualified.
      create_doctype_with_children!("childtest", "Customer",
        j(%({"contacts": {"doctype": "Contact", "collection": true}})),
        j(%({"name": {"type": "string"}, "owner_id": {"type": "reference", "doctype": "iam.Account"}})),
        scopes: {"mine": {"where": {"owner_id": "$self"}}}
      )
      create_simple_doctype!("childtest", "Contact", "Customer", j(%({"name": {"type": "string"}})))
      # The owner_id reference values must pass the authoring-time
      # existence check, so the target account rows must exist.
      with_db do |db|
        ensure_iam_account(db, "account_a")
        ensure_iam_account(db, "account_b")
      end
    end

    it "denies listing children of a parent the caller cannot read" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Owned", "owner_id": "account_a"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Other", "owner_id": "account_b"})))
      create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))
      create_child_doc_id_http("childtest", "Customer", c2_id, "contacts", j(%({"name": "Bob"})))

      Fiber.current.auth_context = scoped_customer_reader("account_a")

      # Parent 1 is owned by account_a → list works.
      resp = list_nested_http("childtest", "Customer", c1_id, "contacts")
      assert_http_status(resp, 200)
      body = parse_body(resp)
      body["meta"]["count"].as_i.should eq(1)

      # Parent 2 is NOT owned by account_a → non-disclosing 404.
      resp2 = list_nested_http("childtest", "Customer", c2_id, "contacts")
      assert_http_status(resp2, 404)
    end

    it "denies reading a single child under a non-readable parent" do
      c1_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Owned", "owner_id": "account_a"})))
      c2_id = create_doc_id_http("childtest", "Customer", j(%({"name": "Other", "owner_id": "account_b"})))
      child_id = create_child_doc_id_http("childtest", "Customer", c1_id, "contacts", j(%({"name": "Alice"})))

      Fiber.current.auth_context = scoped_customer_reader("account_a")

      # Reading the child through the readable parent works.
      resp = read_nested_http("childtest", "Customer", c1_id, "contacts", child_id)
      assert_http_status(resp, 200)

      # Reading the same child through a non-readable parent → 404 (not 403,
      # not 200 with leaked data).
      resp2 = read_nested_http("childtest", "Customer", c2_id, "contacts", child_id)
      assert_http_status(resp2, 404)
    end

    it "denies child access at deeper nesting when the immediate parent is unreadable" do
      # Setup a fresh 3-level hierarchy in a clean test domain.
      create_domain_http("deep")
      create_doctype_with_children!("deep", "Parent",
        j(%({"contacts": {"doctype": "DeepContact", "collection": true}})),
        j(%({"name": {"type": "string"}, "owner_id": {"type": "reference", "doctype": "iam.Account"}})),
        scopes: {"mine": {"where": {"owner_id": "$self"}}}
      )
      with_db do |db|
        ensure_iam_account(db, "account_a")
      end
      create_doctype_http(%({
        "doctype": "DeepContact",
        "domain": "deep",
        "aggregate_root": false,
        "member_of": "Parent",
        "fields": {"name": {"type": "string"}},
        "children": {"notes": {"doctype": "DeepNote", "collection": true}}
      }))
      create_simple_doctype!("deep", "DeepNote", "DeepContact", j(%({"content": {"type": "string"}})))

      perm = Facet::RBAC::Permission.from_json(JSON::Any.new({
        "action" => JSON::Any.new("read"),
        "on"     => JSON::Any.new("deep.Parent"),
        "scope"  => JSON::Any.new("$mine"),
      }))
      role = Facet::RBAC::ActiveRole.new(
        role_id: "scoped_parent_reader",
        visible_tags: Set{"default"},
        permissions: [perm],
      )
      ctx = Facet::RBAC::AuthContext.authenticated("account_a", role)

      p1_id = create_doc_id_http("deep", "Parent", j(%({"name": "Owned", "owner_id": "account_a"})))
      contact_id = create_child_doc_id_http("deep", "Parent", p1_id, "contacts", j(%({"name": "John"})))
      create_child_doc_id_http("deep", "Parent", p1_id, "contacts/#{contact_id}/notes", j(%({"content": "Hi"})))

      Fiber.current.auth_context = ctx

      # Parent p1 is readable; DeepContact contact_id is NOT (no permission
      # granted for DeepContact). The notes list under contact_id must be
      # denied by the gate on the immediate parent: the caller holds no
      # DeepContact grant at all — a class-level denial answers 403. A
      # grant holder whose row is out of scope keeps the non-disclosing
      # 404 (see the scoped-parent specs above).
      resp = list_nested_http("deep", "Parent", p1_id, "contacts/#{contact_id}/notes")
      assert_http_status(resp, 403)
    end
  end
end

# ──────────────────────────────────────────────────────────────────────
# 8. Child list filters (B-38) — `filters` is forwarded on child lists
#    with the same grammar and validation as the flat route.
# ──────────────────────────────────────────────────────────────────────
describe "child list filters" do
  before_each do
    setup_customer_domain!
    create_doctype_with_children!("childtest", "Invoice",
      j(%({"lines": {"doctype": "InvoiceLine", "collection": true}})),
      j(%({"label": {"type": "string"}}))
    )
    create_simple_doctype!("childtest", "InvoiceLine", "Invoice",
      j(%({"label": {"type": "string", "filters": ["equality"]}, "qty": {"type": "integer", "filters": ["comparison"]}})))
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  it "filters the child list with the flat-route grammar" do
    inv = create_doc_id_http("childtest", "Invoice", j(%({"label": "INV-1"})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "alpha", "qty": 2})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "beta", "qty": 4})))

    resp = child_list("/Api/childtest/Invoice/#{inv}/lines?filters[label__eq]=alpha")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    rows = body["data"].as_a
    rows.size.should eq(1)
    rows.first["data"]["label"].as_s.should eq("alpha")
    body["meta"]["count"].as_i.should eq(1)
  end

  it "composes filters with a field aggregate" do
    inv = create_doc_id_http("childtest", "Invoice", j(%({"label": "INV-2"})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "alpha", "qty": 2})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "beta", "qty": 4})))

    resp = child_list("/Api/childtest/Invoice/#{inv}/lines?aggregate=sum&field=qty&filters[label__eq]=alpha")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"]["value"].as_i.should eq(2)
    body["meta"]["count"].as_i.should eq(1)
    body["meta"]["more"].as_bool.should be_false
  end

  it "answers 422 for an unknown filter field" do
    inv = create_doc_id_http("childtest", "Invoice", j(%({"label": "INV-3"})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "alpha", "qty": 2})))

    resp = child_list("/Api/childtest/Invoice/#{inv}/lines?filters[zzz__eq]=1")
    assert_http_status(resp, 422)
    assert_error_contains(resp, "unknown filter field")
  end

  it "answers 422 for an unsupported operator" do
    inv = create_doc_id_http("childtest", "Invoice", j(%({"label": "INV-4"})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "alpha", "qty": 2})))

    resp = child_list("/Api/childtest/Invoice/#{inv}/lines?filters[qty__blah]=1")
    assert_http_status(resp, 422)
    assert_error_contains(resp, "is not served for field")
  end

  it "answers 422 for a non-array value on an array-valued operator (B-41 parity)" do
    inv = create_doc_id_http("childtest", "Invoice", j(%({"label": "INV-5"})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "alpha", "qty": 2})))

    resp = child_list("/Api/childtest/Invoice/#{inv}/lines?filters[qty__in]=2")
    assert_http_status(resp, 422)
    assert_error_contains(resp, "json array")
  end

  it "keeps ignored params out of the ETag fingerprint" do
    inv = create_doc_id_http("childtest", "Invoice", j(%({"label": "INV-6"})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "alpha", "qty": 2})))
    create_child_doc_id_http("childtest", "Invoice", inv, "lines", j(%({"label": "beta", "qty": 4})))

    first = child_list("/Api/childtest/Invoice/#{inv}/lines?filters[label__eq]=alpha")
    assert_http_status(first, 200)
    etag = first.headers["ETag"]

    # A stray `?page=2` is ignored by the route — it must not change the
    # fingerprint, so the revalidation hits.
    stray = call_api(HTTP::Request.new("GET",
      "/Api/childtest/Invoice/#{inv}/lines?filters[label__eq]=alpha&page=2",
      headers: HTTP::Headers{"If-None-Match" => etag}))
    assert_http_status(stray, 304)

    # A different filter changes the fingerprint — no false 304.
    other = call_api(HTTP::Request.new("GET",
      "/Api/childtest/Invoice/#{inv}/lines?filters[label__eq]=beta",
      headers: HTTP::Headers{"If-None-Match" => etag}))
    assert_http_status(other, 200)
  end
end
