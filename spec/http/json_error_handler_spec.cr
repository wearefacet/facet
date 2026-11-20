# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/helpers"
require "../../src/mcp"
require "../../src/http/json_error_handler"

# Raises the given exception from a terminal handler placed after the error
# handler — the same shape a route failure takes in production.
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
  context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/spec/json_error_handler"), response)
  error_handler.call(context)
  response.close rescue nil
  io.rewind
  HTTP::Client::Response.from_io(io, decompress: false)
end

# Produces a real 23505 on `idx_mutations_doc_id_idx`: row 1 lands at idx 1
# via the trigger, row 2 pins idx 1 through `harness.explicit_mutation_idx`
# and collides with the committed row 1 — the violation the
# concurrent-create race raises.
private def idx_conflict_error : PQ::PQError
  insert_row = <<-SQL
    INSERT INTO mutations (
      domain, doc_type, id, doc_id, action, actioner_id, arguments,
      channel, cause_kind, cause_trace, idx
    )
    VALUES ('spec', 'IdxConflict', $1, $2, 'create', 'spec', '{}',
            'internal', 'request', $1, 1)
  SQL

  doc_id = "spec.idxconflict.#{unique_suffix(8)}"
  raised = nil
  with_db do |db|
    begin
      db.exec(insert_row, Facet::Util::ScriptHelpers.ulid, doc_id)
      db.exec("SELECT set_config('harness.explicit_mutation_idx', '1', false)")
      db.exec(insert_row, Facet::Util::ScriptHelpers.ulid, doc_id)
    rescue ex : PQ::PQError
      raised = ex
    ensure
      # The GUC is session-scoped on a pooled connection — always clear it.
      db.exec("SELECT set_config('harness.explicit_mutation_idx', '', false)")
    end
  end
  raised.not_nil!
end

describe Facet::HTTP::JsonErrorHandler do
  describe "mutation write conflict (23505 on idx_mutations_doc_id_idx)" do
    it "renders a 409 with the retry hint" do
      response = render_through_error_handler(idx_conflict_error)
      response.status_code.should eq(409)
      response.headers["Content-Type"]?.try(&.starts_with?("application/json")).should be_true
      parsed = JSON.parse(response.body)
      parsed["error"].as_s.should eq(Facet::HTTP::JsonErrorHandler::MUTATION_CONFLICT_MESSAGE)
    end

    it "sets Cache-Control: no-store" do
      response = render_through_error_handler(idx_conflict_error)
      response.headers["Cache-Control"].should eq("no-store")
    end
  end

  describe "unrelated database errors" do
    it "keeps the generic JSON 500 without the SQL text" do
      ex = begin
        with_db do |db|
          db.exec("SELECT * FROM no_such_table_json_error_handler_spec")
        end
        raise "expected a PQError"
      rescue ex : PQ::PQError
        ex
      end

      response = render_through_error_handler(ex)
      response.status_code.should eq(500)
      parsed = JSON.parse(response.body)
      parsed["error"].as_s.should eq("Internal server error")
      # The SQL/constraint text stays out of the body.
      response.body.should_not contain(ex.message.not_nil!)
    end
  end

  describe "non-database errors" do
    it "keeps the generic JSON 500" do
      response = render_through_error_handler(ArgumentError.new("boom"))
      response.status_code.should eq(500)
      JSON.parse(response.body)["error"].as_s.should eq("Internal server error")
      response.body.should_not contain("boom")
    end

    # Several exception types carry no message (crystal-db's pool errors,
    # `Exception.new` without arguments). The body is generic either way —
    # the class name and message stay in the server log.
    it "renders the generic body when the message is nil" do
      response = render_through_error_handler(Exception.new)
      response.status_code.should eq(500)
      JSON.parse(response.body)["error"].as_s.should eq("Internal server error")
    end
  end
end
