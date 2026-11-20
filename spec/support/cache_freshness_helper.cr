# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Cache-staleness helper ──────────────────────────────────────────────────
#
# `cache.staleness_ttl_s` is `0` (disabled) in `config.test.yml`: examples
# truncate the projections table and seed some registries in memory, so a
# live bound would rebuild from truncated data mid-suite. Specs that exercise
# the bound swap the config singleton for the duration of the block, the same
# way `with_coalesce_window` (spec/document/coalesce_spec.cr) swaps in
# a coalescing window.

# Runs the block with `cache.staleness_ttl_s` set to *seconds*. Restores the
# previous config afterwards.
#
# Re-stamps the currency registry on entry: `Document::Create` and
# `Document::Update` call `Currency::Registry.ensure_fresh` on every write,
# and a TTL window older than the last seed registration would let that call
# rebuild the registry from the example's truncated projections — emptying
# it for every later money spec.
def with_cache_ttl(seconds : Int32, &) : Nil
  original = Facet::Config.instance
  Facet::Config.instance = Facet::Config.new(
    artifact_grant_secret: original.artifact_grant_secret,
    event: original.event,
    domains: original.domains,
    secrets: original.secrets,
    database: original.database,
    cache: Facet::Config::CacheConfig.new(staleness_ttl_s: seconds),
  )
  Facet::Currency::Registry.mark_fresh
  yield
ensure
  Facet::Config.instance = original if original
end
