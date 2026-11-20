# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"

HTTPTest.init

# `/Healthcheck` — liveness + dependency probe.
#
# Whitelisted in `AuthHandler::PUBLIC_ROUTES` (no auth) and outside
# `DomainGate` (no `/Api/:domain` prefix). Returns 200 with per-dependency
# status when everything is reachable, 503 when any backing service is down
# — including one degraded stream consumer.
describe "GET /Healthcheck" do
  before_each do
    # Consumer-health state is process-wide; isolate the probe assertions.
    Facet::Event::ConsumerHealth.reset
  end

  it "returns 200 with database, redis and events status" do
    request = HTTP::Request.new("GET", "/Healthcheck")
    response = call_api(request)

    assert_http_status(response, 200)
    body = JSON.parse(response.body)

    body["status"].as_s.should eq("ok")
    body["database"]["status"].as_s.should eq("ok")
    body["database"]["error"].raw.should be_nil
    body["redis"]["status"].as_s.should eq("in_process")
    body["redis"]["error"].raw.should be_nil
    # No stream consumers run under the InProcessManager.
    body["events"]["status"].as_s.should eq("in_process")
    body["events"]["consumers"].as_a.should be_empty
  end

  it "reports the service identity" do
    request = HTTP::Request.new("GET", "/Healthcheck")
    response = call_api(request)

    assert_http_status(response, 200)
    body = JSON.parse(response.body)
    body["service"]["instance_id"].as_s.should eq(Facet::Service.instance_id)
    body["service"]["instance_id"].as_s.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)
    body["service"]["env"].as_s.should eq(Facet::Service.app_env)
  end

  it "returns 503 with consumer detail when a stream consumer is degraded" do
    Facet::Event::ConsumerHealth.register("cg:spec:degraded")
    Facet::Event::ConsumerHealth.report_failure("cg:spec:degraded", RuntimeError.new("Connection refused"))

    begin
      request = HTTP::Request.new("GET", "/Healthcheck")
      response = call_api(request)

      assert_http_status(response, 503)
      body = JSON.parse(response.body)
      body["status"].as_s.should eq("degraded")
      body["events"]["status"].as_s.should eq("degraded")
      consumers = body["events"]["consumers"].as_a
      consumers.size.should eq(1)
      consumers[0]["name"].as_s.should eq("cg:spec:degraded")
      consumers[0]["consecutive_failures"].as_i.should eq(1)
      consumers[0]["last_error"].as_s.should eq("Connection refused")
    ensure
      Facet::Event::ConsumerHealth.unregister("cg:spec:degraded")
    end
  end

  it "returns 200 with a clean consumer registry" do
    Facet::Event::ConsumerHealth.register("cg:spec:healthy")
    Facet::Event::ConsumerHealth.report_success("cg:spec:healthy")

    begin
      request = HTTP::Request.new("GET", "/Healthcheck")
      response = call_api(request)

      assert_http_status(response, 200)
      body = JSON.parse(response.body)
      body["events"]["status"].as_s.should eq("in_process")
    ensure
      Facet::Event::ConsumerHealth.unregister("cg:spec:healthy")
    end
  end

  it "does not require authentication" do
    # Enable AuthHandler so the public-route whitelist is actually exercised.
    Facet::HTTP::AuthHandler.enabled = true

    begin
      request = HTTP::Request.new("GET", "/Healthcheck")
      response = call_api(request)
      assert_http_status(response, 200)
    ensure
      Facet::HTTP::AuthHandler.enabled = false
    end
  end
end

describe "GET /Healthcheck/live" do
  it "returns 200 with uptime and runs no dependency checks" do
    request = HTTP::Request.new("GET", "/Healthcheck/live")
    response = call_api(request)

    assert_http_status(response, 200)
    body = JSON.parse(response.body)
    body["status"].as_s.should eq("ok")
    body["uptime_seconds"].as_i.should be >= 0
    # No dependency sections — the liveness probe answers while the
    # process itself is alive, regardless of backing services.
    body.as_h.has_key?("database").should be_false
    body.as_h.has_key?("redis").should be_false
  end

  it "does not require authentication" do
    Facet::HTTP::AuthHandler.enabled = true

    begin
      request = HTTP::Request.new("GET", "/Healthcheck/live")
      response = call_api(request)
      assert_http_status(response, 200)
    ensure
      Facet::HTTP::AuthHandler.enabled = false
    end
  end
end
