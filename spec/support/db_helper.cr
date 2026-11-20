# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Database helpers ──────────────────────────────────────────────────────
#
# Generic helpers for opening DB connections and managing test state.
# These are top-level (no module) so they are available in every spec.
#
# All helpers use the `Facet::Database` singleton pool which is
# initialized in `spec_helper.cr`'s `before_suite` hook.

require "../../src/util/script_helpers"

# Returns a short, unique suffix for test fixture names (doctype names,
# domain names, user ids). Draws from the random portion of a ULID so the
# project has a single id-generation primitive.
#
# The suffix is taken from the *random* portion of the ULID (the last 16
# chars), not the timestamp prefix. The first 10 chars of a ULID encode
# only millisecond timestamp — two calls within the same millisecond
# would produce identical 8-char prefixes. The random portion has 80 bits
# of entropy, so collisions are negligible even under tight loops.
def unique_suffix(length : Int = 8) : String
  Facet::Util::ScriptHelpers.ulid[26 - length..-1].downcase
end

# Yields a connection pinned to the current fiber. Nested `with_db` calls
# reuse the same connection (no-op).
def with_db(& : DB::Connection -> _)
  Facet::Database.with_db { |db| yield db }
end

# Opens and returns a standalone connection. The caller is responsible for
# closing it. Used when a spec needs a second independent connection (e.g.
# lock-probing) that is not part of the singleton pool.
def db_open : DB::Database
  DB.open(ENV.fetch("DATABASE_URL") { abort("DATABASE_URL is required") })
end

# Truncates the mutations and projections tables for a clean slate.
# Uses CASCADE and RESTART IDENTITY to reset sequences.
def db_truncate_mutations : Nil
  with_db { |db| db.exec("TRUNCATE mutations, projections RESTART IDENTITY CASCADE") }
end

# Opens a DB connection and yields it along with a unique doctype identifier.
# Each invocation gets a random domain/doctype pair so tests never collide.
def with_temp_doctype(domain : String = "doc-test", doctype : String? = nil, & : DB::Connection, String, String ->)
  dt = doctype || "T#{unique_suffix}"
  with_db { |db| yield db, domain, dt }
end
