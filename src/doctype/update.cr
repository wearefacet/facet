# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "pg"
require "../database"
require "../mutation"
require "../index"
require "./doctype_definition"
require "./definition_store"
require "./structure"
require "./validation"
require "./draft_target_check"
require "../replication/validator"
require "../rbac"
require "../event"
require "../error"
require "../util/projections"
require "../document/projection_gucs"

module Facet
  module Doctype
    # Service for updating (versioning) an existing doctype definition.
    #
    # This is the entry point for schema evolution. The caller provides
    # the **full** new `DoctypeDefinition` — a PUT, not a PATCH.
    #
    # ## Validation rules
    #
    # 1. The doctype must already exist (not be deleted).
    # 2. `doctype` and `domain` must match the existing definition.
    # 3. `schema_version` must be either:
    #    - **Same as current** — non-breaking edit. `migrations` must be empty
    #      in the PUT body; the stored map is carried over (B-301), so the
    #      documents below the version keep their migration path.
    #    - **Exactly current + 1** — breaking change. Every version gap must
    #      have a corresponding entry in `migrations`, and the named function
    #      must exist in the script. Stored entries the PUT omits are kept.
    # 4. The script must compile and pass all existing `ScriptValidator` checks.
    #    A definition that declares `migrations` must also carry a `script` —
    #    a migration function runs only through the doctype's Lua script.
    module Update
      record Result,
        mutation_id : String,
        # True when the PUT body matched the stored definition. The service
        # wrote nothing — an idempotent re-save answers `200` with the
        # unchanged projection.
        unchanged : Bool = false

      # The `$force` flag, when passed at the root of the JSON body, allows
      # destructive same-version edits (field removals, type changes).
      # This is useful during development before documents exist.
      #
      # `doctype_id` is `"#{domain}.#{doctype}"` (e.g. `"production.WorkOrder"`).
      def self.call(
        db : DB::Connection,
        doctype_id : String,
        body : String,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        cause : Mutation::Cause? = nil,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "doctype.update" do |span|
          domain = doctype_id.split('.')[0]
          dtype = doctype_id.split('.')[1]
          span["domain"] = domain
          span["doc_type"] = dtype

          actioner_id = auth_context.account_id

          # 0. Authorize the doctype update
          unless RBAC::WriteEnforcer.authorize_update(db, "core", "DocType", doctype_id, auth_context)
            return Facet::ServiceError.new(403, "Forbidden")
          end

          # 1. Parse body and extract $force flag
          definition, force = parse_body(body)
          return definition if definition.is_a?(Facet::ServiceError)

          # 2. Fetch and parse the current doctype definition
          current_raw = DefinitionStore.fetch_raw(db, doctype_id)
          if current_raw.nil?
            return Facet::ServiceError.new(404, "Doctype '#{doctype_id}' not found")
          end
          current_content = current_raw[0]

          current_def = parse_current_definition(current_content)
          return current_def if current_def.is_a?(Facet::ServiceError)

          current_version = current_def.schema_version

          # 3–6. Draft-mode switch, version + same-version guards, identity
          # match, schema validation, and named-scope validation. On a live
          # domain the stored migration map is merged into the effective
          # definition (B-301) — the caller persists the returned form.
          validation_error, definition = validate_update(db, domain, doctype_id, current_def, definition, current_version, force)
          return validation_error if validation_error

          # 6.5. Duplicate scan for fields that gain `unique: true`. The
          #      managed unique index the flag produces cannot build over
          #      existing duplicates — reject the update with the values
          #      named, before any mutation is written. Draft domains skip
          #      the scan: publish copies structure only, so the definition
          #      meets fresh data on the live domain.
          unless draft_domain?(db, domain)
            unique_errors = UniquePrecheck.validate_added_unique(db, current_def, definition)
            unless unique_errors.empty?
              return Facet::ServiceError.new(422, "Doctype validation failed", details: unique_errors)
            end
          end

          # 7. Compute diff and persist
          diff = compute_diff(current_content, definition)

          # An idempotent re-save is a success, not a caller error: the
          # stored definition already matches the body, so the PUT answers
          # `200` with the unchanged projection. `mutation_id` is the row's
          # current `state` — the same ETag validator a write would return.
          if diff.empty?
            return Result.new(mutation_id: DefinitionStore.fetch_state(db, doctype_id) || "", unchanged: true)
          end

          mut_id = Database.with_transaction(db, ignore_if_set: true) do |txn|
            # Stage the projection GUCs the trigger reads (search corpus,
            # links, display_name) before the raw update — the trigger
            # overwrites the derived columns on every mutation, so an
            # unstaged GUC wipes a previously rendered corpus back to NULL
            # (B-78): an editor save then made the doctype unfindable on
            # `filters[search]`. The templates come from the stored
            # `core.DocType` definition — the doctype this row is written
            # under. The staged content is the post-diff definition; a
            # `core.DocType` self-edit renders one edit behind (the stored
            # templates are pre-diff), the same as every pipeline write —
            # `Doctype::Reproject` re-renders after a template change.
            core_doctype_defn = DefinitionStore.fetch(txn, "core.DocType")
            if core_doctype_defn
              Document::ProjectionGucs.set_all(txn, core_doctype_defn, JSON.parse(definition.to_json))
            else
              Document::ProjectionGucs.clear_all(txn)
            end

            Mutation::Client.update(
              txn, "core", "DocType", doctype_id,
              diff_json: diff.to_json, actioner_id: actioner_id,
              provenance: Mutation::Provenance.from(auth_context),
              cause: cause,
            )
          end

          # Invalidate cache so subsequent reads see the new definition
          DefinitionStore.invalidate(doctype_id)

          # Trigger index sync asynchronously — dropped/added fields are
          # reconciled in a background fiber.
          Index::Manager.sync(db, definition)

          Event::Publisher.enqueue(
            domain: "core", doc_type: "DocType",
            doc_id: doctype_id,
            event: "updated", mutation_id: mut_id,
            actioner_id: actioner_id,
          )

          # The replication registry is NOT eagerly refreshed here. The
          # enqueued `updated` event is delivered post-commit by the HTTP
          # layer's `Event::Publisher.flush`. The `Subscriber::DoctypeCache`
          # Pub/Sub subscriber receives it and marks the registry stale; the
          # next registry read rebuilds lazily from the DB.

          result = Result.new(mutation_id: mut_id)
          span["mutation_id"] = result.mutation_id
          result
        end
      end

      # ── Private helpers ────────────────────────────────────────

      # Steps 3–6: the write-guards for a live or draft domain, then the
      # effective definition the caller persists.
      #
      # Returns `{nil, effective}` when the update passes. On a live domain
      # the effective definition carries the stored migration map merged
      # under the incoming one (see `merge_stored_migrations`); on a draft
      # domain it is the incoming definition unchanged.
      #
      # When the target domain's `draft` flag is `true`, the doctype's
      # schema is freely mutable: version may decrease, skip ahead, or
      # carry destructive same-version edits (field removals, type
      # changes). The dirty history never escapes draft mode because
      # publish copies structure only and drops the draft's data.
      #
      # The draft lookup is `SELECT ... FOR UPDATE` on the core.Domain row,
      # taken inside this update's transaction (Doctype::Update.call is
      # always invoked within Database.with_transaction by callers).
      # This serialises against the publish path's write of the same row
      # and eliminates any TOCTOU between the draft check and the
      # subsequent overwrite.
      #
      # Cross-doctype resolution (replicate source/grant existence,
      # reference target existence) is NOT enforced at authoring time —
      # it would create ordering dependencies between domains and
      # prohibit legitimate forward references. One exception (B-287):
      # a cross-domain reference whose target domain is still a draft is
      # rejected below by `DraftTargetCheck` — publish never rewrites
      # cross-domain tokens, so a draft-qualified target could never
      # resolve after publish. The runtime path
      # already silently no-ops on broken configs (registry fail-closed,
      # SyncPull source-not-found). Use `Doctype::Check` (the
      # `/check` endpoint) to surface the remaining cases as diagnostics.
      # The hard replication invariants (via/replica-of-replica/secret
      # source) ARE enforced here, before persist — see
      # `Replication::Validator`.
      #
      # Named-scope validation, by contrast, is self-contained to this
      # doctype's own fields and this domain's context sets, so it can be
      # enforced here. In draft mode, the domain may not exist as a real
      # domain doc — `domain_context_sets` will be empty, which means
      # `$<context_set>` references in `where` clauses will be rejected.
      # Draft authors should use `$self` and literals only; full
      # context-set resolution is the responsibility of the live domain
      # the draft publishes to.
      private def self.validate_update(
        db : DB::Connection,
        domain : String,
        doctype_id : String,
        current_def : DoctypeDefinition,
        definition : DoctypeDefinition,
        current_version : Int32,
        force : Bool,
      ) : {Facet::ServiceError?, DoctypeDefinition}
        draft_mode = draft_domain?(db, domain)

        unless draft_mode
          # Live domain: enforce the normal version constraints, then carry
          # the stored migration map (B-301).
          error, definition = validate_live_version_gates(current_def, definition, current_version, force)
          return {error, definition} if error
        end

        # Validate doctype/domain identity matches
        unless definition.doctype == current_def.doctype && definition.domain == current_def.domain
          return {Facet::ServiceError.new(422, "doctype and domain cannot be changed"), definition}
        end

        # Run schema-level validation. The template gate (B-296) is a
        # creation gate — an existing doctype keeps its editable shape.
        errors = if draft_mode
                   Validation.validate_draft(definition)
                 else
                   Validation.validate(definition, current_version, creation: false)
                 end
        unless errors.empty?
          return {Facet::ServiceError.new(422, "Doctype validation failed", details: errors), definition}
        end

        # Draft-target gate (B-287): a cross-domain reference whose target
        # domain is still a draft is rejected on draft and live domains
        # alike — publish never rewrites cross-domain tokens.
        draft_errors = DraftTargetCheck.validate(db, definition)
        unless draft_errors.empty?
          return {Facet::ServiceError.new(422, "Cross-domain reference targets a draft domain", details: draft_errors), definition}
        end

        # Validate named scopes against the domain's context sets.
        unless draft_mode
          scope_errors = RBAC::Validator.validate_named_scopes_for(db, definition)
          return {Facet::ServiceError.new(422, "Named scope validation failed", details: scope_errors), definition} unless scope_errors.empty?
        end

        # Hard replication invariants — enforced at authoring time (422),
        # not left advisory. The advisory grant/existence diagnostics stay
        # on `/check` (the full `Validator.validate`). See
        # `Replication::Validator.validate_invariants`.
        rep_errors = Replication::Validator.validate_invariants(definition, db)
        unless rep_errors.empty?
          details = rep_errors.map { |e| ValidationError.new(message: e, code: "schema") }
          return {Facet::ServiceError.new(422, "Replication validation failed", details: details), definition}
        end

        {nil, definition}
      end

      # The live-domain version gates, in guard order: version monotonicity,
      # the same-version guards, then the migration-map carry (B-301). The
      # carry merges the stored map into the incoming definition — the guard
      # above forces a same-version PUT to omit `migrations`, so the diff
      # would otherwise strip the stored entries and strand every document
      # below the version. A `$force` edit stays verbatim — it is the
      # destructive dev-time escape hatch.
      private def self.validate_live_version_gates(
        current_def : DoctypeDefinition,
        definition : DoctypeDefinition,
        current_version : Int32,
        force : Bool,
      ) : {Facet::ServiceError?, DoctypeDefinition}
        version_error = validate_version(current_version, definition.schema_version)
        return {version_error, definition} if version_error

        is_breaking = definition.schema_version > current_version
        same_version_error = check_same_version_guards(current_def, definition, is_breaking, force)
        return {same_version_error, definition} if same_version_error

        definition = merge_stored_migrations(current_def, definition) unless force
        {nil, definition}
      end

      # Merges the stored migration map into the incoming definition
      # (B-301). Keys the incoming map declares win, so a version bump can
      # add its new gap entries; every stored entry the PUT omits survives.
      # A same-version PUT cannot declare keys (the guard above), so its
      # effective map is exactly the stored one.
      private def self.merge_stored_migrations(current_def : DoctypeDefinition, definition : DoctypeDefinition) : DoctypeDefinition
        return definition if current_def.migrations.empty?

        merged = current_def.migrations.dup
        definition.migrations.each { |key, func_name| merged[key] = func_name }
        definition.with_migrations(merged)
      end

      # Reads the `draft` flag from the source domain's `core.Domain`
      # projection row. Locks `FOR UPDATE` so this read serialises against
      # any concurrent publish transaction writing the same row. Treats a
      # missing row, missing field, or any non-`true` value as "not a draft"
      # (fail-closed — live domains take the strict path).
      private def self.draft_domain?(db : DB::Connection, domain : String) : Bool
        Util::Projections.draft_domain?(db, domain, lock: true)
      end

      private def self.validate_version(current_version : Int32, new_version : Int32) : Facet::ServiceError?
        violation = DefinitionGate.version_violations(current_version, new_version).first?
        violation ? Facet::ServiceError.new(422, violation) : nil
      end

      private def self.parse_body(body : String) : {DoctypeDefinition | Facet::ServiceError, Bool}
        raw_body = begin
          JSON.parse(body)
        rescue ex : JSON::ParseException
          return {Facet::ServiceError.new(422, "Invalid JSON body: #{ex.message}"), false}
        end

        # The body must be a JSON object. The `$force` probe below indexes
        # the parsed value, and a scalar or array body must answer `422` —
        # never the cast error a non-object probe raises (a `500`).
        raw_h = raw_body.as_h?
        unless raw_h
          return {Facet::ServiceError.new(422, "Invalid JSON body — the request body must be a JSON object"), false}
        end

        # `as_bool?` (not `as_bool`): a non-boolean flag means "not forced"
        # rather than an uncaught cast error — the guards stay on, which is
        # the safe direction.
        force = raw_h["$force"]?.try(&.as_bool?) || false

        # `$force` is a per-operation transport flag, not definition data.
        # Strip it before parsing so the parser's unknown-key rejection
        # (DoctypeDefinition.KNOWN_KEYS) does not fire on it — same stance
        # as the import path's `Import::Rewrite.strip_force`; the flag is
        # never stored.
        definition_body = raw_body
        if raw_h.has_key?("$force")
          stripped = raw_h.dup
          stripped.delete("$force")
          definition_body = JSON::Any.new(stripped)
        end

        definition = begin
          DoctypeDefinition.from_json(definition_body)
        rescue ex : JSON::ParseException
          return {Facet::ServiceError.new(422, "Invalid doctype definition: #{ex.message}"), false}
        end

        {definition, force}
      end

      private def self.parse_current_definition(content : JSON::Any) : DoctypeDefinition | Facet::ServiceError
        DoctypeDefinition.from_json(content)
      rescue ex : JSON::ParseException
        Facet::ServiceError.new(500, "Stored doctype definition is corrupt: #{ex.message}")
      end

      # Guard order (Doctype::Update and the portable import both keep it):
      # 1. same-version migrations guard (never bypassed),
      # 2. without $force: field-removal check,
      # 3. without $force: field-type-change check,
      # 4. without $force: the generic data-shape catch-all — every
      #    remaining non-additive `Doctype::Structure.data_shape_changes`
      #    entry (nested sub-schema edits, `collection` flips, constraints,
      #    enum key removal/reorder, reference surface, `children`,
      #    `member_of`). Additive changes stay legal: a new field key, a new
      #    enum key, a new nested property key, a new `children` entry.
      #
      # The rules live on `Doctype::DefinitionGate`; `DefinitionGate.render`
      # produces the message in guard order, and this method maps it to a
      # `ServiceError`.
      private def self.check_same_version_guards(current_def : DoctypeDefinition, definition : DoctypeDefinition, is_breaking : Bool, force : Bool) : Facet::ServiceError?
        violations = DefinitionGate.same_version_violations(current_def, definition, is_breaking, force)
        return nil if violations.nil?

        message = DefinitionGate.render(violations, DefinitionGate::Style::Update).first?
        return nil if message.nil?

        Facet::ServiceError.new(422, message)
      end

      private def self.compute_diff(current_content : JSON::Any, definition : DoctypeDefinition)
        new_content_json = definition.to_json
        old_content_json = current_content.to_json
        old_any = JSON.parse(old_content_json)
        new_any = JSON.parse(new_content_json)

        Mutation::JsonDiff.diff(old_any, new_any)
      end
    end
  end
end
