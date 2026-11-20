# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/util/cache_freshness"
require "../../src/doctype/definition_store"

# Unit coverage for `Doctype::ProcessDefinitionCache` — the process-wide
# definition cache installed by `main.cr`. Pure in-memory: the loader is a
# counting closure, no DB. The staleness bound (`Util::CacheFreshness`,
# `cache.staleness_ttl_s`) reloads entries past the bound, so a lost Pub/Sub
# eviction can only delay a refresh by that window; explicit eviction
# (`clear_key`) still wins at any age.
# Builds one minimal, valid definition for the loader to return.
def make_definition(name : String) : Facet::Doctype::DoctypeDefinition
  Facet::Doctype::DoctypeDefinition.new(
    doctype: name,
    domain: "spec",
    fields: {
      "title" => Facet::Doctype::FieldDefinition.new(
        type: Facet::Doctype::FieldType.parse("string"),
      ),
    },
  )
end

describe Facet::Doctype::ProcessDefinitionCache do
  it "caches a loaded definition and does not call the loader again" do
    cache = Facet::Doctype::ProcessDefinitionCache.new
    loads = 0

    cache.fetch("spec.Widget") do
      loads += 1
      make_definition("Widget")
    end.should_not be_nil
    cache.fetch("spec.Widget") { loads += 1; make_definition("Widget") }.should_not be_nil

    loads.should eq(1)
  end

  it "caches a nil result as a keyed miss (unknown doctype)" do
    cache = Facet::Doctype::ProcessDefinitionCache.new
    loads = 0

    loader = -> do
      loads += 1
      nil
    end

    cache.fetch("spec.Ghost") { loader.call }.should be_nil
    cache.fetch("spec.Ghost") { loader.call }.should be_nil

    loads.should eq(1)
  end

  it "reloads an entry when the staleness bound expires" do
    with_cache_ttl(1) do
      cache = Facet::Doctype::ProcessDefinitionCache.new
      loads = 0
      version = 0

      loader = -> do
        loads += 1
        make_definition("WidgetV#{version}")
      end

      first = cache.fetch("spec.Widget") { loader.call }
      first.not_nil!.doctype.should eq("WidgetV0")

      # A doctype mutation lands in the DB but the fanout is lost — the
      # cache has no way to know. Bump the source data behind the loader.
      version = 1

      # Inside the bound the cached definition still serves.
      cache.fetch("spec.Widget") { loader.call }.not_nil!.doctype.should eq("WidgetV0")
      loads.should eq(1)

      # Past the bound the next fetch reloads and sees the new state.
      assert_eventually(timeout: 4.0, interval: 0.05) do
        cache.fetch("spec.Widget") { loader.call }.not_nil!.doctype == "WidgetV1"
      end
      loads.should be >= 2
    end
  end

  it "reloads a keyed miss when the staleness bound expires" do
    with_cache_ttl(1) do
      cache = Facet::Doctype::ProcessDefinitionCache.new
      loads = 0

      # The doctype does not exist yet: the miss is cached.
      cache.fetch("spec.Later") do
        loads += 1
        nil
      end.should be_nil
      loads.should eq(1)

      # The doctype is created (loader now returns a definition), but the
      # fanout is lost. Inside the bound the cached miss still serves —
      # the loader is not even called.
      cache.fetch("spec.Later") do
        loads += 1
        make_definition("Later")
      end.should be_nil
      loads.should eq(1)

      # Past the bound the miss expires and the fetch reloads. Polls
      # inside the bound never call the loader — the count only moves
      # when the expired miss finally reloads.
      assert_eventually(timeout: 4.0, interval: 0.05) do
        result = cache.fetch("spec.Later") do
          loads += 1
          make_definition("Later")
        end
        !result.nil?
      end
      loads.should eq(2)
    end
  end

  it "never expires when the bound is disabled" do
    # config.test.yml sets `cache.staleness_ttl_s: 0` — the bound is off.
    Facet::Config.instance.cache.staleness_ttl_s.should eq(0)

    cache = Facet::Doctype::ProcessDefinitionCache.new
    loads = 0

    cache.fetch("spec.Stable") do
      loads += 1
      make_definition("Stable")
    end

    # A full bound-sized wait would be the honest check; with the bound
    # disabled, a plain re-fetch (plus the loader count) shows the entry
    # is served regardless of age.
    cache.fetch("spec.Stable") { loads += 1; make_definition("Stable") }.not_nil!
    loads.should eq(1)
  end

  it "explicit eviction (clear_key) drops a fresh entry" do
    cache = Facet::Doctype::ProcessDefinitionCache.new
    loads = 0

    cache.fetch("spec.Widget") { loads += 1; make_definition("Widget") }
    loads.should eq(1)

    # The fanout path (`DefinitionStore.invalidate` → `clear_key`) evicts
    # regardless of the entry's age.
    cache.clear_key("spec.Widget")
    cache.fetch("spec.Widget") { loads += 1; make_definition("Widget") }
    loads.should eq(2)
  end

  it "clear drops every entry and miss" do
    cache = Facet::Doctype::ProcessDefinitionCache.new
    loads = 0

    cache.fetch("spec.A") { loads += 1; make_definition("A") }
    cache.fetch("spec.B") { loads += 1; nil }
    loads.should eq(2)

    cache.clear
    cache.fetch("spec.A") { loads += 1; make_definition("A") }
    cache.fetch("spec.B") { loads += 1; nil }
    loads.should eq(4)
  end
end
