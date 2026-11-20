# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/assistant/refusal_guard"

# Unit tests for `RefusalGuard`'s class-level envelope helpers. Pure logic —
# no database, no provider. The per-guard counting behaviour is covered end
# to end by the registrar specs (`spec/assistant/app/registrar_spec.cr`,
# `spec/assistant/workspace/registrar_spec.cr`); here the guard's own
# envelope builder, recognizer, and call key are pinned, because
# `Stream::TerminalRefusalStop` detects the envelope through them.

private def args_from(json : String) : Hash(String, JSON::Any)
  JSON.parse(json).as_h
end

describe Facet::Assistant::RefusalGuard do
  describe ".terminal_envelope" do
    it "builds the terminal envelope the guard returns at the limit" do
      parsed = JSON.parse(Facet::Assistant::RefusalGuard.terminal_envelope("create_document"))

      parsed["ok"].as_bool.should be_false
      parsed["terminal"].as_bool.should be_true
      parsed["error"].as_s.should contain("Repeated refused call to 'create_document'")
      parsed["error"].as_s.should contain("stop retrying")
    end
  end

  describe ".terminal_result?" do
    it "recognizes its own terminal envelope" do
      envelope = Facet::Assistant::RefusalGuard.terminal_envelope("create_document")

      Facet::Assistant::RefusalGuard.terminal_result?(envelope).should be_true
    end

    it "recognizes the envelope regardless of JSON key order" do
      content = %({"terminal":true,"error":"Repeated refused call to 'x' with identical arguments. This refusal is final — stop retrying and tell the user the action did not go through.","ok":false})

      Facet::Assistant::RefusalGuard.terminal_result?(content).should be_true
    end

    it "rejects the normal registrar error envelope" do
      content = %({"ok":false,"error":"Tool 'delete_document' refused","details":{"reason":"rbac_denied"}})

      Facet::Assistant::RefusalGuard.terminal_result?(content).should be_false
    end

    it "rejects a terminal flag without the marker" do
      content = %({"ok":false,"error":"some other final error","terminal":true})

      Facet::Assistant::RefusalGuard.terminal_result?(content).should be_false
    end

    it "rejects non-JSON, empty, and nil content" do
      Facet::Assistant::RefusalGuard.terminal_result?("Error executing tool 'x': boom").should be_false
      Facet::Assistant::RefusalGuard.terminal_result?("").should be_false
      Facet::Assistant::RefusalGuard.terminal_result?(nil).should be_false
    end
  end

  describe ".call_key" do
    it "ignores JSON key order at every depth" do
      a = JSON.parse(%({"b": 1, "a": {"d": [1, 2], "c": 3}}))
      b = JSON.parse(%({"a": {"c": 3, "d": [1, 2]}, "b": 1}))

      Facet::Assistant::RefusalGuard.call_key("t", a)
        .should eq(Facet::Assistant::RefusalGuard.call_key("t", b))
    end

    it "separates different tools and different argument values" do
      args = JSON.parse(%({"a": 1}))

      Facet::Assistant::RefusalGuard.call_key("t1", args)
        .should_not eq(Facet::Assistant::RefusalGuard.call_key("t2", args))
      Facet::Assistant::RefusalGuard.call_key("t1", args)
        .should_not eq(Facet::Assistant::RefusalGuard.call_key("t1", JSON.parse(%({"a": 2}))))
    end
  end

  describe "#result" do
    it "returns the terminal envelope at the limit, identical to .terminal_envelope" do
      guard = Facet::Assistant::RefusalGuard.new
      args = args_from(%({"id": "doc_1"}))
      normal = %({"ok":false,"error":"Tool 'create_document' refused"})

      guard.result("create_document", args, normal).should eq(normal)
      guard.result("create_document", args, normal).should eq(normal)

      third = guard.result("create_document", args, normal)
      third.should eq(Facet::Assistant::RefusalGuard.terminal_envelope("create_document"))
      third.should contain(%("terminal":true))
    end

    it "counts calls that differ only in JSON key order as identical" do
      guard = Facet::Assistant::RefusalGuard.new
      normal = %({"ok":false,"error":"refused"})
      first = args_from(%({"b": "1", "a": "2"}))
      second = args_from(%({"a": "2", "b": "1"}))

      guard.result("t", first, normal).should eq(normal)
      guard.result("t", second, normal).should eq(normal)

      guard.result("t", first, normal)
        .should eq(Facet::Assistant::RefusalGuard.terminal_envelope("t"))
    end
  end
end
