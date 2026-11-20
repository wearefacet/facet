# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/doctype_definition"
require "../doctype/derived_operators"
require "../doctype/definition_store"
require "../document/copy"
require "../document/projection_gucs"
require "../index"
require "../mutation/client"
require "../rbac"
require "../event"
require "../util/projections"
require "./publish_gate"

module Facet
  module Domain
    # Reusable structure-copy primitive for domains.
    #
    # Copies a domain's structure — its `core.DocType` projection rows and
    # the `core.Domain` document itself — into a fresh domain identified by
    # a new domain string. Draft data (mutations, projection documents that
    # are not doctype definitions) is **not** copied.
    #
    # This is the primitive behind `Domain::Publish`:
    #   `Copy.structure(db, from: "_abc", to: "orders", draft: false)
    #
    # ## Atomicity
    #
    # Runs entirely within the caller's transaction. A crash before commit
    # leaves the source intact and the target un-created; the operation is
    # retryable and idempotent (the target is either absent or fully created).
    #
    # ## Identity immutability
    #
    # `(domain, doc_type)` is the compound primary key on `projections` and
    # `mutations`. Because the mutation log is append-only, renaming a domain
    # in place would either rewrite historic mutation rows (breaking the
    # audit contract) or orphan them from their own projections. Copy-and-drop
    # keeps history intact: the target domain gets fresh rows under the new
    # string; the source's projections are later soft-deleted by
    # `Domain::Scratch.drop` (the mutation log is preserved for audit).
    #
    # ## Event flow
    #
    # Each created `core.DocType` definition enqueues a `registered` event
    # (mirroring `Doctype::Create`'s post-commit hook) and the new
    # `core.Domain` document enqueues a `created` event. Callers (typically
    # `Domain::Publish`) commit the transaction and then call
    # `Event::Publisher.flush` so both events reach the doctype-cache and
    # replication subscribers in the normal way.
    #
    # We persist via `Mutation::Client.create` directly rather than through
    # `Doctype::Create`/`Document::Create` to preserve the
    # `actioner_id` provenance string (e.g. `"system:publish"`) on the
    # mutation row, while still triggering `Index::Manager.sync` and
    # `DefinitionStore.invalidate` for each copied doctype — the same
    # side effects the high-level service performs.
    module Copy
      # Copy the structure (doctype definitions + domain document) of the
      # `from` domain into a new `to` domain.
      #
      # The new `core.Domain` document is created with `draft:` set to the
      # given value (publish passes `draft: false` — a live target).
      # Each doctype definition under `from` is re-created under `to` with
      # its `domain` field rewritten; all other definition content is
      # copied verbatim.
      #
      # `extra_content` is an optional set of fields merged into the target
      # `core.Domain` document alongside `id` and `draft` — used by
      # `Domain::Draft.create_from` to stamp the `source_domain` provenance
      # field onto a draft derived from a live domain.
      #
      # No data is copied. Reference indexes are materialised for each new
      # doctype via `Index::Manager.sync`, mirroring `Doctype::Create`.
      def self.structure(
        db : DB::Connection,
        from : String,
        to : String,
        draft : Bool,
        actioner_id : String = "system:publish",
        extra_content : Hash(String, JSON::Any)? = nil,
      ) : Nil
        # 1. Read the source domain document.
        source_domain_content = db.query_one?(
          <<-SQL,
            SELECT content FROM projections
            WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1
              AND deleted_at IS NULL
          SQL
          from,
        ) do |rs|
          rs.read(JSON::Any)
        end

        raise "Source domain '#{from}' not found" if source_domain_content.nil?

        # 2. Create the target core.Domain document, preserving any content
        #    from the source (description, color, context_sets, grants, …)
        #    and forcing `draft` to the requested value. `extra_content` is
        #    layered on top — it cannot override `id` or `draft`, which are
        #    always forced by the caller.
        #
        #    Wrapped in a transaction (no-op when the caller already holds
        #    one — see Copy.structure's atomicity contract) per the rule that
        #    any mutation must be transactional.
        target_content = merge_domain_content(source_domain_content.as_h, to, draft, extra_content)
        domain_mut_id = Database.with_transaction(db, ignore_if_set: true) do |txn|
          # core.Domain has no parseable definition — stage the empty GUC
          # set, the same branch Document::Create uses for domain creates.
          Document::ProjectionGucs.clear_all(txn)

          Mutation::Client.create(
            txn,
            "core", "Domain",
            doc_id: to,
            content: target_content.to_json,
            actioner_id: actioner_id,
          )
        end

        Event::Publisher.enqueue(
          domain: "core", doc_type: "Domain", doc_id: to,
          event: "created", mutation_id: domain_mut_id, actioner_id: actioner_id,
        )

        # 3. Copy each doctype definition under the source domain, then copy
        #    each doctype's owned children (core.DocumentView, etc.) so the
        #    full doctype configuration — not just the field schema — is
        #    carried into the target domain.
        definitions = fetch_source_doctype_definitions(db, from)
        definitions.each do |definition|
          upsert_doctype_definition(
            db, JSON.parse(definition.to_json), definition.doctype, to, actioner_id,
          )

          # Copy the doctype's owned children (DocumentView, etc.). The
          # doctype lives under the `core` domain; its children link to it
          # via `meta.parent_id` and a `parent_doctype` content field, both
          # holding the source qualified id (`{from}.{doctype}`). The
          # transformer rewrites `parent_doctype` to the target qualified id
          # (`{to}.{doctype}`); `meta.parent_id` is remapped by the recursion.
          source_qualified = definition.qualified_name
          target_qualified = "#{to}.#{definition.doctype}"
          transformer = make_parent_doctype_transformer(source_qualified, target_qualified)
          Document::Copy.copy_children_of(
            db,
            from_domain: "core",
            to_domain: "core",
            parent_doctype: "DocType",
            source_parent_id: source_qualified,
            new_parent_id: target_qualified,
            actioner_id: actioner_id,
            content_transformer: transformer,
          )
        end
      end

      # ── Private ──────────────────────────────────────────────────────

      # Fetches every doctype definition whose domain matches `from`.
      # Ordered by `id ASC` so copies land deterministically. Shared with
      # `Domain::Publish`, which fetches the same rows for its draft
      # domain.
      def self.fetch_source_doctype_definitions(
        db : DB::Connection,
        from : String,
      ) : Array(Doctype::DoctypeDefinition)
        rows = db.query_all(
          <<-SQL,
            SELECT content FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType'
              AND content->>'domain' = $1
              AND deleted_at IS NULL
            ORDER BY id ASC
          SQL
          from,
          as: JSON::Any,
        )

        definitions = [] of Doctype::DoctypeDefinition
        rows.each do |row|
          begin
            definitions << Doctype::DoctypeDefinition.from_json(row)
          rescue JSON::ParseException
            # A corrupt doctype projection is skipped — the copy must not
            # abort the whole publish because of one broken definition.
          end
        end
        definitions
      end

      # Persists a doctype definition under the target domain string,
      # creating the row when absent or updating it in place when present.
      # One persist-with-side-effects path shared by the fresh-publish
      # path, the overwrite-publish path, and
      # `Domain::Portable::Import`'s doctype-create path.
      #
      # `content` is the raw definition JSON — persisted through the
      # raw-JSON domain rewrite, so fields not modelled on the struct
      # survive. `doctype_name` names the doctype segment of the target
      # id; everything else (fields, actions, migrations, script,
      # schema_version) persists verbatim.
      #
      # Persists via direct `Mutation::Client` calls and then mirrors the
      # side effects `Doctype::Create`/`Doctype::Update` perform: enqueues
      # the event, triggers `Index::Manager.sync`, and invalidates the
      # definition cache for the doctype id. This preserves the
      # `actioner_id` provenance string on the mutation row while still
      # firing the full event + index flow.
      def self.upsert_doctype_definition(
        db : DB::Connection,
        content : JSON::Any,
        doctype_name : String,
        to : String,
        actioner_id : String,
        event : String = "registered",
      ) : Nil
        rewritten = PublishGate.domained_content(content, to)

        # Stamp the derived per-field `operators` surface. The import path
        # stamps its own copy in `Import.apply_doctypes` (it must derive
        # before the merge identity check); this call covers the publish
        # path and keeps the persist branch safe on its own. Without the
        # member, the frontend filter bar reads an empty operator set
        # (`FieldDef.operators`) and every field is silently non-filterable
        # in the UI.
        rewritten = with_derived_operators(rewritten)

        doc_id = "#{to}.#{doctype_name}"

        # Stage the projection GUCs the trigger reads (search corpus,
        # links, display_name). The raw mutation path stages nothing on
        # its own, and an unstaged GUC stores a NULL derived column
        # (B-78). The templates come from the stored `core.DocType`
        # definition — the doctype these rows are written under — never
        # from the definition being persisted: rendering e.g. `crm.Deal`'s
        # `{{ title }} {{ value }}` against definition content stores
        # NULL, and `iam.Account`'s stores a literal template fragment.
        # The system definition is always live when this runs (the seed
        # pass registers it before any domain write); a fetch that still
        # fails takes the no-definition branch, exactly like the pipeline
        # fallback.
        parsed_content = JSON.parse(rewritten.to_json)

        # DocType is a child of Domain; parent_id is the target domain name
        # (the new core.Domain document's id).
        meta = %({"parent_id": #{to.to_json}})
        existing = Util::Projections.exists?(db, "core", "DocType", doc_id)
        mut_id = Database.with_transaction(db, ignore_if_set: true) do |txn|
          core_doctype_defn = Doctype::DefinitionStore.fetch(txn, "core.DocType")
          if core_doctype_defn
            Document::ProjectionGucs.set_all(txn, core_doctype_defn, parsed_content)
          else
            Document::ProjectionGucs.clear_all(txn)
          end
          if existing
            # Full-replace the stored definition. `compute_diff` yields a
            # `Mutation::JsonDiff` with set/unset entries — the same diff
            # shape `Doctype::Update` persists. An OVERWRITE publish of an
            # untouched copy (identical structure — the gate lets it
            # through on purpose) diffs to empty, and `Mutation::Client
            # .update` raises on an empty diff: skip the no-op mutation and
            # its `updated` event instead of 500ing.
            current_content = Mutation::Client.fetch_content(txn, "core", "DocType", doc_id)
            diff = Mutation::JsonDiff.diff(current_content, rewritten)
            if diff.empty?
              nil
            else
              Mutation::Client.update(
                txn, "core", "DocType", doc_id,
                diff_json: diff.to_json,
                actioner_id: actioner_id,
              )
            end
          else
            Mutation::Client.create(
              txn,
              "core", "DocType",
              doc_id: doc_id,
              content: rewritten.to_json,
              meta: meta,
              actioner_id: actioner_id,
            )
          end
        end

        if mut_id
          Event::Publisher.enqueue(
            domain: "core", doc_type: "DocType", doc_id: doc_id,
            event: event, mutation_id: mut_id, actioner_id: actioner_id,
          )
        end

        # Trigger index sync for the target domain's doctype so reference
        # indexes are materialised. Runs in background fibers.
        copied_defn = Doctype::DoctypeDefinition.from_json(rewritten)
        Index::Manager.sync(db, copied_defn)

        # Invalidate the cache so the new doctype is visible to subsequent
        # readers on the same fiber.
        Doctype::DefinitionStore.invalidate(doc_id)
      end

      # Returns `content` with the derived per-field `operators` surface
      # stamped. Shared by every raw-persist path so the stored definition
      # carries exactly the member the struct writer would have produced —
      # see `Doctype::DerivedOperators`.
      def self.with_derived_operators(content : JSON::Any) : JSON::Any
        Doctype::DerivedOperators.apply(content)
      end

      # Builds a `Document::Copy::ContentTransformer` that rewrites the
      # `parent_doctype` content field from the source qualified id to the
      # target qualified id. Used when copying a doctype's child documents
      # (DocumentView, etc.) so their `parent_doctype` reference points to the
      # doctype under the target domain.
      private def self.make_parent_doctype_transformer(
        source_qualified : String,
        target_qualified : String,
      ) : Document::Copy::ContentTransformer
        Document::Copy::ContentTransformer.new do |content, _src, _dst|
          h = content.as_h?
          next content unless h
          next content unless h["parent_doctype"]?.try(&.as_s?) == source_qualified
          h = h.dup
          h["parent_doctype"] = JSON::Any.new(target_qualified)
          JSON::Any.new(h)
        end
      end

      # Merges source domain content with the target identity. Preserves
      # everything on the source (description, color, grants, context_sets)
      # except `draft`, which is forced to the caller's value, and `id`,
      # which becomes the new domain name. `extra_content` is layered on
      # top of the source — the caller-supplied provenance fields that the
      # merge must stamp onto a draft derived from a live domain
      # (`source_domain`). `id` and `draft` are always forced last and win
      # over any value in `extra_content`.
      private def self.merge_domain_content(
        source : Hash(String, JSON::Any),
        to : String,
        draft : Bool,
        extra_content : Hash(String, JSON::Any)?,
      ) : JSON::Any
        merged = source.dup
        extra_content.try { |extra| extra.each { |k, v| merged[k] = v } }
        merged["id"] = JSON::Any.new(to)
        merged["draft"] = JSON::Any.new(draft)
        JSON::Any.new(merged)
      end
    end
  end
end
