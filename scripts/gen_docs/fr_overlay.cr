# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
#
# French overlay for the generated reference pages. Each generator writes the
# English page under site-docs/src/content/docs/reference/ and the French page
# under site-docs/src/content/docs/fr/reference/. The French prose lives in
# per-page JSON files under scripts/gen_docs/fr_overlay/<page>.json; a key
# missing from the overlay falls back to the English text passed at the call
# site. The Node generators (npm_cli.mjs, feature_index.mjs) read the same
# JSON files directly.
#
# Style rules live in doc/site-docs-fr-style.md: meaning-first translation,
# the glossary there, typographic apostrophe (’), non-breaking space (U+00A0)
# before : ; ! ?, vous-form. Cell values (key names, types, defaults) stay
# verbatim English; only prose and column headers translate.

require "json"

module GenDocs::FrOverlay
  extend self

  DIR = File.join(__DIR__, "fr_overlay")

  # Returns the French text for `page`/`key`, or `fallback` when the overlay
  # has no entry.
  def fetch(page : String, key : String, fallback : String) : String
    path = File.join(DIR, "#{page}.json")
    return fallback unless File.exists?(path)
    data = JSON.parse(File.read(path)).as_h?
    return fallback unless data
    data[key]?.try(&.as_s?) || fallback
  end
end
