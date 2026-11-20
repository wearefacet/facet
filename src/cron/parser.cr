# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "cron_parser"

# Cron expression parser.
#
# Thin wrapper over the `cron_parser` shard. The `CronParser` shard
# validates the expression eagerly in its constructor — an invalid cron
# string raises `ArgumentError` here rather than at the first `next`/`last`
# call. Supports 5-field (min hour dom mon dow) and 6-field (with seconds)
# cron expressions, plus Vixie-style `@hourly` / `@daily` / `@weekly` /
# `@monthly` / `@yearly` aliases.
class Facet::Cron::Parser
  @parser : CronParser

  # Parses a cron expression. Raises `ArgumentError` if the expression is
  # malformed or uses the unsupported `@reboot` alias.
  def initialize(@expression : String)
    @parser = CronParser.new(@expression)
  end

  # Next fire time strictly after `from`.
  def next(from : Time = Time.utc) : Time
    @parser.next(from)
  end

  # Previous fire time strictly before `from`.
  def last(from : Time = Time.utc) : Time
    @parser.last(from)
  end

  getter expression : String
end
