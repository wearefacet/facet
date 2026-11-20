# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Domain
    module Portable
      # In-memory model of a portable-domain bundle, plus directory,
      # `.zip`, and `.tar.gz` readers/writers.
      #
      # A bundle is a directory tree:
      #
      # ```
      # {domain}.facet - domain/
      #                  ├── bundle.yml # format_version, source_domain, exported_at, facet_version
      # ├── domain.yml                  # { content: {...}, meta: {...} } — core.Domain document
      # ├── doctypes/
      #     │ └── { QualifiedDoctype }.yml
      # └── views/
      #     └── { qualified - doctype }/
      #     ├── document_views/
      #         │ └── { kind }.yml
      # └── collection_views/
      #     └── { slug }.yml
      # ```
      #
      # The `.tar.gz` form is a gzip of that directory tree; the `.zip`
      # form carries the same tree as flat zip entries (pure stdlib — no
      # external binary). The reader and writer auto-detect the input
      # type from `File.directory?`, the path extension, and the file's
      # magic bytes.
      #
      # Every entry file is YAML (`FORMAT_VERSION >= 2`). Legacy bundles
      # produced with `FORMAT_VERSION = 1` used JSON entry files and are
      # still readable — the reader dispatches by `format_version`.
      module Archive
        # Bundle format version. Bumped only on a breaking change to the
        # on-disk layout. Future Facet versions may import older versions
        # but never silently export them.
        #
        # Version history:
        #   * `1` — original layout. Entry files written as JSON
        #     (`domain.json`, `doctypes/*.json`, `views/.../*.json`).
        #     `bundle.yml`'s string fields were double-encoded (Crystal's
        #     `.to_json` on a string adds surrounding quotes).
        #   * `2` — entry files are YAML (`domain.yml`, `doctypes/*.yml`,
        #     `views/.../*.yml`). YAML block scalars render the embedded
        #     doctype Lua script as a readable indented block, and
        #     `bundle.yml`'s scalar fields carry no JSON quoting. The
        #     reader still loads v1 bundles by dispatching on
        #     `format_version` to the legacy JSON entry reader.
        FORMAT_VERSION = 2

        # The newest format version the writer can emit. Older readers
        # that do not know about version 2 will refuse the bundle (this is
        # the intended breakage when bumping the format).
        LEGACY_FORMAT_VERSION = 1

        # YAML tag used to reference an externalized sidecar file. The
        # reader (`Util::YamlInclude`) expands it to the file's literal
        # contents; the writer emits it for externalized Lua scripts.
        READ_FILE_TAG = "!read_file"

        # Raised when a bundle cannot be read or its `format_version` is
        # unknown. Import surfaces this as a CLI error rather than letting
        # the system load an incompatible bundle.
        class Error < ::Exception
        end

        # One document entry in the bundle. Stored as `{"content", "meta"}`
        # so the import can reconstruct `meta.parent_id` linkage for child
        # doctypes without re-deriving it from the doctype tree.
        record Entry,
          content : JSON::Any,
          meta : JSON::Any

        # One `core.CollectionView` row. Personal views (those with a
        # non-null `owner_id`) are never exported — they are user data,
        # not definition. `slug` is the on-disk filename; the import uses
        # `content.name` for reconciliation, never the slug.
        record CollectionView,
          slug : String,
          entry : Entry

        # One live document of a user doctype in the source domain. The
        # export only carries documents when `with_documents: true` was
        # passed; definition doctypes (`core.Domain`, `core.DocType`,
        # `core.DocumentView`, `core.CollectionView`) are NEVER exported
        # as documents — they are already carried as definition entries.
        # `id` is the projection id (e.g. `crm.Company.1` or a free-form
        # `exp_a1`). The import rewrites the leading `{source_domain}.`
        # prefix when `--into` renames the target domain.
        record DocumentEntry,
          id : String,
          entry : Entry

        # The bundle model.
        class Bundle
          getter source_domain : String
          getter exported_at : String
          getter facet_version : String
          getter domain : Entry
          getter doctypes : Array({doctype: String, entry: Entry})
          # Keyed by qualified doctype id, ordered by document-view `kind`
          # — definition-owned.
          getter document_views : Hash(String, Array({kind: String, entry: Entry}))
          # Keyed by qualified doctype id. Unordered — general views are
          # live-authored and not part of the strict definition, but are
          # carried so the destination starts with the same listing tabs.
          getter collection_views : Hash(String, Array(CollectionView))
          # Keyed by qualified doctype id, in export insertion order.
          # Empty unless the bundle was produced with `--with-documents`.
          # The import rewrites the leading `{source}.` segment of every
          # qualified key (and every matching document id / reference
          # token inside the content) when `--into` renames the target.
          getter documents : Hash(String, Array(DocumentEntry))

          def initialize(
            @source_domain : String,
            @exported_at : String,
            @facet_version : String,
            @domain : Entry,
            @doctypes : Array({doctype: String, entry: Entry}),
            @document_views : Hash(String, Array({kind: String, entry: Entry})),
            @collection_views : Hash(String, Array(CollectionView)),
            @documents : Hash(String, Array(DocumentEntry)) = {} of String => Array(DocumentEntry),
          )
          end
        end
      end
    end
  end
end
