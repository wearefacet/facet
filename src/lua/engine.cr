# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "opentelemetry"

module Facet
  module Lua
    # Thin wrapper around a `Lua::Stack` that manages the Lua state lifecycle
    # and provides convenience methods for converting results to Crystal types.
    #
    # The engine is sandboxed:
    # - Only safe standard libraries are loaded (`base`, `string`, `math`, `table`, `utf8`).
    # - Dangerous globals (`dofile`, `loadfile`, `load`, `collectgarbage`, `rawget`,
    #   `rawset`, `rawequal`) are stripped from the global environment.
    # - An instruction-count hook prevents infinite loops.
    # - A time-limit hook prevents excessive CPU usage.
    # - A custom memory allocator prevents OOM via `lua_setallocf`.
    #
    # ```
    # engine = Facet::Lua::Engine.new
    # engine.run("return 1 + 2")   # => 3.0
    # engine.run("return 'hello'") # => "hello"
    # engine.close
    # ```
    class Engine
      # A Crystal value type that can carry results from Lua.
      # Tables are normalized to either Hash(String, Value) or Array(Value).
      # Lua functions are kept as-is, callable from Crystal.
      alias Value = Bool | Int64 | Float64 | String |
                    Array(Value) |
                    Hash(String, Value) |
                    ::Lua::Function?

      # Error raised when a Lua chunk fails to compile or run.
      class Error < ::RuntimeError
        # Matches a Lua position prefix on an error message: the optional
        # anonymous-chunk name (`[string "..."]`), an optional separator
        # colon (absent once the chunk name is already stripped), the line
        # number, and its separator colon (`:20: attempt to index a nil`;
        # `20: attempt to index a nil` after a first rebase). The chunk
        # name is the generated wrapper's own source prefix, not the
        # author's script, so it is dropped and the line number is rebased
        # onto the caller's source (B-318).
        POSITION_PREFIX = /\A(?:\[string "[^"]*"\])?:?(\d+):/

        # Wrapper lines `Engine.run` prepends to the caller's source
        # (`__facet_result = (function()` is one line). Every `run` chunk
        # carries it, so a chunk line is one line past the caller's code.
        RUN_WRAPPER_LINES = 1

        getter lua_error : ::Lua::LuaError

        def initialize(@lua_error : ::Lua::LuaError)
          super(Error.rebase_position(@lua_error.message, RUN_WRAPPER_LINES))
        end

        # Rebases one Lua error message onto an earlier line numbering:
        # drops the `[string "..."]` chunk-name prefix and shifts the
        # leading line number down by `lines`. Callers that wrap the source
        # again before `run` (for example `ScriptContext.wrap_script`)
        # rebase once more with their own offset. Messages without a
        # position prefix pass through unchanged; the number clamps at 1
        # so an error on the wrapper's own lines still reports a sane
        # value.
        def self.rebase_position(message : String?, lines : Int32) : String?
          return message if message.nil?

          match = message.match(POSITION_PREFIX)
          return message unless match

          line = {match[1].to_i - lines, 1}.max
          "#{line}:#{match.post_match}"
        end
      end

      # Default values for sandbox limits. These are used when the LuaConfig
      # is not explicitly provided. The config file is the canonical source.
      DEFAULT_INSTRUCTION_LIMIT = 10_000_000_i64
      DEFAULT_MEMORY_LIMIT_MB   =        100_i64
      DEFAULT_TIME_LIMIT_S      =            5.0

      # Registry name of the marker metatable attached to Lua tables that
      # were pushed from a Crystal `Array(Value)`. An empty Lua table is
      # ambiguous (no integer keys to indicate array intent), so without a
      # marker the read path cannot tell an empty array from an empty hash.
      # This caused empty-array JSON fields (e.g. `app.App.allowed_origins`)
      # to round-trip through the Lua VM as `{}`, breaking downstream callers
      # that expected an array. The marker is only attached on the push side
      # (`push_lua_array`); Lua-native empty tables keep the existing
      # "empty hash" semantics, preserving backward compatibility for
      # unannotated tables.
      private ARRAY_MARKER_METATABLE = "__facet_json_array"

      # Only these Lua standard libraries are loaded into the engine.
      # Notable absent libraries and their risks:
      # - `os`     — os.execute, os.exit, os.rename, os.remove, environment access
      # - `io`     — full filesystem read/write
      # - `package` — C shared library loading (loadlib)
      # - `debug`  — stack introspection, local variable mutation, debug hooks
      # - `coroutine` — no legitimate use case for doctype scripts
      ALLOWED_LIBRARIES = [:base, :string, :math, :table, :utf8]

      # Globals from the `base` library that are removed after loading.
      # - `dofile`, `loadfile` — filesystem access via the Lua loader
      # - `load` — arbitrary bytecode/string compilation
      # - `collectgarbage` — can interfere with GC behavior
      # - `rawget`, `rawset`, `rawequal` — bypass metatable protections
      STRIPPED_GLOBALS = %w[
        dofile loadfile load collectgarbage
        rawget rawset rawequal
      ]

      # ── Memory limit via custom allocator ──────────────────────────────

      # Per-engine allocation metadata. The tracker is heap-allocated and
      # its pointer is passed as the `ud` (user data) argument to the
      # custom allocator via `lua_setallocf`.
      private struct AllocationTracker
        property bytes_allocated : Int64 = 0_i64
        property limit : Int64
        property original_allocf : LibLua::Alloc
        property original_ud : Void*

        def initialize(@limit : Int64, @original_allocf : LibLua::Alloc, @original_ud : Void*)
          @bytes_allocated = 0_i64
        end
      end

      # Class-level allocator hook invoked by the Lua VM for every malloc /
      # realloc / free call. Delegates to the original allocator and tracks
      # the net allocation delta. Returns NULL (out-of-memory) when the
      # limit would be exceeded, which causes Lua to raise a memory error.
      @@memory_allocator : LibLua::Alloc = ->(ud : Void*, ptr : Void*, osize : LibC::SizeT, nsize : LibC::SizeT) : Void* {
        tracker = ud.as(AllocationTracker*)
        alloc = tracker.value.original_allocf
        orig_ud = tracker.value.original_ud

        if nsize == 0
          # Free: release the block and subtract the old size.
          result = alloc.call(orig_ud, ptr, osize, 0_u64)
          tracker.value.bytes_allocated -= osize
          result
        elsif ptr.null?
          # Pure allocation: check limit before allocating.
          limit = tracker.value.limit
          if limit > 0 && tracker.value.bytes_allocated + nsize > limit
            Pointer(Void).null
          else
            result = alloc.call(orig_ud, ptr, osize, nsize)
            tracker.value.bytes_allocated += nsize
            result
          end
        else
          # Reallocation: check the delta against the limit.
          delta = nsize.to_i64 - osize.to_i64
          limit = tracker.value.limit
          if limit > 0 && delta > 0 && tracker.value.bytes_allocated + delta > limit
            Pointer(Void).null
          else
            result = alloc.call(orig_ud, ptr, osize, nsize)
            tracker.value.bytes_allocated += delta
            result
          end
        end
      }

      # ── Combined instruction + time hook ───────────────────────────────

      # The hook is called every HOOK_CHECK_EVERY instructions. It tracks
      # the cumulative instruction count and measures elapsed wall-clock
      # time against the configured limits.
      @@hook_instruction_count : Int64 = 0
      @@hook_instruction_limit : Int64 = DEFAULT_INSTRUCTION_LIMIT
      @@hook_time_limit : Float64 = DEFAULT_TIME_LIMIT_S
      @@hook_start_instant : Time::Instant = Time.instant

      private HOOK_CHECK_EVERY = 100_000_i64

      # Mask for lua_sethook: count instructions (LUA_MASKCOUNT = 1 << 3).
      LUA_MASKCOUNT = 8

      @@combined_hook : LibLua::Hook = ->(state : LibLua::State, ar : LibLua::Debug*) {
        # Accumulate instructions.
        @@hook_instruction_count += HOOK_CHECK_EVERY

        if @@hook_instruction_count > @@hook_instruction_limit
          LibLua.pushstring(state, "instruction limit exceeded (#{@@hook_instruction_limit})")
          LibLua.error(state)
          return
        end

        # Check wall-clock time.
        if @@hook_time_limit > 0
          elapsed = (Time.instant - @@hook_start_instant).total_seconds
          if elapsed > @@hook_time_limit
            LibLua.pushstring(state, "time limit exceeded (#{@@hook_time_limit}s)")
            LibLua.error(state)
          end
        end
      }

      # ── Instance ───────────────────────────────────────────────────────

      @tracker_ptr : Pointer(Void)

      # Creates a new sandboxed Engine with the given sandbox limits.
      #
      # Only the allowed standard libraries are loaded, dangerous globals
      # are stripped, and instruction/time/memory hooks are installed.
      def initialize(
        instruction_limit : Int64 = DEFAULT_INSTRUCTION_LIMIT,
        memory_limit_mb : Int64 = DEFAULT_MEMORY_LIMIT_MB,
        time_limit_s : Float64 = DEFAULT_TIME_LIMIT_S,
      )
        @stack = ::Lua::Stack.new(ALLOWED_LIBRARIES)
        @closed = false
        @tracker_ptr = Pointer(Void).null
        strip_dangerous_globals!
        set_memory_limit!(memory_limit_mb)
        set_combined_hook!(instruction_limit, time_limit_s)
      end

      # Creates a new Engine wrapping an existing Lua::Stack.
      # NOTE: This constructor does NOT apply sandboxing — use with caution.
      def initialize(@stack : ::Lua::Stack)
        @closed = false
        @tracker_ptr = Pointer(Void).null
      end

      # Runs one Lua chunk inside the sandbox and returns its result.
      #
      # Shared shell for the public evaluation entry points: open check,
      # hook reset, an `OpenTelemetry` span named *trace_name*, `Lua::Error`
      # wrapping into `Error`, and — in `ensure` — cleanup of the temp
      # `__facet_result` global so state never leaks between runs.
      private def run_chunk(trace_name : String, &)
        Facet::Telemetry.trace trace_name do |_span|
          validate_open!
          reset_hook_state!
          stack = stack_not_nil!
          yield stack
          get_global("__facet_result")
        end
      rescue ex : ::Lua::LuaError
        raise Error.new(ex)
      ensure
        # Clean up the temp global to avoid leaking state.
        if @stack
          state = raw_state
          LibLua.pushnil(state)
          LibLua.setglobal(state, "__facet_result")
        end
      end

      # Runs a Lua code chunk and returns the result as a `Value`.
      #
      # Raises `Error` on compilation or runtime errors.
      #
      # The source is wrapped to capture its return value in a temp global,
      # which is then read back via the raw C API. This bypasses the
      # underlying shard's `Stack#[]` which collapses all Lua numbers to
      # `Float64`, losing precision for integers above 2^53.
      def run(source : String) : Value
        run_chunk("lua.evaluate") do |stack|
          wrapped = "__facet_result = (function()\n#{source}\nend)()"
          stack.run(wrapped)
        end
      end

      # Registers a Crystal proc as a Lua global function.
      #
      # The proc's arguments and return type determine the Lua calling
      # convention. Supported types: Float64, String, Bool, Int64, Nil.
      #
      # ```
      # engine.function "add", ->(x : Float64, y : Float64) { x + y }
      # engine.run("return add(2, 3)") # => 5.0
      # ```
      def function(name : String, proc : Proc(*Args, R)) forall Args, R
        validate_open!
        stack_not_nil!.function(name, proc)
      end

      # Registers a block as a C-level Lua function callback.
      #
      # The block receives the raw `LibLua::State` and must return the
      # number of return values left on the stack. This is useful for building
      # complex Lua tables or handling multiple return values directly.
      #
      # Closures are supported via Lua::Stack's `pushclosure`.
      #
      # ```
      # engine.raw_function "hello" do |state|
      #   LibLua.pushstring(state, "world")
      #   1
      # end
      # ```
      def raw_function(name : String, &fn : LibLua::State -> Int32) : Nil
        validate_open!
        stack_not_nil!.set_global(name, fn)
      end

      # Registers a C-level Lua function callback as a field on a table.
      #
      # Expects a table at stack index `-1`. The callback is pushed onto
      # the stack and set as the field named `field_name` on that table.
      # The table remains on the stack for subsequent field registrations.
      #
      # ```
      # engine.raw_function_in_table(state, "create", &create_handler)
      # engine.raw_function_in_table(state, "get", &get_handler)
      # ```
      def raw_function_in_table(state : LibLua::State, field_name : String, &fn : LibLua::State -> Int32) : Nil
        validate_open!
        stack = stack_not_nil!
        stack.set_global("__facet_temp_fn", fn)
        LibLua.getglobal(state, "__facet_temp_fn")
        LibLua.setfield(state, -2, field_name)
        LibLua.pushnil(state)
        LibLua.setglobal(state, "__facet_temp_fn")
      end

      # Returns the raw `LibLua::State` pointer for direct C API access.
      def raw_state : LibLua::State
        stack_not_nil!.state
      end

      # Sets a global variable in the Lua environment.
      def set_global(name : String, value : Value) : Nil
        validate_open!
        push(value)
        LibLua.setglobal(stack_not_nil!.state, name)
      end

      # Reads a global variable from the Lua environment.
      def get_global(name : String) : Value
        validate_open!
        state = stack_not_nil!.state
        LibLua.getglobal(state, name)
        result = read_stack_value(state, -1)
        LibLua.settop(state, -2) # pop the global
        result
      end

      # Closes the underlying Lua state and frees the allocation tracker.
      def close : Nil
        return if @closed
        stack = @stack
        stack.try(&.close)
      ensure
        @closed = true
        @stack = nil
        free_tracker!
      end

      # Returns `true` if the underlying state has been closed.
      def closed? : Bool
        @closed
      end

      # Yields the engine to a block and closes it when done.
      def self.open(&)
        engine = new
        yield engine
      ensure
        engine.try(&.close)
      end

      # ── private: sandboxing ───────────────────────────────────────

      # Strips dangerous globals from the base library environment.
      private def strip_dangerous_globals!
        state = stack_not_nil!.state
        STRIPPED_GLOBALS.each do |name|
          LibLua.pushnil(state)
          LibLua.setglobal(state, name)
        end
      end

      # Installs the custom memory allocator that tracks and limits
      # Lua heap allocations.
      private def set_memory_limit!(memory_limit_mb : Int64) : Nil
        state = stack_not_nil!.state
        limit_bytes = memory_limit_mb * 1024 * 1024

        # Capture the original allocator before replacing it.
        # lua_getallocf returns the current allocator function pointer
        # and writes the user-data pointer via the out parameter.
        original_allocf = LibLua.getallocf(state, out original_ud)

        @tracker_ptr = LibC.malloc(sizeof(AllocationTracker))
        @tracker_ptr.as(AllocationTracker*).value = AllocationTracker.new(
          limit: limit_bytes > 0 ? limit_bytes : 0_i64,
          original_allocf: original_allocf,
          original_ud: original_ud,
        )

        LibLua.setallocf(state, @@memory_allocator, @tracker_ptr)
      end

      # Installs the combined instruction-count and wall-clock time hook.
      private def set_combined_hook!(instruction_limit : Int64, time_limit_s : Float64) : Nil
        state = stack_not_nil!.state
        @@hook_instruction_limit = instruction_limit
        @@hook_time_limit = time_limit_s
        LibLua.sethook(state, @@combined_hook, LUA_MASKCOUNT, HOOK_CHECK_EVERY)
      end

      # Resets the hook state counters before each run.
      private def reset_hook_state! : Nil
        @@hook_instruction_count = 0_i64
        @@hook_start_instant = Time.instant
      end

      # Frees the allocation tracker if it was allocated.
      private def free_tracker! : Nil
        unless @tracker_ptr.null?
          LibC.free(@tracker_ptr)
          @tracker_ptr = Pointer(Void).null
        end
      end

      # ── private: push closure onto Lua stack ─────────────────────

      # Registers the block as a temp global, copies it onto the stack,
      # then cleans up the temp global. The caller is responsible for
      # consuming the function from the stack (e.g. via setfield).
      private def push_closure(state : LibLua::State, &fn : LibLua::State -> Int32) : Nil
        stack = stack_not_nil!
        stack.set_global("__facet_temp_fn", fn)
        LibLua.getglobal(state, "__facet_temp_fn")
        LibLua.pushnil(state)
        LibLua.setglobal(state, "__facet_temp_fn")
      end

      # ── public: push Value onto the Lua stack ─────────────────────

      # Pushes a Value onto the Lua stack recursively, building Lua
      # tables directly via the C API to avoid ::Lua::Type constraints.
      def push(value : Value) : Nil
        push_value(value)
      end

      # ── private: push Value onto the Lua stack ────────────────────

      # Pushes a Value onto the Lua stack recursively, building Lua
      # tables directly via the C API to avoid ::Lua::Type constraints.
      private def push_value(value : Value) : Nil
        state = stack_not_nil!.state
        case value
        when Nil             then LibLua.pushnil(state)
        when Bool            then LibLua.pushboolean(state, value ? 1 : 0)
        when Int64           then LibLua.pushinteger(state, value)
        when Float64         then LibLua.pushnumber(state, value)
        when String          then LibLua.pushstring(state, value)
        when Array           then push_lua_array(value)
        when Hash            then push_lua_hash(value)
        when ::Lua::Function then stack_not_nil! << value
        else
          LibLua.pushnil(state)
        end
      end

      # Pushes an Engine::Value array onto the stack as a Lua table.
      #
      # Attaches the `ARRAY_MARKER_METATABLE` marker so the read path can
      # distinguish an empty array (pushed from Crystal) from an empty hash.
      # The metatable survives Lua-side mutations (assigning fields on a
      # table does not change its metatable), so a script that sets
      # `ctx.root.field = ...` does not strip the marker from arrays nested
      # elsewhere on `ctx.root`.
      private def push_lua_array(values : Array(Value)) : Nil
        state = stack_not_nil!.state
        LibLua.createtable(state, values.size, 0)
        values.each_with_index do |v, i|
          push_value(v)
          LibLua.rawseti(state, -2, i + 1)
        end
        attach_array_marker(state)
      end

      # Ensures the marker metatable exists in the Lua registry and attaches
      # it to the table at the top of the stack. `luaL_newmetatable` is
      # idempotent: the first call creates and stores the metatable in the
      # registry under the given name; subsequent calls find it and push the
      # existing one. Either way the metatable ends up on top of the stack,
      # ready for `lua_setmetatable` to attach it to the table just below.
      private def attach_array_marker(state : LibLua::State) : Nil
        LibLua.l_newmetatable(state, ARRAY_MARKER_METATABLE)
        LibLua.setmetatable(state, -2)
      end

      # Returns true when the table at `index` carries the array marker
      # metatable. Used by `read_stack_table` to disambiguate empty tables:
      # a marked empty table was pushed from a Crystal `Array(Value)` and is
      # read back as an empty array; an unmarked empty table (Lua-native or
      # pushed from a Crystal `Hash`) keeps the existing empty-hash semantics.
      #
      # Stack: `luaL_newmetatable` pushes the registry-named marker metatable
      # (creating it on first call, returning the existing one thereafter —
      # both leave the same reference on the stack). `lua_getmetatable`
      # pushes the target table's metatable (or 0 / nothing when none).
      # `rawequal` compares by reference without pushing. The function leaves
      # the stack exactly as it found it.
      private def array_marker?(state : LibLua::State, index : Int32) : Bool
        abs_idx = LibLua.absindex(state, index)
        # Bail out cheaply when there is no metatable on the target table.
        # `lua_getmetatable` pushes nothing and returns 0 in that case.
        return false unless LibLua.getmetatable(state, abs_idx) != 0
        # Push the registry-named marker metatable so we can compare by
        # reference. Idempotent — first call creates it, subsequent calls
        # find it in the registry.
        LibLua.l_newmetatable(state, ARRAY_MARKER_METATABLE)
        matches = LibLua.rawequal(state, -1, -2) != 0
        LibLua.settop(state, -3) # pop both metatables; leave the stack as it was
        matches
      end

      # Pushes an Engine::Value hash onto the stack as a Lua table.
      private def push_lua_hash(hash : Hash(String, Value)) : Nil
        state = stack_not_nil!.state
        LibLua.createtable(state, 0, hash.size)
        hash.each do |k, v|
          stack_not_nil! << k
          push_value(v)
          LibLua.settable(state, -3)
        end
      end

      # ── private: read Lua stack → Crystal Value ──────────────────

      # Reads a value from the Lua stack at the given index, preserving
      # integer precision by trying `lua_tointegerx` before `lua_tonumberx`.
      # Tables are converted recursively to `Array(Value)` or `Hash(String, Value)`.
      private def read_stack_value(state : LibLua::State, index : Int32) : Value
        case LibLua.type(state, index)
        when 0 # LUA_TNIL
          nil
        when 1 # LUA_TBOOLEAN
          LibLua.toboolean(state, index) != 0
        when 3 # LUA_TNUMBER
          # Try integer first to preserve int64 precision.
          int_val = LibLua.tointegerx(state, index, out is_int)
          if is_int != 0
            int_val.to_i64
          else
            LibLua.tonumberx(state, index, out _unused)
          end
        when 4 # LUA_TSTRING
          ptr = LibLua.tolstring(state, index, nil)
          ptr.null? ? "" : String.new(ptr)
        when 5 # LUA_TTABLE
          read_stack_table(state, index)
        when 6 # LUA_TFUNCTION
          # Copy to top and create a registry reference (l_ref pops the copy).
          # The original stays on the stack for the caller to clean up.
          LibLua.pushvalue(state, index)
          ref = LibLua.l_ref(state, ::Lua.registry_index)
          ::Lua::Function.new(stack_not_nil!, ref)
        else
          nil
        end
      end

      # Reads a Lua table from the stack, returning an `Array(Value)` if
      # the keys form a clean 1..n sequence, or a `Hash(String, Value)` otherwise.
      #
      # Empty tables are ambiguous (no keys to disambiguate array from hash).
      # When the empty table carries the `ARRAY_MARKER_METATABLE` marker, it
      # was pushed from a Crystal `Array(Value)` (e.g. via `push_lua_array`
      # during `set_global`) and is read back as an empty array. Unmarked
      # empty tables (Lua-native `return {}`, or pushed from a Crystal hash)
      # keep the historical empty-hash semantics so existing behaviour is
      # preserved for code that does not round-trip through Crystal arrays.
      private def read_stack_table(state : LibLua::State, index : Int32) : Value
        abs_idx = LibLua.absindex(state, index)
        pairs = [] of {Value, Value}

        LibLua.pushnil(state)
        while LibLua.next(state, abs_idx) != 0
          key = read_stack_value(state, -2)
          val = read_stack_value(state, -1)
          pairs << {key, val}
          LibLua.settop(state, -2) # pop value, keep key for next()
        end

        if pairs.empty?
          return Array(Value).new if array_marker?(state, abs_idx)
          return Hash(String, Value).new
        end

        # Check if all keys are integers forming a 1..n sequence → array.
        int_keys = pairs.map { |(k, _)| k.as?(Int64) }
        if int_keys.all? { |k| !k.nil? }
          indices = int_keys.map { |k| k || 0_i64 }.sort!
          if indices == (1..indices.size).to_a
            arr = Array(Value).new(indices.size)
            # Build a lookup from key → value for ordered extraction.
            lookup = Hash(Int64, Value).new
            pairs.each { |(k, v)| lookup[k.as(Int64)] = v }
            (1..indices.size).each { |i| arr << lookup[i] }
            return arr
          end
        end

        # Otherwise treat as hash with string keys.
        hash = Hash(String, Value).new
        pairs.each do |(k, v)|
          key_str = case k
                    when String then k
                    when Int64  then k.to_s
                    when Bool   then k.to_s
                    else             k.to_s
                    end
          hash[key_str] = v
        end
        hash
      end

      # ── private: lifecycle guards ──────────────────────────────────

      private def validate_open! : Nil
        if @closed
          raise Error.new(::Lua::RuntimeError.new("Lua state is closed"))
        end
      end

      private def stack_not_nil! : ::Lua::Stack
        @stack.as(::Lua::Stack)
      end
    end
  end
end
