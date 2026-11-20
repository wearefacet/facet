# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../../src/rbac"

# HTTP integration for the field aggregates `sum` / `avg` / `min` / `max`
# (introduced with the sum aggregate — see `doc/backend/http-layer.md` →
# Aggregate responses).
#
# Covers the wire contract end to end: the `{data: {value}, meta: {count,
# more}}` shape for numeric and money fields, the 422 validation errors,
# ETag distinctness per `field` (an aggregate over one field must never
# serve a 304 for an aggregate over another), mutation-driven
# invalidation, and child-list parity. The 503 statement-timeout mapping
# is exercised at the SQLSTATE level with a real `query_canceled`
# cancellation.
#
# Seeding goes through the HTTP layer (domain + doctype + documents) so the
# doctype definition cache, projection triggers, and collection versions all
# behave exactly as in production.
HTTPTest.init

def setup_sum_domain! : Nil
  resp = create_domain_http("sumtest")
  assert_http_status(resp, 201)
end

def setup_sum_doctypes! : Nil
  parent = %({
    "doctype": "SumTask",
    "domain": "sumtest",
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "duration": {"type": "integer"},
      "price": {"type": "money"},
      "label": {"type": "string"}
    },
    "children": {"entries": {"doctype": "SumEntry", "collection": true}}
  })
  resp = create_doctype_http(parent)
  assert_http_status(resp, 201)

  child = %({
    "doctype": "SumEntry",
    "domain": "sumtest",
    "aggregate_root": false,
    "member_of": "SumTask",
    "fields": {
      "elapsed": {"type": "duration"},
      "fee": {"type": "money"}
    }
  })
  resp = create_doctype_http(child)
  assert_http_status(resp, 201)
end

def create_sum_task(json_body : String) : String
  create_doc_id_http("sumtest", "SumTask", json_body)
end

def create_sum_entry(task_id : String, json_body : String) : String
  create_child_doc_id_http("sumtest", "SumTask", task_id, "entries", json_body)
end

# GET with arbitrary headers — mirrors the helper in `etag_spec.cr` for
# `If-None-Match` revalidation (uniquely named so both spec files can
# compile into one suite).
def get_sum_with_headers(path : String, headers : Hash(String, String) = {} of String => String) : HTTP::Client::Response
  h = HTTP::Headers.new
  headers.each { |k, v| h[k] = v }
  call_api(HTTP::Request.new("GET", path, headers: h))
end

describe "HTTP field aggregates (sum / avg / min / max)" do
  before_each do
    setup_sum_domain!
    setup_sum_doctypes!
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  it "sums an integer field end to end with the aggregate response shape" do
    create_sum_task(%({"duration": 30, "label": "a"}))
    create_sum_task(%({"duration": 45, "label": "b"}))

    resp = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=duration")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"]["value"].as_i.should eq(75)
    body["meta"]["count"].as_i.should eq(2)
    body["meta"]["more"].as_bool.should be_false
  end

  it "sums a money field into a per-currency bag of decimal strings" do
    create_sum_task(%({"price": {"value": "10.50", "currency": "USD"}, "label": "a"}))
    create_sum_task(%({"price": {"value": "100.00", "currency": "USD"}, "label": "b"}))
    create_sum_task(%({"price": {"value": "99.95", "currency": "EUR"}, "label": "c"}))

    resp = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=price")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    value = body["data"]["value"].as_h
    value.size.should eq(2)
    value["USD"].as_s.should eq("110.50")
    value["EUR"].as_s.should eq("99.95")
    body["meta"]["count"].as_i.should eq(3)
  end

  it "averages an integer field, emitting the exact PG decimal when fractional" do
    create_sum_task(%({"duration": 10, "label": "a"}))
    create_sum_task(%({"duration": 25, "label": "b"}))

    resp = list_documents_http("sumtest", "SumTask", "aggregate=avg&field=duration")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    # PG's avg(numeric) scale pads to 16 decimal digits; the string form is
    # exact and the spec pins it verbatim — no client-side rounding.
    body["data"]["value"].as_s.should eq("17.5000000000000000")
    body["meta"]["count"].as_i.should eq(2)
    body["meta"]["more"].as_bool.should be_false
  end

  it "returns min and max of an integer field as JSON numbers" do
    create_sum_task(%({"duration": 10, "label": "a"}))
    create_sum_task(%({"duration": 25, "label": "b"}))
    create_sum_task(%({"duration": 17, "label": "c"}))

    min_resp = list_documents_http("sumtest", "SumTask", "aggregate=min&field=duration")
    assert_http_status(min_resp, 200)
    parse_body(min_resp)["data"]["value"].as_i.should eq(10)

    max_resp = list_documents_http("sumtest", "SumTask", "aggregate=max&field=duration")
    assert_http_status(max_resp, 200)
    parse_body(max_resp)["data"]["value"].as_i.should eq(25)
  end

  it "returns max over a money field as a per-currency bag" do
    create_sum_task(%({"price": {"value": "10.50", "currency": "USD"}, "label": "a"}))
    create_sum_task(%({"price": {"value": "100.00", "currency": "USD"}, "label": "b"}))
    create_sum_task(%({"price": {"value": "99.95", "currency": "EUR"}, "label": "c"}))

    resp = list_documents_http("sumtest", "SumTask", "aggregate=max&field=price")
    assert_http_status(resp, 200)
    value = parse_body(resp)["data"]["value"].as_h
    value["USD"].as_s.should eq("100.00")
    value["EUR"].as_s.should eq("99.95")
  end

  it "returns value null for avg/min/max over an empty result set" do
    {"avg", "min", "max"}.each do |aggregate|
      resp = list_documents_http("sumtest", "SumTask", "aggregate=#{aggregate}&field=duration")
      assert_http_status(resp, 200)
      body = parse_body(resp)
      body["data"]["value"].raw.should be_nil
      body["meta"]["count"].as_i.should eq(0)
    end
  end

  it "returns 422 when aggregate=sum has no field" do
    resp = list_documents_http("sumtest", "SumTask", "aggregate=sum")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("field")
  end

  it "returns 422 for an unknown field" do
    resp = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=nope")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("Unknown field")
  end

  it "returns 422 for a non-numeric field" do
    resp = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=label")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("not a numeric field")
  end

  # B-358: `field` is only the target of the field aggregates — without
  # one (or with the field-free `count`), the parameter would vanish into
  # a 200.
  it "returns 422 when field rides without any aggregate" do
    resp = list_documents_http("sumtest", "SumTask", "field=duration")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("field=duration requires an aggregate parameter")
  end

  it "returns 422 when field rides with aggregate=count" do
    resp = list_documents_http("sumtest", "SumTask", "aggregate=count&field=duration")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("requires an aggregate parameter")
  end

  it "keeps aggregate and field working together through the QUERY door" do
    create_sum_task(%({"duration": 5, "label": "a"}))

    resp = call_api(HTTP::Request.new("QUERY", "/Api/sumtest/SumTask",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"aggregate": "sum", "field": "duration"})))
    assert_http_status(resp, 200)
    parse_body(resp)["data"]["value"].as_i.should eq(5)
  end

  # ── ETag correctness ────────────────────────────────────────────────

  it "returns a distinct ETag per field" do
    create_sum_task(%({"duration": 5, "price": {"value": "1.00", "currency": "USD"}, "label": "x"}))

    duration_resp = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=duration")
    price_resp = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=price")
    assert_http_status(duration_resp, 200)
    assert_http_status(price_resp, 200)
    duration_resp.headers["ETag"]?.should_not be_nil
    duration_resp.headers["ETag"].should_not eq(price_resp.headers["ETag"])
  end

  it "returns a distinct ETag from a plain list with otherwise-equal parameters" do
    create_sum_task(%({"duration": 5, "label": "x"}))

    plain_resp = list_documents_http("sumtest", "SumTask")
    sum_resp = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=duration")
    assert_http_status(plain_resp, 200)
    assert_http_status(sum_resp, 200)
    plain_resp.headers["ETag"].should_not eq(sum_resp.headers["ETag"])
  end

  it "serves 304 on a sum re-validated with its own ETag" do
    create_sum_task(%({"duration": 5, "label": "x"}))
    first = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=duration")
    assert_http_status(first, 200)
    etag = first.headers["ETag"]

    second = get_sum_with_headers(
      "/Api/sumtest/SumTask?aggregate=sum&field=duration",
      {"If-None-Match" => etag},
    )
    assert_http_status(second, 304)
    second.body.should eq("")
    second.headers["ETag"]?.should eq(etag)
  end

  it "does NOT serve 304 after a mutation — the sum and the ETag both change" do
    create_sum_task(%({"duration": 5, "label": "x"}))
    first = list_documents_http("sumtest", "SumTask", "aggregate=sum&field=duration")
    assert_http_status(first, 200)
    first.headers["ETag"]?.should_not be_nil
    etag = first.headers["ETag"]

    create_sum_task(%({"duration": 7, "label": "y"}))

    second = get_sum_with_headers(
      "/Api/sumtest/SumTask?aggregate=sum&field=duration",
      {"If-None-Match" => etag},
    )
    # The projection trigger bumps `updated_at`, so the collection version
    # — and with it the ETag — must move. A stale 304 would hide the new
    # document from the sum.
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag)
    second_body = JSON.parse(second.body)
    second_body["data"]["value"].as_i.should eq(12)
  end

  # ── Child-list parity ───────────────────────────────────────────────

  it "sums a child collection through the child-list route" do
    task_id = create_sum_task(%({"duration": 1, "label": "t"}))
    create_sum_entry(task_id, %({"elapsed": 10, "fee": {"value": "2.50", "currency": "USD"}}))
    create_sum_entry(task_id, %({"elapsed": 20, "fee": {"value": "3.50", "currency": "EUR"}}))

    resp = get_sum_with_headers("/Api/sumtest/SumTask/#{task_id}/entries?aggregate=sum&field=elapsed")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"]["value"].as_i.should eq(30)
    body["meta"]["count"].as_i.should eq(2)
    body["meta"]["more"].as_bool.should be_false
  end

  it "averages a child collection through the child-list route" do
    task_id = create_sum_task(%({"duration": 1, "label": "t"}))
    create_sum_entry(task_id, %({"elapsed": 10, "fee": {"value": "2.50", "currency": "USD"}}))
    create_sum_entry(task_id, %({"elapsed": 20, "fee": {"value": "3.50", "currency": "EUR"}}))

    resp = get_sum_with_headers("/Api/sumtest/SumTask/#{task_id}/entries?aggregate=avg&field=elapsed")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    # (10 + 20) / 2 is integral → emitted as a JSON number.
    body["data"]["value"].as_i.should eq(15)
    body["meta"]["count"].as_i.should eq(2)
    body["meta"]["more"].as_bool.should be_false
  end

  it "returns a distinct child ETag per field" do
    task_id = create_sum_task(%({"duration": 1, "label": "t"}))
    create_sum_entry(task_id, %({"elapsed": 10, "fee": {"value": "2.50", "currency": "USD"}}))

    elapsed_resp = get_sum_with_headers("/Api/sumtest/SumTask/#{task_id}/entries?aggregate=sum&field=elapsed")
    fee_resp = get_sum_with_headers("/Api/sumtest/SumTask/#{task_id}/entries?aggregate=sum&field=fee")
    assert_http_status(elapsed_resp, 200)
    assert_http_status(fee_resp, 200)
    elapsed_resp.headers["ETag"].should_not eq(fee_resp.headers["ETag"])
  end

  it "returns 422 on the child-list route when aggregate=sum has no field" do
    task_id = create_sum_task(%({"duration": 1, "label": "t"}))

    resp = get_sum_with_headers("/Api/sumtest/SumTask/#{task_id}/entries?aggregate=sum")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("field")
  end

  it "returns 422 on the child-list route when field rides without a field aggregate (B-358)" do
    task_id = create_sum_task(%({"duration": 1, "label": "t"}))

    resp = get_sum_with_headers("/Api/sumtest/SumTask/#{task_id}/entries?field=elapsed")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("requires an aggregate parameter")
  end

  # ── Statement-timeout mapping ───────────────────────────────────────

  describe "statement timeout → 503 mapping" do
    it "detects a query_canceled statement (SQLSTATE 57014) as a statement timeout" do
      DB.open(ENV.fetch("DATABASE_URL")) do |db|
        # A dedicated connection carries its own session budget; the suite
        # pool's 5s setting is untouched.
        db.exec("SET statement_timeout = 200")
        ex = expect_raises(PQ::PQError) do
          # pg_sleep(2) against a 200ms budget: a deterministic, 10x-margin
          # cancellation.
          db.exec("SELECT pg_sleep(2)")
        end
        Facet::HTTP::Helpers.statement_timeout?(ex).should be_true
      end
    end

    it "does not treat other PG errors as statement timeouts" do
      DB.open(ENV.fetch("DATABASE_URL")) do |db|
        ex = expect_raises(PQ::PQError) do
          db.exec("SELECT * FROM no_such_table_for_sum_spec")
        end
        Facet::HTTP::Helpers.statement_timeout?(ex).should be_false
      end
    end
  end
end
