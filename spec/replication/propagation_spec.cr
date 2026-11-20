# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# End-to-end source-update propagation through a real Redis event bus.
#
# The unit-level handler behaviour lives in `handler_spec.cr` (synthetic
# messages, no Redis). This file exercises the *manager wiring* that the
# handler depends on — the piece B-35 broke:
#
# - a consuming domain that did not exist at boot gets its stream subscriber
#   from the sync fiber, and its messages must reach the handler;
# - a source doctype added to an already-subscribed consumer domain must be
#   picked up by the channel provider AND get a dispatch registration, or
#   the subscriber reads the messages and drops them silently;
# - a consumer group created after the events were published replays the
#   retained stream (`group_start_id = "0"`) and converges.
#
# Every example registers its doctypes at runtime (the registry is empty at
# boot), which is the production shape for a dev server whose domains are
# built through the domain builder after start.
require "../spec_helper"
require "json"
require "pg"
require "uri"
require "redis"
require "../../src/event"
require "../../src/replication"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/util/script_helpers"
require "./registry_auto_refresh_spec" # replication_test_redis_available?

# Redis URL the whole propagation bus runs on. Production aligns the
# publisher, the doctype-cache subscriber and the replication manager on
# `config.event`; the spec must too — a publisher writing to a different
# Redis DB than the replication subscriber reads is the silent no-op shape
# this spec exists to catch.
PROPAGATION_BUS_URL = Facet::Config.instance.event.url

# Starts a real Redis-backed event bus (publisher + doctype-cache Pub/Sub
# subscriber + replication manager) all pointed at `PROPAGATION_BUS_URL`, and
# restores the in-process publisher afterwards. Mirrors the production wiring
# in `main.cr` and the `with_replication_manager` helper in
# `registry_auto_refresh_spec.cr` (which that file keeps on its own URL for
# the registry-rebuild examples).
def with_propagation_manager(& : Facet::Replication::Manager ->)
  client = ::Redis::Client.new(URI.parse(PROPAGATION_BUS_URL))
  begin
    client.flushdb
  ensure
    client.close
  end

  saved_publisher = Facet::Event::Publisher.manager
  event_config = Facet::Event::Config.new(
    url: PROPAGATION_BUS_URL,
    partitions: Facet::Config.instance.event.partitions,
    maxlen: Facet::Config.instance.event.maxlen,
  )
  publisher_manager = Facet::Event::Manager.new(
    config: event_config,
    service_id: "prop-pub-#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..6]}",
  )
  publisher_manager.start
  Facet::Event::Publisher.manager = publisher_manager

  doctype_cache = Facet::Event::Subscriber::DoctypeCache.new(
    redis_url: PROPAGATION_BUS_URL,
    service_id: "prop-dtc-#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..6]}",
  )
  doctype_cache.start

  manager = Facet::Replication::Manager.new(
    config: Facet::Config.instance,
    service_id: "prop-repl-#{Facet::Util::ScriptHelpers.ulid.tr("-", "")[0..6]}",
    domain_enabled: ->(_d : String) { true },
  )
  with_db { |db| manager.start(db) }
  Facet::Replication::Manager.instance = manager

  begin
    yield manager
  ensure
    manager.stop
    Facet::Replication::Manager.instance = nil
    doctype_cache.stop
    publisher_manager.stop
    Facet::Event::Publisher.manager = saved_publisher
  end
end

# ── Module-level helpers ─────────────────────────────────────────────────

# Registers a source doctype plus a consumer doctype with one replicate
# field, and (for a cross-domain edge) the producer-side grant.
def register_propagation_pair(
  db,
  source_domain : String,
  source_doctype : String,
  consumer_domain : String,
  consumer_doctype : String,
  ref_field : String,
  replica_field : String,
  *,
  on_source_delete : String = "keep",
  grant : Bool = false,
) : Nil
  ensure_domain(db, source_domain)
  ensure_domain(db, consumer_domain)

  if grant && source_domain != consumer_domain
    upsert_domain_with_grants(db, source_domain, %([
      {"to": "#{consumer_domain}", "doctype": "#{source_doctype}", "fields": ["name"]}
    ]))
  end

  source_defn = %({
    "doctype": "#{source_doctype}",
    "domain": "#{source_domain}",
    "schema_version": 1,
    "aggregate_root": false,
    "fields": {
      "name": {"type": "string", "required": true}
    }
  })
  res = Facet::Doctype::Create.call(db, "core", "DocType", source_defn, Facet::RBAC::AuthContext.system)
  raise "source doctype create failed: #{res.inspect}" unless res.is_a?(Facet::Doctype::Create::Result)

  consumer_defn = %({
    "doctype": "#{consumer_doctype}",
    "domain": "#{consumer_domain}",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "label":   {"type": "string", "required": true},
      "#{ref_field}": {"type": "reference", "doctype": "#{source_domain}.#{source_doctype}", "required": true},
      "#{replica_field}": {
        "type": "string",
        "replicate": {"via": "#{ref_field}", "field": "name"},
        "on_source_delete": "#{on_source_delete}"
      }
    }
  })
  res2 = Facet::Doctype::Create.call(db, "core", "DocType", consumer_defn, Facet::RBAC::AuthContext.system)
  raise "consumer doctype create failed: #{res2.inspect}" unless res2.is_a?(Facet::Doctype::Create::Result)
end

# Creates a source document with a fixture-style id ("{domain}.{doctype}.1",
# the shape the seeds and domain-builder imports produce) and returns it.
def create_propagation_source(db, source_domain : String, source_doctype : String, name : String) : String
  doc_id = "#{source_domain}.#{source_doctype}.1"
  res = Facet::Document::Create.call(db, source_domain, source_doctype,
    %({"name": "#{name}"}),
    Facet::RBAC::AuthContext.system, doc_id: doc_id)
  raise "source create failed: #{res.inspect}" unless res.is_a?(Facet::Document::Create::Result)
  res.projection.id
end

# Creates a consumer document referencing the source and returns its id. The
# via value uses the picker form ("{qualifiedDoctype}.{meta.id}") — what the
# frontend ReferencePicker emits, and the form that keeps create-pull working
# for fixture-style source ids.
def create_propagation_consumer(
  db,
  consumer_domain : String,
  consumer_doctype : String,
  source_doctype_qualified : String,
  source_id : String,
  ref_field : String,
) : String
  via_value = "#{source_doctype_qualified}.#{source_id}"
  res = Facet::Document::Create.call(db, consumer_domain, consumer_doctype,
    %({"label": "c1", "#{ref_field}": "#{via_value}"}),
    Facet::RBAC::AuthContext.system)
  raise "consumer create failed: #{res.inspect}" unless res.is_a?(Facet::Document::Create::Result)
  res.projection.id
end

# Renames the source through the service layer (the HTTP PATCH path).
def rename_propagation_source(db, source_domain : String, source_doctype : String, source_id : String, name : String) : Nil
  res = Facet::Document::Update.call(db, source_domain, source_doctype, source_id,
    %({"name": "#{name}"}),
    Facet::RBAC::AuthContext.system)
  raise "source update failed: #{res.inspect}" unless res.is_a?(Facet::Document::Update::Result)
end

def propagation_replica(db, consumer_domain : String, consumer_doctype : String, consumer_id : String, replica_field : String) : JSON::Any?
  Facet::Mutation::Client.fetch_content(db, consumer_domain, consumer_doctype, consumer_id)
    .as_h[replica_field]?
end

# Polls `predicate` (evaluated on a fresh pooled connection each round) until
# it returns true or the timeout elapses. The bus is async across Redis, and
# a subscriber created by the sync fiber waits up to one sync interval. Each
# round is one blocking DB query, so a tight 5 ms poll adds no measurable
# load while cutting the granularity tail from 250 ms to 5 ms.
def wait_for_propagation(timeout_s : Int32 = 25, & : DB::Connection -> Bool) : Bool
  deadline = Time.instant + timeout_s.seconds
  while Time.instant < deadline
    return true if with_db { |db| yield db }
    sleep 5.milliseconds
  end
  false
end

# ── Specs ──────────────────────────────────────────────────────────────────

describe "Replication source-update propagation (real event bus)" do
  redis_available = replication_test_redis_available?
  skip_msg = "requires Redis at #{PROPAGATION_BUS_URL} (config.event.url)"

  it "propagates a source rename to a same-domain consumer registered after boot", tags: %(redis) do
    pending skip_msg unless redis_available

    with_propagation_manager do |_manager|
      suffix = unique_suffix
      source_domain = "rp#{suffix}"
      source_doctype = "Person#{suffix.capitalize}"
      consumer_doctype = "Note#{suffix.capitalize}"

      consumer_id = nil
      with_db do |db|
        register_propagation_pair(db, source_domain, source_doctype, source_domain,
          consumer_doctype, "person", "person_name")
        source_id = create_propagation_source(db, source_domain, source_doctype, "Alice")
        consumer_id = create_propagation_consumer(db, source_domain, consumer_doctype,
          "#{source_domain}.#{source_doctype}", source_id, "person")

        rename_propagation_source(db, source_domain, source_doctype, source_id, "Renamed Source Person")
      end
      Facet::Event::Publisher.flush

      reached = wait_for_propagation do |db|
        propagation_replica(db, source_domain, consumer_doctype, consumer_id.not_nil!, "person_name") ==
          JSON::Any.new("Renamed Source Person")
      end

      reached.should be_true
    end
  end

  it "propagates a source rename across domains through an active grant", tags: %(redis) do
    pending skip_msg unless redis_available

    with_propagation_manager do |_manager|
      suffix = unique_suffix
      source_domain = "rp#{suffix}"
      consumer_domain = "lp#{suffix}"
      source_doctype = "Person#{suffix.capitalize}"
      consumer_doctype = "Invoice#{suffix.capitalize}"

      consumer_id = nil
      with_db do |db|
        register_propagation_pair(db, source_domain, source_doctype, consumer_domain,
          consumer_doctype, "customer", "customer_name", grant: true)
        source_id = create_propagation_source(db, source_domain, source_doctype, "Alice")
        consumer_id = create_propagation_consumer(db, consumer_domain, consumer_doctype,
          "#{source_domain}.#{source_doctype}", source_id, "customer")

        rename_propagation_source(db, source_domain, source_doctype, source_id, "Renamed Source Person")
      end
      Facet::Event::Publisher.flush

      reached = wait_for_propagation do |db|
        propagation_replica(db, consumer_domain, consumer_doctype, consumer_id.not_nil!, "customer_name") ==
          JSON::Any.new("Renamed Source Person")
      end

      reached.should be_true
    end
  end

  it "clears the replica when the source is deleted (on_source_delete unset)", tags: %(redis) do
    pending skip_msg unless redis_available

    with_propagation_manager do |_manager|
      suffix = unique_suffix
      source_domain = "rp#{suffix}"
      source_doctype = "Person#{suffix.capitalize}"
      consumer_doctype = "Note#{suffix.capitalize}"

      consumer_id = nil
      with_db do |db|
        register_propagation_pair(db, source_domain, source_doctype, source_domain,
          consumer_doctype, "person", "person_name", on_source_delete: "unset")
        source_id = create_propagation_source(db, source_domain, source_doctype, "Alice")
        consumer_id = create_propagation_consumer(db, source_domain, consumer_doctype,
          "#{source_domain}.#{source_doctype}", source_id, "person")
      end

      with_db do |db|
        res = Facet::Document::Delete.call(db, source_domain, source_doctype,
          "#{source_domain}.#{source_doctype}.1", Facet::RBAC::AuthContext.system)
        raise "source delete failed: #{res.inspect}" unless res.is_a?(Facet::Document::Delete::Result)
      end
      Facet::Event::Publisher.flush

      cleared = wait_for_propagation do |db|
        value = propagation_replica(db, source_domain, consumer_doctype, consumer_id.not_nil!, "person_name")
        value.nil? || value.raw.nil?
      end

      cleared.should be_true
    end
  end

  it "converges by replaying the retained stream when the consumer group is created after the events", tags: %(redis) do
    pending skip_msg unless redis_available

    with_propagation_manager do |_manager|
      suffix = unique_suffix
      source_domain = "rp#{suffix}"
      source_doctype = "Person#{suffix.capitalize}"
      consumer_doctype = "Note#{suffix.capitalize}"

      # The consumer group cannot exist before the first subscriber-sync tick
      # (the registry is empty at boot and nothing else creates groups), and
      # the tick fires `SUBSCRIBER_SYNC_INTERVAL` after start. Every source
      # mutation below completes well inside that window, so the only path to
      # a correct replica is the replay of the retained frames from id 0.
      consumer_id = nil
      with_db do |db|
        register_propagation_pair(db, source_domain, source_doctype, source_domain,
          consumer_doctype, "person", "person_name")
        source_id = create_propagation_source(db, source_domain, source_doctype, "Alice")
        consumer_id = create_propagation_consumer(db, source_domain, consumer_doctype,
          "#{source_domain}.#{source_doctype}", source_id, "person")
        rename_propagation_source(db, source_domain, source_doctype, source_id, "Renamed Source Person")
      end
      Facet::Event::Publisher.flush

      reached = wait_for_propagation do |db|
        propagation_replica(db, source_domain, consumer_doctype, consumer_id.not_nil!, "person_name") ==
          JSON::Any.new("Renamed Source Person")
      end
      reached.should be_true

      # Prove the replay: the group read the frames that predate its
      # creation — the source stream carries the `created` + `updated` pair.
      client = ::Redis::Client.new(URI.parse(PROPAGATION_BUS_URL))
      begin
        replayed = 0
        Facet::Config.instance.event.partitions.times do |shard|
          groups = client.xinfo_groups("FACET:RESOURCE:#{source_domain}:#{source_doctype}$#{shard}")
          next unless groups.is_a?(Array)
          groups.each do |group|
            group = group.as(Array)
            pairs = group.each_slice(2).to_a
            next unless pairs.any? { |pair| pair[0].as(String) == "name" && pair[1].as(String) == "cg:repl:#{source_domain}" }
            pairs.each do |pair|
              next unless pair[0].as(String) == "entries-read"
              count = pair[1]
              replayed += count.as(Int64) if count.is_a?(Int64)
            end
          end
        rescue
          # No stream on this shard yet.
        end
      ensure
        client.close
      end
      replayed.should be >= 2
    end
  end

  it "propagates to a consumer whose source channel was added to an already-subscribed domain", tags: %(redis) do
    pending skip_msg unless redis_available

    suffix = unique_suffix
    source_domain = "rp#{suffix}"
    boot_doctype = "Team#{suffix.capitalize}"
    boot_consumer = "Squad#{suffix.capitalize}"
    runtime_doctype = "Person#{suffix.capitalize}"
    runtime_consumer = "Note#{suffix.capitalize}"

    # Boot edge: exists before the manager starts, so the consumer domain
    # owns a stream subscriber at boot whose channel set does NOT include
    # the runtime source doctype.
    with_db do |db|
      register_propagation_pair(db, source_domain, boot_doctype, source_domain,
        boot_consumer, "member", "member_name")
    end

    with_propagation_manager do |_manager|
      consumer_id = nil
      with_db do |db|
        # Runtime edge: a NEW source doctype for the already-subscribed
        # consumer domain — the channel must be added at runtime, paired
        # with a dispatch registration.
        register_propagation_pair(db, source_domain, runtime_doctype, source_domain,
          runtime_consumer, "person", "person_name")
        source_id = create_propagation_source(db, source_domain, runtime_doctype, "Alice")
        consumer_id = create_propagation_consumer(db, source_domain, runtime_consumer,
          "#{source_domain}.#{runtime_doctype}", source_id, "person")

        rename_propagation_source(db, source_domain, runtime_doctype, source_id, "Renamed Source Person")
      end
      Facet::Event::Publisher.flush

      reached = wait_for_propagation do |db|
        propagation_replica(db, source_domain, runtime_consumer, consumer_id.not_nil!, "person_name") ==
          JSON::Any.new("Renamed Source Person")
      end

      reached.should be_true
    end
  end
end
