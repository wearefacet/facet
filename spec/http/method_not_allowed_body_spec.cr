# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/http/helpers"
require "../../src/http/json_error_handler"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# B-175 — the JSON 405 body names the allowed methods. The header carried
# the `Allow` set already; API consumers that read only the JSON error body
# get the fix from the body now. The concrete trigger is a `PUT` on a
# document route (`/Api/:domain/:doctype/:id` answers PATCH, not PUT).

# Raises the given exception from a terminal handler placed after the error
# handler — the same shape a router miss takes in production.
private class RaiseExHandler
  include HTTP::Handler

  def initialize(@ex : ::Exception); end

  def call(context : HTTP::Server::Context)
    raise @ex
  end
end

# Drives the handler chain [JsonErrorHandler → RaiseExHandler] on a fresh
# context and returns the raw response.
private def render_through_error_handler(ex : ::Exception) : HTTP::Client::Response
  error_handler = Facet::HTTP::JsonErrorHandler.new
  error_handler.next = RaiseExHandler.new(ex)

  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(HTTP::Request.new("PUT", "/Api/core/DocumentView/view-1"), response)
  error_handler.call(context)
  response.close rescue nil
  io.rewind
  HTTP::Client::Response.from_io(io, decompress: false)
end

describe Facet::HTTP::JsonErrorHandler do
  describe "method-not-allowed body (B-175)" do
    it "names the allowed methods in the 405 body" do
      ex = Kemal::Exceptions::MethodNotAllowed.new(
        HTTP::Server::Context.new(HTTP::Request.new("PUT", "/Api/core/DocumentView/view-1"), HTTP::Server::Response.new(IO::Memory.new)),
        ["GET", "HEAD", "PATCH", "DELETE"]
      )

      response = render_through_error_handler(ex)

      response.status_code.should eq(405)
      response.headers["Allow"].should eq("GET, HEAD, PATCH, DELETE")
      parsed = JSON.parse(response.body)
      parsed["error"].as_s.should contain("Method not allowed")
      parsed["error"].as_s.should contain("PATCH")
      parsed["error"].as_s.should eq("Method not allowed. Allowed: GET, HEAD, PATCH, DELETE")
    end

    it "keeps the bare body when the router reports no allowed methods" do
      ex = Kemal::Exceptions::MethodNotAllowed.new(
        HTTP::Server::Context.new(HTTP::Request.new("PUT", "/Api/core/DocumentView/view-1"), HTTP::Server::Response.new(IO::Memory.new)),
        [] of String
      )

      response = render_through_error_handler(ex)

      response.status_code.should eq(405)
      response.headers["Allow"]?.should be_nil
      JSON.parse(response.body)["error"].as_s.should eq("Method not allowed")
    end
  end

  describe "PUT on a DocumentView route (end to end, B-175)" do
    it "answers 405 naming PATCH, and PATCH stays the working door" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        # The core domain row rides the seed corpus — re-create it after the
        # per-example truncate so the DocumentView parent reference passes
        # the authoring-time existence check.
        Facet::Mutation::Client.create(
          db, "core", "Domain",
          doc_id: "core",
          content: %({"description": "core domain"}),
          actioner_id: "system:test",
        )

        # One live DocumentView under a freshly registered `core.Widget`
        # doctype — the flat document routes serve it the same way they
        # serve the seeded views.
        Facet::Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "core.Widget",
          content: %({"doctype": "Widget", "domain": "core", "schema_version": 1, "fields": {"name": {"type": "string"}}}),
          meta: %({"parent_id": "core"}),
          actioner_id: "system:test",
        )
        Facet::Mutation::Client.create(
          db, "core", "DocumentView",
          content: %({"parent_doctype": "core.Widget", "kind": "view", "template": {"layout": "single"}}),
          meta: %({"parent_id": "core.Widget"}),
          actioner_id: "system:test",
        )
        view_id = db.query_one(
          "SELECT id FROM projections WHERE domain = 'core' AND doc_type = 'DocumentView' AND deleted_at IS NULL AND meta->>'parent_id' = 'core.Widget'",
          as: String,
        )

        put_response = call_api(HTTP::Request.new("PUT", "/Api/core/DocumentView/#{view_id}", nil, %({"kind": "form"})))
        put_response.status_code.should eq(405)
        put_response.headers["Allow"]?.try(&.includes?("PATCH")).should be_true
        body = JSON.parse(put_response.body)["error"].as_s
        body.should contain("Method not allowed")
        body.should contain("PATCH")

        patch_response = call_api(HTTP::Request.new("PATCH", "/Api/core/DocumentView/#{view_id}", nil, %({"kind": "form"})))
        patch_response.status_code.should eq(200)
      end
    end
  end
end
