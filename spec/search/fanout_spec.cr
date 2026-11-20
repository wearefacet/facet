# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../spec_helper"
require "../../src/http/server"
require "../../src/document"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# The app-wide fan-out: readable domains grouped by their routed database
# (`Database.group_by_database`), one statement per group, merged and
# re-ranked in Crystal.
#
# The spec-scoped cluster points both entries at the worker database URL
# but routes the split domain to its own entry — one physical database,
# two distinct pools, so the grouping and the per-group statement run are
# observable without a second host. `after_each` restores the suite setup
# the way the cluster specs do.

private def build_fanout_cluster(url : String, split_domain : String) : Facet::Database::ClusterConfig
  Facet::Database::ClusterConfig.new(
    databases: [
      Facet::Database::ClusterDatabase.new(name: "fanout_main", url: url, resources: ["*"]),
      Facet::Database::ClusterDatabase.new(name: "fanout_secondary", url: url, resources: [split_domain]),
    ],
  )
end

private def create_fanout_doc(domain : String, doctype : String, name : String) : String
  with_db do |db|
    result = Facet::Document::Create.call(
      db, domain, doctype, %({"name": "#{name}"}), Facet::RBAC::AuthContext.system
    )
    result.should be_a(Facet::Document::Create::Result)
    result.as(Facet::Document::Create::Result).projection.id
  end
end

describe "Search app-wide fan-out" do
  after_each do
    # Restore the suite setup — configured timeout + session tuning — for
    # every example that follows.
    init_suite_database_pool
  end

  it "groups domains by their routed database entry" do
    url = ENV.fetch("DATABASE_URL")
    main_domain = "dm#{unique_suffix}"
    split_domain = "ds#{unique_suffix}"
    with_db { |db| ensure_domain(db, main_domain) }
    with_db { |db| ensure_domain(db, split_domain) }

    Facet::Database.init(build_fanout_cluster(url, split_domain))
    groups = Facet::Database.group_by_database([main_domain, split_domain])
    # `main` resolves through the `*` entry, the split domain through its
    # own entry — two groups, input order preserved.
    groups.should eq([[main_domain], [split_domain]])
  end

  it "yields one group for every resource on a single-pool config" do
    url = ENV.fetch("DATABASE_URL")
    Facet::Database.init(build_fanout_cluster(url, "unused"))
    domains = (1..3).map { "dq#{unique_suffix}" }
    # Everything unrouted resolves through the `*` entry — one group.
    Facet::Database.group_by_database(domains).should eq([domains])
  end

  it "merges hits from both entries in rank order" do
    url = ENV.fetch("DATABASE_URL")
    main_domain = "dm#{unique_suffix}"
    split_domain = "ds#{unique_suffix}"
    main_dt = "M#{unique_suffix}"
    split_dt = "S#{unique_suffix}"

    with_db { |db| ensure_domain(db, main_domain) }
    with_db { |db| ensure_domain(db, split_domain) }
    with_db do |db|
      main_defn = %({"doctype": "#{main_dt}", "domain": "#{main_domain}", "aggregate_root": true,
                     "display_name": "{{ name }}", "search": "{{ name }}",
                     "fields": {"name": {"type": "string"}}})
      split_defn = %({"doctype": "#{split_dt}", "domain": "#{split_domain}", "aggregate_root": true,
                      "display_name": "{{ name }}", "search": "{{ name }}",
                      "fields": {"name": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", main_defn, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)
      Facet::Document::Create.call(db, "core", "DocType", split_defn, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)
    end

    main_exact = create_fanout_doc(main_domain, main_dt, "Fanout Zed")
    create_fanout_doc(split_domain, split_dt, "Fanout Zed plus tail")
    split_exact = create_fanout_doc(split_domain, split_dt, "Fanout Zed Two")
    create_fanout_doc(main_domain, main_dt, "Unrelated Row")

    Facet::Database.init(build_fanout_cluster(url, split_domain))
    resp = call_api(HTTP::Request.new(
      "GET", "/Api/search?q=fanout%20zed",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 200)

    body = parse_body(resp)
    body["meta"]["scope"].as_s.should eq("app")
    groups = body["data"].as_a
    # Both routed databases contributed; each group carries its domain so
    # the client can qualify group headers when escalated.
    groups.map(&.["domain"].as_s).uniq!.sort.should eq([main_domain, split_domain].sort)
    hits = groups.flat_map(&.["hits"].as_a)
    # The exact main-domain label ranks first across the merge.
    hits.first["id"].as_s.should eq(main_exact)
    hits.map(&.["id"].as_s).should contain(split_exact)
  end
end
