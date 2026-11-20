# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../lua"
require "../cron/parser"
require "../validation_error"
require "./definition"

module Facet
  module Hooks
    # Authoring-time validator for hook definitions.
    #
    # Runs at `core.Domain` create/update time (via `Document::Update`'s
    # `validate_rbac_definitions?` dispatch) and on demand from the
    # `Domain::Check` `/check` report. The checks are pure: no DB access, no
    # cross-domain resolution. The runtime registry performs the runtime
    # safety net (draft filtering, etc.) — this validator only catches
    # syntactic and structural mistakes that would otherwise surface at the
    # first fire.
    #
    # ## Checks
    #
    # 1. Hook ids are unique within the array.
    # 2. `script` compiles in a fresh `Lua::Engine` and returns a Lua table.
    # 3. The script's export table has the required function (`on_event` for
    #    `:event` hooks, `on_schedule` for `:schedule` hooks) and it is a
    #    function.
    # 4. For `:schedule` hooks, the cron expression is accepted by
    #    `Facet::Cron::Parser` and passes the restrictiveness check below.
    #
    # ## Cron restrictiveness
    #
    # The `cron_parser` shard accepts `@hourly`-style macros, a 6-field
    # seconds form, and `L` / `W` / `#` modifiers. The hooks surface is
    # deliberately smaller: **5 numeric fields only, with `/` step
    # repetition**, no macros and no modifiers. Each field must match
    # `^(\*|\d+(-\d+)?(\/\d+)?)(,\1)*$`. This is enforced here rather than
    # in the parser so the error points at the hook author.
    module Validator
      # Required Lua export name per hook kind.
      REQUIRED_EXPORT = {:event => "on_event", :schedule => "on_schedule"}

      # Validates a parsed array of hooks. Returns an empty array when valid.
      def self.validate(hooks : Array(Hooks::Definition::Hook)) : Array(Facet::ValidationError)
        errors = [] of Facet::ValidationError
        validate_unique_ids(hooks, errors)
        hooks.each { |hook| validate_hook(hook, errors) }
        errors
      end

      def self.validate_unique_ids(hooks : Array(Hooks::Definition::Hook), errors : Array(Facet::ValidationError)) : Nil
        seen = Set(String).new
        hooks.each do |hook|
          unless seen.add?(hook.id)
            errors << Facet::ValidationError.new(
              field: "hooks",
              message: "Duplicate hook id '#{hook.id}' — ids must be unique within the domain",
              code: "schema",
            )
          end
        end
      end

      def self.validate_hook(hook : Hooks::Definition::Hook, errors : Array(Facet::ValidationError)) : Nil
        prefix = "hooks.#{hook.id}"

        export = compile_script(hook, prefix, errors)
        return if export.nil? # compile error already recorded

                  # Required export function per kind.
        required_name = REQUIRED_EXPORT[hook.kind]
        func = export[required_name]?
        if func.nil?
          errors << Facet::ValidationError.new(
            field: "#{prefix}.script",
            message: "Hook '#{hook.id}' expects exported function '#{required_name}', but it was not found",
            code: "schema",
          )
        elsif !func.is_a?(::Lua::Function)
          errors << Facet::ValidationError.new(
            field: "#{prefix}.script",
            message: "Hook '#{hook.id}': export '#{required_name}' must be a function",
            code: "schema",
          )
        end

        return unless hook.kind == :schedule

        # Cron expression restrictiveness — only `:schedule` hooks.
        validate_cron_expression(hook, prefix, errors) if hook.schedule
      end

      # Compiles the Lua script and returns its export table (a
      # `Hash(String, Lua::Engine::Value)`) or `nil` on failure. The engine
      # is closed in every path. Mirrors `Doctype::ScriptValidator`'s shape.
      def self.compile_script(
        hook : Hooks::Definition::Hook,
        prefix : String,
        errors : Array(Facet::ValidationError),
      ) : Hash(String, Lua::Engine::Value)?
        engine = Lua::Engine.new
        result = begin
          engine.run(hook.script)
        rescue ex : Lua::Engine::Error
          errors << Facet::ValidationError.new(
            field: "#{prefix}.script",
            message: script_error_message(hook.id, ex),
            code: "schema",
          )
          engine.close
          return nil
        end

        export = result.as?(Hash(String, Lua::Engine::Value))
        if export.nil?
          errors << Facet::ValidationError.new(
            field: "#{prefix}.script",
            message: "Hook '#{hook.id}' script must return a Lua table (use `local export = {}; ...; return export`)",
            code: "schema",
          )
          engine.close
          return nil
        end

        engine.close
        export
      end

      # Validates the cron expression by first enforcing the hooks-specific
      # restrictiveness (5 numeric fields, `/` step repetition, no macros, no
      # `L` / `W` / `#` modifiers), then delegating range validation to
      # `Facet::Cron::Parser`. Restrictiveness runs first so the macro /
      # field-count failures get a clearer message than the shard's generic
      # "not a valid cronline".
      def self.validate_cron_expression(
        hook : Hooks::Definition::Hook,
        prefix : String,
        errors : Array(Facet::ValidationError),
      ) : Nil
        cron = hook.schedule.as(String)

        # 1. Restrictiveness: 5 fields, each one of `*`, `n`, `n-m`, `n/s`,
        #    `n-m/s`, joined by commas. Rejects `@`-macros, a 6-field
        #    seconds form, and `L` / `W` / `#` modifiers by construction.
        fields = cron.split
        unless fields.size == 5 && fields.all?(&.matches?(CRON_FIELD_REGEX))
          errors << Facet::ValidationError.new(
            field: "#{prefix}.schedule",
            message: "Hook '#{hook.id}' cron expression '#{cron}' is not in the supported form " \
                     "(5 numeric fields with `/` step repetition; no `@` macros, no `L` / `W` / `#` modifiers)",
            code: "schema",
          )
          return
        end

        # 2. Range validation — delegated to the shard. Accepts /
        #    range-validates a 5-field expression the restrictiveness check
        #    has already let through.
        begin
          Facet::Cron::Parser.new(cron)
        rescue ex : ArgumentError
          errors << Facet::ValidationError.new(
            field: "#{prefix}.schedule",
            message: "Hook '#{hook.id}' cron expression '#{cron}' is invalid: #{ex.message}",
            code: "schema",
          )
          return
        end
      end

      # Renders one Lua compile/run failure of a hook script. A compile
      # failure is a syntax error; anything else is a plain script error.
      # A script error that names an index on a nil global `export` appends
      # the module-pattern hint — the missing wrapper is the common cause.
      private def self.script_error_message(hook_id : String, ex : Lua::Engine::Error) : String
        case ex.lua_error
        when ::Lua::SyntaxError
          "Hook '#{hook_id}' script syntax error: #{ex.message}"
        else
          raw = ex.message || ""
          message = "Hook '#{hook_id}' script error: #{raw}"
          if raw.includes?("attempt to index a nil value") && raw.includes?("export")
            "#{message} — declare `local export = {}` before `function export.…`"
          else
            message
          end
        end
      end

      # Anchored: matches exactly one 5-field-cron field value with no
      # leftover characters, so a trailing `W` / `L` modifier is rejected
      # (`\d+` would otherwise match the leading digits). Each field is one
      # of: `*`, `*/n`, `n`, `n-m`, `n/s`, `n-m/s`, or a comma list of these.
      # Rejects `@`-macros, a 6-field seconds form, and `L` / `W` / `#`
      # modifiers by construction.
      private CRON_FIELD_REGEX = /\A(?:\*(?:\/\d+)?|\d+(?:-\d+)?(?:\/\d+)?)(?:,(?:\*(?:\/\d+)?|\d+(?:-\d+)?(?:\/\d+)?))*\z/
    end
  end
end
