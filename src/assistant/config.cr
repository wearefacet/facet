# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "yaml"

module Facet
  module Assistant
    # Configuration for the AI Assistant.
    #
    # Holds the API endpoint, model name, system prompt, and other
    # settings that control how the agent behaves. Loaded from the
    # `assistant:` section of `config.{env}.yml`.
    #
    # See `doc/backend/assistant.md` for the full design.
    struct Config
      # Display name shown on every assistant surface — the workspace
      # window, the builder window, and the top-bar entry point all render
      # one name. The runtime settings document pins it (`assistant.name`);
      # the file value and the built-in default ("Assistant") are the
      # fallback tiers.
      getter name : String

      # OpenAI-compatible API endpoint URL.
      getter api_endpoint : String

      # API key for authentication.
      getter api_key : String?

      # Model identifier (e.g. "gpt-4o", "claude-3-opus", "deepseek-chat").
      getter model : String

      # System prompt that sets the agent's behavior and persona.
      getter system_prompt : String?

      # Maximum number of conversation turns to keep in history.
      # nil means unlimited.
      getter max_history : Int32?

      # Maximum tokens in the completion response.
      getter max_tokens : Int32?

      # Sampling temperature (0.0 - 2.0).
      getter temperature : Float64?

      # Whether to automatically execute registered tools when the model
      # requests them.
      getter? auto_execute_tools : Bool

      # TTL (seconds) for Redis-backed cancel keys. A streaming turn's
      # cancel token is published to a Pub/Sub channel and also set as a
      # Redis key with this TTL so late subscribers observe the cancel.
      getter cancel_ttl_seconds : Int32

      # How long a `running` agent turn row may stay un-flipped before
      # `Cron::AssistantTurnSweep` marks it `error`/`interrupted`. Bounds
      # the write for turns whose process died mid-generation.
      getter turn_timeout_seconds : Int32

      # Schedule for the stale-turn sweep task.
      getter turn_sweep_cron : String

      # Retention window (days) for the `assistant_usage` ledger. A ledger
      # row is prunable when it is older than the window AND its
      # conversation has not been updated within the window (a deleted
      # conversation counts as stale — the ledger carries no FK). `0` — the
      # default — never prunes. When set, keep the window at or above the
      # budget's rolling 30-day query window: 31 or more is always safe; a
      # window of 1–30 under-counts every live budget and makes the daily
      # prune pass log a warning.
      getter usage_retention_days : Int32

      # Schedule for the usage-ledger prune task (`Cron::AssistantUsagePrune`).
      getter usage_prune_cron : String

      def initialize(
        @name : String = "Assistant",
        @api_endpoint : String = "https://api.openai.com/v1",
        @api_key : String? = nil,
        @model : String = "gpt-4o",
        @system_prompt : String? = nil,
        @max_history : Int32? = nil,
        @max_tokens : Int32? = nil,
        @temperature : Float64? = nil,
        @auto_execute_tools : Bool = true,
        @cancel_ttl_seconds : Int32 = 15,
        @turn_timeout_seconds : Int32 = 900,
        @turn_sweep_cron : String = "*/5 * * * *",
        @usage_retention_days : Int32 = 0,
        @usage_prune_cron : String = "30 4 * * *",
      )
      end

      # Build an `Agent::Config` from this assistant's settings.
      def to_agent_config : Agent::Config
        Agent::Config.new(
          api_key: @api_key,
          api_endpoint: @api_endpoint,
          model: @model,
          system_prompt: @system_prompt,
          max_history: @max_history,
          max_tokens: @max_tokens,
          temperature: @temperature,
          auto_execute_tools: @auto_execute_tools
        )
      end

      # Parses the `assistant:` section of `config.{env}.yml` into a
      # `Config` instance. Mirrors `Event::Config.from_yaml`. Only fields
      # present in the YAML override defaults; absent keys keep the default.
      #
      # NOTE: `api_key` is loaded here so the file side of the runtime
      # settings (`SystemSettings::AssistantView`) can resolve the
      # fallback tier; per the config golden rule, no consumer reads `ENV`
      # directly.
      def self.from_yaml(raw : YAML::Any?) : self
        return new if raw.nil? || raw.raw.nil?

        # A blank file value reads as unset — an operator leaving `name: ""`
        # means "use the built-in default", mirroring the write gate's
        # refusal of a blank runtime pin.
        file_name = raw["name"]?.try(&.as_s?)

        new(
          name: file_name.presence || "Assistant",
          api_endpoint: raw["api_endpoint"]?.try(&.as_s) || "https://api.openai.com/v1",
          api_key: raw["api_key"]?.try(&.as_s?),
          model: raw["model"]?.try(&.as_s) || "gpt-4o",
          system_prompt: raw["system_prompt"]?.try(&.as_s?),
          max_history: raw["max_history"]?.try(&.as_i?),
          max_tokens: raw["max_tokens"]?.try(&.as_i?),
          temperature: raw["temperature"]?.try(&.as_f?),
          auto_execute_tools: raw["auto_execute_tools"]?.try(&.as_bool?) || true,
          cancel_ttl_seconds: raw["cancel_ttl_seconds"]?.try(&.as_i) || 15,
          turn_timeout_seconds: raw["turn_timeout_seconds"]?.try(&.as_i) || 900,
          turn_sweep_cron: raw["turn_sweep_cron"]?.try(&.as_s) || "*/5 * * * *",
          usage_retention_days: raw["usage_retention_days"]?.try(&.as_i) || 0,
          usage_prune_cron: raw["usage_prune_cron"]?.try(&.as_s) || "30 4 * * *",
        )
      end
    end
  end
end
