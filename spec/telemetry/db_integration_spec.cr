# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

# Captures traces in-process instead of sending them to an OTLP endpoint.
private class CapturingExporter
  include OpenTelemetry::Exporter

  getter traces = [] of OpenTelemetry::Exporter::Trace

  def trace(traces : Array(OpenTelemetry::Exporter::Trace)) : Nil
    @traces.concat(traces)
  end

  def reset : Nil
    @traces.clear
  end
end

private SPEC_DB_EXPORTER          = CapturingExporter.new
private SPEC_DB_ORIGINAL_EXPORTER = OpenTelemetry::CONFIG.exporter

# Assertion helpers over the protobuf span objects the exporter sees.
private def captured_spans : Array(OpenTelemetry::Proto::Trace::V1::Span)
  SPEC_DB_EXPORTER.traces.flat_map do |resource_spans|
    libraries = resource_spans.instrumentation_library_spans ||
                [] of OpenTelemetry::Proto::Trace::V1::InstrumentationLibrarySpans
    libraries.flat_map do |library|
      library.spans || [] of OpenTelemetry::Proto::Trace::V1::Span
    end
  end
end

private def query_spans : Array(OpenTelemetry::Proto::Trace::V1::Span)
  captured_spans.select { |s| s.name == "db.query" }
end

private def attribute(span : OpenTelemetry::Proto::Trace::V1::Span, key : String) : String?
  attrs = span.attributes
  return nil unless attrs
  attrs.find { |a| a.key == key }.try(&.value).try(&.string_value)
end

private def statements : Array(String)
  query_spans.compact_map { |s| attribute(s, "db.statement") }
end

describe "Telemetry DB integration" do
  # NOTE: `before_all` cannot be used here — Kemal bakes its own global
  # `before_all` (HTTP filter DSL) into the top-level scope, which shadows the
  # spec hook inside describe blocks. Swap the exporter per example instead.
  before_each do
    OpenTelemetry.configure(&.exporter=(SPEC_DB_EXPORTER))
    SPEC_DB_EXPORTER.reset
  end

  after_each do
    OpenTelemetry.configure(&.exporter=(SPEC_DB_ORIGINAL_EXPORTER))
  end

  it "creates a db.query span per statement with db attributes" do
    OpenTelemetry.trace("spec.root") do
      Facet::Database.with_connection do |db|
        db.exec("SELECT 1")
        db.query_one?("SELECT $1::text AS v", "hello", as: String)
      end
    end

    statements.should contain("SELECT 1")
    statements.should contain("SELECT $1::text AS v")
    query_spans.each do |span|
      attribute(span, "db.system").should eq("postgresql")
    end
  end

  it "nests query spans inside the transaction under db.transaction" do
    OpenTelemetry.trace("spec.root") do
      Facet::Database.with_transaction do |db|
        db.exec("SELECT 1")
      end
    end

    txn = captured_spans.find { |s| s.name == "db.transaction" }
    txn.should_not be_nil
    txn = txn.not_nil!

    inner = query_spans.find { |s| attribute(s, "db.statement") == "SELECT 1" }
    inner.should_not be_nil
    inner.not_nil!.parent_span_id.should eq(txn.span_id)
  end

  it "does not create spans for BEGIN and COMMIT" do
    OpenTelemetry.trace("spec.root") do
      Facet::Database.with_transaction do |db|
        db.exec("SELECT 2")
      end
    end

    lower = statements.map(&.downcase)
    lower.should_not contain("begin")
    lower.should_not contain("commit")
  end

  it "keeps savepoint spans for nested transactions" do
    OpenTelemetry.trace("spec.root") do
      Facet::Database.with_transaction do |db|
        Facet::Database.with_transaction(db) do |inner_db|
          inner_db.exec("SELECT 3")
        end
      end
    end

    statements.any?(&.starts_with?("SAVEPOINT")).should be_true
  end

  it "marks a failing statement with error status" do
    OpenTelemetry.trace("spec.root") do
      Facet::Database.with_connection do |db|
        begin
          db.exec("SELECT * FROM telemetry_missing_table_xyz")
        rescue
          # Expected failure — the span must record it.
        end
      end
    end

    failed = query_spans.find do |s|
      attribute(s, "db.statement").try(&.includes?("telemetry_missing_table_xyz"))
    end
    failed.should_not be_nil
    status = failed.not_nil!.status
    status.should_not be_nil
    code = status.not_nil!.code
    code.should_not be_nil
    code.not_nil!.error?.should be_true
  end

  it "truncates long statements in the db.statement attribute" do
    long_sql = "SELECT " + ("1, " * 1200) + "1"

    OpenTelemetry.trace("spec.root") do
      Facet::Database.with_connection do |db|
        db.exec(long_sql)
      end
    end

    span = query_spans.find { |s| attribute(s, "db.statement").try(&.starts_with?("SELECT 1, ")) }
    span.should_not be_nil
    attribute(span.not_nil!, "db.statement").not_nil!.size.should eq(
      DB::Statement::MAX_STATEMENT_ATTRIBUTE_SIZE
    )
  end
end
