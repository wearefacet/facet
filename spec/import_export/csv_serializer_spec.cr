# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "csv"
require "big"
require "../../src/doctype"
require "../../src/util/money"
require "../../src/currency"
require "../../src/config"
require "../../src/rbac"
require "../../src/import_export/csv_serializer"
require "../support/money_helper"

alias CsvSerializer = Facet::ImportExport::CsvSerializer
alias DoctypeDefinition = Facet::Doctype::DoctypeDefinition

# A System caller sees every field — the header then lists all declared
# fields, which is what the round-trip helpers below expect.
private def system_context : Facet::RBAC::AuthContext
  Facet::RBAC::AuthContext.system
end

# Builds a doctype definition with the given fields JSON (definition order
# is the order of the JSON object's keys).
private def make_defn(fields_json : String) : DoctypeDefinition
  DoctypeDefinition.from_json(%({
    "doctype": "Widget",
    "domain": "demo",
    "schema_version": 1,
    "fields": #{fields_json}
  }))
end

# Encodes `content` for the given definition, then decodes the row back.
private def round_trip(fields_json : String, content_json : String) : Tuple(Array(String), Hash(String, JSON::Any))
  defn = make_defn(fields_json)
  content = JSON.parse(content_json)
  row = CsvSerializer.encode_row("doc-1", content, defn, system_context)
  result = CsvSerializer.decode_row(CsvSerializer.header(defn, system_context), row, defn)
  {row, result[:content]}
end

describe Facet::ImportExport::CsvSerializer do
  # Money decode validates tickers against the currency registry, so the
  # registry must hold at least USD/EUR. `before_each` is used (not
  # `before_all`) per the spec-helper rule that `before_all` is broken in
  # this project.
  before_each do
    Facet::Config.reset!
    Facet::Config.instance
    register_seed_currencies
  end

  describe ".header" do
    it "puts the id column first, then fields in definition order" do
      defn = make_defn(%({
        "zeta":  {"type": "string"},
        "alpha": {"type": "integer"},
        "mid":   {"type": "boolean"}
      }))
      CsvSerializer.header(defn, system_context).should eq(["id", "zeta", "alpha", "mid"])
    end

    it "keeps server-managed fields in the header (export-only)" do
      defn = make_defn(%({
        "title": {"type": "string"},
        "audit": {"type": "data"}
      }))
      CsvSerializer.header(defn, system_context).should eq(["id", "title", "audit"])
    end

    it "omits a field the caller cannot see (tag-masked)" do
      defn = make_defn(%({
        "title":  {"type": "string"},
        "salary": {"type": "integer", "tags": ["confidential"]},
        "notes":  {"type": "string"}
      }))
      role = Facet::RBAC::ActiveRole.new("restricted", Set{"default"}, [] of Facet::RBAC::Permission)
      ctx = Facet::RBAC::AuthContext.authenticated("acc-1", role)
      CsvSerializer.header(defn, ctx).should eq(["id", "title", "notes"])
    end
  end

  describe ".encode_row / .decode_row — round trip per field type" do
    it "round-trips the text scalars as stored text" do
      fields = %({
        "title": {"type": "string"},
        "notes": {"type": "longtext"},
        "status": {"type": "enum", "values": ["open", "closed"]},
        "phone": {"type": "phone"},
        "site":  {"type": "url"},
        "tint":  {"type": "color"}
      })
      expected = %({
        "title": "Widget A",
        "notes": "multi\\nline",
        "status": "open",
        "phone": "+1 555 0100",
        "site": "https://example.com",
        "tint": "#3366ff"
      })
      row, decoded = round_trip(fields, expected)
      row[1].should eq("Widget A")
      row[2].should eq("multi\nline")
      row[3].should eq("open")
      decoded.should eq(JSON.parse(expected).as_h)
    end

    it "round-trips integer and duration as decimal text" do
      row, decoded = round_trip(%({
        "count": {"type": "integer"},
        "span":  {"type": "duration"}
      }), %({"count": 42, "span": 3600}))
      row[1].should eq("42")
      row[2].should eq("3600")
      decoded["count"].as_i64.should eq(42)
      decoded["span"].as_i64.should eq(3600)
    end

    it "round-trips boolean as true / false" do
      row, decoded = round_trip(%({
        "active": {"type": "boolean"},
        "locked": {"type": "boolean"}
      }), %({"active": true, "locked": false}))
      row[1].should eq("true")
      row[2].should eq("false")
      decoded["active"].as_bool.should be_true
      decoded["locked"].as_bool.should be_false
    end

    it "round-trips date and datetime as ISO-8601 text" do
      row, decoded = round_trip(%({
        "born": {"type": "date"},
        "seen": {"type": "datetime"}
      }), %({
        "born": "2001-02-03",
        "seen": "2026-01-15T10:30:00Z"
      }))
      row[1].should eq("2001-02-03")
      row[2].should eq("2026-01-15T10:30:00Z")
      decoded["born"].as_s.should eq("2001-02-03")
      decoded["seen"].as_s.should eq("2026-01-15T10:30:00Z")
    end

    it "round-trips reference and file as ids" do
      row, decoded = round_trip(%({
        "company": {"type": "reference", "doctype": "crm.Company"},
        "avatar":  {"type": "file"}
      }), %({
        "company": "demo.Company.01HXXXXXXXXXXXXXXX",
        "avatar": "01JZZZZZZZZZZZZZZZZZZZZZZZ"
      }))
      row[1].should eq("demo.Company.01HXXXXXXXXXXXXXXX")
      row[2].should eq("01JZZZZZZZZZZZZZZZZZZZZZZZ")
      decoded["company"].as_s.should eq("demo.Company.01HXXXXXXXXXXXXXXX")
      decoded["avatar"].as_s.should eq("01JZZZZZZZZZZZZZZZZZZZZZZZ")
    end

    it "round-trips period and dateperiod as JSON" do
      row, decoded = round_trip(%({
        "window": {"type": "period"},
        "days":   {"type": "dateperiod"}
      }), %({
        "window": {"start": "2026-01-01T08:00:00Z", "end": "2026-01-02T08:00:00Z"},
        "days":   {"start": "2026-01-01", "end": "2026-01-05"}
      }))
      row[1].should eq(%({"start":"2026-01-01T08:00:00Z","end":"2026-01-02T08:00:00Z"}))
      decoded["window"].as_h["start"].as_s.should eq("2026-01-01T08:00:00Z")
      decoded["days"].as_h["end"].as_s.should eq("2026-01-05")
    end

    it "round-trips object, array, and dictionary as JSON" do
      row, decoded = round_trip(%({
        "meta": {"type": "object"},
        "tags": {"type": "array"},
        "props": {"type": "dictionary"}
      }), %({
        "meta": {"a": 1, "b": [true, null]},
        "tags": ["x", "y"],
        "props": {"k": "v"}
      }))
      row[1].should eq(%({"a":1,"b":[true,null]}))
      row[2].should eq(%(["x","y"]))
      row[3].should eq(%({"k":"v"}))
      decoded["meta"].as_h["a"].as_i.should eq(1)
      decoded["tags"].as_a.size.should eq(2)
      decoded["props"].as_h["k"].as_s.should eq("v")
    end

    it "round-trips any, secret marker (JSON), and secret handle (text)" do
      row, decoded = round_trip(%({
        "wild":   {"type": "any"},
        "marker": {"type": "secret", "mode": "hash"},
        "handle": {"type": "secret", "mode": "token"}
      }), %({
        "wild": {"anything": [1, 2]},
        "marker": {"mode": "hash", "version": 1, "set_at": "2026-01-01T00:00:00Z"},
        "handle": "sh_01HZZZZZZZZZZZZZZZZZZZZZZZ"
      }))
      row[1].should eq(%({"anything":[1,2]}))
      row[2].should eq(%({"mode":"hash","version":1,"set_at":"2026-01-01T00:00:00Z"}))
      row[3].should eq("sh_01HZZZZZZZZZZZZZZZZZZZZZZZ")
      decoded["wild"].as_h["anything"].as_a.size.should eq(2)
      decoded["marker"].as_h["version"].as_i.should eq(1)
      decoded["handle"].as_s.should eq("sh_01HZZZZZZZZZZZZZZZZZZZZZZZ")
    end

    it "encodes absent and null values as empty cells and decodes them to explicit null" do
      row, decoded = round_trip(%({
        "title": {"type": "string"},
        "count": {"type": "integer"}
      }), %({"title": null}))
      row[1].should eq("")
      row[2].should eq("")
      decoded["title"].raw.nil?.should be_true
      decoded.has_key?("count").should be_true
    end

    it "round-trips a collection field as a JSON cell" do
      row, decoded = round_trip(%({
        "labels": {"type": "string", "collection": true}
      }), %({"labels": ["a", "b"]}))
      row[1].should eq(%(["a","b"]))
      decoded["labels"].as_a.map(&.as_s).should eq(["a", "b"])
    end
  end

  describe "money" do
    it "writes the stored value verbatim after the ticker" do
      row, _ = round_trip(%({"price": {"type": "money"}}),
        %({"price": {"value": "12.50", "currency": "EUR"}}))
      row[1].should eq("EUR 12.50")
    end

    it "decodes a currency-prefixed cell to the structured object" do
      _, decoded = round_trip(%({"price": {"type": "money"}}),
        %({"price": {"value": "1.0", "currency": "USD"}}))
      decoded["price"].as_h["value"].as_s.should eq("1.0")
      decoded["price"].as_h["currency"].as_s.should eq("USD")
    end

    it "rejects a bare amount with the field named" do
      defn = make_defn(%({"price": {"type": "money"}}))
      cells = ["doc-1", "1.0"]
      expect_raises(CsvSerializer::RowError, "price") do
        CsvSerializer.decode_row(CsvSerializer.header(defn, system_context), cells, defn)
      end
    end

    it "rejects an unknown ticker" do
      defn = make_defn(%({"price": {"type": "money"}}))
      cells = ["doc-1", "XYZ 1.0"]
      expect_raises(CsvSerializer::RowError, "price") do
        CsvSerializer.decode_row(CsvSerializer.header(defn, system_context), cells, defn)
      end
    end

    it "rejects a non-decimal amount" do
      defn = make_defn(%({"price": {"type": "money"}}))
      cells = ["doc-1", "USD abc"]
      expect_raises(CsvSerializer::RowError, "price") do
        CsvSerializer.decode_row(CsvSerializer.header(defn, system_context), cells, defn)
      end
    end
  end

  describe "decode rules" do
    it "leaves no entry for a column missing from the header" do
      defn = make_defn(%({
        "title": {"type": "string"},
        "count": {"type": "integer"}
      }))
      # Header omits `count` — the field stays untouched on update.
      result = CsvSerializer.decode_row(["id", "title"], ["doc-1", "Widget A"], defn)
      result[:content].has_key?("title").should be_true
      result[:content].has_key?("count").should be_false
    end

    it "drops server-managed fields from the decode target" do
      defn = make_defn(%({
        "title": {"type": "string"},
        "audit": {"type": "data"},
        "frozen": {"type": "string", "read_only": true},
        "mirror": {"type": "string", "replicate": {"via": "join", "field": "src"}}
      }))
      result = CsvSerializer.decode_row(
        ["id", "title", "audit", "frozen", "mirror"],
        ["doc-1", "A", "{}", "x", "y"], defn)
      result[:content].keys.should eq(["title"])
    end

    it "rejects a header column that is not a declared field" do
      defn = make_defn(%({"title": {"type": "string"}}))
      expect_raises(CsvSerializer::RowError, "ghost") do
        CsvSerializer.decode_row(["id", "ghost"], ["doc-1", "x"], defn)
      end
    end

    it "rejects a cell count that does not match the header" do
      defn = make_defn(%({"title": {"type": "string"}}))
      expect_raises(CsvSerializer::RowError, "header") do
        CsvSerializer.decode_row(["id", "title"], ["doc-1"], defn)
      end
    end

    it "rejects a duplicate column" do
      defn = make_defn(%({"title": {"type": "string"}}))
      expect_raises(CsvSerializer::RowError, "duplicate") do
        CsvSerializer.decode_row(["id", "title", "title"], ["doc-1", "a", "b"], defn)
      end
    end

    it "returns the id from the row and nil for an empty or absent id cell" do
      defn = make_defn(%({"title": {"type": "string"}}))
      result = CsvSerializer.decode_row(["id", "title"], ["doc-9", "A"], defn)
      result[:id].should eq("doc-9")

      result = CsvSerializer.decode_row(["id", "title"], ["", "A"], defn)
      result[:id].should be_nil

      result = CsvSerializer.decode_row(["title"], ["A"], defn)
      result[:id].should be_nil
    end

    it "rejects a boolean cell that is not exactly true or false" do
      defn = make_defn(%({"active": {"type": "boolean"}}))
      expect_raises(CsvSerializer::RowError, "active") do
        CsvSerializer.decode_row(["id", "active"], ["doc-1", "True"], defn)
      end
    end

    it "rejects a non-integer cell on an integer field" do
      defn = make_defn(%({"count": {"type": "integer"}}))
      expect_raises(CsvSerializer::RowError, "count") do
        CsvSerializer.decode_row(["id", "count"], ["doc-1", "4.5"], defn)
      end
    end

    it "rejects a malformed JSON cell with the field named" do
      defn = make_defn(%({"meta": {"type": "object"}}))
      expect_raises(CsvSerializer::RowError, "meta") do
        CsvSerializer.decode_row(["id", "meta"], ["doc-1", "{bad"], defn)
      end
    end
  end

  describe "formula-injection guard" do
    it "prefixes a text cell that starts with a formula trigger" do
      triggers = ["=cmd|calc", "+1 2", "-2 = ", "@x", "\ttab"]
      triggers.each do |value|
        row, _ = round_trip(%({"notes": {"type": "longtext"}}),
          %({"notes": #{value.to_json}}))
        row[1].should eq("'#{value}")
      end
    end

    it "strips the guard prefix on decode, so the round trip keeps the stored value" do
      _, decoded = round_trip(%({"notes": {"type": "longtext"}}),
        %({"notes": "=cmd|calc"}))
      decoded["notes"].as_s.should eq("=cmd|calc")
    end

    it "leaves a plain text cell untouched" do
      row, decoded = round_trip(%({"notes": {"type": "string"}}),
        %({"notes": "Widget A"}))
      row[1].should eq("Widget A")
      decoded["notes"].as_s.should eq("Widget A")
    end

    it "does not double-prefix a stored text that itself starts with a quote; decode strips the one leading quote (the documented trade)" do
      row, decoded = round_trip(%({"notes": {"type": "string"}}),
        %({"notes": "'quoted"}))
      row[1].should eq("'quoted")
      decoded["notes"].as_s.should eq("quoted")
    end

    it "does not guard the numeric path (a negative integer stays bare)" do
      row, decoded = round_trip(%({"count": {"type": "integer"}}),
        %({"count": -5}))
      row[1].should eq("-5")
      decoded["count"].as_i64.should eq(-5)
    end

    it "guards the view codec too" do
      defn = make_defn(%({"notes": {"type": "string"}}))
      content = JSON.parse(%({"notes": "=cmd|calc"}))
      time = Time.utc(2026, 1, 1, 0, 0, 0)
      row = CsvSerializer.encode_view_row(
        "doc-1", content, time, time, defn, ["notes"], nil)
      row[0].should eq("'=cmd|calc")
    end

    it "survives the CSV text layer: the builder writes the guarded cell raw, the parse keeps it, decode strips it" do
      defn = make_defn(%({"notes": {"type": "string"}}))
      content = JSON.parse(%({"notes": "=cmd|calc"}))
      row = CsvSerializer.encode_row("doc-1", content, defn, system_context)

      csv = CSV.build do |builder|
        builder.row(CsvSerializer.header(defn, system_context))
        builder.row(row)
      end
      parsed = CSV.parse(csv)
      parsed[1][1].should eq("'=cmd|calc")

      result = CsvSerializer.decode_row(parsed[0], parsed[1], defn)
      result[:content]["notes"].as_s.should eq("=cmd|calc")
    end
  end

  describe "CSV text layer" do
    it "round-trips commas, quotes, and newlines inside cells" do
      defn = make_defn(%({
        "title": {"type": "string"},
        "notes": {"type": "longtext"},
        "meta":  {"type": "object"}
      }))
      content = JSON.parse(%({
        "title": "a,b \\"c\\"",
        "notes": "line1\\nline2, with, commas",
        "meta": {"k": "v, {w}"}
      }))
      row = CsvSerializer.encode_row("doc-1", content, defn, system_context)

      csv = CSV.build do |builder|
        builder.row(CsvSerializer.header(defn, system_context))
        builder.row(row)
      end
      parsed = CSV.parse(csv)
      parsed.size.should eq(2)

      result = CsvSerializer.decode_row(parsed[0], parsed[1], defn)
      result[:content].should eq(content.as_h)
    end
  end
end
