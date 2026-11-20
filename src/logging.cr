# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "log/json"
require "./config"

module Facet
  # Explicit, config-driven log setup.
  #
  # Logging must not hang on a transitive shard call: the `shrine` shard
  # runs `Log.setup_from_env` at require time (level from `LOG_LEVEL`,
  # stdlib `Log::ShortFormat` to STDOUT), and every entry point inherits
  # that binding only because `src/artifact/uploader.cr` requires shrine.
  # `Facet::Logging.setup` runs afterwards from `Facet::CLI.run` and
  # replaces the binding — `Log.setup` clears the builder first, so the
  # explicit setup always wins over the require-time one.
  #
  # Config keys live in the optional `logs:` section of
  # `config.{env}.yml` (`logs.format`, `logs.level`) — the YAML file is
  # the single source of truth. `LOG_LEVEL` does not affect the app
  # process (shrine still reads it first at require time; our setup
  # replaces the binding).
  #
  # See `doc/backend/logging.md`.
  module Logging
    # Text mode delegates to the stdlib `Log::ShortFormat` — the exact
    # formatter the accidental shrine setup used, so the switch from the
    # require-time binding to this module is byte-identical on stdout.
    private struct TextFormatter
      include ::Log::Formatter

      def initialize
      end

      def format(entry : ::Log::Entry, io : IO) : Nil
        ::Log::ShortFormat.format(entry, io)
      end
    end

    # One JSON line per entry: `ts`, `level`, `source`, `message`,
    # `exception {class, message}` when present, and `context` when the
    # entry carries `Log` metadata. No backtrace — traces carry error
    # state (see `doc/backend/telemetry.md`).
    struct JsonFormatter
      include ::Log::Formatter

      def initialize
      end

      def format(entry : ::Log::Entry, io : IO) : Nil
        JSON.build(io) do |json|
          json.object do
            json.field("ts", entry.timestamp.to_utc.to_rfc3339)
            json.field("level", entry.severity.label)
            json.field("source", entry.source)
            json.field("message", entry.message)
            if ex = entry.exception
              json.field("exception") do
                json.object do
                  json.field("class", ex.class.name)
                  json.field("message", ex.message)
                end
              end
            end
            unless entry.context.empty?
              json.field("context") do
                entry.context.to_json(json)
              end
            end
          end
        end
      end
    end

    # Binds every log source to one STDOUT backend with the configured
    # level and format. Raises on an invalid `level` — the config loader
    # already validates both keys, so this is the defensive net for
    # callers that build a `LogsConfig` by hand. The `builder` keyword
    # mirrors the stdlib `Log.setup` shape; specs pass an isolated
    # builder so examples never re-bind the process-wide one.
    def self.setup(config : Config::LogsConfig, *, builder : ::Log::Builder = ::Log.builder) : Nil
      severity = parse_severity(config.level)
      backend = ::Log::IOBackend.new(formatter: formatter(config.format))
      ::Log.setup(severity, backend, builder: builder)
    end

    # The formatter for a configured format name. Raises on anything but
    # `text` / `json` (same contract as the config loader).
    def self.formatter(format : String) : ::Log::Formatter
      case format
      when "text" then TextFormatter.new
      when "json" then JsonFormatter.new
      else
        raise ArgumentError.new("Invalid logs.format '#{format}' — expected 'text' or 'json'.")
      end
    end

    private def self.parse_severity(level : String) : ::Log::Severity
      ::Log::Severity.parse?(level) ||
        raise ArgumentError.new("Invalid logs.level '#{level}' — expected one of " \
                                "trace, debug, info, notice, warn, error, fatal.")
    end
  end
end
