# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/http/domain_gate"
require "../../src/http/helpers"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# Terminal probe for the gate specs. It marks every request that the gate
# lets through.
private class GateProbeHandler
  include HTTP::Handler

  def initialize
    @reached = false
  end

  def reached? : Bool
    @reached
  end

  def call(context : HTTP::Server::Context)
    @reached = true
    context.response.status_code = 200
    context.response.print("ok")
  end
end

# Runs the gate with a probe handler after it. Returns the response and the
# probe flag. The flag is true when the gate passes the request on.
private def run_through_gate(path : String) : {response: HTTP::Client::Response, passed: Bool}
  gate = Facet::HTTP::DomainGate.new
  probe = GateProbeHandler.new
  gate.next = probe

  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(HTTP::Request.new("GET", path), response)
  gate.call(context)
  response.close rescue nil
  io.rewind
  {response: HTTP::Client::Response.from_io(io, decompress: false), passed: probe.reached?}
end

# Builds a minimal valid config. The gate reads only the `domains` section.
private def gate_config(domains : Facet::Config::DomainsConfig) : Facet::Config
  Facet::Config.new(
    artifact_grant_secret: "test-secret",
    host: "localhost:3000",
    domains: domains,
    secrets: Facet::Secrets::Config.new(
      # The secret store needs a valid 32-byte key.
      master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
    ),
  )
end

# Installs a test config. It restores the previous config after the block.
private def with_gate_config(domains : Facet::Config::DomainsConfig, &)
  original = Facet::Config.instance
  begin
    Facet::Config.instance = gate_config(domains)
    yield
  ensure
    Facet::Config.instance = original
  end
end

# Creates a domain and one doctype through the service layer. The generic
# document routes serve that domain when the gate passes the request.
private def gate_chain_create_doctype(db : DB::Connection, domain : String, doctype : String) : Nil
  ensure_domain(db, domain)
  defn_json = %({
    "doctype": "#{doctype}",
    "domain": "#{domain}",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "name": {"type": "string"}
    }
  })
  result = Facet::Document::Create.call(db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

describe Facet::HTTP::DomainGate do
  describe "reserved first segments" do
    it "passes system namespaces through, even when their names are excluded" do
      reserved = %w[Audit Indexes Artifacts SystemSettings iam assistant]
      with_gate_config(Facet::Config::DomainsConfig.new(excluded: reserved)) do
        [
          "/Api/Audit",
          "/Api/Audit/01HX/rollback",
          "/Api/Indexes",
          "/Api/Artifacts",
          "/Api/Artifacts/01HX/grants",
          "/Api/SystemSettings",
          "/Api/iam",
          "/Api/iam/login",
          "/Api/assistant",
          "/Api/assistant/conversations",
        ].each do |path|
          result = run_through_gate(path)
          result[:passed].should be_true, "gate blocked reserved path #{path}"
          result[:response].status_code.should eq(200)
        end
      end
    end

    it "keeps the core artifact namespace outside the domain gate" do
      with_gate_config(Facet::Config::DomainsConfig.new(excluded: ["core"])) do
        [
          "/Api/core/artifacts",
          "/Api/core/artifacts/01HX",
          "/Api/core/artifacts/01HX/download",
          "/Api/core/Artifacts/01HX",
        ].each do |path|
          result = run_through_gate(path)
          result[:passed].should be_true, "gate blocked reserved path #{path}"
        end
      end
    end

    it "still gates the core domain itself" do
      with_gate_config(Facet::Config::DomainsConfig.new(excluded: ["core"])) do
        result = run_through_gate("/Api/core/DocType")
        result[:passed].should be_false
        result[:response].status_code.should eq(404)
      end
    end
  end

  describe "user domains that start with a reserved name" do
    it "gates them like any other domain" do
      {
        "Audits"     => "/Api/Audits/Thing",
        "IndexesFoo" => "/Api/IndexesFoo/Thing",
        "ArtifactsX" => "/Api/ArtifactsX/Thing",
        "audit"      => "/Api/audit/Thing",
      }.each do |domain, path|
        with_gate_config(Facet::Config::DomainsConfig.new(excluded: [domain])) do
          result = run_through_gate(path)
          result[:passed].should be_false, "gate passed excluded domain path #{path}"
          resp = result[:response]
          resp.status_code.should eq(404)
          resp.headers["Cache-Control"].should eq("no-store")
          JSON.parse(resp.body)["error"].as_s.should eq("Not found")
        end
      end
    end

    it "treats a reserved prefix as part of the domain name" do
      # "Audit" is reserved but "AuditFoo" is not. The exclusion of "Audit"
      # must not block "AuditFoo".
      with_gate_config(Facet::Config::DomainsConfig.new(excluded: ["Audit"])) do
        result = run_through_gate("/Api/AuditFoo/Thing")
        result[:passed].should be_true
      end
    end
  end

  describe "ordinary domains" do
    it "gates an excluded domain" do
      with_gate_config(Facet::Config::DomainsConfig.new(excluded: ["hr"])) do
        result = run_through_gate("/Api/hr/Employee")
        result[:passed].should be_false
        result[:response].status_code.should eq(404)
      end
    end

    it "passes an enabled domain" do
      with_gate_config(Facet::Config::DomainsConfig.new) do
        result = run_through_gate("/Api/hr/Employee")
        result[:passed].should be_true
        result[:response].status_code.should eq(200)
      end
    end

    it "passes paths without a domain segment" do
      with_gate_config(Facet::Config::DomainsConfig.new(excluded: ["hr"])) do
        ["/Healthcheck", "/Api", "/Api/"].each do |path|
          result = run_through_gate(path)
          result[:passed].should be_true, "gate blocked path without a domain: #{path}"
        end
      end
    end
  end

  describe "over the HTTP chain" do
    before_each do
      with_db do |db|
        gate_chain_create_doctype(db, "iam2", "Thing")
      end
    end

    # `iam` is a reserved segment; `iam2` is a legal lowercase user domain
    # whose path the old prefix matcher swallowed. With exact-segment
    # matching the gate serves it when enabled and 404s it when excluded.
    it "404s an excluded domain whose name starts with a reserved name" do
      with_gate_config(Facet::Config::DomainsConfig.new(excluded: ["iam2"])) do
        resp = list_documents_http("iam2", "Thing")
        assert_http_status(resp, 404)
        JSON.parse(resp.body)["error"].as_s.should eq("Not found")
      end
    end

    it "serves the same domain when it is enabled" do
      with_gate_config(Facet::Config::DomainsConfig.new) do
        resp = list_documents_http("iam2", "Thing")
        assert_http_status(resp, 200)
        JSON.parse(resp.body)["data"].as_a.should be_empty
      end
    end

    it "keeps a reserved namespace serving under an exclusion" do
      with_gate_config(Facet::Config::DomainsConfig.new(excluded: ["iam2"])) do
        resp = call_api(HTTP::Request.new("GET", "/Api/Audit"))
        assert_http_status(resp, 200)
      end
    end
  end
end
