# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/lua"

module Facet::Lua
  # Test value: 2^53 + 1. This is the smallest integer that cannot be
  # exactly represented as a Float64 (it rounds down to 2^53).
  BIG_INT64_ENG = 9_007_199_254_740_993_i64

  describe Engine do
    # ── Lifecycle ──────────────────────────────────────────────────

    it "starts open" do
      engine = Engine.new
      engine.closed?.should be_false
      engine.close
      engine.closed?.should be_true
    end

    it "is open after wrapping a stack" do
      stack = ::Lua::Stack.new
      engine = Engine.new(stack)
      engine.closed?.should be_false
      engine.close
    end

    it "raises on use after close" do
      engine = Engine.new
      engine.close
      expect_raises(Engine::Error, /closed/) do
        engine.run("return 1")
      end
    end

    it "self.open yields and closes" do
      engine = nil
      Engine.open do |e|
        engine = e
        engine.closed?.should be_false
      end
      engine.not_nil!.closed?.should be_true
    end

    # ── Basic execution ────────────────────────────────────────────

    it "evaluates an arithmetic expression" do
      Engine.open do |engine|
        result = engine.run("return 1 + 2")
        result.should eq 3.0
      end
    end

    it "returns a string" do
      Engine.open do |engine|
        result = engine.run("return 'hello world'")
        result.should eq "hello world"
      end
    end

    it "returns a boolean" do
      Engine.open do |engine|
        engine.run("return true").should be_true
        engine.run("return false").should be_false
      end
    end

    it "returns nil" do
      Engine.open do |engine|
        result = engine.run("return nil")
        result.should be_nil
      end
    end

    it "returns no value as nil" do
      Engine.open do |engine|
        result = engine.run("x = 42")
        result.should be_nil
      end
    end

    # ── Tables ────────────────────────────────────────────────────

    it "returns an array when Lua returns a 1-indexed list" do
      Engine.open do |engine|
        result = engine.run("return { 'a', 'b', 'c' }")
        result.should eq ["a", "b", "c"]
      end
    end

    it "returns a hash when Lua returns a key-value table" do
      Engine.open do |engine|
        result = engine.run("return { name = 'Alice', age = 30 }")
        result.should eq({"name" => "Alice", "age" => 30.0})
      end
    end

    it "returns an empty hash for an empty table" do
      Engine.open do |engine|
        result = engine.run("return {}")
        result.should eq({} of String => Engine::Value)
      end
    end

    it "returns a hash for a table with mixed key types" do
      Engine.open do |engine|
        result = engine.run("return { [10] = 'ten', name = 'bob' }")
        result.should eq({"10" => "ten", "name" => "bob"})
      end
    end

    # ── Nested tables ─────────────────────────────────────────────

    it "handles nested arrays" do
      Engine.open do |engine|
        result = engine.run("return { { 1, 2 }, { 3, 4 } }")
        result.should eq [[1.0, 2.0], [3.0, 4.0]]
      end
    end

    it "handles nested hashes" do
      Engine.open do |engine|
        result = engine.run("return { person = { name = 'Alice', age = 30 } }")
        result.should eq({"person" => {"name" => "Alice", "age" => 30.0}})
      end
    end

    # ── Array marker round-trip ─────────────────────────────────────
    # An empty Lua table is ambiguous: no integer keys exist, so the read
    # path cannot tell an empty array from an empty hash. Without the
    # marker, a Crystal `Array(Value)` pushed via `set_global` round-trips
    # back as an empty `Hash(String, Value)`. This breaks doctype scripts
    # that read back `ctx.root` (e.g. `app.App` create hook) — empty-array
    # fields like `allowed_origins` arrive as `{}` instead of `[]`.
    #
    # The marker (`ARRAY_MARKER_METATABLE`) is attached on the push side
    # and checked on the read side. Lua-native empty tables stay unmarked,
    # so the existing "returns an empty hash for an empty table" contract
    # above is preserved.

    it "round-trips an empty array pushed from Crystal as an empty array" do
      Engine.open do |engine|
        engine.set_global("arr", [] of Engine::Value)
        result = engine.get_global("arr")
        result.should eq([] of Engine::Value)
        result.is_a?(Array(Engine::Value)).should be_true
      end
    end

    it "round-trips a non-empty array pushed from Crystal as an array" do
      Engine.open do |engine|
        engine.set_global("arr", ["a", "b"] of Engine::Value)
        result = engine.get_global("arr")
        result.should eq(["a", "b"])
        result.is_a?(Array(Engine::Value)).should be_true
      end
    end

    it "round-trips an empty hash pushed from Crystal as a hash" do
      Engine.open do |engine|
        engine.set_global("h", {} of String => Engine::Value)
        result = engine.get_global("h")
        result.should eq({} of String => Engine::Value)
        result.is_a?(Hash(String, Engine::Value)).should be_true
      end
    end

    it "preserves the array marker through a nested empty array field" do
      # Mirrors the `ctx.root` round-trip shape: a hash field whose value is
      # an empty array. The marker is attached recursively on push and
      # consulted recursively on read, so the nested empty array survives.
      Engine.open do |engine|
        root = {"allowed_origins" => [] of Engine::Value, "name" => "app"}
        engine.set_global("root", root)
        result = engine.get_global("root").as(Hash(String, Engine::Value))
        result["allowed_origins"].should eq([] of Engine::Value)
        result["allowed_origins"].is_a?(Array(Engine::Value)).should be_true
      end
    end

    it "keeps Lua-native empty tables as hashes (marker is push-side only)" do
      Engine.open do |engine|
        result = engine.run("return {}")
        result.should eq({} of String => Engine::Value)
        result.is_a?(Hash(String, Engine::Value)).should be_true
      end
    end

    # ── Functions ─────────────────────────────────────────────────

    it "registers and calls a Crystal proc" do
      Engine.open do |engine|
        engine.function "add", ->(x : Float64, y : Float64) { x + y }
        result = engine.run("return add(2, 3)")
        result.should eq 5.0
      end
    end

    it "registers a proc that mutates captured state" do
      counter = 0
      Engine.open do |engine|
        engine.function "tick", -> { counter += 1; nil }
        engine.run("tick()")
        engine.run("tick()")
        counter.should eq 2
      end
    end

    it "registers a proc that receives a string argument" do
      Engine.open do |engine|
        engine.function "greet", ->(name : String) { "Hi, #{name}" }
        result = engine.run("return greet('Lua')")
        result.should eq "Hi, Lua"
      end
    end

    it "returns a Lua function and calls it from Crystal" do
      Engine.open do |engine|
        result = engine.run(%q(
          function sum(x, y)
            return x + y
          end
          return sum
        ))
        result.should be_a(::Lua::Function)
        fn = result.as(::Lua::Function)
        fn.call(10, 20).should eq 30.0
      end
    end

    # ── Globals ───────────────────────────────────────────────────

    it "reads a global variable" do
      Engine.open do |engine|
        engine.run("x = 42")
        engine.get_global("x").should eq 42.0
      end
    end

    it "writes a global variable" do
      Engine.open do |engine|
        engine.set_global("msg", "hello from crystal")
        result = engine.run("return msg")
        result.should eq "hello from crystal"
      end
    end

    it "reads nil for an undefined global" do
      Engine.open do |engine|
        engine.get_global("does_not_exist").should be_nil
      end
    end

    # ── UTF-8 / multi-byte characters ─────────────────────────────
    #
    # Lua chunks must be loaded by byte count (`#bytesize`), not codepoint
    # count (`String#size`) — a codepoint-counted length silently shortens
    # the chunk by (bytes - 1) per multi-byte character, producing opaque
    # `near <eof>` syntax errors. The failure is position-agnostic (comments
    # and string literals alike) and script-language-agnostic (Latin-1
    # supplement, em-dash, Thai, CJK all fail identically), so one
    # round-trip assertion catches a `.size` regression immediately.

    it "preserves multi-byte UTF-8 in comments and string literals" do
      Engine.open do |engine|
        # The chunk deliberately ends with `end return export.greet()`
        # after the last multi-byte character -- if the load length is
        # wrong, that tail gets eaten and the engine raises a syntax
        # error instead of returning the string.
        script = <<-LUA
          -- em-dash comment —
          -- Thai comment สวัสดี
          local export = {}
          function export.greet()
            return "café — ภาษาไทย 漢字"
          end
          return export.greet()
        LUA
        result = engine.run(script)
        result.should eq("café — ภาษาไทย 漢字")
      end
    end

    # ── Error handling ────────────────────────────────────────────

    it "raises Error on syntax error" do
      Engine.open do |engine|
        expect_raises(Engine::Error, /syntax/i) do
          engine.run("this is not valid lua")
        end
      end
    end

    it "raises Error on runtime error" do
      Engine.open do |engine|
        expect_raises(Engine::Error) do
          engine.run("error('boom')")
        end
      end
    end

    # ── Error message rebasing (B-318) ────────────────────────────

    it "reports a runtime error against the caller's source line, without the wrapper chunk name" do
      Engine.open do |engine|
        ex = expect_raises(Engine::Error) do
          # `mistake()` is line 4 of the passed source; the engine wrapper
          # shifts it to chunk line 5, and the rebase must undo that shift.
          engine.run(<<-LUA)
            local export = {}
            local pad = 1
            export.greet = function()
              mistake()
            end
            return export.greet()
          LUA
        end
        msg = ex.message || ""
        msg.should_not contain("[string")
        msg.should start_with("4: ")
      end
    end

    it "rebases a Lua position prefix by the given wrapper lines" do
      Engine::Error.rebase_position("[string \"__facet_result\"]:20: boom", 2).should eq("18: boom")
      Engine::Error.rebase_position(":5: boom", 1).should eq("4: boom")
      Engine::Error.rebase_position("5: boom", 1).should eq("4: boom")
      Engine::Error.rebase_position("no position here", 1).should eq("no position here")
      Engine::Error.rebase_position(nil, 1).should be_nil
      # A number that would fall below 1 clamps at 1.
      Engine::Error.rebase_position("[string \"x\"]:1: boom", 5).should eq("1: boom")
    end

    # ── Sandboxing: safe libraries are available ─────────────────

    it "can use string library" do
      Engine.open do |engine|
        result = engine.run("return string.upper('hello')")
        result.should eq "HELLO"
      end
    end

    it "can use math library" do
      Engine.open do |engine|
        result = engine.run("return math.sqrt(9)")
        result.should eq 3.0
      end
    end

    it "can use table library" do
      Engine.open do |engine|
        result = engine.run("return table.concat({ 'a', 'b' }, ',')")
        result.should eq "a,b"
      end
    end

    it "can use utf8 library" do
      Engine.open do |engine|
        # ASCII is not enough to prove the utf8 library actually loaded --
        # `utf8.len` on ASCII returns the byte count, same as `string.len`.
        # Use a multi-byte string so the result distinguishes a working
        # `utf8` library (codepoint count) from a no-op stub or a missing
        # library (which would surface as `nil` from the missing global).
        result = engine.run("return utf8.len('café')")
        # 'café' is 4 codepoints but 5 bytes (é is 2 bytes in UTF-8).
        result.should eq 4
      end
    end

    # ── Sandboxing: dangerous libraries are blocked ──────────────

    it "blocks os library" do
      Engine.open do |engine|
        result = engine.run("return os")
        result.should be_nil
      end
    end

    it "blocks io library" do
      Engine.open do |engine|
        result = engine.run("return io")
        result.should be_nil
      end
    end

    it "blocks debug library" do
      Engine.open do |engine|
        result = engine.run("return debug")
        result.should be_nil
      end
    end

    it "blocks package library" do
      Engine.open do |engine|
        result = engine.run("return package")
        result.should be_nil
      end
    end

    it "blocks coroutine library" do
      Engine.open do |engine|
        result = engine.run("return coroutine")
        result.should be_nil
      end
    end

    # ── Sandboxing: dangerous globals stripped from base ─────────

    it "strips dofile" do
      Engine.open do |engine|
        engine.get_global("dofile").should be_nil
      end
    end

    it "strips loadfile" do
      Engine.open do |engine|
        engine.get_global("loadfile").should be_nil
      end
    end

    it "strips load" do
      Engine.open do |engine|
        engine.get_global("load").should be_nil
      end
    end

    it "strips collectgarbage" do
      Engine.open do |engine|
        engine.get_global("collectgarbage").should be_nil
      end
    end

    it "strips rawget" do
      Engine.open do |engine|
        engine.get_global("rawget").should be_nil
      end
    end

    it "strips rawset" do
      Engine.open do |engine|
        engine.get_global("rawset").should be_nil
      end
    end

    it "strips rawequal" do
      Engine.open do |engine|
        engine.get_global("rawequal").should be_nil
      end
    end

    # ── Sandboxing: instruction limit prevents infinite loops ────

    it "aborts infinite loop via instruction limit" do
      Engine.open do |engine|
        expect_raises(Engine::Error, /instruction limit/) do
          engine.run("while true do end")
        end
      end
    end

    it "aborts tight loop via instruction limit" do
      Engine.open do |engine|
        expect_raises(Engine::Error, /instruction limit/) do
          engine.run("for i = 1, 1e9 do end")
        end
      end
    end

    # ── Sandboxing: memory limit prevents OOM ─────────────────────

    it "aborts huge string.rep via memory limit" do
      # Use a tighter memory limit to reliably trigger the memory error.
      engine = Engine.new(
        instruction_limit: 100_000_000_i64,
        memory_limit_mb: 10_i64,
        time_limit_s: 5.0,
      )
      expect_raises(Engine::Error, /memory/i) do
        engine.run("string.rep('x', 2^30)")
      end
      engine.close
    end

    it "allows moderate string.rep within memory limit" do
      Engine.open do |engine|
        result = engine.run("return string.rep('x', 1000)")
        result.should be_a(String)
        result.as(String).size.should eq 1000
      end
    end

    it "aborts large table allocation via memory limit" do
      engine = Engine.new(
        instruction_limit: 100_000_000_i64,
        memory_limit_mb: 10_i64,
        time_limit_s: 5.0,
      )
      expect_raises(Engine::Error, /memory/i) do
        engine.run(%q(
          local t = {}
          for i = 1, 10 do t[i] = string.rep("x", 10 * 1024 * 1024) end
          return t
        ))
      end
      engine.close
    end

    # ── Sandboxing: time limit prevents excessive CPU ─────────────

    it "aborts busy-wait via time limit" do
      # Use a tight engine with a very short time limit (10ms) to test
      # the time-limit hook independently of the instruction limit.
      engine = Engine.new(
        instruction_limit: 100_000_000_i64,
        memory_limit_mb: 100_i64,
        time_limit_s: 0.01,
      )
      expect_raises(Engine::Error, /time limit/) do
        engine.run("for i = 1, 1e9 do end")
      end
      engine.close
    end

    # ── Sandboxing: configurable instruction limit ────────────────

    it "respects a lowered instruction limit" do
      engine = Engine.new(
        instruction_limit: 1000_i64,
        memory_limit_mb: 100_i64,
        time_limit_s: 5.0,
      )
      expect_raises(Engine::Error, /instruction limit/) do
        engine.run("for i = 1, 1e9 do end")
      end
      engine.close
    end

    # ── Sandboxing: limits are per engine ─────────────────────────

    # A script that pauses inside a helper (a db call) lets other fibers
    # run. The other engine must not reset this script's counter or its
    # limits, so the paused script still trips its own budget.
    it "keeps instruction budgets separate when runs overlap" do
      start_gate = Channel(Nil).new
      resume_gate = Channel(Nil).new
      done = Channel(Nil).new
      failure : Exception? = nil

      engine = Engine.new(
        instruction_limit: 100_000_i64,
        memory_limit_mb: 100_i64,
        time_limit_s: 0.0,
      )
      engine.raw_function "facet_gate" do |_state|
        start_gate.send(nil)
        resume_gate.receive
        0
      end

      spawn do
        begin
          engine.run("facet_gate() for i = 1, 1e9 do end")
        rescue ex
          failure = ex
        ensure
          done.send(nil)
        end
      end

      start_gate.receive # the script is now paused inside facet_gate
      Engine.open do |other|
        other.run("return 1 + 1").should eq 2.0
      end
      resume_gate.send(nil)
      done.receive

      failure.should be_a(Engine::Error)
      # The message names the budget: 100000 here, not the other engine's
      # default of 1000000.
      failure.as(Engine::Error).message.to_s.should contain "(100000)"
      engine.close
    end

    # ── Multiple returns ──────────────────────────────────────────

    it "returns the first value on multiple returns" do
      Engine.open do |engine|
        # Standard Lua semantics: when adjusting to one value, the first
        # return value is used.
        result = engine.run("return 1, 2, 3")
        result.should eq 1
      end
    end

    # ── Int64 precision ─────────────────────────────────────────

    # The Lua 5.4 C API has a dedicated integer subtype (lua_Integer = int64).
    # Int64 values pushed to Lua must survive a round-trip without being
    # collapsed to Float64 (which loses precision above 2^53).

    it "preserves Int64 precision when pushing and reading a global" do
      Engine.open do |engine|
        engine.set_global("big_id", BIG_INT64_ENG)
        result = engine.get_global("big_id")
        result.should be_a(Int64)
        result.should eq BIG_INT64_ENG
      end
    end

    it "preserves Int64 precision inside a table when pushing and reading a global" do
      Engine.open do |engine|
        engine.set_global("data", {"id" => BIG_INT64_ENG, "name" => "test"})
        result = engine.get_global("data")
        result.should be_a(Hash(String, Engine::Value))
        hash = result.as(Hash(String, Engine::Value))
        hash["id"].should be_a(Int64)
        hash["id"].should eq BIG_INT64_ENG
      end
    end

    it "preserves Int64 precision when a Lua script returns an integer literal" do
      Engine.open do |engine|
        # In Lua 5.4, this literal is an integer subtype.
        result = engine.run("return #{BIG_INT64_ENG}")
        result.should be_a(Int64)
        result.should eq BIG_INT64_ENG
      end
    end
  end
end
