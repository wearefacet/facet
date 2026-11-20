# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "http"
require "../../src/http/list_request"

# Specs for the B-169 residual: a present, well-shaped `page` / `items`
# value below 1 is a caller error and answers `422` — the parser never
# clamps it into the first page. The upper clamp (`items` above
# `MAX_ITEMS`) and the "not given" forms keep their behaviour, so the
# known-parameter contract is unchanged.

# `from_json` / `from_query` return `ListRequest | Facet::ServiceError`;
# the happy-path examples narrow through these helpers — the cast fails
# loud when a ServiceError shows up. File-scoped (`private def`), so the
# names may repeat across spec files.
private def parse_body(body : String) : Facet::HTTP::ListRequest
  Facet::HTTP::ListRequest.from_json(body).as(Facet::HTTP::ListRequest)
end

private def parse_query(query : String) : Facet::HTTP::ListRequest
  Facet::HTTP::ListRequest.from_query(URI::Params.parse(query)).as(Facet::HTTP::ListRequest)
end

private def body_error(body : String) : Facet::ServiceError
  Facet::HTTP::ListRequest.from_json(body).as(Facet::ServiceError)
end

private def query_error(query : String) : Facet::ServiceError
  Facet::HTTP::ListRequest.from_query(URI::Params.parse(query)).as(Facet::ServiceError)
end

# Minimal stand-in for the Kemal request context, mirroring the surface
# `ListRequest.from_request` reads: `env.request.body` and
# `env.params.query`. File-scoped, so the name may repeat across spec
# files.
private class ListRequestEnvStub
  getter request : HTTP::Request
  getter params : Params

  def initialize(@request : HTTP::Request, query : URI::Params)
    @params = Params.new(query)
  end

  class Params
    getter query : URI::Params

    def initialize(@query)
    end
  end
end

describe Facet::HTTP::ListRequest do
  describe "page/items below-range gate (B-169 residual)" do
    it "answers 422 for body page=0 and page=-1" do
      ["0", "-1"].each do |raw|
        err = body_error(%({"page": #{raw}}))
        err.status.should eq(422)
        err.message.should contain("Parameter 'page'")
        err.message.should contain("at least 1")
      end
    end

    it "answers 422 for body items=0" do
      err = body_error(%({"items": 0}))
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
      err.message.should contain("at least 1")
    end

    it "answers 422 for query page=0, page=-1, and items=0" do
      ["page=0", "page=-1"].each do |qs|
        err = query_error(qs)
        err.status.should eq(422)
        err.message.should contain("Parameter 'page'")
      end

      err = query_error("items=0")
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "answers 422 through from_request when the query carries page=0" do
      request = HTTP::Request.new("GET", "/Api/test/Thing")
      env = ListRequestEnvStub.new(request, URI::Params.parse("page=0"))
      err = Facet::HTTP::ListRequest.from_request(env).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'page'")
    end

    it "answers 422 through from_request when the body carries items=0" do
      request = HTTP::Request.new("GET", "/Api/test/Thing", body: %({"items": 0}))
      env = ListRequestEnvStub.new(request, URI::Params.parse(""))
      err = Facet::HTTP::ListRequest.from_request(env).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "keeps known parameters and page=1 / items=25 accepted" do
      req = parse_body(%({"page": 1, "items": 25, "sort": ["-created_at", "id"], "filters": {"status__eq": "active"}}))
      req.page.should eq(1)
      req.items.should eq(25)
      req.sort.should eq(["-created_at", "id"])
      req.filters.should eq({"status__eq" => "active"})

      req = parse_query("page=1&items=25&sort=-created_at,id&filters[status__eq]=active")
      req.page.should eq(1)
      req.items.should eq(25)
      req.sort.should eq(["-created_at", "id"])
      req.filters.should eq({"status__eq" => "active"})
    end

    it "keeps the not-given forms on the default" do
      req = parse_body(%({"page": null, "items": null}))
      req.page.should eq(1)
      req.items.should eq(100)

      req = parse_query("page=&items=")
      req.page.should eq(1)
      req.items.should eq(100)
    end

    it "keeps the above-MAX_ITEMS clamp on items" do
      req = parse_body(%({"items": 5000}))
      req.items.should eq(1000)

      req = parse_query("items=5000")
      req.items.should eq(1000)
    end

    it "keeps the body page above the query page merge precedence" do
      request = HTTP::Request.new("GET", "/Api/test/Thing", body: %({"page": 2}))
      env = ListRequestEnvStub.new(request, URI::Params.parse("page=3"))
      req = Facet::HTTP::ListRequest.from_request(env).as(Facet::HTTP::ListRequest)
      req.page.should eq(3)
    end
  end
end
