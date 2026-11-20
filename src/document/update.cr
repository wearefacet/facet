# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "../database"
require "../mutation/json_diff"
require "../mutation/client"
require "../doctype"
require "../doctype/doctype_definition"
require "./validation"
require "./coalesce"
require "./compute"
require "./script_context"
require "./strip_write_only"
require "./recompute"
require "../rbac"
require "../iam/helpers"
require "../event"
require "../error"
require "../replication/sync_pull"
require "../artifact/owners"
require "./normalize"
require "./search"
require "./links"
require "./reference_check"
require "./file_mime_check"
require "./money_currency_check"
require "./unique_constraint"
require "./view_template_gate"
require "../secrets/adoption"
require "../grants/validator"
require "../app/grants_validator"
require "../hooks/validator"
require "../system_settings/write_gate"

module Facet
  module Document
    # Service for partially updating a document via PATCH.
    #
    # The caller provides the updated document body (a partial or full
    # JSON object). The service merges it over the existing projection
    # content with JSON Merge Patch semantics (RFC 7386 — a `null` patch
    # value removes the key), computes a JsonDiff, and persists it as an
    # `update` mutation.
    module Update
      record Result,
        projection : Mutation::Client::Projection,
        mutation_id : String

      # Partially updates a document.
      #
      # Requires an `auth_context` for RBAC authorization.
      # Returns `Result` on success, `Error` on failure.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        body : String,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        reentrant : Bool = false,
        actioner_id : String? = nil,
        skip_authorization : Bool = false,
        currency_check_mode : MoneyCurrencyCheck::Mode = MoneyCurrencyCheck::Mode::Write,
        authorize_path : Array(String)? = nil,
        allow_computed_writes : Bool = false,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "document.update" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["doc_id"] = doc_id

          # Default to the auth context's account id; allow an explicit
          # override so a system-authorized mutation (e.g. a Lua `document.*`
          # call driven by a user action) can still be attributed to the
          # original caller in the audit log.
          actioner_id = actioner_id || auth_context.account_id

          # core.DocType: the definition is an ordinary projection row to
          # the patch pipeline, so the flat PATCH used to write it with
          # none of the authoring gates only `Doctype::Update` runs — the
          # version gate, the same-version destructive-edit guards, the
          # migration-map carry — and never triggered `Index::Manager.sync`
          # (B-371). Mirror the flat-create dispatch: merge the patch over
          # the stored definition (the same RFC 7386 merge the generic
          # pipeline applies) and run the merged form through
          # `Doctype::Update.call`, the service the flat PUT delegates to.
          # A same-schema_version change the PUT answers 422, the PATCH
          # answers 422 too.
          if {domain, doc_type} == {"core", "DocType"}
            result = update_doctype_definition(db, doc_id, body, auth_context, cause)
            record_update_span(span, result)
            return result
          end

          # 0. Authorize the update. `skip_authorization` is set by callers
          # that have ALREADY enforced an equivalent (or stronger) gate at a
          # higher layer — today only the nested per-document sidecar route,
          # which runs the host read gate plus the nested sidecar update grant.
          if err = authorize_update(db, domain, doc_type, doc_id, auth_context, skip_authorization, authorize_path)
            return Telemetry.record_error(span, err)
          end

          # 1-3. Fetch the definition, parse the patch, and validate it
          #      against the doctype definition (partial update).
          #
          #      Hydrate the currency registry first: the patch validation
          #      (`MoneyType#validate`) and the lifecycle check below read
          #      the in-process snapshot, which rebuilds here only after the
          #      Pub/Sub subscriber marked it stale.
          Currency::Registry.ensure_fresh(db)
          parsed = parse_and_validate_patch(db, span, domain, doc_type, body, reentrant, auth_context, allow_computed_writes)
          return Telemetry.record_error(span, parsed) if parsed.is_a?(Facet::ServiceError)
          defn, patch = parsed

          # 4. Fetch the current projection
          projection = Mutation::Client.fetch_projection_or_404(db, domain, doc_type, doc_id, "Document #{domain}.#{doc_type}##{doc_id} not found")
          if projection.is_a?(Facet::ServiceError)
            Telemetry.record_error(span, projection)
            return projection
          end
          projection = projection.as(Mutation::Client::Projection)

          # 5. Check if document is deleted
          return Telemetry.record_error(span, Facet::ServiceError.new(404, "Document #{doc_id} not found")) if projection.deleted_at

          # 6. Deep-merge the patch over the current content
          current = projection.content
          merged = deep_merge(current, patch)

          # 6a. Unique constraint check on the merged document. Only fields
          # whose value changed in this update are queried; the target
          # document's own row is excluded, so keeping an existing value is
          # always a no-op for this check. Runs after the merge so it sees
          # the exact state the mutation would land on.
          if unique_error = check_unique_constraints(db, domain, doc_type, projection.id, current, merged, defn)
            return Telemetry.record_error(span, unique_error)
          end

          # 6b. Currency lifecycle on the money paths this update touches.
          # The check runs on the merged document against the stored
          # content: a money path re-saved with the same ticker passes even
          # when the currency row went inactive ("stays up and running");
          # switching a path to a new ticker requires an active row.
          # Unknown tickers already fail as `schema` errors in
          # `MoneyType#validate` — the patch was validated before the merge,
          # so `validate_patch` holds neither the old content nor the
          # merged state; this seam holds both.
          currency_errors = MoneyCurrencyCheck.check_update(defn, merged, current, currency_check_mode)
          unless currency_errors.empty?
            err = Facet::ServiceError.new(422, "Document validation failed", details: currency_errors)
            return Telemetry.record_error(span, err)
          end

          # 6c. Authoring-time RBAC validation for role and domain documents.
          # Re-checks the merged content so malformed or unknown-scope-alias
          # permissions / context sets are rejected at PATCH time, not just at
          # create time. Grant documents run the same dispatch (self-grant,
          # resource shape, empty tags) against the producer parent.
          if rbac_error = validate_rbac_definitions?(db, span, domain, doc_type, merged, projection, patch)
            return rbac_error
          end

          # 6d–6e. Write-time semantic gates, one dispatch per doctype.
          # The definition owns shape and the Lua script owns the singleton
          # guards; these branches own every rule the definition cannot
          # express (the settings singleton's smtp-host cross-field rule,
          # the production dev-adapter gate with escape-hatch parity, the
          # IAM policy enums, the `oidc_only` needs-a-provider rule, and
          # the account email immutability). Bad values answer 422 at save
          # time. One combined call keeps the complexity of `call` flat —
          # each new gate joins the dispatch instead of the flow.
          if gate_error = validate_semantic_gates?(db, span, domain, doc_type, current, merged)
            return gate_error
          end

          # 6f. Role-authority boundary for the IAM doctypes. Runs on the
          # merged content against the stored content, after normalization
          # and structural validation, and before the lifecycle hook. The
          # guard is independent of route-level `skip_authorization` — only
          # the System principal bypasses it.
          if auth_error = RBAC::RoleAuthority.authorize_transition(db, "update", domain, doc_type, current, merged, auth_context)
            return Telemetry.record_error(span, auth_error)
          end

          # 7. Run the Lua update lifecycle hook (validate and/or mutate)
          #    and re-run computed fields after mutation. The hook may write
          #    unique fields, so the constraint check is deliberately not
          #    repeated after it: the hook is trusted system code, and the
          #    merged state below is what the mutation lands on.
          #
          #    The mutation ULID is minted first so the hook's Lua
          #    `document.*` writes can stamp it as their `cause.parent`.
          mut_id = Util::ScriptHelpers.ulid
          merged, pending = run_script_update(span, db, defn, merged, current, actioner_id, domain, doc_type, doc_id, patch, cause: cause.try(&.child_of(mut_id)), provenance: provenance, auth_context: auth_context, authorize_path: authorize_path) do |err_merged|
            return err_merged
          end

          result = finalize_and_persist(span, db, defn, domain, doc_type, doc_id, actioner_id, auth_context, cause, provenance, mut_id, reentrant, current, merged, projection)

          # Drain the update hook's notification queue now that the
          # operation succeeded (a no-op update included — the hook ran
          # and may have sent). `doc_ref = nil` entries resolve to the
          # updated document.
          Notification::Queue.drain(db, pending, domain, doc_type, doc_id)

          result
        end
      end

      # Records a finished update on the span — the mutation id on success,
      # the error on a refusal. Shared by the generic flow and the
      # core.DocType dispatch.
      private def self.record_update_span(
        span,
        result : Result | Facet::ServiceError,
      ) : Nil
        case result
        in Result
          span["mutation_id"] = result.mutation_id
        in Facet::ServiceError
          Telemetry.record_error(span, result)
        end
      end

      # core.DocType PATCH dispatch (B-371): merges the patch over the
      # stored definition and runs the merged full definition through
      # `Doctype::Update.call`. The row-level 404/410 answers match the
      # generic pipeline's; the definition gates are the PUT's.
      private def self.update_doctype_definition(
        db : DB::Connection,
        doctype_id : String,
        body : String,
        auth_context : RBAC::AuthContext,
        cause : Mutation::Cause?,
      ) : Result | Facet::ServiceError
        projection = Mutation::Client.fetch_projection_or_404(db, "core", "DocType", doctype_id, "Document core.DocType##{doctype_id} not found")
        return projection if projection.is_a?(Facet::ServiceError)
        proj = projection.as(Mutation::Client::Projection)
        return Facet::ServiceError.new(404, "Document #{doctype_id} not found") if proj.deleted_at

        patch = parse_body(body)
        return patch if patch.is_a?(Facet::ServiceError)

        merged = deep_merge(proj.content, patch)
        inner = Doctype::Update.call(db, doctype_id, merged.to_json, auth_context, cause: cause)
        case inner
        in Doctype::Update::Result
          updated = Mutation::Client.fetch_projection_or_404(db, "core", "DocType", doctype_id, "Document core.DocType##{doctype_id} not found")
          return updated if updated.is_a?(Facet::ServiceError)
          Result.new(projection: updated.as(Mutation::Client::Projection), mutation_id: inner.mutation_id)
        in Facet::ServiceError
          inner
        end
      end

      # Finalizes the merged document (strip write-only fields, re-pull
      # replica `via` values, adopt secret handles / verify markers),
      # computes the diff against the current content, and persists the
      # mutation.
      #
      # Returns the new `Result`; when the update is a no-op (empty diff),
      # returns the existing projection without a new mutation. Returns a
      # `ServiceError` when secret adoption rejects the document.
      private def self.finalize_and_persist(
        span,
        db : DB::Connection,
        defn : Doctype::DoctypeDefinition,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        auth_context : RBAC::AuthContext,
        cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        mutation_id : String,
        reentrant : Bool,
        current : JSON::Any,
        merged : JSON::Any,
        projection : Mutation::Client::Projection,
      ) : Result | Facet::ServiceError
        # Strip write_only fields before computing the diff so they don't
        # appear as changes (they are never user-writable).
        merged = StripWriteOnly.call(merged, defn)

        # Pull replica field values from source documents when the `via`
        # reference field changed during this update. Only the changed `via`
        # fields are re-pulled; the result is merged into `merged` before the
        # diff is computed so the replica update is part of the same mutation.
        changed_via_fields = compute_changed_via_fields(defn, current, merged)
        unless changed_via_fields.empty?
          merged = Replication::SyncPull.call(db, defn, merged, changed_via_fields: changed_via_fields)
        end

        # Secret adoption runs inside a transaction so the slot upserts and
        # staging deletes stay atomic with the mutation on the HTTP paths
        # (an ambient transaction is already open there). Direct (non-HTTP)
        # callers get an isolated adoption — a crash between adoption and
        # the mutation leaves an orphan slot that the prune sweep removes
        # (fail closed). Failure rolls back and surfaces as a ServiceError.
        begin
          merged = Database.with_transaction(db, ignore_if_set: true) do |txn|
            Secrets::Adoption.call(txn, defn, merged, domain, doc_type, doc_id, actioner_id, previous: current)
          end
        rescue e : Secrets::Adoption::AdoptionError
          return Telemetry.record_error(span, e.error)
        end

        diff = Mutation::JsonDiff.diff(current, merged)
        if diff.empty?
          span["mutation_id"] = projection.state
          return Result.new(projection: projection, mutation_id: projection.state)
        end

        result = persist_update(span, db, defn, domain, doc_type, doc_id, actioner_id, auth_context, cause, provenance, mutation_id, reentrant, merged, diff, current)

        # Parent recompute: this update mutated a composition child. Runs
        # inside the caller's transaction; a recompute-caused driving write
        # (the loop guard) skips the walk.
        if recompute_error = Recompute.after_child_mutation(db, domain, doc_type, doc_id, result.mutation_id,
             (cause || Mutation::Cause.root(Mutation::CauseKind::Request)).resolve(result.mutation_id),
             provenance, actioner_id)
          return recompute_error
        end

        result
      end

      # Persists an `update` mutation. The persist step and the write-time
      # coalescing decision live in `Document::Coalesce`; this method is the
      # seam between the update pipeline and that module.
      private def self.persist_update(
        span,
        db : DB::Connection,
        defn : Doctype::DoctypeDefinition,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        auth_context : RBAC::AuthContext,
        cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        mutation_id : String,
        reentrant : Bool,
        merged : JSON::Any,
        diff : Mutation::JsonDiff::Result,
        current : JSON::Any,
      ) : Result
        Coalesce.call(span, db, defn, domain, doc_type, doc_id, actioner_id, auth_context, cause, provenance, mutation_id, reentrant, merged, diff, current)
      end

      # ── Private helpers ──────────────────────────────────────

      # Step-0 update gate. Returns `nil` when the caller is authorized, or
      # the denial error otherwise: a class-level denial — no update
      # permission on the doctype at all — answers `403`; a scoped caller
      # whose row check fails answers `404`, so an inaccessible document
      # is indistinguishable from a missing one. `skip_authorization`
      # bypasses the enforcer for callers that already enforced a stronger
      # gate. `authorize_path` overrides the gate path — the composition
      # path on nested child routes, the bare path on flat routes.
      private def self.authorize_update(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : RBAC::AuthContext,
        skip_authorization : Bool,
        authorize_path : Array(String)? = nil,
      ) : Facet::ServiceError?
        return nil if skip_authorization

        # Class-level denial first — no row state is read for a caller the
        # gate denies outright.
        if RBAC::WriteEnforcer.action_denied?("update", domain, doc_type, auth_context, authorize_path)
          IAM::Helpers.write_layer1_denial(db, auth_context, "update", domain, authorize_path || [doc_type])
          return Facet::ServiceError.new(403, "Forbidden")
        end

        return nil if RBAC::WriteEnforcer.authorize_update(db, domain, doc_type, doc_id, auth_context, authorize_path)

        IAM::Helpers.write_layer1_denial(db, auth_context, "update", domain, authorize_path || [doc_type])
        Facet::ServiceError.new(404, "Document #{doc_id} not found")
      end

      # Steps 1-3 of the update pipeline: fetch the doctype definition, parse
      # the patch, and validate it against the definition (partial update).
      # The field-write guard runs on the raw caller body before any format
      # validation, so format errors never disclose a field the role cannot
      # see (B-325). Returns `{definition, normalized_patch}` on success.
      #
      # When this is a reentrant (system-driven replication) write, the
      # validation additionally allows writes to read-only replicated fields
      # — the replica field is the target of the write itself. When this is
      # a recompute write, the validation additionally allows computed
      # (`data`) fields — the compute pipeline owns their values, and
      # `DataType#validate` exists to refuse user input only.
      private def self.parse_and_validate_patch(
        db : DB::Connection,
        span,
        domain : String,
        doc_type : String,
        body : String,
        reentrant : Bool,
        auth_context : RBAC::AuthContext,
        allow_computed_writes : Bool = false,
      ) : {Doctype::DoctypeDefinition, JSON::Any} | Facet::ServiceError
        # 1. Fetch the doctype definition
        doctype_id = "#{domain}.#{doc_type}"
        defn = Doctype::DefinitionStore.fetch!(db, doctype_id)
        return defn if defn.is_a?(Facet::ServiceError)

        # 2. Parse the request body
        patch = parse_body(body)
        return patch if patch.is_a?(Facet::ServiceError)

        # 2a. Field-write guard: refuse caller-submitted writes into
        # invisible fields (an explicit `null` included) BEFORE any format
        # validation, so a caller whose role cannot see a field never learns
        # the field's type contract from a 422 (B-325). Trusted lifecycle
        # work (hooks, replication, computed fields) is not a caller write
        # and stays outside this guard — those callers run under the system
        # context, which the guard bypasses.
        if field_error = RBAC::WriteEnforcer.authorize_field_writes(defn, patch, auth_context)
          return field_error
        end

        # 2b. State-machine guard: reject any patch that touches the `draft`
        # field on a core.Domain document. See `reject_draft_patch?` for the
        # rationale.
        if reject_draft_patch?(span, domain, doc_type, patch)
          return Facet::ServiceError.new(422, "The 'draft' field cannot be modified via document update")
        end

        # 3a. Normalize canonical formats (e.g. \r\n → \n in longtext)
        # before validation, so subsequent diffing sees only `\n`.
        patch = Document::Normalize.call(patch, defn)
        if validation_error = validate_patch(db, patch, defn, reentrant, auth_context, allow_computed_writes)
          return validation_error
        end

        {defn, patch}
      end

      # Parses the request body as JSON. Returns the parsed patch, or a
      # `ServiceError` (422) when the body is not valid JSON.
      private def self.parse_body(body : String) : JSON::Any | Facet::ServiceError
        JSON.parse(body)
      rescue ex : JSON::ParseException
        Facet::ServiceError.new(422, "Invalid JSON body: #{ex.message}")
      end

      # Validates the patch against the doctype definition and checks
      # reference field filters. Returns a `ServiceError` (422) when either
      # step fails, or `nil` when the patch is structurally sound.
      #
      # The reference check runs under `auth_context`, so a referenced target
      # the caller cannot read is refused like a missing one (B-356).
      #
      # `allow_computed_writes` (the parent-recompute write) validates the
      # patch without its computed entries: `DataType#validate` refuses any
      # user-provided value, and the compute pipeline owns these values —
      # they never pass through type validation on the create path either.
      # They ride the merge unchanged.
      private def self.validate_patch(
        db : DB::Connection,
        patch : JSON::Any,
        defn : Doctype::DoctypeDefinition,
        reentrant : Bool,
        auth_context : RBAC::AuthContext,
        allow_computed_writes : Bool = false,
      ) : Facet::ServiceError?
        validated_patch = if allow_computed_writes && (patch_h = patch.as_h?)
                            JSON::Any.new(patch_h.reject { |name, _| defn.fields[name]?.try(&.computed?) })
                          else
                            patch
                          end
        errors = Document::Validation.validate_update(
          validated_patch, defn,
          allow_system_writes: reentrant,
        )
        unless errors.empty?
          return Facet::ServiceError.new(422, "Document validation failed", details: errors)
        end

        # Only the fields being changed in this patch are checked — existing
        # reference values that are not touched remain valid.
        ref_errors = ReferenceCheck.check(db, defn, patch, auth_context)
        mime_errors = FileMimeCheck.check(db, defn, patch)
        all_errors = ref_errors + mime_errors
        return nil if all_errors.empty?

        Facet::ServiceError.new(422, "Document validation failed", details: all_errors)
      end

      # Authoring-time RBAC validation for role and domain documents.
      # Dispatches to the appropriate validator based on the doctype:
      # - `iam.Roles`: validates the merged permissions array against the
      #   doctype-definition scope catalogue.
      # - `core.Domain`: validates the merged context_sets field names against
      #   SQL-safe identifier rules (free-form JSONB, injection vector), and
      #   validates any declared domain hooks via `Hooks::Validator`
      #   (script compile, required export, cron expression shape). Hook
      #   validation runs on drafts too so misconfigurations surface at
      #   publish, not at first fire.
      # - `core.CollectionView`: validates the calendar title template
      #   against the parent doctype when the patch touches `config` — a
      #   patch that only renames the view must not be blocked by a
      #   template that went stale after a parent-doctype field removal
      #   (the client renderer tolerates unknown fields, rendering them
      #   empty).
      # Returns an `Error` to surface, or `nil` if validation passes (or the
      # document is not an RBAC-relevant doctype).
      private def self.validate_rbac_definitions?(
        db : DB::Connection,
        span,
        domain : String,
        doc_type : String,
        merged : JSON::Any,
        projection : Mutation::Client::Projection? = nil,
        patch : JSON::Any? = nil,
      ) : Facet::ServiceError?
        if {domain, doc_type} == {"iam", "Roles"}
          return validate_role_permissions?(db, span, merged)
        end

        if {domain, doc_type} == {"core", "Domain"}
          return validate_domain_context_sets?(span, domain, merged) ||
            validate_domain_hooks?(span, merged)
        end

        if {domain, doc_type} == {"core", "DomainGrant"} && projection
          parent_id = projection.meta.as_h?.try(&.["parent_id"]?).try(&.as_s?)
          parent_domain = parent_id.try { |p| p.starts_with?("core.Domain.") ? p["core.Domain.".size..] : p }
          if parent_domain
            consumer = merged["consumer_domain"]?.try(&.as_s?)
            errors = [] of ValidationError
            Grants::Validator.validate(parent_domain, consumer, merged["resources"]?, errors)
            return rbac_failure(span, "Grant validation failed", errors) unless errors.empty?
          end
        end

        # Authoring-time grant validation for `app.App` documents — the
        # merged state must parse grant-by-grant and name concrete targets
        # only (see `App::GrantsAuthoring`). The merge keeps untouched
        # grants, so every app update re-validates the full array.
        if {domain, doc_type} == {"app", "App"}
          app_grant_errors = App::GrantsAuthoring.validate(merged["grants"]?)
          return rbac_failure(span, "Grant validation failed", app_grant_errors) unless app_grant_errors.empty?
        end

        # Authoring-time validation for the view children of `core.DocType`
        # — the CollectionView calendar title and the DocumentView template
        # tree. Both re-check the merged content against the parent doctype
        # definition; see `validate_view_child_definitions?`.
        if view_error = validate_view_child_definitions?(db, span, domain, doc_type, merged, projection, patch)
          return view_error
        end

        nil
      end

      # Authoring-time validation for the view children of `core.DocType`.
      # Dispatches on the doctype:
      # - `core.CollectionView`: the calendar title template — runs only
      #   when the patch touches `config`, so a rename of a view whose
      #   template went stale after a parent-doctype field removal still
      #   passes (the client renderer tolerates unknown fields, rendering
      #   them empty).
      # - `core.DocumentView`: the template tree — same touch-scoping on
      #   `template`; see `validate_document_view_template?`.
      private def self.validate_view_child_definitions?(
        db : DB::Connection,
        span,
        domain : String,
        doc_type : String,
        merged : JSON::Any,
        projection : Mutation::Client::Projection?,
        patch : JSON::Any?,
      ) : Facet::ServiceError?
        if {domain, doc_type} == {"core", "CollectionView"}
          return validate_collection_view_config?(db, span, merged, projection, patch)
        end

        if {domain, doc_type} == {"core", "DocumentView"}
          return validate_document_view_template?(db, span, merged, projection, patch)
        end

        nil
      end

      # Write-time semantic gate for `core.CollectionView` — same shape as
      # `validate_system_settings?`. Runs only when the patch touches the
      # `config` field, so a rename of a view whose template went stale
      # after a parent-doctype change still passes.
      private def self.validate_collection_view_config?(
        db : DB::Connection,
        span,
        merged : JSON::Any,
        projection : Mutation::Client::Projection?,
        patch : JSON::Any?,
      ) : Facet::ServiceError?
        config_touched = patch.try(&.as_h?).try(&.has_key?("config")) || false
        return nil unless config_touched

        parent_id = projection.try(&.meta.as_h?).try(&.["parent_id"]?).try(&.as_s?)
        errors = collection_view_title_template_errors(db, parent_id, merged)
        return nil if errors.empty?

        rbac_failure(span, "Collection view validation failed", errors)
      end

      # Write-time semantic gate for `core.DocumentView` — same shape as
      # `validate_collection_view_config?`. Runs only when the patch touches
      # the `template` field, so a rename of a view whose template went stale
      # after a parent-doctype field removal still passes (the client
      # renderer tolerates unknown bindings, rendering them empty). The
      # `:error` issues answer 422; warnings stay report-only (see
      # `Document::ViewTemplateGate`).
      private def self.validate_document_view_template?(
        db : DB::Connection,
        span,
        merged : JSON::Any,
        projection : Mutation::Client::Projection?,
        patch : JSON::Any?,
      ) : Facet::ServiceError?
        template_touched = patch.try(&.as_h?).try(&.has_key?("template")) || false
        return nil unless template_touched

        parent_id = projection.try(&.meta.as_h?).try(&.["parent_id"]?).try(&.as_s?)
        errors = ViewTemplateGate.errors(db, parent_id, merged)
        return nil if errors.empty?

        rbac_failure(span, "Document view validation failed", errors)
      end

      # Extracts the calendar title template from a `core.CollectionView`
      # document and validates it against the parent doctype's definition.
      # Returns an empty array when there is nothing to check (no calendar
      # config or no template) or when the parent definition cannot be
      # resolved. Shared by the create and update dispatches.
      private def self.collection_view_title_template_errors(
        db : DB::Connection,
        parent_id : String?,
        document : JSON::Any,
      ) : Array(ValidationError)
        return [] of ValidationError unless parent_id

        template = document.dig?("config", "calendar", "title_template").try(&.as_s?)
        return [] of ValidationError unless template

        case defn = Doctype::DefinitionStore.fetch!(db, parent_id)
        when Doctype::DoctypeDefinition
          Doctype::CollectionView::TitleTemplate.validate(template, defn)
        else
          [] of ValidationError
        end
      end

      # Write-time semantic gate for `core.SystemSettings`. Returns an
      # `Error` to surface, or `nil` when the document is not the settings
      # singleton or the merged state passes. Mirrors the
      # `validate_rbac_definitions?` dispatch (step 6c). `db` serves the
      # gate's save-time queries (the `oidc_only` provider check).
      private def self.validate_system_settings?(
        db : DB::Connection,
        span,
        domain : String,
        doc_type : String,
        merged : JSON::Any,
      ) : Facet::ServiceError?
        return nil unless {domain, doc_type} == {"core", "SystemSettings"}

        errors = Facet::SystemSettings::WriteGate.validate(merged, db)
        return nil if errors.empty?

        rbac_failure(span, "System settings validation failed", errors)
      end

      # The 6d–6e dispatch: every doctype-keyed semantic gate of the update
      # path, in one call site. `call` stays flat; a new gate joins here.
      private def self.validate_semantic_gates?(
        db : DB::Connection,
        span,
        domain : String,
        doc_type : String,
        current : JSON::Any,
        merged : JSON::Any,
      ) : Facet::ServiceError?
        if settings_error = validate_system_settings?(db, span, domain, doc_type, merged)
          return settings_error
        end

        validate_account_email_immutable?(span, domain, doc_type, current, merged)
      end

      # Write-time semantic gate for `iam.Account` email immutability.
      # The account's document id is its email address — a content change
      # would desynchronize the identity from the mutation log, the
      # references, and the secret slots bound to the original id. A
      # case-only rewrite passes: the create hook lowercases the stored
      # email, so the forms differ only on legacy rows, and the merged
      # state equals the identity either way.
      private def self.validate_account_email_immutable?(
        span,
        domain : String,
        doc_type : String,
        current : JSON::Any,
        merged : JSON::Any,
      ) : Facet::ServiceError?
        return nil unless {domain, doc_type} == {"iam", "Account"}

        old_email = current["email"]?.try(&.as_s?)
        new_email = merged["email"]?.try(&.as_s?)
        return nil if old_email.nil? || new_email.nil?
        return nil if new_email.downcase == old_email.downcase

        err = Facet::ServiceError.new(
          422,
          "email is immutable — the account id is the email address; " \
          "create a new account for a different address",
          details: [ValidationError.new(
            field: "email",
            message: "is immutable and cannot be changed after creation",
            code: "immutable",
            params: {"value" => new_email},
          )],
        )
        Telemetry.record_error(span, err)
        err
      end

      # Composes the shared `ServiceError` + span plumbing of the RBAC
      # validators: builds the 422 error with structured details, records
      # it on the span, and attaches the joined error messages.
      private def self.rbac_failure(
        span,
        message : String,
        errors : Array(ValidationError),
      ) : Facet::ServiceError
        err = Facet::ServiceError.new(422, message, details: errors)
        Telemetry.record_error(span, err)
        span["error.details"] = errors.map(&.message).join("; ")
        err
      end

      # Validates the permissions array on `iam.Roles` documents against the
      # doctype-definition scope catalogue. Returns an `Error` to surface,
      # or `nil` if validation passes.
      private def self.validate_role_permissions?(
        db : DB::Connection,
        span,
        merged : JSON::Any,
      ) : Facet::ServiceError?
        perms_raw = merged["permissions"]?.try(&.as_a) || [] of JSON::Any
        errors = RBAC::Validator.validate_permissions_for(perms_raw, db)
        return nil if errors.empty?

        rbac_failure(span, "RBAC permission validation failed", errors)
      end

      # Validates the context sets on a `core.Domain` document against the
      # SQL-safe identifier rules. Returns an `Error` to surface, or `nil` if
      # validation passes.
      private def self.validate_domain_context_sets?(
        span,
        domain : String,
        merged : JSON::Any,
      ) : Facet::ServiceError?
        parsed_sets = RBAC::ContextResolver.extract_context_sets(merged)
        errors = [] of ValidationError
        RBAC::Validator.validate_context_set_definitions(merged, domain, parsed_sets, errors)
        return nil if errors.empty?

        rbac_failure(span, "RBAC context set validation failed", errors)
      end

      # Validates any declared hooks on a `core.Domain` document via
      # `Hooks::Validator` — script compile + required export + cron
      # expression shape. Returns an `Error` to surface, or `nil` when the
      # domain declares no hooks or all hooks are valid. Runs on drafts too
      # so misconfigurations surface at publish, not at first fire.
      # See `doc/backend/hooks.md`.
      private def self.validate_domain_hooks?(
        span,
        merged : JSON::Any,
      ) : Facet::ServiceError?
        hooks, parse_errors = Facet::Hooks::Definition.parse(merged)
        errors = parse_errors + Facet::Hooks::Validator.validate(hooks)
        return nil if errors.empty?

        rbac_failure(span, "Domain hooks validation failed", errors)
      end

      # Runs the Lua `update` lifecycle hook (validate and/or mutate) and
      # re-evaluates computed fields that depend on the changed keys. No-op
      # when the doctype has no script.
      #
      # Yields an `Error` to the caller's block when the script or compute
      # step raises a validation failure, so the caller can short-circuit
      # out of the main `call` flow. Returns the (potentially mutated)
      # `merged` document plus the update hook's pending notification
      # queue otherwise.
      private def self.run_script_update(
        span,
        db : DB::Connection,
        defn : Doctype::DoctypeDefinition,
        merged : JSON::Any,
        current : JSON::Any,
        actioner_id : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        patch : JSON::Any,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        auth_context : RBAC::AuthContext? = nil,
        authorize_path : Array(String)? = nil,
        &
      )
        script = defn.script
        return {merged, [] of Notification::Pending} if script.nil?

        pending = [] of Notification::Pending
        script_errors = [] of ValidationError
        update_ctx = nil
        begin
          ScriptContext::Update.new(script, merged, actioner_id, db: db, domain: domain, doc_type: doc_type, doc_id: doc_id, cause: cause, provenance: provenance, auth_context: auth_context, patch: patch, rbac_doctype_path: authorize_path) do |ctx|
            update_ctx = ctx
            script_errors = ctx.run
            merged = ctx.root_document
            pending = ctx.notification_queue
          end
        rescue ex : ScriptContext::Error
          # A `document.*` helper refused a nested write: surface the
          # recorded ServiceError with its native status (B-30). A script
          # bug with no recorded refusal becomes a 422 carrying the Lua
          # error message (B-131).
          se = ScriptContext.refusal_or_script_error(update_ctx, ex)
          Telemetry.record_error(span, se)
          span["error.details"] = se.message
          yield se
          return {merged, pending}
        end
        unless script_errors.empty?
          err = Facet::ServiceError.new(422, "Script validation failed", details: script_errors)
          Telemetry.record_error(span, err)
          span["error.details"] = script_errors.map(&.message).join("; ")
          yield err
          return {merged, pending}
        end

        changed_fields = Mutation::JsonDiff.changed_fields(current, merged)
        unless changed_fields.empty?
          merged, compute_errors = Document::Compute.call(
            script,
            defn,
            merged,
            changed_fields: changed_fields,
            actioner_id: actioner_id,
            db: db,
            domain: domain,
            cause: cause,
            provenance: provenance,
            children: Document::Compute.stage_children(db, domain, defn, doc_id, changed_fields),
            doc_id: doc_id,
          )
          unless compute_errors.empty?
            err = Facet::ServiceError.new(422, "Computed fields failed", details: compute_errors)
            Telemetry.record_error(span, err)
            span["error.details"] = compute_errors.map(&.message).join("; ")
            yield err
            return {merged, pending}
          end
        end
        {merged, pending}
      end

      # Deep-merges `patch` over `base` with JSON Merge Patch semantics
      # (RFC 7386): a `null` value in the patch REMOVES the key from the
      # merged document. Nested objects merge recursively (with the same
      # null-removal rule); arrays and primitives from the patch replace
      # base values outright.
      #
      # A removed key produces an `unset` entry in the JsonDiff (the key
      # disappears from the stored content), so a patch of `{"field": null}`
      # is the one way — and the standard way — to clear a field. A patch
      # nulling a required field never reaches the merge: patch validation
      # rejects it first (`required`).
      private def self.deep_merge(base : JSON::Any, patch : JSON::Any) : JSON::Any
        base_h = base.as_h?
        patch_h = patch.as_h?

        # If either is not an object, patch wins
        return patch if base_h.nil? || patch_h.nil?

        merged = base_h.dup
        patch_h.each do |key, value|
          # RFC 7386: a null patch value removes the member
          if value.raw.nil?
            merged.delete(key)
          elsif (existing = merged[key]?) && value.as_h?
            # Recursive merge for nested objects
            merged[key] = deep_merge(existing, value)
          else
            merged[key] = value
          end
        end

        JSON::Any.new(merged)
      end

      # State-machine guard for draft domains.
      #
      # `draft` is set once at create time and is the source of truth for
      # every isolation and capability decision in the draft-domains
      # machinery (free schema mutation, replication exclusion, scratch
      # drop). Allowing it to be flipped via a normal document update would
      # let a live domain be turned into a draft (and thus become eligible
      # for the destructive `Doctype::Update` overwrite path), or a draft be
      # silently promoted without going through publish. The only
      # legitimate transition (draft → published) happens via
      # `Domain::Publish`, which copies structure to a new domain and
      # drops the draft — it never flips the flag in place.
      #
      # Returns true (and marks the span errored) when the patch must be
      # rejected; false otherwise.
      private def self.reject_draft_patch?(
        span,
        domain : String,
        doc_type : String,
        patch : JSON::Any,
      ) : Bool
        return false unless domain == "core" && doc_type == "Domain"
        return false unless patch.as_h?.try(&.has_key?("draft"))

        Telemetry.record_error(span, "Cannot modify 'draft' field via document update", status: 422)
        true
      end

      # Checks unique constraints for fields marked `unique: true` on the
      # merged document. Only fields whose value changed in this update are
      # checked — a document whose unique field is untouched must not be
      # blocked by its own row. The target document's own row is excluded
      # from the collision query.
      #
      # Returns a `ServiceError` (422) on collision, or `nil` when the
      # update preserves uniqueness.
      private def self.check_unique_constraints(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        current : JSON::Any,
        merged : JSON::Any,
        definition : Doctype::DoctypeDefinition,
      ) : Facet::ServiceError?
        changed = Mutation::JsonDiff.changed_fields(current, merged)
        return nil if changed.empty?

        changed_document = JSON::Any.new(
          merged.as_h.select { |key, _| changed.includes?(key) }
        )

        errors = UniqueConstraint.check(db, domain, doc_type, changed_document, definition, exclude_id: doc_id)
        return nil if errors.empty?

        Facet::ServiceError.new(422, "Document validation failed", details: errors)
      end

      # Returns the set of `via` reference field names that changed in this
      # update and that back a replicate field. Used by the SyncPull hook to
      # decide which replica values must be re-pulled from source documents.
      private def self.compute_changed_via_fields(
        definition : Doctype::DoctypeDefinition,
        original : JSON::Any,
        updated : JSON::Any,
      ) : Set(String)
        changed = Mutation::JsonDiff.changed_fields(original, updated)

        via_fields = Set(String).new
        definition.fields.each_value do |field_def|
          if (rep = field_def.replicate) && changed.includes?(rep.via)
            via_fields << rep.via
          end
        end
        via_fields
      end
    end
  end
end
