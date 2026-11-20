# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "json"
require "log"
require "../src/logging"

# `Facet::Logging` — the explicit, config-driven log setup that replaces
# the require-time binding the shrine shard performs.
#
# The examples below never touch the process-wide `Log.builder`: they run
# against isolated builders or drive the formatters through hand-built
# `Log::Entry` values. `Log.setup` clears every binding on its target
# builder, and other spec files (e.g. `domain_watcher_spec`) hold capture
# bindings on the global builder that must survive this file.

# One isolated builder bound to an in-memory backend with the given
# formatter, plus the IO it writes to.
private def captured_log_builder(formatter : ::Log::Formatter, level : ::Log::Severity)
  io = IO::Memory.new
  backend = ::Log::IOBackend.new(io, dispatcher: ::Log::DispatchMode::Sync)
  backend.formatter = formatter
  builder = ::Log::Builder.new
  builder.bind("*", level, backend)
  {builder, io}
end

# A hand-built entry — the formatters are pure functions of one entry.
private def make_log_entry(severity : ::Log::Severity, message : String, source : String = "facet.probe", exception : Exception? = nil, context : ::Log::Metadata? = nil)
  ::Log::Entry.new(source, severity, message, context || ::Log::Metadata.empty, exception, timestamp: Time.utc(2026, 1, 1, 12, 0, 0))
end

describe Facet::Logging do
  describe ".formatter" do
    it "raises on an unknown format" do
      expect_raises(ArgumentError, "logs.format") do
        Facet::Logging.formatter("xml")
      end
    end
  end

  describe ".setup" do
    it "binds the configured level to every source" do
      builder = ::Log::Builder.new
      Facet::Logging.setup(Facet::Config::LogsConfig.new(format: "text", level: "warn"), builder: builder)
      builder.for("facet.probe").level.should eq(::Log::Severity::Warn)
    end

    it "raises on an invalid level" do
      builder = ::Log::Builder.new
      expect_raises(ArgumentError, "logs.level") do
        Facet::Logging.setup(Facet::Config::LogsConfig.new(format: "text", level: "bogus"), builder: builder)
      end
    end

    it "replaces a previously bound builder (the explicit setup wins)" do
      # Simulate the shrine require-time binding: LOG_LEVEL-driven, all
      # sources. The explicit setup must replace, not stack on, that
      # binding — `Log.setup` clears the builder first.
      ENV["LOG_LEVEL"] = "debug"
      builder = ::Log::Builder.new
      begin
        Log.setup_from_env(builder: builder)
        builder.for("facet.probe").level.should eq(::Log::Severity::Debug)

        Facet::Logging.setup(Facet::Config::LogsConfig.new(format: "text", level: "error"), builder: builder)
        builder.for("facet.probe").level.should eq(::Log::Severity::Error)
      ensure
        ENV.delete("LOG_LEVEL")
      end
    end
  end

  describe "text format" do
    it "renders the stdlib short format" do
      io = IO::Memory.new
      Facet::Logging.formatter("text").format(make_log_entry(:info, "text line"), io)

      output = io.to_s
      output.should contain("INFO - facet.probe: text line")
      output.should_not contain("ts=")
    end
  end

  describe "JSON format" do
    it "renders the entry shape" do
      io = IO::Memory.new
      Facet::Logging.formatter("json").format(make_log_entry(:info, "hello"), io)

      entry = JSON.parse(io.to_s)
      entry["ts"].as_s.should eq("2026-01-01T12:00:00Z")
      entry["level"].as_s.should eq("INFO")
      entry["source"].as_s.should eq("facet.probe")
      entry["message"].as_s.should eq("hello")
      as_object = entry.as_h
      as_object.has_key?("exception").should be_false
      as_object.has_key?("context").should be_false
    end

    it "carries the exception class and message" do
      io = IO::Memory.new
      exception = RuntimeError.new("boom")
      Facet::Logging.formatter("json").format(make_log_entry(:error, "failed", exception: exception), io)

      entry = JSON.parse(io.to_s)
      entry["level"].as_s.should eq("ERROR")
      entry["exception"]["class"].as_s.should eq("RuntimeError")
      entry["exception"]["message"].as_s.should eq("boom")
    end

    it "carries the log context when non-empty" do
      builder, io = captured_log_builder(Facet::Logging.formatter("json"), :info)
      Log.context.clear
      begin
        # The entry captures the fiber-local context at emit time.
        Log.with_context(request_id: "abc-123") do
          builder.for("facet.probe").info { "with context" }
        end
      ensure
        Log.context.clear
      end

      entry = JSON.parse(io.to_s)
      entry["context"]["request_id"].as_s.should eq("abc-123")
    end

    it "filters entries below the bound level" do
      builder, io = captured_log_builder(Facet::Logging.formatter("json"), :warn)
      builder.for("facet.probe").info { "hidden" }
      builder.for("facet.probe").warn { "kept" }

      lines = io.to_s.lines
      lines.size.should eq(1)
      JSON.parse(lines[0])["message"].as_s.should eq("kept")
    end
  end
end
