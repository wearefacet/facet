# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Domain
    module Portable
      module Import
        # ── Helpers — content rewrite ────────────────────────────────────

        # Rewrites a bundled `core.Domain` content so id/draft match the
        # target identity. The `id` field is the projection id (also the
        # domain name) — it is implicit, but the body may also carry a
        # `name` field for the display name; we preserve that.
        private def self.rewrite_domain(content : JSON::Any, target_domain : String) : JSON::Any
          h = content.as_h? || {} of String => JSON::Any
          h = h.dup
          h["id"] = JSON::Any.new(target_domain)
          h["draft"] = JSON::Any.new(false)
          JSON::Any.new(h)
        end

        # Returns the qualified doctype id under the target domain. The
        # bundle carries the source qualified id (e.g. `crm.Widget`) and
        # the source domain name; rewriting the leading `"{source}."`
        # prefix with `"{target}."` produces the target id.
        #
        # The rewrite is by *domain segment*, not by string prefix — a
        # doctype named `crm.crm` must not be turned into
        # `targetdomain.crm` by a naive prefix replace. We split on the
        # first `.` and verify the leading segment equals the source
        # domain; if it does not, the doctype's `domain` field would not
        # have matched Export's `fetch_doctypes` filter either, so we
        # leave it untouched. The rewrite itself is the shared
        # `rewrite_leading_segment` primitive.
        private def self.target_qualified_name(
          source_qualified : String,
          source_domain : String,
          target_domain : String,
        ) : String
          rewrite_leading_segment(source_qualified, source_domain, target_domain)
        end

        # Rewrites a document id's leading `{source_domain}.` segment to
        # `{target_domain}.` when the bundle is being imported under a
        # different domain name. Mirrors `target_qualified_name`: only the
        # leading *segment* is rewritten. Free-form ids (`exp_a1`,
        # `cand_01HZX9Q2`) that do not start with `{source}.` are left
        # untouched — they are doctype-local ids, not qualified.
        private def self.rewrite_document_id(
          doc_id : String,
          source_domain : String,
          target_domain : String,
        ) : String
          rewrite_leading_segment(doc_id, source_domain, target_domain)
        end

        # Rewrites every string leaf inside a document's content that
        # starts with `{source_domain}.` so the leading segment becomes
        # `{target_domain}.` — document `content` and `meta` both flow
        # through this walk. This catches cross-doctype `reference`
        # tokens (e.g. `owner_id: "iam.Account.account_recruiter_kim"` on an
        # `hr` bundle imported `--into hr2`) and composition parent ids
        # stored inside `content` (uncommon — `meta.parent_id` is the
        # canonical parent link, but a doctype may also embed it).
        #
        # References to doctypes outside the bundle (e.g. an `iam.*`
        # reference inside an `hr` bundle) are left untouched — Facet
        # documents may reference objects that do not yet exist, and the
        # cross-domain reference integrity is never enforced (see
        # `doc/backend/portable-domains.md` → Cross-domain references).
        #
        # When the domains are equal the walk is a no-op —
        # `rewrite_leading_segment` rewrites nothing and non-string leaves
        # pass through. Recursively walks a `JSON::Any` tree and rewrites
        # the leading `{source}.` segment of every matching string scalar.
        private def self.rewrite_any_strings(
          value : JSON::Any,
          source_domain : String,
          target_domain : String,
        ) : JSON::Any
          case raw = value.raw
          when Hash(String, JSON::Any)
            h = {} of String => JSON::Any
            raw.each { |k, v| h[k] = rewrite_any_strings(v, source_domain, target_domain) }
            JSON::Any.new(h)
          when Array(JSON::Any)
            a = [] of JSON::Any
            raw.each { |v| a << rewrite_any_strings(v, source_domain, target_domain) }
            JSON::Any.new(a)
          when String
            JSON::Any.new(rewrite_leading_segment(raw, source_domain, target_domain))
          else
            value
          end
        end

        # Rewrites `value` if it starts with `{source}.`, splitting on the
        # first `.` exactly as `target_qualified_name` does.
        private def self.rewrite_leading_segment(
          value : String,
          source_domain : String,
          target_domain : String,
        ) : String
          prefix = "#{source_domain}."
          return target_domain + value[source_domain.size..] if value.starts_with?(prefix)
          value
        end

        # Removes the `$force` key from a content root. The flag is
        # per-operation (`Doctype::Update` reads it from the raw request
        # body and never persists it — `compute_diff` serializes the
        # parsed struct, which has no `$force` property). The import
        # strips it explicitly instead, so the stored `core.DocType` row
        # never carries it and a re-export stays round-trip clean.
        private def self.strip_force(content : JSON::Any) : JSON::Any
          h = content.as_h? || {} of String => JSON::Any
          return content unless h.has_key?("$force")
          h = h.dup
          h.delete("$force")
          JSON::Any.new(h)
        end

        # Returns `meta` with `parent_id` rewritten to `new_parent`.
        private def self.remap_parent_id(meta : JSON::Any, new_parent : String) : JSON::Any
          h = meta.as_h? || {} of String => JSON::Any
          h = h.dup
          h["parent_id"] = JSON::Any.new(new_parent)
          JSON::Any.new(h)
        end

        # Rewrites a bundled `core.DocumentView` content's
        # `parent_doctype` field from the source qualified id to the
        # target — mirrors `Domain::Copy.make_parent_doctype_transformer`.
        # `kind` is preserved (it is the view's identity).
        private def self.rewrite_document_view(
          content : JSON::Any,
          target_domain : String,
          kind : String,
          target_qualified : String,
        ) : JSON::Any
          h = content.as_h? || {} of String => JSON::Any
          h = h.dup
          h["parent_doctype"] = JSON::Any.new(target_qualified) if h["parent_doctype"]?
          JSON::Any.new(h)
        end

        # Returns `meta` with `parent_id` removed (top-level documents
        # like `core.Domain` are not children).
        private def self.drop_parent_id(meta : JSON::Any) : JSON::Any
          h = meta.as_h? || {} of String => JSON::Any
          h = h.dup
          h.delete("parent_id")
          JSON::Any.new(h)
        end

        # ── Helpers — display-name backfill ─────────────────────────────

        # Recomputes `display_name` for every document of the doctype whose
        # qualified id is `source_qualified`, once those rows live under
        # `target_domain`, when the `display_name` template contains at
        # least one `$<field>` token naming a `reference` field. Plain-field
        # templates were already correct at write time, so they are
        # skipped. Runs post-commit on the caller's connection.
        #
        # A doctype whose definition declares no `search` template derives
        # its `search` corpus from the display_name (B-115), so the same
        # UPDATE refreshes that corpus from the new label. A templated
        # corpus is left untouched — its reference variables are not
        # refreshed on this path either.
        private def self.refresh_reference_display_names(
          db : DB::Connection,
          source_qualified : String,
          source_domain : String,
          target_domain : String,
        ) : Nil
          resolver = Document::DisplayName::DatabaseReferenceResolver.new(db)

          target_qualified = target_qualified_name(source_qualified, source_domain, target_domain)
          domain_segment, _, doctype_segment = target_qualified.partition('.')

          defn = Doctype::DefinitionStore.fetch(db, target_qualified)
          return unless defn
          template = defn.display_name
          return if template.nil? || template.empty?
          return unless template_references_any_field?(template, defn)

          search_template = defn.search

          rows = db.query_all(
            "SELECT id, content, display_name FROM projections WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL",
            domain_segment, doctype_segment,
          ) do |rs|
            {rs.read(String), rs.read(JSON::Any), rs.read(String?)}
          end

          rows.each do |(doc_id, content, current_dn)|
            new_dn = Document::DisplayName.compute(defn, content, resolver)
            next if new_dn == current_dn

            if search_template.nil? || search_template.empty?
              new_search = Document::Search.compute(defn, content, resolver, new_dn)
              db.exec(
                "UPDATE projections SET display_name = $1, search = $2, updated_at = now() WHERE domain = $3 AND doc_type = $4 AND id = $5",
                new_dn, new_search, domain_segment, doctype_segment, doc_id,
              )
            else
              db.exec(
                "UPDATE projections SET display_name = $1, updated_at = now() WHERE domain = $2 AND doc_type = $3 AND id = $4",
                new_dn, domain_segment, doctype_segment, doc_id,
              )
            end
          end
        end

        # Returns true if `template` references at least one field (root
        # variable) that is a `reference` field on `defn`. Only such
        # references can have been mis-resolved by ordering during the
        # source export — plain-field templates were already correct at
        # write time.
        private def self.template_references_any_field?(
          template : String,
          defn : Doctype::DoctypeDefinition,
        ) : Bool
          Templating::Engine.roots(template).any? do |root|
            field = defn.fields[root]?
            field && field.reference?
          end
        end
      end
    end
  end
end
