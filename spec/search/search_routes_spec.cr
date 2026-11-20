# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../spec_helper"
require "../../src/http/server"
require "../../src/document"
require "../../src/mutation/client"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# HTTP contract of the cross-doctype search endpoint
# (`GET|QUERY /Api/:domain/search` and `GET|QUERY /Api/search`).
#
# The endpoint reads live doctype definitions, joins one ranked branch per
# contributing doctype (read grant + non-empty `search` template), and
# resolves composition children to their aggregate root. Every document in
# these specs is created through the normal mutation API, so the `search`
# corpus is computed by the real projection trigger. Doctypes and domains
# get unique names per example — the fiber-local definition cache persists
# across examples, and unique ids never serve a stale entry.
#
# The auth-context specs pin an `RBAC::AuthContext` on the fiber with
# `call_api_as` — the same harness surface the RBAC specs use.

private def build_doctype(domain : String, doctype : String, extra : String = "") : String
  %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true,
     "display_name": "{{ name }}", "search": "{{ name }}",
     "fields": {"name": {"type": "string"}, "owner_id": {"type": "string"}},
     "scopes": {"mine": {"where": {"owner_id": "$self"}}}#{extra}})
end

private def build_child_doctype(domain : String, doctype : String, member_of : String, with_search : Bool = true, extra : String = "") : String
  search = with_search ? %("search": "{{ label }}",) : ""
  %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": false,
     "member_of": "#{member_of}", "display_name": "{{ label }}", #{search}
     "fields": {"label": {"type": "string"}}#{extra}})
end

private def create_doctype_expect_ok(definition : String) : Nil
  with_db do |db|
    result = Facet::Document::Create.call(db, "core", "DocType", definition, Facet::RBAC::AuthContext.system)
    unless result.is_a?(Facet::Document::Create::Result)
      STDERR.puts "doctype create failed: #{result.message} for #{definition}"
    end
    result.should be_a(Facet::Document::Create::Result)
  end
end

private def create_search_doc(domain : String, doctype : String, name : String, owner_id : String? = nil) : String
  with_db do |db|
    content = {"name" => JSON::Any.new(name)}
    content["owner_id"] = JSON::Any.new(owner_id) if owner_id
    result = Facet::Document::Create.call(db, domain, doctype, content.to_json, Facet::RBAC::AuthContext.system)
    result.should be_a(Facet::Document::Create::Result)
    result.as(Facet::Document::Create::Result).projection.id
  end
end

private def create_search_child(domain : String, doctype : String, label : String, parent_id : String) : String
  with_db do |db|
    result = Facet::Document::Create.call(
      db, domain, doctype, %({"label": "#{label}"}), Facet::RBAC::AuthContext.system,
      meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
    )
    result.should be_a(Facet::Document::Create::Result)
    result.as(Facet::Document::Create::Result).projection.id
  end
end

private def get_search(path : String, body : String? = nil) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  request = HTTP::Request.new("GET", path, headers, body: body)
  call_api(request)
end

private def get_search_request(path : String) : HTTP::Request
  HTTP::Request.new("GET", path, headers: HTTP::Headers{"Content-Type" => "application/json"})
end

private def query_search(path : String, body : String? = nil, content_type : String? = "application/json") : HTTP::Client::Response
  h = HTTP::Headers.new
  h["Content-Type"] = content_type if content_type
  request = HTTP::Request.new("QUERY", path, headers: h, body: body)
  call_api(request)
end

# Every value node of a parsed response must carry no document content —
# the search surface returns labels only.
private def assert_no_content_key(node : JSON::Any) : Nil
  if obj = node.as_h?
    obj.keys.should_not contain("content")
    obj.each_value { |v| assert_no_content_key(v) }
  elsif arr = node.as_a?
    arr.each { |v| assert_no_content_key(v) }
  end
end

# ── Transport pair ────────────────────────────────────────────────────────

describe "Search endpoint — transport pair" do
  it "searches one domain from the query string" do
    domain = "d#{unique_suffix}"
    doctype = "T#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, doctype))
    doc_id = create_search_doc(domain, doctype, "Alpha Widget")

    resp = get_search("/Api/#{domain}/search?q=alpha")
    assert_http_status(resp, 200)

    body = parse_body(resp)
    body["meta"]["q"].as_s.should eq("alpha")
    body["meta"]["scope"].as_s.should eq("domain")
    body["meta"]["count"].raw.should be_a(Int64 | Int32)
    groups = body["data"].as_a
    groups.size.should eq(1)
    groups.first["domain"].as_s.should eq(domain)
    groups.first["doctype"].as_s.should eq(doctype)
    hits = groups.first["hits"].as_a
    hits.size.should eq(1)
    hits.first["id"].as_s.should eq(doc_id)
    hits.first["display_name"].as_s.should eq("Alpha Widget")
    hits.first["root_doctype"].as_s.should eq(doctype)
    hits.first["root_id"].as_s.should eq(doc_id)
    hits.first["child_label"].raw.should be_nil
    assert_no_content_key(body)
  end

  it "merges a JSON body on GET with the query string winning" do
    domain = "d#{unique_suffix}"
    doctype = "T#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, doctype))
    create_search_doc(domain, doctype, "Bravo Body")
    create_search_doc(domain, doctype, "Charlie Query")

    # Query string q=charlie wins over the body's q=bravo.
    resp = get_search("/Api/#{domain}/search?q=charlie", %({"q": "bravo"}))
    assert_http_status(resp, 200)
    names = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a.map(&.["display_name"].as_s))
    names.should contain("Charlie Query")
    names.should_not contain("Bravo Body")

    # Body-only GET merge works too.
    resp = get_search("/Api/#{domain}/search", %({"q": "bravo"}))
    assert_http_status(resp, 200)
    names = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a.map(&.["display_name"].as_s))
    names.should contain("Bravo Body")
  end

  it "reads q from the QUERY body and rejects query-string parameters with 422" do
    domain = "d#{unique_suffix}"
    doctype = "T#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, doctype))
    create_search_doc(domain, doctype, "Delta Query")

    resp = query_search("/Api/#{domain}/search", %({"q": "delta"}))
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(1)
    resp.headers["Accept-Query"]?.should eq("application/json")

    resp = query_search("/Api/#{domain}/search?q=delta", %({"q": "delta"}))
    assert_http_status(resp, 422)
  end

  it "rejects a non-JSON QUERY media type with 415 and a non-object body with 422" do
    domain = "d#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }

    resp = query_search("/Api/#{domain}/search", %({"q": "x"}), content_type: "text/plain")
    assert_http_status(resp, 415)

    resp = query_search("/Api/#{domain}/search", %([1, 2]))
    assert_http_status(resp, 422)
  end

  it "answers 200 with an empty result for a short or missing q" do
    domain = "d#{unique_suffix}"
    doctype = "T#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, doctype))
    create_search_doc(domain, doctype, "Echo Document")

    resp = get_search("/Api/#{domain}/search?q=e")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.size.should eq(0)
    body["meta"]["count"].raw.should eq(0)

    resp = get_search("/Api/#{domain}/search")
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(0)

    resp = query_search("/Api/#{domain}/search", %({}))
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(0)
  end

  it "404s an unknown domain without disclosing it" do
    resp = get_search("/Api/no_such_#{unique_suffix}/search?q=anything")
    assert_http_status(resp, 404)
  end

  it "serves the app-wide route ungated by the domain check" do
    resp = query_search("/Api/search", %({"q": "zz_no_such_term_#{unique_suffix}"}))
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["meta"]["scope"].as_s.should eq("app")
    body["data"].as_a.size.should eq(0)
  end
end

# ── D3 — the search template is the searchability flag ────────────────────

describe "Search endpoint — template gate" do
  it "gives a template-less doctype no branch" do
    domain = "d#{unique_suffix}"
    doctype = "T#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    bare = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true,
              "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}})
    create_doctype_expect_ok(bare)
    create_search_doc(domain, doctype, "Findme Unique")

    resp = get_search("/Api/#{domain}/search?q=findme")
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(0)
  end
end

# ── RBAC — grants and scope fragments ─────────────────────────────────────

describe "Search endpoint — RBAC branches" do
  it "gives a doctype without a read grant no branch" do
    domain = "d#{unique_suffix}"
    granted = "G#{unique_suffix}"
    denied = "D#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, granted))
    create_doctype_expect_ok(build_doctype(domain, denied))
    create_search_doc(domain, granted, "Grantzone Item")
    create_search_doc(domain, denied, "Grantzone Item")

    # The caller may read the granted doctype only; the denied one
    # contributes no branch and leaks nothing.
    perm = Facet::RBAC::Permission.new(action: "read", domain: domain, path: [granted])
    ctx = Facet::RBAC::AuthContext.authenticated(
      "acc_#{unique_suffix}",
      Facet::RBAC::ActiveRole.new(
        role_id: "search_reader",
        visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
        permissions: [perm],
      ),
    )

    resp = call_api_as(get_search_request("/Api/#{domain}/search?q=grantzone"), ctx)
    assert_http_status(resp, 200)
    groups = parse_body(resp)["data"].as_a
    groups.size.should eq(1)
    groups.first["doctype"].as_s.should eq(granted)
  end

  it "filters rows through the doctype's scope fragments" do
    domain = "d#{unique_suffix}"
    doctype = "T#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, doctype))
    account = "acc_#{unique_suffix}"
    mine_id = create_search_doc(domain, doctype, "Scoped Mine", owner_id: "iam.Account.#{account}")
    create_search_doc(domain, doctype, "Scoped Theirs", owner_id: "iam.Account.acc_other")

    perm = Facet::RBAC::Permission.new(action: "read", domain: domain, path: [doctype], scope: ["$mine"])
    ctx = Facet::RBAC::AuthContext.authenticated(
      account,
      Facet::RBAC::ActiveRole.new(
        role_id: "search_scoped",
        visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
        permissions: [perm],
      ),
    )

    resp = call_api_as(get_search_request("/Api/#{domain}/search?q=scoped"), ctx)
    assert_http_status(resp, 200)
    hits = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a)
    hits.size.should eq(1)
    hits.first["id"].as_s.should eq(mine_id)
  end

  it "fails closed when the scope fragments are unsatisfiable" do
    domain = "d#{unique_suffix}"
    doctype = "T#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, doctype))
    create_search_doc(domain, doctype, "Closed Shop")

    # A scope alias the definition does not declare fails to expand —
    # the enforcer emits `1=0`, the branch matches nothing.
    perm = Facet::RBAC::Permission.new(action: "read", domain: domain, path: [doctype], scope: ["$missing_scope"])
    ctx = Facet::RBAC::AuthContext.authenticated(
      "acc_#{unique_suffix}",
      Facet::RBAC::ActiveRole.new(
        role_id: "search_broken_scope",
        visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
        permissions: [perm],
      ),
    )

    resp = call_api_as(get_search_request("/Api/#{domain}/search?q=closed"), ctx)
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(0)
  end
end

# ── Child → root combination ──────────────────────────────────────────────

describe "Search endpoint — child to root" do
  it "anchors a one-level child hit at its root" do
    domain = "d#{unique_suffix}"
    root_dt = "R#{unique_suffix}"
    child_dt = "C#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, root_dt, %(, "children": {"items": {"doctype": "#{child_dt}", "collection": true}})))
    create_doctype_expect_ok(build_child_doctype(domain, child_dt, root_dt))

    root_id = create_search_doc(domain, root_dt, "Root Bundle")
    child_id = create_search_child(domain, child_dt, "Inventory Entry", root_id)

    resp = get_search("/Api/#{domain}/search?q=inventory")
    assert_http_status(resp, 200)
    hits = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a)
    hits.size.should eq(1)
    hit = hits.first
    hit["id"].as_s.should eq(child_id)
    hit["display_name"].as_s.should eq("Inventory Entry")
    hit["child_label"].as_s.should eq("Inventory Entry")
    hit["root_doctype"].as_s.should eq(root_dt)
    hit["root_id"].as_s.should eq(root_id)
    hit["root_display_name"].as_s.should eq("Root Bundle")

    # The root itself is searchable and anchors to itself.
    resp = get_search("/Api/#{domain}/search?q=bundle")
    assert_http_status(resp, 200)
    hits = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a)
    hits.size.should eq(1)
    hits.first["id"].as_s.should eq(root_id)
    hits.first["child_label"].raw.should be_nil
    hits.first["root_id"].as_s.should eq(root_id)
  end

  it "walks a two-hop chain through a template-less intermediate" do
    domain = "d#{unique_suffix}"
    root_dt = "R#{unique_suffix}"
    mid_dt = "M#{unique_suffix}"
    leaf_dt = "L#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, root_dt, %(, "children": {"mids": {"doctype": "#{mid_dt}", "collection": true}})))
    # The intermediate carries no search template — it joins only the walk.
    create_doctype_expect_ok(build_child_doctype(domain, mid_dt, root_dt, with_search: false, extra: %(, "children": {"leaves": {"doctype": "#{leaf_dt}", "collection": true}})))
    create_doctype_expect_ok(build_child_doctype(domain, leaf_dt, mid_dt))

    root_id = create_search_doc(domain, root_dt, "Top Root")
    mid_id = create_search_child(domain, mid_dt, "Mid Node", root_id)
    leaf_id = create_search_child(domain, leaf_dt, "Deep Leaf", mid_id)

    resp = get_search("/Api/#{domain}/search?q=deep")
    assert_http_status(resp, 200)
    hits = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a)
    hits.size.should eq(1)
    hits.first["id"].as_s.should eq(leaf_id)
    hits.first["child_label"].as_s.should eq("Deep Leaf")
    hits.first["root_doctype"].as_s.should eq(root_dt)
    hits.first["root_id"].as_s.should eq(root_id)
    hits.first["root_display_name"].as_s.should eq("Top Root")
  end

  it "keeps same-named child doctypes of different domains apart" do
    # Two domains each declare a child doctype with the SAME name but a
    # different parent. The composition walk is domain-scoped: neither
    # domain's pm rows may steer (or strand) the other's climb.
    domain_a = "da#{unique_suffix}"
    domain_b = "db#{unique_suffix}"
    shared_child = "Sh#{unique_suffix}"
    root_a = "Ra#{unique_suffix}"
    root_b = "Rb#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain_a) }
    with_db { |db| ensure_domain(db, domain_b) }
    create_doctype_expect_ok(build_doctype(domain_a, root_a, %(, "children": {"items": {"doctype": "#{shared_child}", "collection": true}})))
    create_doctype_expect_ok(build_doctype(domain_b, root_b, %(, "children": {"items": {"doctype": "#{shared_child}", "collection": true}})))
    create_doctype_expect_ok(build_child_doctype(domain_a, shared_child, root_a))
    create_doctype_expect_ok(build_child_doctype(domain_b, shared_child, root_b))

    root_a_id = create_search_doc(domain_a, root_a, "Alpha Bundle")
    root_b_id = create_search_doc(domain_b, root_b, "Beta Bundle")
    create_search_child(domain_a, shared_child, "Shared Entry", root_a_id)
    create_search_child(domain_b, shared_child, "Shared Entry", root_b_id)

    resp = get_search("/Api/#{domain_a}/search?q=shared")
    assert_http_status(resp, 200)
    hits = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a)
    hits.size.should eq(1)
    hits.first["root_doctype"].as_s.should eq(root_a)
    hits.first["root_id"].as_s.should eq(root_a_id)
  end

  it "drops a child hit whose root the caller cannot read" do
    domain = "d#{unique_suffix}"
    root_dt = "R#{unique_suffix}"
    child_dt = "C#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, root_dt, %(, "children": {"items": {"doctype": "#{child_dt}", "collection": true}})))
    create_doctype_expect_ok(build_child_doctype(domain, child_dt, root_dt))

    root_id = create_search_doc(domain, root_dt, "Locked Root")
    create_search_child(domain, child_dt, "Hidden Child", root_id)

    # Read grant on the child only — the root scope check denies, so the
    # hit never reaches the client.
    child_perm = Facet::RBAC::Permission.new(action: "read", domain: domain, path: [child_dt])
    ctx = Facet::RBAC::AuthContext.authenticated(
      "acc_#{unique_suffix}",
      Facet::RBAC::ActiveRole.new(
        role_id: "child_only",
        visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
        permissions: [child_perm],
      ),
    )

    resp = call_api_as(get_search_request("/Api/#{domain}/search?q=hidden"), ctx)
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(0)

    # The same caller sees the child once the root grant is added.
    ctx = Facet::RBAC::AuthContext.authenticated(
      "acc_#{unique_suffix}",
      Facet::RBAC::ActiveRole.new(
        role_id: "child_and_root",
        visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
        permissions: [
          child_perm,
          Facet::RBAC::Permission.new(action: "read", domain: domain, path: [root_dt]),
        ],
      ),
    )
    resp = call_api_as(get_search_request("/Api/#{domain}/search?q=hidden"), ctx)
    assert_http_status(resp, 200)
    hits = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a)
    hits.size.should eq(1)
    hits.first["root_id"].as_s.should eq(root_id)
  end

  it "drops a child hit whose root is deleted" do
    domain = "d#{unique_suffix}"
    root_dt = "R#{unique_suffix}"
    child_dt = "C#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, root_dt, %(, "children": {"items": {"doctype": "#{child_dt}", "collection": true}})))
    create_doctype_expect_ok(build_child_doctype(domain, child_dt, root_dt))

    root_id = create_search_doc(domain, root_dt, "Doomed Root")
    child_id = create_search_child(domain, child_dt, "Orphan Candidate", root_id)

    # A low-level delete skips the service's cascade, so the child stays
    # live while the root is a tombstone — the walk must refuse to
    # anchor on it.
    with_db do |db|
      Facet::Mutation::Client.delete(db, domain, root_dt, root_id)
    end

    resp = get_search("/Api/#{domain}/search?q=orphan")
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(0)

    # Sanity: the child row is still live, so the empty result came from
    # the root scope check, not from a cascade.
    with_db do |db|
      live = db.query_one?(
        "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
        domain, child_dt, child_id, as: Int32)
      live.should eq(1)
    end
  end

  it "drops a child hit whose parent chain is broken" do
    domain = "d#{unique_suffix}"
    root_dt = "R#{unique_suffix}"
    child_dt = "C#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, root_dt, %(, "children": {"items": {"doctype": "#{child_dt}", "collection": true}})))
    create_doctype_expect_ok(build_child_doctype(domain, child_dt, root_dt))

    create_search_child(domain, child_dt, "Broken Chain", "missing_parent_id")

    resp = get_search("/Api/#{domain}/search?q=broken")
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(0)
  end
end

# ── Caps and rank order ───────────────────────────────────────────────────

describe "Search endpoint — caps and rank order" do
  it "caps a single doctype at PER_DOCTYPE_CAP hits" do
    domain = "d#{unique_suffix}"
    doctype = "T#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, doctype))
    7.times { |i| create_search_doc(domain, doctype, "Overflow Item #{i}") }

    resp = get_search("/Api/#{domain}/search?q=overflow")
    assert_http_status(resp, 200)
    groups = parse_body(resp)["data"].as_a
    groups.size.should eq(1)
    groups.first["hits"].as_a.size.should eq(Facet::Search::PER_DOCTYPE_CAP)
  end

  it "ranks the exact label first" do
    domain = "d#{unique_suffix}"
    exact_dt = "E#{unique_suffix}"
    long_dt = "W#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    create_doctype_expect_ok(build_doctype(domain, exact_dt))
    create_doctype_expect_ok(build_doctype(domain, long_dt))
    exact_id = create_search_doc(domain, exact_dt, "Ranked Zed")
    create_search_doc(domain, long_dt, "Ranked Zed plus a long tail of words")

    resp = get_search("/Api/#{domain}/search?q=ranked%20zed")
    assert_http_status(resp, 200)
    hits = parse_body(resp)["data"].as_a.flat_map(&.["hits"].as_a)
    hits.size.should eq(2)
    hits.first["id"].as_s.should eq(exact_id)
    ranks = hits.map(&.["rank"].as_f)
    ranks.should eq(ranks.sort { |a, b| b <=> a })
  end

  it "caps the whole response at OVERALL_CAP hits" do
    domain = "d#{unique_suffix}"
    with_db { |db| ensure_domain(db, domain) }
    # Six doctypes with five matches each exceed the overall cap.
    6.times do |i|
      doctype = "N#{i}#{unique_suffix}"
      create_doctype_expect_ok(build_doctype(domain, doctype))
      5.times { |j| create_search_doc(domain, doctype, "Capped Sea #{j}") }
    end

    resp = get_search("/Api/#{domain}/search?q=capped%20sea")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["meta"]["count"].raw.should eq(Facet::Search::OVERALL_CAP)
    groups = body["data"].as_a
    groups.size.should eq(5)
    groups.each { |g| g["hits"].as_a.size.should eq(Facet::Search::PER_DOCTYPE_CAP) }
  end
end
