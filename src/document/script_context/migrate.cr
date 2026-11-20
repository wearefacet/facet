# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./base"

module Facet
  module Document
    module ScriptContext
      # ── MigrateContext ────────────────────────────────────────────────

      # Context for running a single migration function on a document.
      #
      # Calls `_MODULE.{func_name}(ctx)` where `ctx.root` is the document
      # content at the source schema version. The function transforms
      # `ctx.root` to the next schema version.
      #
      # Migration functions receive the same `ctx` table as lifecycle hooks:
      #   ctx.root      — document content (source schema), mutable
      #   ctx.error(msg) — validation error collector
      #   ctx.actor_id  — always "system:migration"
      #   ctx.now       — ISO 8601 timestamp
      class Migrate < Base
        @func_name : String

        # The (potentially mutated) root document after migration runs.
        getter root_document : JSON::Any

        def initialize(
          script : String,
          func_name : String,
          document : JSON::Any,
          actor_id : String = "system:migration",
          now : Time = Time.utc,
          & : Migrate -> _
        )
          super(Lua::Sandbox.new, script)
          @root_document = document
          @func_name = func_name
          setup_ctx(document, actor_id, now)
          yield self
        ensure
          close
        end

        # Runs `_MODULE.validate(ctx)` (if defined) then `_MODULE.{func_name}(ctx)`.
        # Returns the list of validation error messages (empty if successful).
        def run : Array(ValidationError)
          errors = run_hooks(@func_name)
          @root_document = read_root
          errors
        end
      end
    end
  end
end
