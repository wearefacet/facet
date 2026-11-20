# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "yaml"

# Builds a money-shaped JSON payload for specs.
#
# Money fields are stored as `{"value":"...","currency":"..."}` JSON objects.
# This helper keeps spec construction terse and avoids escaped-template typos.
def money(value : String, currency : String) : JSON::Any
  JSON.parse(%({"value":"#{value}","currency":"#{currency}"}))
end

# Builds a money-shaped JSON string for specs that pass raw JSON (e.g. fixtures).
def money_json(value : String, currency : String) : String
  %({"value":"#{value}","currency":"#{currency}"})
end

# Registers the full `core.Currency` seed set into the in-memory registry and
# marks it fresh.
#
# The per-example truncation wipes the seeded projections, so DB specs cannot
# rebuild the registry from the database — `Registry.refresh` against a
# truncated projections table would empty it. Reading the seed YAML keeps the
# registry in parity with what a fresh database would hold, without re-seeding
# ~150 documents through `Document::Create` in every example.
def register_seed_currencies : Nil
  path = File.join(__DIR__, "..", "..", "data", "seeds", "core.Currency", "documents.yml")
  docs = YAML.parse(File.read(path)).as_a

  currencies = {} of String => Facet::Util::Currency
  docs.each do |doc|
    content = doc["content"]
    currency = Facet::Util::Currency.new(
      ticker: content["ticker"].as_s,
      symbol: content["symbol"]?.try(&.as_s) || "",
      name: content["name"].as_s,
      digits: content["digits"].as_i.to_i32,
      active: content["active"]?.try(&.as_bool) || true,
      favorite: content["favorite"]?.try(&.as_bool) || false,
      grouping: content["grouping"]?.try(&.as_s) || "standard",
    )
    currencies[currency.ticker] = currency
  end

  Facet::Util::Currency.reset!
  Facet::Util::Currency.register(currencies)
  Facet::Currency::Registry.mark_fresh
end
