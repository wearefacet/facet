# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "json"
require "../src/metrics"
require "../src/http/server"
require "./support/http_helper"

HTTPTest.init

# Parses the value of one exposition series out of a rendered body.
# `key` is the full sample prefix, e.g. `metric{label="value"}`.
private def series_value(body : String, key : String) : Float64?
  body.each_line.find(&.starts_with?(key)).try(&.split(' ').last.to_f)
end

describe Facet::Metrics do
  before_each do
    Facet::Metrics.reset
  end

  describe "registry" do
    it "increments an unlabeled counter from zero" do
      Facet::Metrics.value("facet_spec_total").should eq(0.0)

      Facet::Metrics.inc("facet_spec_total")
      Facet::Metrics.inc("facet_spec_total", by: 4)

      Facet::Metrics.value("facet_spec_total").should eq(5.0)
    end

    it "isolates series by label set" do
      Facet::Metrics.inc("facet_spec_labeled_total", {"kind" => "a"})
      Facet::Metrics.inc("facet_spec_labeled_total", {"kind" => "b"}, by: 2)
      Facet::Metrics.inc("facet_spec_labeled_total", {"kind" => "a"})

      Facet::Metrics.value("facet_spec_labeled_total", {"kind" => "a"}).should eq(2.0)
      Facet::Metrics.value("facet_spec_labeled_total", {"kind" => "b"}).should eq(2.0)
      Facet::Metrics.value("facet_spec_labeled_total", {"kind" => "c"}).should eq(0.0)
    end

    it "sets a gauge to an absolute value" do
      Facet::Metrics.set("facet_spec_gauge", 7)
      Facet::Metrics.value("facet_spec_gauge").should eq(7.0)
      Facet::Metrics.set("facet_spec_gauge", 2.5)
      Facet::Metrics.value("facet_spec_gauge").should eq(2.5)
    end

    it "resets every series" do
      Facet::Metrics.inc("facet_spec_total")
      Facet::Metrics.set("facet_spec_gauge", 3, {"name" => "x"})
      Facet::Metrics.reset
      Facet::Metrics.value("facet_spec_total").should eq(0.0)
      Facet::Metrics.value("facet_spec_gauge", {"name" => "x"}).should eq(0.0)
    end
  end

  describe "render" do
    it "emits HELP and TYPE pairs from the catalog and sorted samples" do
      Facet::Metrics.inc("facet_events_published_total")
      Facet::Metrics.inc("facet_spec_unknown_total", by: 9)

      body = Facet::Metrics.render

      body.should contain("# HELP facet_events_published_total Resource events written to the Redis streams by this process.")
      body.should contain("# TYPE facet_events_published_total counter")
      body.should contain("facet_events_published_total 1\n")

      # Catalog-less names still render, as counters with a generic help.
      body.should contain("# HELP facet_spec_unknown_total (undocumented metric)")
      body.should contain("facet_spec_unknown_total 9\n")

      # Names render in sorted order (events < spec name).
      lines = body.split('\n')
      spec_index = lines.index! { |l| l.starts_with?("facet_spec_unknown_total 9") }
      events_index = lines.index! { |l| l.starts_with?("facet_events_published_total 1") }
      events_index.should be < spec_index
    end

    it "sorts series by label set and escapes label values" do
      Facet::Metrics.inc("facet_spec_esc_total", {"kind" => "b"})
      Facet::Metrics.inc("facet_spec_esc_total", {"kind" => "a\"x\\y"})
      Facet::Metrics.inc("facet_spec_esc_total", {"kind" => "a\nb"})

      body = Facet::Metrics.render
      lines = body.split('\n').select(&.starts_with?("facet_spec_esc_total{"))

      # Sorted by the rendered label set (the escaped form defines order).
      lines[0].should eq("facet_spec_esc_total{kind=\"a\\\"x\\\\y\"} 1")
      lines[1].should eq("facet_spec_esc_total{kind=\"a\\nb\"} 1")
      lines[2].should eq("facet_spec_esc_total{kind=\"b\"} 1")
    end

    it "renders integer values without a decimal point" do
      Facet::Metrics.set("facet_spec_gauge", 2.5)
      Facet::Metrics.inc("facet_spec_total", by: 3)

      body = Facet::Metrics.render
      body.should contain("facet_spec_gauge 2.5\n")
      body.should contain("facet_spec_total 3\n")
    end
  end
end

describe "GET /metrics" do
  it "returns 200 with the Prometheus exposition content type" do
    Facet::Metrics.reset
    request = HTTP::Request.new("GET", "/metrics")
    response = call_api(request)

    assert_http_status(response, 200)
    response.headers["Content-Type"].should contain("text/plain")
    response.body.should contain("# TYPE facet_event_lag_max gauge")
    # Scrape-time gauges render even with no recorded counters.
    response.body.should contain("facet_event_lag_max 0\n")
  end

  it "does not require authentication" do
    Facet::HTTP::AuthHandler.enabled = true

    begin
      request = HTTP::Request.new("GET", "/metrics")
      response = call_api(request)
      assert_http_status(response, 200)
    ensure
      Facet::HTTP::AuthHandler.enabled = false
    end
  end

  it "counts handled requests by method, route group, and status class" do
    Facet::Metrics.reset
    before = series_value(call_api(HTTP::Request.new("GET", "/metrics")).body,
      "facet_http_requests_total{method=\"GET\",route=\"/metrics\",status_class=\"2xx\"}") || 0.0

    call_api(HTTP::Request.new("GET", "/metrics"))

    after = series_value(call_api(HTTP::Request.new("GET", "/metrics")).body,
      "facet_http_requests_total{method=\"GET\",route=\"/metrics\",status_class=\"2xx\"}").not_nil!
    (after - before).should eq(2.0)
  end

  it "collapses unknown first path segments into other" do
    Facet::Metrics.reset
    call_api(HTTP::Request.new("GET", "/no-such-prefix/deep/path"))

    body = call_api(HTTP::Request.new("GET", "/metrics")).body
    series_value(body, "facet_http_requests_total{method=\"GET\",route=\"other\",status_class=\"4xx\"}").should eq(1.0)
  end
end
