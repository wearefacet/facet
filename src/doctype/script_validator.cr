# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../lua"
require "../error"

module Facet
  module Doctype
    # Validates that a Lua script conforms to the doctype's action declarations.
    #
    # ## Checks performed
    #
    # 1. The script compiles without syntax errors.
    # 2. The script returns a table (module pattern).
    # 3. For every action declared in `definition.actions`, a corresponding
    #    function exists in the returned table.
    # 4. For every action function, every static `args.<name>` /
    #    `args["<name>"]` read names an arg declared on the action. A
    #    dynamic read (`args[var]`) escapes the static scan and passes.
    #
    # Lifecycle hooks (`create`, `update`, `delete`) are **optional** — if
    # present in the export table they are used; if absent the lifecycle
    # hook is skipped.
    #
    # ## Computed fields
    #
    # Every field with `type: data` and a `compute` value must have a
    # corresponding `compute_{suffix}` function in the export table.
    class ScriptValidator
      # Validates the script against the definition's actions and computed fields.
      #
      # Returns an array of structured errors (empty if valid).
      def self.validate(script : String, definition : DoctypeDefinition) : Array(ValidationError)
        new.validate(script, definition)
      end

      def validate(script : String, definition : DoctypeDefinition) : Array(ValidationError)
        errors = [] of ValidationError

        # 1. Syntax check: try to compile
        engine = Lua::Engine.new
        begin
          result = engine.run(script)
        rescue ex : Lua::Engine::Error
          errors << ValidationError.new(
            field: nil,
            message: script_error_message(ex),
            code: "schema",
          )
          return errors
        end

        # 2. Must return a table
        export = result.as?(Hash(String, Lua::Engine::Value))
        if export.nil?
          errors << ValidationError.new(
            field: nil,
            message: "Script must return a Lua table (use `local export = {}; ...; return export`)",
            code: "schema",
          )
          engine.close
          return errors
        end

        # 3. Check action functions
        definition.actions.each do |action_name, action_def|
          unless export[action_name]?
            errors << ValidationError.new(
              field: nil,
              message: "Action '#{action_name}' expects function '#{action_name}' in script, but it was not found",
              code: "schema",
            )
            next
          end

          next unless check_export(export, action_name, nil, errors)

          check_action_args(script, action_name, action_def, errors)
        end

        # 4. Check migration functions
        definition.migrations.each do |source_version, func_name|
          unless export[func_name]?
            errors << ValidationError.new(
              field: nil,
              message: "Migration from v#{source_version} expects function '#{func_name}' in script, but it was not found",
              code: "schema",
            )
            next
          end

          check_export(export, func_name, nil, errors)
        end

        # 5. Check computed field functions
        definition.computed_field_names.each do |field_name|
          field = definition.fields[field_name]
          compute_name = field.compute

          if compute_name.nil? || compute_name.empty?
            errors << ValidationError.new(
              field: field_name,
              message: "has type 'data' but is missing a 'compute' value",
              code: "schema",
            )
            next
          end

          func_name = "compute_#{compute_name}"

          unless export[func_name]?
            errors << ValidationError.new(
              field: field_name,
              message: "expects function '#{func_name}' in script, but it was not found",
              code: "schema",
            )
            next
          end

          check_export(export, func_name, field_name, errors)
        end

        engine.close
        errors
      end

      # Renders one Lua compile/run failure. The engine surfaces both under
      # one `Lua::Engine::Error`, so the label follows the wrapped shard
      # error: a compile failure is a syntax error, anything else is a
      # plain script error — a nil-global `export` index is a runtime
      # failure, not a syntax one.
      private def script_error_message(ex : Lua::Engine::Error) : String
        case ex.lua_error
        when ::Lua::SyntaxError
          "Script syntax error: #{ex.message}"
        else
          "Script error: #{ex.message}"
        end
      end

      # Checks that a script export entry is a function. Appends an error
      # and returns `false` when the entry is missing or holds another type.
      private def check_export(
        export : Hash(String, Lua::Engine::Value),
        func_name : String,
        field : String?,
        errors : Array(ValidationError),
      ) : Bool
        func = export[func_name]?
        return false if func.nil?

        unless func.is_a?(::Lua::Function)
          errors << ValidationError.new(
            field: field,
            message: "Script export '#{func_name}' must be a function (got #{typeof(func)})",
            code: "schema",
          )
          return false
        end

        true
      end

      # ── Action arg lint (B-117) ────────────────────────────────────

      # Compares the static `args` reads of one action's export function
      # with the args declared on the action. An undeclared read would be
      # nil at runtime — the preflight validator never sees the name — so
      # it blocks authoring with a 422.
      #
      # Documented limit: a dynamic read (`args[var]`) escapes the static
      # scan and passes.
      private def check_action_args(
        script : String,
        action_name : String,
        action_def : ActionDefinition,
        errors : Array(ValidationError),
      ) : Nil
        reads = action_arg_reads(script, action_name)
        return if reads.nil?

        reads.each do |name|
          next if action_def.args.has_key?(name)
          errors << ValidationError.new(
            field: nil,
            message: "Action '#{action_name}' reads args.#{name}, but the action declares no such arg — declare it in the action's args or remove the read",
            code: "schema",
          )
        end
      end

      # Collects the static `args` reads of an action's export function
      # body, or nil when the body cannot be located — the lint then skips
      # the action. The module pattern defines the function as
      # `function export.<name>(...)` or `export.<name> = function(...)`;
      # a function aliased into the export table under another name
      # escapes the scan the same way a dynamic read does.
      private def action_arg_reads(script : String, action_name : String) : Array(String)?
        name = Regex.escape(action_name)
        positions = [] of Int32
        script.scan(/function\s+export\s*\.\s*#{name}\s*\(/) do |m|
          pos = m.begin(0)
          positions << pos + m[0].size if pos
        end
        script.scan(/\bexport\s*\.\s*#{name}\s*=\s*function\s*\(/) do |m|
          pos = m.begin(0)
          positions << pos + m[0].size if pos
        end

        positions.sort.each do |pos|
          reads = ActionBodyScanner.scan(script, pos)
          return reads unless reads.nil?
        end
        nil
      end

      # Walks one Lua function body from its parameter list and collects
      # every static `args.<name>` / `args["<name>"]` read. Returns nil
      # when the body never closes — the scan then has no trusted slice.
      #
      # The walk skips string literals and comments (a message string may
      # contain the word `end`), balances the block keywords, and consumes
      # a `for` / `while` header's own `do` so the header does not count
      # twice. Inside a dynamic `args[...]` index expression it counts
      # square brackets only — keywords there belong to nested literals.
      private class ActionBodyScanner
        @reads = [] of String
        @depth = 0    # 0 = still inside the parameter list
        @await_do = 0 # headers of `for` / `while` that still owe their `do`
        @bracket_depth = 0
        @closed = false
        @broken = false

        def self.scan(script : String, pos : Int32) : Array(String)?
          new(script).run(pos)
        end

        private def initialize(@script : String)
        end

        def run(pos : Int32) : Array(String)?
          i = pos
          while i < @script.size
            if ni = skip_lexeme(i)
              i = ni
              next
            end

            if @bracket_depth > 0
              c = @script[i]
              @bracket_depth += 1 if c == '['
              @bracket_depth -= 1 if c == ']'
              i += 1
              next
            end

            if @depth == 0
              @depth = 1 if @script[i] == ')'
              i += 1
              next
            end

            if ni = consume_args_read(i)
              i = ni
              next
            end

            if ni = consume_keyword(i)
              return nil if @broken
              return @reads.uniq if @closed
              i = ni
              next
            end

            i += 1
          end
          nil
        end

        # Advances past a string literal or a comment at `i`, or returns
        # nil when the position holds none.
        private def skip_lexeme(i : Int32) : Int32?
          c = @script[i]
          if c == '-' && @script[i + 1]? == '-'
            return skip_comment(i)
          end
          return skip_short_string(i) if c == '"' || c == '\''
          if c == '[' && (level = long_bracket_level(i))
            return skip_long_bracket(i, level)
          end
          nil
        end

        # Records one static read at `i` (the `a` of `args`) and returns
        # the position to continue from, or nil when the shape is not a
        # static read. A dynamic `args[...]` index switches the walk into
        # bracket-counting mode instead.
        private def consume_args_read(i : Int32) : Int32?
          return nil unless word_at?(i, "args")
          return nil unless word_boundary_before?(i)
          prev = i == 0 ? nil : @script[i - 1]?
          return nil if prev == '.' || prev == ':'

          j = skip_ws(i + "args".size)
          c = @script[j]?
          if c == '.'
            return dotted_read(j)
          elsif c == '['
            return bracket_read(j)
          end
          j # `args` used as a value, no read of a named arg
        end

        private def dotted_read(dot_pos : Int32) : Int32
          j = skip_ws(dot_pos + 1)
          name_start = j
          j = read_ident(j)
          @reads << @script[name_start, j - name_start] if j > name_start
          j
        end

        private def bracket_read(open_pos : Int32) : Int32?
          j = skip_ws(open_pos + 1)
          c = @script[j]?
          if c != '"' && c != '\''
            @bracket_depth = 1
            return j # dynamic index — the documented lint limit
          end

          parts = short_string_parts(j)
          return nil unless parts
          content, after = parts
          m = skip_ws(after)
          if @script[m]? == ']' && ident_shaped?(content)
            @reads << content
            return m + 1
          end
          after # a quoted non-identifier key — nothing to check
        end

        # Advances past a block keyword at `i`, or returns nil.
        private def consume_keyword(i : Int32) : Int32?
          return nil unless word_boundary_before?(i)
          c = @script[i]
          case c
          when 'f'
            ni = advance(i, "function") { @depth += 1 }
            return ni if ni
            return advance(i, "for") { @depth += 1; @await_do += 1 }
          when 'i'
            return advance(i, "if") { @depth += 1 }
          when 'w'
            return advance(i, "while") { @depth += 1; @await_do += 1 }
          when 'r'
            return advance(i, "repeat") { @depth += 1 }
          when 'd'
            return advance(i, "do") do
              if @await_do > 0
                @await_do -= 1
              else
                @depth += 1
              end
            end
          when 'e'
            return advance(i, "end") { close_body }
          when 'u'
            return advance(i, "until") do
              @depth -= 1
              @broken = true if @depth < 1
            end
          end
          nil
        end

        private def advance(i : Int32, word : String, &) : Int32?
          return nil unless word_at?(i, word)
          yield
          i + word.size
        end

        private def close_body : Nil
          @depth -= 1
          @closed = true if @depth == 0
        end

        # ── Lexical helpers ──────────────────────────────────────────

        private def word_at?(i : Int32, word : String) : Bool
          return false if i + word.size > @script.size
          return false if @script[i, word.size] != word
          after = @script[i + word.size]?
          !(after && ident_char?(after))
        end

        private def word_boundary_before?(i : Int32) : Bool
          return true if i == 0
          prev = @script[i - 1]?
          prev.nil? || !ident_char?(prev)
        end

        private def read_ident(i : Int32) : Int32
          j = i
          while (c = @script[j]?) && ident_char?(c)
            j += 1
          end
          j
        end

        private def skip_ws(i : Int32) : Int32
          j = i
          while (c = @script[j]?) && c.ascii_whitespace?
            j += 1
          end
          j
        end

        private def skip_comment(i : Int32) : Int32
          if level = long_bracket_level(i + 2)
            return skip_long_bracket(i + 2, level)
          end
          j = i + 2
          while j < @script.size
            return j + 1 if @script[j] == '\n'
            j += 1
          end
          j
        end

        private def skip_short_string(i : Int32) : Int32
          quote = @script[i]
          j = i + 1
          while j < @script.size
            c = @script[j]
            if c == '\\'
              j += 2
              next
            end
            return j + 1 if c == quote
            j += 1
          end
          @script.size
        end

        # Returns the raw content between the quotes at `i` plus the
        # position after the closing quote, or nil when unterminated.
        private def short_string_parts(i : Int32) : {String, Int32}?
          quote = @script[i]
          j = i + 1
          start = j
          while j < @script.size
            c = @script[j]
            if c == '\\'
              j += 2
              next
            end
            return {@script[start, j - start], j + 1} if c == quote
            j += 1
          end
          nil
        end

        private def long_bracket_level(i : Int32) : Int32?
          return nil unless @script[i]? == '['
          j = i + 1
          level = 0
          while @script[j]? == '='
            level += 1
            j += 1
          end
          return level if @script[j]? == '['
          nil
        end

        private def skip_long_bracket(i : Int32, level : Int32) : Int32
          j = i + level + 2
          while j < @script.size
            if @script[j] == ']'
              k = j + 1
              eq = 0
              while @script[k]? == '='
                eq += 1
                k += 1
              end
              return k + 1 if eq == level && @script[k]? == ']'
            end
            j += 1
          end
          @script.size
        end

        private def ident_char?(c : Char) : Bool
          c.ascii_alphanumeric? || c == '_'
        end

        private def ident_shaped?(s : String) : Bool
          return false if s.empty?
          first = s[0]
          return false unless first.ascii_letter? || first == '_'
          s.each_char { |c| return false unless ident_char?(c) }
          true
        end
      end
    end
  end
end
