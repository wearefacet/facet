# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "pg"
require "../config"
require "../util/cache_freshness"
require "../util/projections"
require "./spec"

module Facet
  module SystemSettings
    Log = ::Log.for("facet.system_settings")

    DOMAIN   = "core"
    DOC_TYPE = "SystemSettings"
    DOC_ID   = "settings"

    # The qualified reference the secret store slots bind to.
    DOC_REF = "#{DOMAIN}.#{DOC_TYPE}.#{DOC_ID}"

    # Process cache of the effective settings, in the invalidate-only
    # contract of the doctype-definition cache and the currency registry:
    #
    # - The `SystemSettingsCache` Pub/Sub subscriber marks the cache stale
    #   on every `fanout:core.SystemSettings:*` fanout (the doctype has
    #   exactly one document, so that one channel is the whole surface).
    # - The next `ensure_fresh` call rebuilds from the projection row. The
    #   rebuild resolves every non-secret path once (document value when
    #   set, else the file fallback) so reads after that are hash lookups
    #   with zero queries on the hot path.
    # - A fanout lost while Redis was down self-heals through the
    #   `cache.staleness_ttl_s` bound (`Util::CacheFreshness`).
    #
    # The cache holds **non-secret values only**: `values` carries no
    # credential material, and `secret_pinned` records only the paths whose
    # document field is non-null (the adoption marker — the sealed slot
    # exists). `reveal_secret` reads the store each time and is never
    # cached. Until the document exists, every key follows the file.
    #
    # Consistency window: between a commit and the next `ensure_fresh` on
    # the affected process — the same contract the other registries accept.

    @@stale : Bool = true

    # Monotonic stamp of the last refresh. Drives the staleness bound.
    @@refreshed_at : Time::Instant? = nil

    # Effective non-secret values keyed by path. Always complete: every
    # registered non-secret path has an entry (the file fallback fills the
    # unpinned ones).
    @@values : Hash(String, JSON::Any) = {} of String => JSON::Any

    # Paths whose document field is non-null — the document pins them.
    @@pinned : Set(String) = Set(String).new

    # Secret paths whose document field is non-null — the adoption marker
    # is in content, so the sealed slot exists.
    @@secret_pinned : Set(String) = Set(String).new

    def self.stale? : Bool
      @@stale
    end

    # Pure flag — called by the Pub/Sub subscriber. No DB access.
    def self.mark_stale : Nil
      @@stale = true
    end

    # True when the cache may serve reads: rebuilt after the last
    # invalidation and inside the staleness bound.
    def self.fresh? : Bool
      !@@stale && !Util::CacheFreshness.expired?(@@refreshed_at)
    end

    # Spec-only: drops the cache to the never-rebuilt state. The per-example
    # truncation wipes the projection row but no process cache; specs that
    # pin settings call this between examples so a later example never sees
    # an earlier one's pinned values.
    def self.reset_cache! : Nil
      @@stale = true
      @@refreshed_at = nil
      @@values = {} of String => JSON::Any
      @@pinned = Set(String).new
      @@secret_pinned = Set(String).new
    end

    # Rebuilds the cache when it is stale, or when the last refresh is
    # older than the staleness bound — the safety net for a lost fanout.
    # A flag check is cheap, so consumers may call this unconditionally.
    def self.ensure_fresh(db : DB::Connection) : Nil
      refresh(db) if @@stale || Util::CacheFreshness.expired?(@@refreshed_at)
    end

    # Rebuilds the cache from the singleton projection row. A missing or
    # tombstoned row is tolerated: every key then follows the file. Secret
    # values never land here — only the fact that a slot is pinned.
    def self.refresh(db : DB::Connection) : Nil
      content = db.query_one?(
        "SELECT content FROM projections " \
        "WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
        DOMAIN, DOC_TYPE, DOC_ID,
        as: JSON::Any,
      )

      values = {} of String => JSON::Any
      pinned = Set(String).new
      secret_pinned = Set(String).new
      config = Facet::Config.instance

      SPEC.each do |path, entry|
        doc_value = content ? content_at(content, path) : nil
        if (dv = doc_value) && !dv.raw.nil?
          pinned << path
          secret_pinned << path if entry.secret?
          values[path] = dv unless entry.secret?
        elsif !entry.secret?
          values[path] = entry.fallback.call(config) || JSON::Any.new(nil)
        end
      end

      @@values = values
      @@pinned = pinned
      @@secret_pinned = secret_pinned
      @@stale = false
      @@refreshed_at = Time.instant
      Log.debug { "System settings cache refreshed (#{pinned.size} pinned paths)" }
    end

    # Effective snapshot of the non-secret values, keyed by path. Secret
    # paths are absent — read credentials through `reveal_secret`.
    def self.effective(db : DB::Connection) : Hash(String, JSON::Any)
      ensure_fresh(db)
      @@values
    end

    # The registered paths the document currently pins: non-null fields,
    # plus secret paths with a sealed slot (the adoption marker). This is
    # the pin visibility the GET surface exposes — without it an operator
    # cannot tell a pinned value from an inherited one.
    def self.pinned(db : DB::Connection) : Array(String)
      ensure_fresh(db)
      @@pinned.to_a.sort
    end

    # One effective value. Unknown paths raise — a typo in consumer code
    # must fail loud, not silently read nothing.
    def self.value_at(db : DB::Connection, path : String) : JSON::Any?
      entry = SPEC[path]?
      raise ArgumentError.new("Unknown system setting path '#{path}'") if entry.nil?
      return nil if entry.secret?

      ensure_fresh(db)
      @@values[path]?
    end

    # String convenience over `value_at`.
    def self.string_at(db : DB::Connection, path : String) : String?
      value_at(db, path).try(&.as_s?)
    end

    # One effective string read straight from the document row — the
    # process cache is not consulted. The tier chain mirrors the cached
    # read exactly: the document value wins, the spec's file fallback
    # fills an unpinned path, and `nil` means neither tier pins the path.
    # Unknown and secret paths raise — a caller bug must fail loud, and a
    # secret must never resolve through a string reader.
    #
    # The IAM policy gates read through this tier (`IAM::Policy`): an
    # auth decision must not tolerate a stale-cache window. A CLI writer
    # publishes its fanout only since `CLI.dispatch` flushes the
    # publisher, and a re-applied value produces no mutation at all (the
    # empty-diff fast path) — the fanout is not a freshness guarantee a
    # security gate may lean on. One primary-key read per call; the gates
    # sit on non-hot paths (login, password reset, `/me`).
    def self.uncached_string_at(db : DB::Connection, path : String) : String?
      entry = SPEC[path]?
      raise ArgumentError.new("Unknown system setting path '#{path}'") if entry.nil?
      raise ArgumentError.new("System setting path '#{path}' is a secret — " \
                              "read it through reveal_secret") if entry.secret?

      content = db.query_one?(
        "SELECT content FROM projections " \
        "WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
        DOMAIN, DOC_TYPE, DOC_ID,
        as: JSON::Any,
      )
      doc_value = content ? content_at(content, path) : nil
      return doc_value.as_s? if doc_value && !doc_value.raw.nil?
      entry.fallback.call(Facet::Config.instance).try(&.as_s?)
    end

    # One effective string-array read straight from the document row — the
    # process cache is not consulted. Same tier chain and fail-loud contract
    # as `uncached_string_at`; the coercion keeps the string entries and
    # drops anything else (the write gate refuses malformed arrays on the
    # StringList paths anyway). An unpinned path resolves through the
    # spec's file fallback — an empty list is a real value, not "unset".
    def self.uncached_string_array_at(db : DB::Connection, path : String) : Array(String)
      entry = SPEC[path]?
      raise ArgumentError.new("Unknown system setting path '#{path}'") if entry.nil?
      raise ArgumentError.new("System setting path '#{path}' is a secret — " \
                              "read it through reveal_secret") if entry.secret?

      content = db.query_one?(
        "SELECT content FROM projections " \
        "WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
        DOMAIN, DOC_TYPE, DOC_ID,
        as: JSON::Any,
      )
      doc_value = content ? content_at(content, path) : nil
      if doc_value && !doc_value.raw.nil?
        if arr = doc_value.as_a?
          return arr.compact_map(&.as_s?)
        end
        return [] of String
      end
      entry.fallback.call(Facet::Config.instance).try(&.as_a?.try(&.compact_map(&.as_s?))) || [] of String
    end

    # One effective integer read straight from the document row — the
    # process cache is not consulted. Same tier chain and same fail-loud
    # contract as `uncached_string_at`; the int coercion follows `int_at`
    # (whole-number floats accepted, a fractional value reads as nil —
    # the write gate refuses those on the integer paths anyway).
    def self.uncached_int_at(db : DB::Connection, path : String) : Int64?
      entry = SPEC[path]?
      raise ArgumentError.new("Unknown system setting path '#{path}'") if entry.nil?
      raise ArgumentError.new("System setting path '#{path}' is a secret — " \
                              "read it through reveal_secret") if entry.secret?

      content = db.query_one?(
        "SELECT content FROM projections " \
        "WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
        DOMAIN, DOC_TYPE, DOC_ID,
        as: JSON::Any,
      )
      doc_value = content ? content_at(content, path) : nil
      if doc_value && !doc_value.raw.nil?
        if i = doc_value.as_i64?
          return i
        end
        if (f = doc_value.as_f?) && f == f.trunc
          return f.to_i64
        end
        return nil
      end
      entry.fallback.call(Facet::Config.instance).try(&.as_i64?)
    end

    # Int convenience over `value_at`. Accepts a whole-number float (the
    # JSON wire has one number type); a fractional value reads as nil —
    # the write gate refuses those on the integer paths anyway.
    def self.int_at(db : DB::Connection, path : String) : Int64?
      value = value_at(db, path)
      return nil if value.nil?

      if i = value.as_i64?
        return i
      end
      if (f = value.as_f?) && f == f.trunc
        return f.to_i64
      end
      nil
    end

    # Resolves one secret path: the sealed slot → reveal; else the file
    # value (via `!env`); else nil. Never cached — the store read is one
    # AES-GCM open, and the cache then holds no credentials. A reveal
    # failure (tamper, AAD mismatch) raises — fail loud, never fall back.
    def self.reveal_secret(db : DB::Connection, path : String) : String?
      entry = SPEC[path]?
      raise ArgumentError.new("Unknown system setting path '#{path}'") if entry.nil?
      raise ArgumentError.new("System setting path '#{path}' is not a secret") unless entry.secret?

      ensure_fresh(db)
      if @@secret_pinned.includes?(path)
        revealed = Secrets.reveal(db, DOC_REF, path)
        return revealed if revealed
      end
      entry.fallback.call(Facet::Config.instance).try(&.as_s?)
    end

    # Reads one dot-separated path off the document content. A missing
    # segment or a non-object hop yields nil; a JSON null at the leaf
    # yields `JSON::Any` wrapping nil (the caller checks `.raw.nil?`).
    private def self.content_at(content : JSON::Any, path : String) : JSON::Any?
      node = content
      path.split('.').each do |segment|
        obj = node.as_h?
        return nil if obj.nil?
        node = obj[segment]?
        return nil if node.nil?
      end
      node
    end
  end
end
