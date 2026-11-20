# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Command chain validation ───────────────────────────────────────────────
# Pure logic behind `CLI.run`'s pre-validation pass. It reads nothing but
# its arguments — the caller injects the valid command names and the
# option-taking command names — so specs exercise it without loading the
# application.
module Facet
  class CLI
    # One validated step of a command chain: the command name plus the
    # tokens that belong to it. For a chainable command these are its dash
    # flags (e.g. `--yes`); for an option-taking command they are every
    # token after it — the command's own parser validates them.
    record ChainStep, name : String, flags : Array(String)

    # Raised by `parse_chain` when the chain holds an unknown bare token.
    # `CLI.run` rescues it before any command has executed.
    class ChainError < Exception
    end

    # Splits a raw command list into validated `ChainStep`s:
    #
    # - A bare token after a chainable command must be a known command. An
    #   unknown one raises `ChainError`, so a typo after a destructive
    #   command fails the run instead of executing the command first.
    # - Dash tokens after a chainable command belong to that command as its
    #   flags (e.g. `facet db_reset --yes seed:dev`) and never dispatch as
    #   commands.
    # - An option-taking command consumes the rest of the list; its own
    #   parser validates those tokens.
    def self.parse_chain(commands : Array(String), known : Array(String), option_commands : Array(String)) : Array(ChainStep)
      steps = [] of ChainStep
      idx = 0
      while idx < commands.size
        name = commands[idx]
        raise ChainError.new("Unknown command: #{name}") unless known.includes?(name)

        if option_commands.includes?(name)
          steps << ChainStep.new(name, commands[(idx + 1)..])
          return steps
        end

        flags = commands.skip(idx + 1).take_while(&.starts_with?("-"))
        steps << ChainStep.new(name, flags)
        idx += 1 + flags.size
      end
      steps
    end
  end
end
