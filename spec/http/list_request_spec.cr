# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "http"
require "digest"
require "../../src/http/list_request"

alias LR = Facet::HTTP::ListRequest

# Minimal stand-in for the Kemal request context. `ListRequest.from_request`
# is untyped and only reads `env.request.body` and `env.params.query`, so the
# stub mirrors exactly that surface.
private class ListEnvStub
  getter request : HTTP::Request
  getter params : Params

  def initialize(body : String?, query : String)
    @request = HTTP::Request.new("GET", "/Api/test/Thing", body: body)
    @params = Params.new(URI::Params.parse(query))
  end

  class Params
    getter query : URI::Params

    def initialize(@query)
    end
  end
end

# `ListRequest.from_json` returns `ListRequest | Facet::ServiceError`
# (B-100): a `sort` / `select` value with the wrong shape answers 422. The
# happy-path examples below expect the parsed request, so they narrow
# through this helper — the cast fails loud when a ServiceError shows up.
private def json_request(body : String) : Facet::HTTP::ListRequest
  LR.from_json(body).as(Facet::HTTP::ListRequest)
end

# `ListRequest.from_query` returns `ListRequest | Facet::ServiceError`
# (B-158): a sort entry outside the field shape answers 422. The happy-path
# examples below narrow through this helper — the cast fails loud when a
# ServiceError shows up.
private def query_request(params : URI::Params) : Facet::HTTP::ListRequest
  LR.from_query(params).as(Facet::HTTP::ListRequest)
end

describe Facet::HTTP::ListRequest do
  # ── JSON parsing ──────────────────────────────────────────────────

  describe ".from_json" do
    it "uses defaults when body is empty" do
      req = json_request("{}")
      req.page.should eq(1)
      req.items.should eq(100)
      req.filters.should be_empty
      req.sort.should eq(["id"])
    end

    it "parses a full JSON object" do
      json = %({
        "page": 2,
        "items": 50,
        "filters": { "status__eq": "active", "age__gt": 18 },
        "sort": ["-created_at", "id"]
      })
      req = json_request(json)
      req.page.should eq(2)
      req.items.should eq(50)
      req.filters.should eq({"status__eq" => "active", "age__gt" => 18})
      req.sort.should eq(["-created_at", "id"])
    end

    # Below-range `page` / `items` is the B-169 residual: a present,
    # well-shaped value below 1 answers 422 — the parser never clamps a
    # caller error into the first page.
    it "answers 422 for a body page below 1" do
      ["0", "-5"].each do |raw|
        err = LR.from_json(%({"page": #{raw}})).as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Parameter 'page'")
      end
    end

    it "clamps items above 1000 and answers 422 below 1" do
      req = json_request(%({"items": 9999}))
      req.items.should eq(1000)

      err = LR.from_json(%({"items": 0})).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "accepts string numbers in JSON" do
      req = json_request(%({"page": "2", "items": "50"}))
      req.page.should eq(2)
      req.items.should eq(50)
    end

    it "defaults sort to [\"id\"] when missing" do
      req = json_request(%({"page": 1}))
      req.sort.should eq(["id"])
    end

    it "handles empty filters" do
      req = json_request(%({"filters": {}}))
      req.filters.should be_empty
    end
  end

  # ── sort / select shape gate (B-100) ────────────────────────────

  # A parseable body whose `sort` or `select` value is not an array of
  # strings is a caller error: it answers 422 through the same
  # ServiceError channel the B-59 body-shape gate uses — never a 500 from
  # `JSON::Any#as_a`.
  describe ".from_json sort/select shape gate" do
    it "answers 422 when sort is a string" do
      result = LR.from_json(%({"sort": "name"}))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("sort must be an array of strings")
    end

    it "answers 422 when sort holds a non-string element" do
      result = LR.from_json(%({"sort": ["name", 5]}))
      result.as(Facet::ServiceError).status.should eq(422)
    end

    it "answers 422 when select is a string" do
      result = LR.from_json(%({"select": "name"}))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("select must be an array of strings")
    end

    it "answers 422 when select holds a non-string element" do
      result = LR.from_json(%({"select": ["name", true]}))
      result.as(Facet::ServiceError).status.should eq(422)
    end

    it "surfaces the 422 through .from_request" do
      result = LR.from_request(ListEnvStub.new(%({"sort": "name"}), ""))
      result.as(Facet::ServiceError).status.should eq(422)
    end
  end

  # ── Query-string parsing ──────────────────────────────────────────

  describe ".from_query" do
    it "uses defaults when no params are given" do
      params = URI::Params.parse("")
      req = query_request(params)
      req.page.should eq(1)
      req.items.should eq(100)
      req.filters.should be_empty
      req.sort.should eq(["id"])
    end

    it "parses page, items, and sort" do
      params = URI::Params.parse("page=3&items=25&sort=-name,id")
      req = query_request(params)
      req.page.should eq(3)
      req.items.should eq(25)
      req.sort.should eq(["-name", "id"])
    end

    it "parses repeated sort params" do
      params = URI::Params.parse("sort=-created_at&sort=id")
      req = query_request(params)
      req.sort.should eq(["-created_at", "id"])
    end

    it "parses filters with bracket notation" do
      params = URI::Params.parse("filters[status__eq]=active&filters[age__gt]=18")
      req = query_request(params)
      req.filters.should eq({"status__eq" => "active", "age__gt" => "18"})
    end

    it "decodes a JSON-array filter value into an array" do
      payload = ["USD 25000", "USD 100000"].to_json
      params = URI::Params.parse("filters[value__between]=#{payload}")
      req = query_request(params)
      req.filters["value__between"].as_a.map(&.as_s).should eq(["USD 25000", "USD 100000"])
    end

    it "keeps a raw string for a [ value that is not valid JSON" do
      params = URI::Params.parse("filters[title__eq]=[untitled]")
      req = query_request(params)
      req.filters["title__eq"].as_s.should eq("[untitled]")
    end

    it "keeps scalar filter values as strings (no JSON number decode)" do
      params = URI::Params.parse("filters[age__gt]=18")
      req = query_request(params)
      req.filters["age__gt"].as_s.should eq("18")
    end

    it "answers 422 for a query page below 1 and clamps items above 1000" do
      err = LR.from_query(URI::Params.parse("page=-1&items=2000")).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'page'")

      req = query_request(URI::Params.parse("items=2000"))
      req.items.should eq(1000)
    end

    it "defaults sort to [\"id\"] when sort is empty" do
      params = URI::Params.parse("sort=")
      req = query_request(params)
      req.sort.should eq(["id"])
    end
  end

  # ── `aggregate` parameter ────────────────────────────────────────

  describe "aggregate" do
    it "is nil by default on .from_json" do
      req = json_request("{}")
      req.aggregate.should be_nil
    end

    it "parses aggregate from JSON body" do
      req = json_request(%({"aggregate": "count"}))
      req.aggregate.should eq("count")
    end

    it "parses aggregate from query string" do
      params = URI::Params.parse("aggregate=count")
      req = query_request(params)
      req.aggregate.should eq("count")
    end

    it "treats empty aggregate query value as nil" do
      params = URI::Params.parse("aggregate=")
      req = query_request(params)
      req.aggregate.should be_nil
    end

    # The aggregate value is NOT validated at the ListRequest layer — it is
    # surfaced verbatim so `Document::List` can reject unknown values with
    # 422. This keeps the validation single-sourced in the service layer.
    it "does not reject unknown aggregate values at parse time" do
      params = URI::Params.parse("aggregate=sum")
      req = query_request(params)
      req.aggregate.should eq("sum")
    end

    # Critical: a count request and a normal list request with the same
    # filters must NOT share an ETag. Otherwise a client fetching the data
    # after a count would get a 304 with no body.
    it "includes aggregate in to_json so it affects the ETag fingerprint" do
      base = query_request(URI::Params.parse("filters[status__eq]=active"))
      count = query_request(URI::Params.parse("filters[status__eq]=active&aggregate=count"))
      base.to_json.should_not eq(count.to_json)
      count.to_json.should contain("\"aggregate\":\"count\"")
      base.to_json.should_not contain("\"aggregate\"")
    end
  end

  # ── `field` parameter ────────────────────────────────────────

  describe "field" do
    it "is nil by default on .from_json" do
      req = json_request("{}")
      req.field.should be_nil
    end

    it "parses field from JSON body" do
      req = json_request(%({"aggregate": "sum", "field": "duration"}))
      req.field.should eq("duration")
    end

    it "parses field from query string" do
      params = URI::Params.parse("aggregate=sum&field=duration")
      req = query_request(params)
      req.field.should eq("duration")
    end

    it "treats empty field query value as nil" do
      params = URI::Params.parse("field=")
      req = query_request(params)
      req.field.should be_nil
    end

    # Mirrors `aggregate`: the parse layer surfaces the value verbatim.
    # Field existence and numeric type are validated by the service layer.
    it "does not validate the field name at parse time" do
      params = URI::Params.parse("field=parent.child")
      req = query_request(params)
      req.field.should eq("parent.child")
    end

    describe ".from_request merge precedence" do
      it "prefers the query string over the body" do
        env = ListEnvStub.new(
          body: "{\"aggregate\": \"sum\", \"field\": \"amount\"}",
          query: "aggregate=sum&field=duration",
        )
        req = LR.from_request(env).as(LR)
        req.aggregate.should eq("sum")
        req.field.should eq("duration")
      end

      it "falls back to the body when the query omits field" do
        env = ListEnvStub.new(
          body: "{\"aggregate\": \"sum\", \"field\": \"duration\"}",
          query: "",
        )
        req = LR.from_request(env).as(LR)
        req.field.should eq("duration")
      end

      it "uses query-only requests when no body is present" do
        env = ListEnvStub.new(nil, "aggregate=sum&field=duration")
        req = LR.from_request(env).as(LR)
        req.field.should eq("duration")
      end
    end

    # Critical, same as `aggregate`: two sums over different fields must not
    # share an ETag, so the canonical form (which feeds
    # `Helpers.list_request_fingerprint`) carries `field` when set.
    it "includes field in to_json so it affects the ETag fingerprint" do
      sum_a = query_request(URI::Params.parse("filters[status__eq]=active&aggregate=sum&field=duration"))
      sum_b = query_request(URI::Params.parse("filters[status__eq]=active&aggregate=sum&field=amount"))
      sum_a.to_json.should_not eq(sum_b.to_json)
      sum_a.to_json.should contain("\"field\":\"duration\"")
    end

    it "produces different fingerprints for different field values" do
      a = query_request(URI::Params.parse("aggregate=sum&field=duration"))
      b = query_request(URI::Params.parse("aggregate=sum&field=amount"))
      Digest::SHA256.hexdigest(a.to_json).should_not eq(Digest::SHA256.hexdigest(b.to_json))
    end

    # No digest churn for existing clients: a request without `field`
    # serializes exactly as before.
    it "omits field from to_json when absent" do
      req = query_request(URI::Params.parse("filters[status__eq]=active"))
      req.to_json.should_not contain("field")
    end
  end

  # ── `deleted` flag ────────────────────────────────────────────

  describe "deleted flag" do
    it "is false by default on .from_json" do
      req = json_request("{}")
      req.include_deleted?.should be_false
    end

    it "parses deleted=true from JSON body" do
      req = json_request(%({"deleted": true}))
      req.include_deleted?.should be_true
    end

    it "parses deleted=true from query string" do
      params = URI::Params.parse("deleted=true")
      req = query_request(params)
      req.include_deleted?.should be_true
    end

    it "stays off for any non-true query value" do
      {"", "false", "1", "TRUE"}.each do |value|
        params = URI::Params.parse("deleted=#{value}")
        query_request(params).include_deleted?.should be_false
      end
    end

    it "prefers the query string over the body" do
      env = ListEnvStub.new(
        body: "{}",
        query: "deleted=true",
      )
      LR.from_request(env).as(LR).include_deleted?.should be_true
    end

    it "falls back to the body when the query omits deleted" do
      env = ListEnvStub.new(
        body: "{\"deleted\": true}",
        query: "",
      )
      LR.from_request(env).as(LR).include_deleted?.should be_true
    end

    # Critical, same as `aggregate` / `field`: the trash listing and the live
    # listing must never share an ETag. Without the flag the canonical form
    # serializes exactly as before (no digest churn for existing clients).
    it "includes deleted in to_json so it affects the ETag fingerprint" do
      live = query_request(URI::Params.parse("filters[status__eq]=active"))
      trash = query_request(URI::Params.parse("filters[status__eq]=active&deleted=true"))
      live.to_json.should_not eq(trash.to_json)
      trash.to_json.should contain("\"deleted\":true")
      live.to_json.should_not contain("deleted")
    end
  end

  # ── `scope` parameter ─────────────────────────────────────────

  describe "scope" do
    it "is nil by default on .from_json" do
      req = json_request("{}")
      req.scope.should be_nil
    end

    it "parses scope from JSON body" do
      req = json_request(%({"scope": "mine"}))
      req.scope.should eq("mine")
    end

    it "parses scope from query string" do
      params = URI::Params.parse("scope=mine")
      req = query_request(params)
      req.scope.should eq("mine")
    end

    it "treats empty scope query value as nil" do
      params = URI::Params.parse("scope=")
      req = query_request(params)
      req.scope.should be_nil
    end

    # Same contract as `aggregate` / `field`: the parse layer surfaces the
    # value verbatim; `Document::List` validates the name against the
    # doctype's declared scopes (422 on an unknown name).
    it "does not validate the scope name at parse time" do
      params = URI::Params.parse("scope=nope")
      req = query_request(params)
      req.scope.should eq("nope")
    end

    it "prefers the query string over the body" do
      env = ListEnvStub.new(
        body: "{\"scope\": \"mine\"}",
        query: "scope=team",
      )
      LR.from_request(env).as(LR).scope.should eq("team")
    end

    it "falls back to the body when the query omits scope" do
      env = ListEnvStub.new(
        body: "{\"scope\": \"mine\"}",
        query: "",
      )
      LR.from_request(env).as(LR).scope.should eq("mine")
    end

    # Critical, same as `aggregate` / `field` / `deleted`: a scoped request
    # narrows the result set, so a scoped request and its unscoped form
    # must never share an ETag.
    it "includes scope in to_json so it affects the ETag fingerprint" do
      unscoped = query_request(URI::Params.parse("filters[status__eq]=active"))
      scoped = query_request(URI::Params.parse("filters[status__eq]=active&scope=mine"))
      unscoped.to_json.should_not eq(scoped.to_json)
      scoped.to_json.should contain("\"scope\":\"mine\"")
      unscoped.to_json.should_not contain("scope")
    end
  end

  # ── Body-shape gate (B-59 sibling) ────────────────────────────────

  # A present body must parse as JSON and be a JSON object. Before the
  # gate, any other shape escaped the parser as a 500 (a `JSON::Any` hash
  # access on an array / scalar, or an unrescued `JSON::ParseException`).
  describe ".from_request body-shape gate" do
    it "answers 422 for a JSON-array body" do
      result = LR.from_request(ListEnvStub.new("[1]", ""))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("Body must be a JSON object (got array)")
    end

    it "answers 422 for a JSON-string body" do
      result = LR.from_request(ListEnvStub.new(%("x"), ""))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("Body must be a JSON object (got string)")
    end

    it "answers 422 for a body that is not valid JSON" do
      result = LR.from_request(ListEnvStub.new("=", ""))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Invalid JSON body")
    end

    it "still parses a valid object body" do
      req = LR.from_request(ListEnvStub.new(%({"page": 2}), "")).as(LR)
      req.page.should eq(2)
    end
  end

  # ── Sort shape gate (B-158) ──────────────────────────────────

  # A sort entry outside SORT_FIELD_RE used to drop silently and fall back
  # to `["id"]` — a caller typo vanished behind the default order. The
  # shape gate now answers 422 through the same ServiceError channel the
  # B-100 array-shape gate uses; nothing drops.
  describe "sort shape gate" do
    it "answers 422 naming the entry when a sort entry holds specials" do
      result = LR.from_json(%({"sort": ["id; DROP", "created_at", "../etc"]}))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("'id; DROP'")
    end

    it "answers 422 for a bare `-`" do
      err = LR.from_json(%({"sort": ["-"]})).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("'-'")
    end

    it "answers 422 for an empty string entry" do
      LR.from_json(%({"sort": [""]})).as(Facet::ServiceError).status.should eq(422)
    end

    it "answers 422 for uppercase letters, spaces, and specials" do
      {"CreatedAt", "sort field", "foo@bar"}.each do |entry|
        err = LR.from_json(%({"sort": ["#{entry}"]})).as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("'#{entry}'")
      end
    end

    it "keeps entries inside the shape" do
      req = json_request(%({"sort": ["my_field", "nested.field"]}))
      req.sort.should eq(["my_field", "nested.field"])
    end

    it "keeps a leading `-` for descending" do
      req = json_request(%({"sort": ["-score", "id"]}))
      req.sort.should eq(["-score", "id"])
    end

    it "defaults an empty sort array to [\"id\"]" do
      req = json_request(%({"sort": []}))
      req.sort.should eq(["id"])
    end

    it "surfaces the 422 through .from_request (body)" do
      result = LR.from_request(ListEnvStub.new(%({"sort": ["Foo!"]}), ""))
      result.as(Facet::ServiceError).status.should eq(422)
    end

    it "answers 422 for query-string junk the same way" do
      # A raw `;` is a query-pair separator (not part of the sort value), so
      # the junk entry must ride the value URL-encoded.
      result = LR.from_query(URI::Params.parse("sort=-name,id%3B%20DROP,../etc"))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("'id; DROP'")
    end

    it "surfaces the 422 through .from_request (query)" do
      result = LR.from_request(ListEnvStub.new(nil, "sort=Foo!"))
      result.as(Facet::ServiceError).status.should eq(422)
    end

    it "keeps the [\"id\"] default when sort is absent" do
      req = query_request(URI::Params.parse(""))
      req.sort.should eq(["id"])
    end
  end

  # ── page/items integer gate (B-169) ───────────────────────────

  # A present but non-numeric `page` / `items` used to fall back to the
  # default — the same silent-drop class as the B-158 sort bug. The parser
  # now answers 422 naming the parameter. A well-shaped value below 1 is
  # the B-169 residual and answers 422 the same way. Only garbage input
  # fails: the above-MAX_ITEMS clamp stays, an empty query value keeps the
  # default, and JSON `null` keeps the default.
  describe "page/items integer gate" do
    it "answers 422 naming 'items' when body items is a non-numeric string" do
      err = LR.from_json(%({"items": "abc"})).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "answers 422 naming 'page' when body page is a non-numeric string" do
      err = LR.from_json(%({"page": "abc"})).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'page'")
    end

    it "answers 422 for a wrong-typed body page (bool, array, object)" do
      bodies = [%({"page": true}), %({"page": [1]}), %({"page": {"n": 1}})]
      bodies.each do |body|
        err = LR.from_json(body).as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Parameter 'page'")
      end
    end

    it "answers 422 for a wrong-typed body items (bool, array, object)" do
      bodies = [%({"items": false}), %({"items": ["5"]}), %({"items": []})]
      bodies.each do |body|
        err = LR.from_json(body).as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Parameter 'items'")
      end
    end

    # Pinned: JSON `null` meant "use the default" before the gate, and it
    # still does — only a wrong-typed non-null value is an error.
    it "keeps the default for JSON null page and items" do
      req = json_request(%({"page": null, "items": null}))
      req.page.should eq(1)
      req.items.should eq(100)
    end

    # Pinned: numeric strings parsed before the gate and still parse.
    it "keeps numeric strings in the body accepted" do
      req = json_request(%({"page": "3", "items": "25"}))
      req.page.should eq(3)
      req.items.should eq(25)
    end

    # Pinned: extract_int truncates a JSON number with a fraction.
    it "keeps a JSON number with a fraction accepted (truncated)" do
      req = json_request(%({"items": 25.9}))
      req.items.should eq(25)
    end

    # A JSON number outside the Int32 range used to raise OverflowError
    # past the parser — a 500. It now joins the same 422 channel as every
    # other unconvertible shape, matching the query path (a huge numeric
    # string fails String#to_i? there the same way).
    it "answers 422 for a body page outside the Int32 range" do
      err = LR.from_json(%({"page": 1099511627776})).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'page'")
    end

    it "answers 422 for a body items outside the Int32 range" do
      err = LR.from_json(%({"items": 1099511627776})).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "answers 422 for a body float outside the Int32 range" do
      err = LR.from_json(%({"items": 1e40})).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "answers 422 for a huge numeric string in the body (query-path parity)" do
      err = LR.from_json(%({"items": "1099511627776"})).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "answers 422 for a huge query value" do
      err = LR.from_query(URI::Params.parse("items=1099511627776")).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    # Boundary: Int32::MAX itself fits — items clamps, page keeps the value.
    it "keeps the Int32 boundary accepted (clamped, not errored)" do
      req = json_request(%({"items": 2147483647}))
      req.items.should eq(1000)

      req = json_request(%({"page": 2147483647}))
      req.page.should eq(2147483647)
    end

    it "answers 422 naming 'items' when query items is not an integer" do
      err = LR.from_query(URI::Params.parse("items=abc")).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "answers 422 naming 'page' when query page is not an integer" do
      err = LR.from_query(URI::Params.parse("page=abc")).as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'page'")
    end

    it "answers 422 for query values that are not integer text" do
      ["page=3.5", "items=1_0", "items=12ab"].each do |qs|
        err = LR.from_query(URI::Params.parse(qs)).as(Facet::ServiceError)
        err.status.should eq(422)
      end
    end

    # Pinned: String#to_i? skips surrounding whitespace, so an encoded
    # " 2 " parsed before the gate and still parses.
    it "keeps a query value with surrounding whitespace accepted" do
      req = query_request(URI::Params.parse("page=%202%20"))
      req.page.should eq(2)
    end

    # Empty query values are the "not given" form — they keep the default.
    it "keeps the default for an empty query page and items" do
      req = query_request(URI::Params.parse("page=&items="))
      req.page.should eq(1)
      req.items.should eq(100)
    end

    it "surfaces the query 422 through .from_request" do
      result = LR.from_request(ListEnvStub.new(nil, "items=abc"))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    it "surfaces the body 422 through .from_request" do
      result = LR.from_request(ListEnvStub.new(%({"items": "abc"}), ""))
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Parameter 'items'")
    end

    # Regression: valid page, items, and sort still parse on both transports.
    it "keeps valid page, items, and sort working" do
      req = query_request(URI::Params.parse("page=2&items=50&sort=-updated_at"))
      req.page.should eq(2)
      req.items.should eq(50)
      req.sort.should eq(["-updated_at"])

      req = json_request(%({"page": 2, "items": 50, "sort": ["-updated_at"]}))
      req.page.should eq(2)
      req.items.should eq(50)
      req.sort.should eq(["-updated_at"])
    end

    # Regression: the above-MAX_ITEMS clamp is not an error; a below-1
    # value now is (the B-169 residual).
    it "keeps the above-MAX_ITEMS clamp and errors below 1" do
      req = query_request(URI::Params.parse("items=2000"))
      req.items.should eq(1000)

      req = json_request(%({"items": 2000}))
      req.items.should eq(1000)

      err = LR.from_query(URI::Params.parse("page=-1")).as(Facet::ServiceError)
      err.status.should eq(422)

      err = LR.from_json(%({"page": -1})).as(Facet::ServiceError)
      err.status.should eq(422)
    end
  end

  # ── Accessor semantics ────────────────────────────────────────────

  describe "instance properties" do
    it "exposes page, items, filters, sort" do
      req = LR.new(3, 25, {"a" => JSON::Any.new("b")}, ["-x"])
      req.page.should eq(3)
      req.items.should eq(25)
      req.filters.should eq({"a" => "b"})
      req.sort.should eq(["-x"])
    end
  end
end
