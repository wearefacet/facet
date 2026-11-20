# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"

module Facet
  # ── `dev:` section of `Facet::Config` ────────────────────────────────
  #
  # The `dev:` records and their YAML loader live here, next to the dev
  # concern. `Facet::Config` (src/config.cr) declares the `dev` field and
  # calls `load_dev` when it parses the file.
  class Config
    # ── Dev domain watch ─────────────────────────────────────────────────

    # Document retention mode for the dev domain watcher. `preserve` keeps
    # documents created through the app across sync cycles; `discard`
    # restores strict bundle-is-truth (every cycle reseeds from `documents/`).
    enum DocumentsMode
      Preserve
      Discard
    end

    # The watcher's knobs. `path` is the watch root — a parent directory
    # whose immediate children (each carrying a `bundle.yml`) are managed
    # bundles. `poll_ms` is the poll interval (lower bound 100 ms, enforced
    # at load). `documents` is the retention mode, global for every child
    # in v1. See `Facet::Dev::DomainWatcher`.
    record DomainWatchConfig,
      path : String,
      poll_ms : Int32 = 500,
      documents : DocumentsMode = DocumentsMode::Preserve

    # The optional `dev:` section. `domain_watch` is `nil` when the section
    # (or the `dev:` block itself) is absent — the watcher only runs when it
    # is present and the environment is not production.
    record DevConfig,
      domain_watch : DomainWatchConfig? = nil

    # Parses the dev config from the YAML document. The section is
    # dev-only: the production boot refuses to start the watcher even when
    # the section is present (see `Facet::Dev::DomainWatcher`). The path
    # must be a readable directory at load time — the config line is the
    # teardown consent for every domain the root's children name, so a
    # typo'd path must fail loud instead of silently doing nothing.
    private def self.load_dev(raw : YAML::Any) : DevConfig
      dev_raw = raw["dev"]?
      return DevConfig.new if dev_raw.nil? || dev_raw.raw.nil?

      domain_watch_raw = dev_raw["domain_watch"]?
      return DevConfig.new if domain_watch_raw.nil? || domain_watch_raw.raw.nil?

      path = read_str(domain_watch_raw["path"]?) ||
             raise ArgumentError.new(
               "dev.domain_watch.path is required — it names the watch root " \
               "(a parent directory holding the domain bundles)"
             )

      unless Dir.exists?(path)
        raise ArgumentError.new(
          "dev.domain_watch.path '#{path}' is not a readable directory. " \
          "Create it or point the path at the existing watch root before boot."
        )
      end

      poll_ms = read_int(domain_watch_raw["poll_ms"]?, 500)
      unless poll_ms >= 100
        raise ArgumentError.new(
          "dev.domain_watch.poll_ms must be >= 100 (got #{poll_ms}) — " \
          "a faster poll hammers the filesystem for no gain"
        )
      end

      documents_raw = read_str(domain_watch_raw["documents"]?) || "preserve"
      documents = case documents_raw
                  when "preserve" then DocumentsMode::Preserve
                  when "discard"  then DocumentsMode::Discard
                  else
                    raise ArgumentError.new(
                      "dev.domain_watch.documents must be 'preserve' or 'discard' " \
                      "(got '#{documents_raw}')"
                    )
                  end

      DevConfig.new(
        domain_watch: DomainWatchConfig.new(
          path: path,
          poll_ms: poll_ms,
          documents: documents,
        ),
      )
    end
  end
end
