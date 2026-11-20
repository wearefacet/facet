# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "http/client"
require "http/headers"
require "pg"
require "../error"
require "./views"

module Facet
  module SystemSettings
    # The "Send test request" action behind the platform settings page's
    # assistant group — the assistant counterpart of `MailTest`.
    #
    # One synchronous, non-streaming chat completion through the **saved**
    # assistant settings: the probe rides the effective document-over-file
    # view (`AssistantView.build`), exactly like a real turn start. Pending
    # edits in the form do not participate; the operator saves first.
    #
    # Blocking by decision: the operator waits for the provider, and the
    # provider error comes back as the message. That is the whole point of
    # the action — "401 invalid_api_key" or "connection refused" is the
    # diagnostic. The request is minimal (a one-word prompt, `max_tokens`
    # capped), so the wait is short and the cost negligible.
    #
    # Facet-side rejections answer `422` (no API key resolves — the
    # unconfigured posture); a provider or transport failure answers `502`
    # with the transport's own message. The probe never runs agent tools,
    # never touches a conversation, and never writes a turn row.
    #
    # `probe` is the seam a spec replaces to observe or fail the request
    # without a live provider: it receives the endpoint, the resolved key,
    # and the model, and returns the HTTP status and body.
    module AssistantTest
      # The smallest request that proves the endpoint, the key, and the
      # model name all work. A one-word reply keeps the wait and cost low.
      PROBE_PROMPT = "Reply with the single word: pong"

      # Caps the probe's completion — enough for the one-word reply, small
      # enough that a misbehaving provider cannot drag the request out.
      PROBE_MAX_TOKENS = 16

      # Runs one probe. Returns the resolved model, endpoint, and the reply
      # snippet on success, or the `ServiceError` to render.
      def self.call(
        db : DB::Connection,
        probe : Proc(String, String?, String, Tuple(Int32, String)) = ->(endpoint : String, key : String?, model : String) { dial(endpoint, key, model) },
      ) : Result | Facet::ServiceError
        config = AssistantView.build(db, nil)

        # No key resolves — the unconfigured posture the settings page
        # exists to fix. Refuse before the wire; the message names the fix.
        key = config.api_key
        if key.nil? || key.empty?
          return Facet::ServiceError.new(
            422,
            "The assistant is not configured: no API key resolves. Set assistant.api_key " \
            "(or the FACET_AI_API_KEY environment variable) and save before testing",
            [ValidationError.new(field: "assistant.api_key", message: "is not set",
              code: "required")],
          )
        end

        status, body = begin
          probe.call(config.api_endpoint, key, config.model)
        rescue ex : Exception
          # The transport is the remote authority: report what it said. The
          # route turns this into a `502` — the failure is upstream, not a
          # bad request.
          return Facet::ServiceError.new(502, "Assistant request failed: #{ex.message}")
        end

        unless status.in?(200..299)
          return Facet::ServiceError.new(
            502,
            "Assistant request failed: HTTP #{status} — #{body_snippet(body)}",
          )
        end

        Result.new(model: config.model, endpoint: config.api_endpoint, reply: extract_reply(body))
      end

      # One non-streaming chat completion against the OpenAI-compatible
      # endpoint. Mirrors the provider's request shape (`chat/completions`,
      # Bearer auth) without pulling in the streaming machinery.
      private def self.dial(endpoint : String, api_key : String?, model : String) : {Int32, String}
        uri = URI.parse(endpoint)
        unless uri.scheme && uri.host
          raise ArgumentError.new("assistant.api_endpoint is not a valid URL: #{endpoint}")
        end

        headers = ::HTTP::Headers{
          "Content-Type" => "application/json",
          "Accept"       => "application/json",
        }
        headers["Authorization"] = "Bearer #{api_key}" if api_key

        body = {
          model:      model,
          messages:   [{role: "user", content: PROBE_PROMPT}],
          max_tokens: PROBE_MAX_TOKENS,
          stream:     false,
        }.to_json

        client = ::HTTP::Client.new(uri)
        client.connect_timeout = 5.seconds
        client.read_timeout = 30.seconds
        response = client.post(chat_path(uri), headers: headers, body: body)
        {response.status_code, response.body}
      end

      # The chat-completions path derived from the endpoint — the same
      # normalization the streaming provider applies (collapse duplicate
      # slashes, strip the trailing slash, append the resource path).
      private def self.chat_path(uri : URI) : String
        base = uri.path.empty? || uri.path == "/" ? "" : uri.path.gsub(/\/+/, "/").rstrip('/')
        "#{base}/chat/completions"
      end

      # The first choice's text content, when the response shape carries
      # one. A probe only needs proof of life — a parse miss keeps `nil`,
      # and the success surface reports model + endpoint alone.
      private def self.extract_reply(body : String) : String?
        content = JSON.parse(body).dig?("choices", 0, "message", "content")
        text = content.try(&.as_s?).try(&.strip)
        return nil if text.nil? || text.empty?

        text = "#{text[0, 120]}…" if text.size > 120
        text
      rescue JSON::ParseException
        nil
      end

      # One line of the transport's own words for the error surface. Capped
      # so a chatty provider error cannot flood the settings page.
      private def self.body_snippet(body : String) : String
        flat = body.gsub(/\s+/, " ").strip
        flat = "#{flat[0, 200]}…" if flat.size > 200
        flat.empty? ? "(empty response)" : flat
      end

      # What the settings page shows on success: which model answered, at
      # which endpoint, and (when the shape allowed) what it said.
      record Result,
        model : String,
        endpoint : String,
        reply : String?
    end
  end
end
