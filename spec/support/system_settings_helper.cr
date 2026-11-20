# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── SystemSettings pin helpers ───────────────────────────────────────────────
#
# Shared by the spec files that exercise policy behaviour through the
# runtime-settings tier (login gates, MFA setup, auth-mode refusals): pins
# a value on the `core.SystemSettings` document with the system principal
# and marks the process cache stale, the same invalidation the Pub/Sub
# subscriber drives in the server process.
#
# The per-example truncation wipes every projection — doctype definitions
# included — so the caller seeds the singleton first (`ensure_settings_doc`).

require "../spec_helper"
require "../../src/system_settings"
require "../../src/doctype/seed"
require "../../src/document"

# Seeds the `core.SystemSettings` doctype (definition + the null singleton
# document) when the truncation wiped it. Idempotent.
def ensure_settings_doc(db) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
end

# Patches the singleton settings document. Raises when the write gate
# refuses the patch (so a bad fixture fails the example, not the example
# after it).
def pin_settings(db, patch : String) : Nil
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    patch,
    Facet::RBAC::AuthContext.system,
  )
  if result.is_a?(Facet::ServiceError)
    raise "pin_settings rejected #{patch}: #{result.message} " \
          "(#{result.details.try(&.map { |d| "#{d.field}: #{d.message}" }.join("; "))})"
  end
  # No Redis fanout runs in the unit suite — invalidate like the subscriber.
  Facet::SystemSettings.mark_stale
end
