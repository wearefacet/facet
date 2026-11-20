# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Assistant
    # Per-turn guard against repeated identical refused tool calls.
    #
    # A poisoned document can make a gullible model re-emit the same refused
    # call until the agent's `max_tool_iterations` cap. One guard instance
    # lives for one registrar invocation (one streaming turn): it counts
    # identical `(tool, arguments)` refusals and, at `REPEAT_REFUSAL_LIMIT`,
    # returns a terminal envelope that tells the model to stop retrying.
    #
    # The envelope is model-facing text only — agent-cr does not read the
    # `terminal` flag. `Stream::TerminalRefusalStop` watches the tool
    # results for it and cancels the turn when a call repeats one; both
    # sides share the shape through `terminal_envelope` / `terminal_result?`
    # and key calls through `call_key`.
    #
    # Successful calls never reach the guard, so a legitimate retry after a
    # state change still works.
    class RefusalGuard
      # Identical refused calls tolerated in one turn before the guard
      # returns a terminal result. `max_tool_iterations` stays the backstop.
      REPEAT_REFUSAL_LIMIT = 3

      # The error-text phrase that marks the terminal envelope. Detection
      # parses the JSON and matches this marker; scanning raw tool-result
      # text would be a guess, not a contract.
      TERMINAL_MARKER = "This refusal is final"

      @counts = Hash(String, Int32).new(0)

      # Counts one refused call and returns the envelope the model sees. The
      # first `REPEAT_REFUSAL_LIMIT - 1` identical refusals return the normal
      # error envelope; the limit-th returns a terminal result.
      def result(tool : String, args : Hash(String, JSON::Any), envelope : String) : String
        count = @counts[call_key(tool, args)] += 1
        return envelope if count < REPEAT_REFUSAL_LIMIT

        self.class.terminal_envelope(tool)
      end

      # Builds the terminal envelope for one tool — the result the model
      # sees at `REPEAT_REFUSAL_LIMIT`. Class-level so the guard and the
      # stream handler that detects its results share one shape.
      def self.terminal_envelope(tool : String) : String
        {
          ok:       false,
          error:    "Repeated refused call to '#{tool}' with identical arguments. #{TERMINAL_MARKER} — stop retrying and tell the user the action did not go through.",
          terminal: true,
        }.to_json
      end

      # True when `content` is the guard's terminal envelope: a JSON object
      # with `terminal: true` and the marker in `error`. Non-JSON content,
      # the normal error envelope, and other tool results answer false.
      def self.terminal_result?(content : String?) : Bool
        return false if content.nil? || content.empty?

        hash = JSON.parse(content).as_h?
        return false if hash.nil?
        return false unless hash["terminal"]?.try(&.as_bool?)

        error = hash["error"]?.try(&.as_s?)
        return false if error.nil?

        error.includes?(TERMINAL_MARKER)
      rescue JSON::Error
        false
      end

      # A stable key for one tool call: the tool name plus its arguments
      # with object keys sorted, so two calls that differ only in JSON key
      # order count as identical. Class-level so the stream handler keys its
      # seen-terminal set the same way.
      def self.call_key(tool : String, args : JSON::Any) : String
        String.build do |io|
          io << tool
          io << '\0'
          canonical_json(args, io)
        end
      end

      private def call_key(tool : String, args : Hash(String, JSON::Any)) : String
        self.class.call_key(tool, JSON::Any.new(args))
      end

      # Writes `value` as JSON with object keys sorted at every depth.
      private def self.canonical_json(value : JSON::Any, io : IO) : Nil
        case raw = value.raw
        when Hash
          io << '{'
          raw.keys.sort!.each_with_index do |key, index|
            io << ',' if index > 0
            io << key.to_json
            io << ':'
            canonical_json(raw[key], io)
          end
          io << '}'
        when Array
          io << '['
          raw.each_with_index do |item, index|
            io << ',' if index > 0
            canonical_json(item, io)
          end
          io << ']'
        else
          io << value.to_json
        end
      end
    end
  end
end
