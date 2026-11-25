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
    # - The `string.*` pattern functions are wrapped so a C-side match is
    #   deadline-checked and size-bounded (S8 — the count hook never fires
    #   inside a C call).
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
      # is not explicitly provided. They match the `Config::LuaConfig`
      # defaults — the config file is the canonical source.
      DEFAULT_INSTRUCTION_LIMIT = 1_000_000_i64
      DEFAULT_MEMORY_LIMIT_MB   =        32_i64
      DEFAULT_TIME_LIMIT_S      =           0.5

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

      # ── Per-engine sandbox state ──────────────────────────────────────

      # Per-engine sandbox state: the allocation budget plus the
      # instruction and time budgets. The tracker is heap-allocated and
      # its pointer is passed as the `ud` (user data) argument to the
      # custom allocator via `lua_setallocf`. The debug hook reads the
      # same pointer back from the state with `lua_getallocf`, so each
      # engine owns its counters and limits. The engines share no hook
      # state, even when runs overlap on different fibers.
      private struct SandboxTracker
        property bytes_allocated : Int64 = 0_i64
        property limit : Int64
        property original_allocf : LibLua::Alloc
        property original_ud : Void*
        property instruction_count : Int64
        property instruction_limit : Int64
        property time_limit : Float64
        property start_instant : Time::Instant

        def initialize(
          @limit : Int64,
          @original_allocf : LibLua::Alloc,
          @original_ud : Void*,
          @instruction_count : Int64 = 0_i64,
          @instruction_limit : Int64 = DEFAULT_INSTRUCTION_LIMIT,
          @time_limit : Float64 = DEFAULT_TIME_LIMIT_S,
        )
          @start_instant = Time.instant
        end
      end

      # Class-level allocator hook invoked by the Lua VM for every malloc /
      # realloc / free call. Delegates to the original allocator and tracks
      # the net allocation delta. Returns NULL (out-of-memory) when the
      # limit would be exceeded, which causes Lua to raise a memory error.
      @@memory_allocator : LibLua::Alloc = ->(ud : Void*, ptr : Void*, osize : LibC::SizeT, nsize : LibC::SizeT) : Void* {
        tracker = ud.as(SandboxTracker*)
        alloc = tracker.value.original_allocf
        orig_ud = tracker.value.original_ud

        if nsize == 0
          # Free: release the block and subtract the old size. Explicit
          # read-modify-write: compound assignment through a pointer to a
          # struct mutates a temporary copy and loses the update.
          result = alloc.call(orig_ud, ptr, osize, 0_u64)
          tracker.value.bytes_allocated = tracker.value.bytes_allocated - osize.to_i64
          result
        elsif ptr.null?
          # Pure allocation: check limit before allocating.
          limit = tracker.value.limit
          if limit > 0 && tracker.value.bytes_allocated + nsize > limit
            Pointer(Void).null
          else
            result = alloc.call(orig_ud, ptr, osize, nsize)
            tracker.value.bytes_allocated = tracker.value.bytes_allocated + nsize.to_i64
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
            tracker.value.bytes_allocated = tracker.value.bytes_allocated + delta
            result
          end
        end
      }

      # ── Combined instruction + time hook ───────────────────────────────

      # The hook is called every HOOK_CHECK_EVERY instructions. It tracks
      # the cumulative instruction count and measures elapsed wall-clock
      # time against the configured limits. All values live in this
      # engine's SandboxTracker, read back from the state's allocator user
      # data. The hook is installed only after `set_memory_limit!`, so the
      # user data always points at this engine's tracker.

      private HOOK_CHECK_EVERY = 100_000_i64

      # Mask for lua_sethook: count instructions (LUA_MASKCOUNT = 1 << 3).
      LUA_MASKCOUNT = 8

      # ── Pattern-match bound (S8) ────────────────────────────────────
      #
      # The count hook fires between VM instructions. A Lua pattern match
      # runs inside a C function (`string.find` / `match` / `gmatch` /
      # `gsub`), where no hook fires, so one pathological pattern would hold
      # the single-threaded event loop past both the instruction and the
      # time budget. A C call cannot be interrupted from Crystal, so a
      # before/after deadline check cannot stop a match that is already
      # backtracking. The wrappers installed by `install_pattern_guards!`
      # therefore refuse an over-complex pattern and an over-size subject
      # BEFORE entering the C matcher, so the pathological case never runs.
      #
      # Backtracking cost grows with the number of quantifiers in a pattern
      # (each `*`, `+`, `-`, `?` is a backtrack point). A pattern with `k`
      # quantifiers over a subject of `n` bytes costs up to `O(n^k)`. Capping
      # the quantifier count caps that exponent; capping the subject caps
      # `n`. Together they bound the worst-case work well below the time
      # budget. Doctype scripts match identifiers, slugs, and field values —
      # a handful of quantifiers on a short subject — so these caps are
      # generous for real scripts.
      #
      # Upper bound on a subject or pattern string handed to a Lua pattern
      # call.
      PATTERN_SIZE_LIMIT = 65_536

      # Upper bound on the number of quantifiers in a pattern. A pattern at
      # or below this count backtracks in bounded polynomial time on a
      # subject within `PATTERN_SIZE_LIMIT`.
      PATTERN_QUANTIFIER_LIMIT = 8

      # The `string.*` functions whose C-side pattern match the dispatcher
      # guards. `find` / `match` / `gmatch` / `gsub` all run a pattern match
      # inside a C call, where the count hook never fires.
      GUARDED_STRING_FUNCTIONS = ["find", "match", "gmatch", "gsub"]

      @@combined_hook : LibLua::Hook = ->(state : LibLua::State, ar : LibLua::Debug*) {
        LibLua.getallocf(state, out ud)
        tracker = ud.as(SandboxTracker*)

        # Accumulate instructions. Read-modify-write through the pointer:
        # `tracker.value.instruction_count += ...` would mutate a temporary
        # copy of the struct and lose the update.
        count = tracker.value.instruction_count + HOOK_CHECK_EVERY
        tracker.value.instruction_count = count

        if count > tracker.value.instruction_limit
          LibLua.pushstring(state, "instruction limit exceeded (#{tracker.value.instruction_limit})")
          LibLua.error(state)
          return
        end

        # Check wall-clock time.
        if tracker.value.time_limit > 0
          elapsed = (Time.instant - tracker.value.start_instant).total_seconds
          if elapsed > tracker.value.time_limit
            LibLua.pushstring(state, "time limit exceeded (#{tracker.value.time_limit}s)")
            LibLua.error(state)
          end
        end
      }

      # The C entry every guarded `string.*` wrapper calls: a dispatcher that
      # runs the original function named by its light-userdata upvalue (the
      # `String` pointer set at install time). It checks the deadline, bounds
      # the subject, refuses an over-complex pattern, then calls the named
      # original with the wrapper's arguments and returns its results.
      #
      # A count hook does not fire inside the original C call, and Crystal
      # cannot interrupt it, so the guards run BEFORE the call — see
      # `PATTERN_SIZE_LIMIT` and `PATTERN_QUANTIFIER_LIMIT`.
      @@guarded_dispatch_cfun : LibLua::CFunction = ->(state : LibLua::State) {
        Engine.pattern_dispatch(state)
      }

      # Runs one guarded `string.*` call. Upvalue 1 names the original
      # (`"find"`, `"match"`, `"gmatch"`, `"gsub"`); the arguments are the
      # caller's.
      def self.pattern_dispatch(state : LibLua::State) : Int32
        Engine.check_pattern_deadline(state)

        # The function name rides a light-userdata upvalue (a `String` pointer
        # owned by `@pattern_names`), so the dispatcher never trusts a
        # caller-side argument for the function selection.
        name = Box(String).unbox(LibLua.touserdata(state, ::Lua.registry_index - 1))

        # The subject is argument 1 and the pattern is argument 2 for every
        # guarded function. `lua_rawlen` on a non-string is 0, so a non-string
        # argument is not size-bounded here; the original raises its own
        # argument-type error.
        if LibLua.rawlen(state, 1) > PATTERN_SIZE_LIMIT
          LibLua.pushstring(state, "pattern subject exceeds the #{PATTERN_SIZE_LIMIT}-byte limit")
          LibLua.error(state)
          return 0
        end

        # Refuse an over-complex pattern before the C matcher runs. A pattern
        # with too many quantifiers backtracks past the time budget inside a
        # single C call that cannot be interrupted, so the check must happen
        # here, not after. A non-string pattern is left to the original's own
        # type error.
        if pattern = read_string_arg(state, 2)
          if quantifier_count(pattern) > PATTERN_QUANTIFIER_LIMIT
            LibLua.pushstring(state, "pattern is too complex: at most #{PATTERN_QUANTIFIER_LIMIT} quantifiers are allowed")
            LibLua.error(state)
            return 0
          end
        end

        # Call the named original with the wrapper's arguments. The original
        # is the function this wrapper replaced, captured in a protected
        # registry table (`__facet_string_originals`) at install time — never
        # `string.<name>`, which is the wrapper and would recurse.
        #
        # Stack before: [arg1 .. argN]. Pushing the originals table, the
        # original, and N copies of the args makes it
        # [arg1 .. argN, originals, original, arg1 .. argN]; `pcallk`
        # consumes `original` + the N arg copies and leaves the results on
        # top: [arg1 .. argN, originals, r1 .. rM].
        arg_count = LibLua.gettop(state)
        LibLua.getfield(state, ::Lua.registry_index, "__facet_string_originals")
        LibLua.getfield(state, -1, name) # pushes the original, keeps the table
        (1..arg_count).each { |i| LibLua.pushvalue(state, i) }
        status = LibLua.pcallk(state, arg_count, -1, 0, 0, nil)
        if status != 0
          LibLua.error(state)
          return 0
        end

        # The C function returns the top N values as its results. Only the
        # original's results may remain, so drop the leading args and the
        # originals table, keeping the `M` results on top: rotate them to the
        # bottom, then truncate.
        total = LibLua.gettop(state)
        result_count = total - arg_count - 1 # [args(N) | originals(1) | results(M)]
        if result_count > 0
          LibLua.rotate(state, 1, result_count) # results first, args+originals after
        end
        LibLua.settop(state, result_count)

        Engine.check_pattern_deadline(state)

        result_count
      end

      # Reads stack index `index` as a String when it holds a string value
      # (numbers coerce, like Lua), else nil.
      private def self.read_string_arg(state : LibLua::State, index : Int32) : String?
        return nil if LibLua.isstring(state, index) == 0
        ptr = LibLua.tolstring(state, index, out len)
        return nil if ptr.null?
        String.new(ptr, len)
      end

      # Counts the backtrack points in a Lua pattern: an unescaped `*`, `+`,
      # `-`, or `?` (a `%`-escaped character is a literal, not a quantifier).
      # This is the exponent of the pattern's worst-case backtracking cost, so
      # capping it bounds the work of the C match call.
      private def self.quantifier_count(pattern : String) : Int32
        count = 0
        escaped = false
        pattern.each_char do |ch|
          if escaped
            escaped = false
            next
          end
          if ch == '%'
            escaped = true
          elsif ch.in?('*', '+', '-', '?')
            count += 1
          end
        end
        count
      end

      # Raises the time-limit error when the tracker's deadline has passed.
      # A non-sandboxed engine has no tracker, so the check is a no-op.
      def self.check_pattern_deadline(state : LibLua::State) : Nil
        LibLua.getallocf(state, out ud)
        return if ud.null?
        tracker = ud.as(SandboxTracker*)
        return unless tracker.value.time_limit > 0
        elapsed = (Time.instant - tracker.value.start_instant).total_seconds
        if elapsed > tracker.value.time_limit
          LibLua.pushstring(state, "time limit exceeded (#{tracker.value.time_limit}s)")
          LibLua.error(state)
        end
      end

      # ── Instance ───────────────────────────────────────────────────────

      @tracker_ptr : Pointer(Void)

      # Keeps the guarded `string.*` wrapper name strings alive for the
      # engine's lifetime (each dispatcher closure holds a pointer to one).
      @pattern_names = [] of String

      # Boxed name pointers, stable for the engine's lifetime.
      @pattern_boxes = [] of Void*

      # The wrappers are installed lazily, on the first `run`. Installing them
      # needs the error handler, which the shard's `Stack` builds by running
      # its own chunk — and the shard refuses to run chunks on an empty stack.
      @pattern_guards_installed = false

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
          install_pattern_guards_once!
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

        @tracker_ptr = LibC.malloc(sizeof(SandboxTracker))
        @tracker_ptr.as(SandboxTracker*).value = SandboxTracker.new(
          limit: limit_bytes > 0 ? limit_bytes : 0_i64,
          original_allocf: original_allocf,
          original_ud: original_ud,
        )

        LibLua.setallocf(state, @@memory_allocator, @tracker_ptr)
      end

      # Installs the `string.*` pattern-match guards (S8). Each guarded
      # function is wrapped in a closure that bounds the subject and pattern
      # size and checks the deadline before and after the C call. See
      # `@@guarded_dispatch_cfun` and `PATTERN_SIZE_LIMIT`.
      private def install_pattern_guards! : Nil
        state = stack_not_nil!.state

        # The originals are captured before any wrapper replaces them. This
        # runs once, on the first `run` (see `install_pattern_guards_once!`),
        # and the `string` table is already loaded by then. The originals
        # table sits at stack index 1 and the string table at index 2 while
        # each function is copied on top and stored into the table.
        LibLua.createtable(state, 0, GUARDED_STRING_FUNCTIONS.size) # index 1
        LibLua.getglobal(state, "string")                           # index 2
        GUARDED_STRING_FUNCTIONS.each do |name|
          LibLua.pushvalue(state, 2)       # [originals, string, string]
          LibLua.getfield(state, -1, name) # [originals, string, string, fn]
          LibLua.setfield(state, 1, name)  # originals[name] = fn
          LibLua.settop(state, 2)          # [originals, string]
        end
        LibLua.pushvalue(state, 1) # [originals, string, originals]
        LibLua.setfield(state, ::Lua.registry_index, "__facet_string_originals")
        LibLua.settop(state, -3) # []

        # One dispatcher closure per name, with the name string as its
        # light-userdata upvalue. It is installed as `string.<name>`, so a
        # script call reaches the dispatcher with its own arguments.
        LibLua.getglobal(state, "string")
        GUARDED_STRING_FUNCTIONS.each do |name|
          @pattern_names << name
          name_ptr = Box.box(name)
          @pattern_boxes << name_ptr
          LibLua.pushlightuserdata(state, name_ptr)
          LibLua.pushcclosure(state, @@guarded_dispatch_cfun, 1)
          LibLua.setfield(state, -2, name) # string[name] = closure
        end
        LibLua.settop(state, -2) # drop the string table
      end

      # Installs the `string.*` guards on the first run only.
      private def install_pattern_guards_once! : Nil
        return if @pattern_guards_installed
        @pattern_guards_installed = true
        install_pattern_guards!
      end

      # Installs the combined instruction-count and wall-clock time hook.
      # Runs after `set_memory_limit!`: the hook state lives in the
      # tracker that method allocates.
      private def set_combined_hook!(instruction_limit : Int64, time_limit_s : Float64) : Nil
        state = stack_not_nil!.state
        tracker = @tracker_ptr.as(SandboxTracker*)
        tracker.value.instruction_limit = instruction_limit
        tracker.value.time_limit = time_limit_s
        LibLua.sethook(state, @@combined_hook, LUA_MASKCOUNT, HOOK_CHECK_EVERY)
      end

      # Resets the instruction counter and the start instant before each
      # run. The state belongs to this engine, so an overlapping run on
      # another engine cannot reset this script's budget. Non-sandboxed
      # engines have no tracker and no hook; nothing to reset.
      private def reset_hook_state! : Nil
        return if @tracker_ptr.null?
        tracker = @tracker_ptr.as(SandboxTracker*)
        tracker.value.instruction_count = 0_i64
        tracker.value.start_instant = Time.instant
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
