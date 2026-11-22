# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "yaml"
require "pg"

require "../../database"
require "../../doctype/definition_store"
require "../../doctype/doctype_definition"
require "../../error"
require "./archive"
require "./secret_stripper"

# Facet's own version, embedded at compile time from `shard.yml` at the
# repo root. Used to stamp `bundle.yml`'s `facet_version` so an operator
# can tell which Facet release produced a bundle.
FACET_VERSION = begin
  parsed = YAML.parse({{ read_file("#{__DIR__}/../../../shard.yml") }})
  parsed["version"]?.try(&.as_s?) || "unknown"
rescue
  "unknown"
end

module Facet
  module Domain
    module Portable
      # Service that builds an `Archive::Bundle` from a live domain in the
      # database.
      #
      # The export is a **definition-only** snapshot: it carries the
      # `core.Domain` document, every `core.DocType` definition in the
      # domain, every owned `core.DocumentView` template, and every
      # **general** (shared, owner-less) `core.CollectionView`. Personal
      # collection views and document data are **not** exported — they
      # are user data, not definition.
      #
      # Drafts are refused: the export of a `draft = true` domain returns
      # a `ServiceError` so scratch data never lands in a bundle.
      module Export
        # Result of a successful export. The CLI prints the bundle path
        # and counts; the service returns the in-memory model so a future
        # HTTP route can ship the bundle over the wire without touching
        # disk.
        record Result,
          bundle : Archive::Bundle,
          doctype_count : Int32,
          document_view_count : Int32,
          collection_view_count : Int32,
          document_count : Int32

        # Builds a bundle from the domain named `source_domain`. Refuses
        # draft domains (defense-in-depth — scratch data must not be
        # portable). Raises `Archive::Error` is not used here: every
        # recoverable condition returns a `ServiceError`.
        #
        # When `with_documents` is true, every non-deleted document of
        # every user doctype in the source domain is also captured into
        # `bundle.documents`. Definition doctypes (`core.Domain`,
        # `core.DocType`, `core.DocumentView`, `core.CollectionView`)
        # are NEVER captured as documents — they are already carried as
        # definition entries (the `core` domain is excluded entirely
        # from the document set).
        #
        # When `omit_secrets` is true, every `secret` marker in a captured
        # document is replaced with `null` (see `SecretStripper`). The
        # secret state is lost: the fields import unset, because a marker
        # names a slot row that does not exist on the importing instance
        # and the import's secret-leaf gate refuses it.
        def self.call(
          db : DB::Connection,
          source_domain : String,
          *,
          with_documents : Bool = false,
          omit_secrets : Bool = false,
        ) : Result | Facet::ServiceError
          domain_entry, draft = fetch_domain(db, source_domain)
          return domain_entry if domain_entry.is_a?(Facet::ServiceError)
          if draft
            return Facet::ServiceError.new(
              422,
              "Domain '#{source_domain}' is a draft — scratch data is not portable. " \
              "Publish it first.",
            )
          end

          doctypes = fetch_doctypes(db, source_domain)
          document_views = {} of String => Array({kind: String, entry: Archive::Entry})
          collection_views = {} of String => Array(Archive::CollectionView)
          documents = {} of String => Array(Archive::DocumentEntry)

          doctypes.each do |entry|
            qualified = entry[:doctype]
            document_views[qualified] = fetch_document_views(db, qualified)
            cvs = fetch_collection_views(db, qualified)
            collection_views[qualified] = cvs unless cvs.empty?
            if with_documents
              docs = fetch_documents(db, qualified)
              if omit_secrets && !docs.empty?
                defn = Doctype::DefinitionStore.fetch(db, qualified)
                if defn
                  docs.each do |doc|
                    SecretStripper.strip!(defn, doc.entry.content)
                  end
                end
              end
              documents[qualified] = docs unless docs.empty?
            end
          end

          bundle = Archive::Bundle.new(
            source_domain: source_domain,
            exported_at: Time.utc.to_rfc3339,
            facet_version: FACET_VERSION,
            domain: domain_entry,
            doctypes: doctypes,
            document_views: document_views,
            collection_views: collection_views,
            documents: documents,
          )

          Result.new(
            bundle: bundle,
            doctype_count: doctypes.size,
            document_view_count: document_views.values.sum(&.size),
            collection_view_count: collection_views.values.sum(&.size),
            document_count: documents.values.sum(&.size),
          )
        end

        # ── Private ──────────────────────────────────────────────────────

        # Fetches the `core.Domain` projection row for `source_domain`.
        # Returns the entry and the parsed `draft` flag (treats any
        # missing or non-`true` value as `false` — fail-closed, matching
        # `Doctype::Create#draft_domain?`).
        private def self.fetch_domain(
          db : DB::Connection,
          source_domain : String,
        ) : {Archive::Entry | Facet::ServiceError, Bool}
          row = db.query_one?(
            <<-SQL,
              SELECT content, meta FROM projections
              WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1
                AND deleted_at IS NULL
            SQL
            source_domain,
          ) do |rs|
            content = rs.read(JSON::Any)
            meta = rs.read(JSON::Any)
            {content, meta}
          end

          if row.nil?
            return {
              Facet::ServiceError.new(404, "Domain '#{source_domain}' not found"),
              false,
            }
          end

          content, meta = row
          draft = content.as_h? && content["draft"]? && content["draft"].raw == true
          {Archive::Entry.new(content, meta), draft || false}
        end

        # Fetches every non-deleted `core.DocType` whose `domain` field
        # equals `source_domain`, ordered by id for deterministic output.
        # Each row is wrapped in an `Archive::Entry` so the import can
        # reproduce `meta.parent_id` (the domain name).
        private def self.fetch_doctypes(
          db : DB::Connection,
          source_domain : String,
        ) : Array({doctype: String, entry: Archive::Entry})
          rows = db.query_all(
            <<-SQL,
              SELECT id, content, meta FROM projections
              WHERE domain = 'core' AND doc_type = 'DocType'
                AND content->>'domain' = $1
                AND deleted_at IS NULL
              ORDER BY id ASC
            SQL
            source_domain,
          ) do |rs|
            {rs.read(String), rs.read(JSON::Any), rs.read(JSON::Any)}
          end

          rows.map do |_id, content, meta|
            {doctype: _id, entry: Archive::Entry.new(content, meta)}
          end
        end

        # Fetches the live `core.DocumentView` children of the doctype
        # whose qualified id is `qualified_doctype`. Mirrors the child
        # traversal that `Document::Copy.copy_children_of` walks —
        # `meta.parent_id` carries the parent linkage. Ordered by `kind`
        # so the bundle is stable.
        private def self.fetch_document_views(
          db : DB::Connection,
          qualified_doctype : String,
        ) : Array({kind: String, entry: Archive::Entry})
          rows = db.query_all(
            <<-SQL,
              SELECT id, content, meta FROM projections
              WHERE domain = 'core' AND doc_type = 'DocumentView'
                AND meta->>'parent_id' = $1
                AND deleted_at IS NULL
              ORDER BY id ASC
            SQL
            qualified_doctype,
          ) do |rs|
            {rs.read(String), rs.read(JSON::Any), rs.read(JSON::Any)}
          end

          rows.map do |_id, content, meta|
            kind = content.as_h? && content["kind"]?.try(&.as_s?) || "view"
            {kind: kind, entry: Archive::Entry.new(content, meta)}
          end
        end

        # Fetches **general** `core.CollectionView` rows for the given
        # doctype — those whose `owner_id` is null/absent. Personal
        # (owner-bound) views are user data and excluded by design (see
        # `doc/backend/collection-view.md` → the General-vs-Personal
        # distinction).
        #
        # The `owner_id IS NULL OR … IN ('', 'null')` predicate mirrors
        # the `$null` named-scope `where: { owner_id: '$null' }` and
        # tolerates both JSON null and a text-empty string.
        private def self.fetch_collection_views(
          db : DB::Connection,
          qualified_doctype : String,
        ) : Array(Archive::CollectionView)
          rows = db.query_all(
            <<-SQL,
              SELECT id, content, meta FROM projections
              WHERE domain = 'core' AND doc_type = 'CollectionView'
                AND meta->>'parent_id' = $1
                AND deleted_at IS NULL
                AND (content->>'owner_id' IS NULL
                     OR content->>'owner_id' = ''
                     OR content->>'owner_id' = 'null')
              ORDER BY id ASC
            SQL
            qualified_doctype,
          ) do |rs|
            {rs.read(String), rs.read(JSON::Any), rs.read(JSON::Any)}
          end

          rows.map do |id, content, meta|
            name = content.as_h? && content["name"]?.try(&.as_s?)
            slug = Archive.collection_view_slug(id, name)
            Archive::CollectionView.new(slug, Archive::Entry.new(content, meta))
          end
        end

        # Fetches every non-deleted document of the user doctype whose
        # qualified id is `qualified_doctype`. The `core` domain is never
        # captured here — definition doctypes (`core.Domain`,
        # `core.DocType`, `core.DocumentView`, `core.CollectionView`)
        # are already carried as definition entries and would otherwise
        # be double-shipped. The caller passes the qualified doctype id
        # (`{domain}.{doctype}`), so we split off the leading `domain.`
        # and refuse to fetch when the leading segment is `core`.
        private def self.fetch_documents(
          db : DB::Connection,
          qualified_doctype : String,
        ) : Array(Archive::DocumentEntry)
          domain_segment, _, doctype_segment = qualified_doctype.partition('.')
          return [] of Archive::DocumentEntry if domain_segment == "core"

          rows = db.query_all(
            <<-SQL,
              SELECT id, content, meta FROM projections
              WHERE domain = $1 AND doc_type = $2
                AND deleted_at IS NULL
              ORDER BY id ASC
            SQL
            domain_segment, doctype_segment,
          ) do |rs|
            {rs.read(String), rs.read(JSON::Any), rs.read(JSON::Any)}
          end

          rows.map do |id, content, meta|
            Archive::DocumentEntry.new(id, Archive::Entry.new(content, meta))
          end
        end
      end
    end
  end
end
