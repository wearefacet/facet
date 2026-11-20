# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/util/cache_freshness"
require "../../src/iam/role_store"
require "../../src/event/subscriber/role_cache"

# Unit coverage for `IAM::RoleStore` — the process-local role content cache
# installed by `main.cr` (server command). Pure in-memory: the loader is a
# counting closure, no DB. The DB read path itself is exercised by every
# auth/RBAC spec through `IAM::Helpers.find_role_content`; this file pins
# the cache contract: hit, keyed miss, TTL reload, explicit eviction, and
# the `RoleCache` fanout subscriber's eviction.
#
# The eviction contract mirrors `Doctype::ProcessDefinitionCache`
# (`spec/doctype/process_definition_cache_spec.cr`): the fanout is the fast
# path, and `cache.staleness_ttl_s` bounds the worst case when a fanout is
# lost. The suite runs with the bound disabled (`0`); the TTL examples swap
# the config singleton via `with_cache_ttl`.
private def make_role_content(name : String) : JSON::Any
  JSON.parse(%({"name": "#{name}", "permissions": []}))
end

describe Facet::IAM::RoleStore::ProcessCache do
  it "caches a loaded role and does not call the loader again" do
    cache = Facet::IAM::RoleStore::ProcessCache.new
    loads = 0

    cache.fetch("iam.Roles.editor") do
      loads += 1
      make_role_content("editor")
    end.should_not be_nil
    cache.fetch("iam.Roles.editor") { loads += 1; make_role_content("editor") }.should_not be_nil

    loads.should eq(1)
  end

  it "caches a nil result as a keyed miss (unknown role)" do
    cache = Facet::IAM::RoleStore::ProcessCache.new
    loads = 0

    cache.fetch("iam.Roles.Ghost") do
      loads += 1
      nil
    end.should be_nil
    cache.fetch("iam.Roles.Ghost") do
      loads += 1
      nil
    end.should be_nil

    loads.should eq(1)
  end

  it "clear_key drops a hit and a keyed miss independently" do
    cache = Facet::IAM::RoleStore::ProcessCache.new
    loads = 0

    cache.fetch("iam.Roles.editor") { loads += 1; make_role_content("editor") }
    cache.fetch("iam.Roles.Ghost") { loads += 1; nil }
    loads.should eq(2)

    cache.clear_key("iam.Roles.editor")
    cache.fetch("iam.Roles.editor") { loads += 1; make_role_content("editor") }
    cache.fetch("iam.Roles.Ghost") { loads += 1; nil }
    loads.should eq(3)
  end

  it "clear drops every entry and miss" do
    cache = Facet::IAM::RoleStore::ProcessCache.new
    loads = 0

    cache.fetch("iam.Roles.A") { loads += 1; make_role_content("a") }
    cache.fetch("iam.Roles.B") { loads += 1; nil }
    loads.should eq(2)

    cache.clear
    cache.fetch("iam.Roles.A") { loads += 1; make_role_content("a") }
    cache.fetch("iam.Roles.B") { loads += 1; nil }
    loads.should eq(4)
  end

  it "reloads an entry when the staleness bound expires" do
    with_cache_ttl(1) do
      cache = Facet::IAM::RoleStore::ProcessCache.new
      loads = 0
      version = 0

      loader = -> do
        loads += 1
        make_role_content("editorV#{version}")
      end

      first = cache.fetch("iam.Roles.editor") { loader.call }
      first.not_nil!["name"].as_s.should eq("editorV0")

      # A role mutation lands in the DB but the fanout is lost — the cache
      # has no way to know. Bump the source data behind the loader.
      version = 1

      # Inside the bound the cached content still serves.
      cache.fetch("iam.Roles.editor") { loader.call }.not_nil!["name"].as_s.should eq("editorV0")
      loads.should eq(1)

      # Past the bound the next fetch reloads and sees the new state.
      assert_eventually(timeout: 4.0, interval: 0.05) do
        cache.fetch("iam.Roles.editor") { loader.call }.not_nil!["name"].as_s == "editorV1"
      end
      loads.should be >= 2
    end
  end

  it "reloads a keyed miss when the staleness bound expires" do
    with_cache_ttl(1) do
      cache = Facet::IAM::RoleStore::ProcessCache.new
      loads = 0

      # The role does not exist yet: the miss is cached.
      cache.fetch("iam.Roles.Later") do
        loads += 1
        nil
      end.should be_nil
      loads.should eq(1)

      # The role is created (loader now returns content), but the fanout is
      # lost. Inside the bound the cached miss still serves — the loader is
      # not even called.
      cache.fetch("iam.Roles.Later") do
        loads += 1
        make_role_content("later")
      end.should be_nil
      loads.should eq(1)

      # Past the bound the miss expires and the fetch reloads.
      assert_eventually(timeout: 4.0, interval: 0.05) do
        result = cache.fetch("iam.Roles.Later") do
          loads += 1
          make_role_content("later")
        end
        !result.nil?
      end
      loads.should eq(2)
    end
  end

  it "never expires when the bound is disabled" do
    # config.test.yml sets `cache.staleness_ttl_s: 0` — the bound is off.
    Facet::Config.instance.cache.staleness_ttl_s.should eq(0)

    cache = Facet::IAM::RoleStore::ProcessCache.new
    loads = 0

    cache.fetch("iam.Roles.Stable") do
      loads += 1
      make_role_content("stable")
    end

    # With the bound disabled, a plain re-fetch (plus the loader count)
    # shows the entry is served regardless of age.
    cache.fetch("iam.Roles.Stable") { loads += 1; make_role_content("stable") }.not_nil!
    loads.should eq(1)
  end
end

describe Facet::IAM::RoleStore::PassThrough do
  it "calls the loader on every fetch (no caching)" do
    cache = Facet::IAM::RoleStore::PassThrough.new
    loads = 0

    cache.fetch("iam.Roles.editor") { loads += 1; make_role_content("editor") }
    cache.fetch("iam.Roles.editor") { loads += 1; make_role_content("editor") }

    loads.should eq(2)
  end
end

describe Facet::IAM::RoleStore do
  # Restores the default (pass-through) cache — the suite must never run
  # with a live process cache, or wiped projections would serve stale roles
  # across examples.
  after_each do
    Facet::IAM::RoleStore.cache = Facet::IAM::RoleStore::PassThrough.new
  end

  it "delegates fetch through the configured cache" do
    Facet::IAM::RoleStore.cache = Facet::IAM::RoleStore::ProcessCache.new

    with_db do |db|
      seed_test_roles(db)

      # Warm the cache, then delete the row behind it (no invalidation —
      # simulates a fanout that has not landed yet). The cached content
      # still serves.
      first = Facet::IAM::RoleStore.fetch(db, "iam.Roles.viewer")
      first.should_not be_nil

      db.exec("UPDATE projections SET deleted_at = now() WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.viewer'")

      cached = Facet::IAM::RoleStore.fetch(db, "iam.Roles.viewer")
      cached.should_not be_nil
      cached.not_nil!["name"].as_s.should eq("viewer")
    end
  end

  it "invalidate evicts the configured cache so the next fetch reloads" do
    Facet::IAM::RoleStore.cache = Facet::IAM::RoleStore::ProcessCache.new

    with_db do |db|
      seed_test_roles(db)

      Facet::IAM::RoleStore.fetch(db, "iam.Roles.viewer").should_not be_nil

      db.exec("UPDATE projections SET deleted_at = now() WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.viewer'")

      # The fanout path: evict, then the next fetch sees the tombstone.
      Facet::IAM::RoleStore.invalidate("iam.Roles.viewer")
      Facet::IAM::RoleStore.fetch(db, "iam.Roles.viewer").should be_nil
    end
  end
end

describe Facet::Event::Subscriber::RoleCache do
  # Restores the default (pass-through) cache — these examples swap it and
  # later spec files must not inherit a live process cache.
  after_each do
    Facet::IAM::RoleStore.cache = Facet::IAM::RoleStore::PassThrough.new
  end

  it "evicts the role content cache on a per-document fanout message" do
    store = Facet::IAM::RoleStore::ProcessCache.new
    Facet::IAM::RoleStore.cache = store

    loads = 0
    store.fetch("iam.Roles.editor") { loads += 1; make_role_content("editor") }
    loads.should eq(1)

    subscriber = Facet::Event::Subscriber::RoleCache.new("redis://localhost:6379/0", "spec-role-cache")
    subscriber.handle_message("fanout:iam.Roles:iam.Roles.editor", "{}")

    # The eviction clears both the hit and the keyed miss; the next fetch
    # reloads from the loader.
    store.fetch("iam.Roles.editor") { loads += 1; make_role_content("editor") }
    loads.should eq(2)

    store.fetch("iam.Roles.Ghost") { loads += 1; nil }.should be_nil
    subscriber.handle_message("fanout:iam.Roles:iam.Roles.Ghost", "{}")
    store.fetch("iam.Roles.Ghost") { loads += 1; nil }.should be_nil
    loads.should eq(4)
  end

  it "still marks the MCP tools registry stale" do
    generation_before = Facet::AgentTools.current_generation

    subscriber = Facet::Event::Subscriber::RoleCache.new("redis://localhost:6379/0", "spec-role-cache")
    subscriber.handle_message("fanout:iam.Roles:iam.Roles.editor", "{}")

    Facet::AgentTools.current_generation.should be > generation_before
  end
end
