# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "pg"
require "../database"
require "../doctype/doctype_definition"
require "./validation"
require "../doctype/create"
require "../mutation/client"
require "../iam/helpers"
require "./script_context"
require "./strip_write_only"
require "./sequence_id"
require "./apply_defaults"
require "./recompute"
require "../util/script_helpers"
require "../util/projections"
require "../util/sequence"
require "../currency"
require "./normalize"
require "./search"
require "./links"
require "./reference_check"
require "./file_mime_check"
require "./money_currency_check"
require "./unique_constraint"
require "./view_template_gate"
require "./collection_view_gate"
require "../grants/validator"
require "../app/grants_validator"
require "../rbac"
require "../event"
require "../error"
require "../replication/sync_pull"
require "../artifact/owners"
require "../secrets/adoption"
require "../domain/editors"

module Facet
  module Document
    # Service for creating a new document of a given doctype.
    #
    # Handles two scenarios:
    #
    # 1. **DocType registration** (`core.DocType`) — validates the body as a
    #    `DoctypeDefinition` via `Doctype::Validation`, then persists
    #    it as a mutation. Delegates to `Doctype::Create`.
    #
    # 2. **General document creation** — looks up the doctype definition from
    #    `core.DocType` projections, validates via `Document::Validation`,
    #    then persists.
    #
    # Returns a `Mutation::Client::Projection` on success.
    module Create
      # Unified result type.
      record Result,
        projection : Mutation::Client::Projection,
        mutation_id : String

      # Result of the create lifecycle: the finalized document plus the
      # notification queue the create hook enqueued. The queue is drained
      # by `create_from_parsed` after the mutation persists, so a
      # notification is never applied for a create that failed.
      record LifecycleOutcome,
        document : JSON::Any,
        pending : Array(Notification::Pending)

      # Creates a document of the given domain/doctype.
      #
      # Requires an `auth_context` for RBAC authorization.
      # `meta_overrides` allows extra meta fields to be injected (e.g. parent_id for children).
      # Returns `Result` on success, `Error` on failure.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        body : String,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        meta_overrides : Hash(String, JSON::Any)? = nil,
        doc_id : String? = nil,
        allow_system_writes : Bool = false,
        skip_authorization : Bool = false,
        cause : Mutation::Cause? = nil,
        authorize_path : Array(String)? = nil,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "document.create" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          actioner_id = auth_context.account_id

          result = case {domain, doc_type}
                   when {"core", "DocType"}
                     # Delegate to Doctype::Create for core.DocType registration
                     # and wrap the result into our own return type.
                     inner = Doctype::Create.call(db, domain, doc_type, body, auth_context)
                     case inner
                     in Doctype::Create::Result
                       Result.new(projection: inner.projection, mutation_id: inner.mutation_id)
                     in Facet::ServiceError
                       Facet::ServiceError.new(status: inner.status, message: inner.message, details: inner.details)
                     end
                   when {"core", "Domain"}
                     # RBAC gate: the generic domain-create path used to skip
                     # the enforcer entirely — any authenticated principal
                     # could mint a live domain. Mirror `create_from_parsed`:
                     # authorize before anything else (skipped for callers
                     # that already enforced an equivalent gate upstream).
                     unless skip_authorization || RBAC::WriteEnforcer.authorize_create(db, "core", "Domain", auth_context)
                       IAM::Helpers.write_layer1_denial(db, auth_context, "create", "core", ["Domain"])
                       return Facet::ServiceError.new(403, "Forbidden")
                     end
                     domain_name = domain_create_name(body)
                     return domain_name if domain_name.is_a?(Facet::ServiceError)
                     create_domain_instance(db, domain_name, body, actioner_id, provenance: Mutation::Provenance.from(auth_context), cause: cause)
                   else
                     create_document(db, domain, doc_type, body, auth_context, actioner_id, meta_overrides, doc_id, allow_system_writes, skip_authorization, cause, authorize_path)
                   end

          case result
          in Result
            span["doc_id"] = result.projection.id
            span["mutation_id"] = result.mutation_id
          in Facet::ServiceError
            Telemetry.record_error(span, result)
          end

          result
        end
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Step-0 create gate: the flat `create` grant on the target doctype.
      # `skip_authorization` is set by callers that have ALREADY enforced an
      # equivalent (or stronger) gate at a higher layer — today only
      # `SidecarHandler`, which enforces the host read gate plus the
      # flat-or-nested sidecar create grant before delegating here. Skipping
      # the inner flat gate lets a nested-grant holder (e.g.
      # `create hr.Employee.Comment`) reach the create path, which the flat
      # `create core.Comment` gate would otherwise deny.
      #
      # `authorize_path` overrides the path the gate checks — nested child
      # routes pass the composition path (`["WorkOrder", "WorkLog"]`), so a
      # parent grant/permission covers the nested create. The flat route
      # keeps the bare path. See `EnforcerSupport.dispatch_action`.
      private def self.authorize_create_gate(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        auth_context : RBAC::AuthContext,
        skip_authorization : Bool,
        authorize_path : Array(String)?,
      ) : Facet::ServiceError?
        return nil if skip_authorization
        return nil if RBAC::WriteEnforcer.authorize_create(db, domain, doc_type, auth_context, authorize_path)

        IAM::Helpers.write_layer1_denial(db, auth_context, "create", domain, authorize_path || [doc_type])
        Facet::ServiceError.new(403, "Forbidden")
      end

      # Handles general document creation: parse JSON body, then delegate to
      # `create_from_parsed` for the shared creation pipeline.
      private def self.create_document(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        body : String,
        auth_context : RBAC::AuthContext,
        actioner_id : String,
        meta_overrides : Hash(String, JSON::Any)? = nil,
        doc_id : String? = nil,
        allow_system_writes : Bool = false,
        skip_authorization : Bool = false,
        cause : Mutation::Cause? = nil,
        authorize_path : Array(String)? = nil,
      ) : Result | Facet::ServiceError
        document = begin
          JSON.parse(body)
        rescue ex : JSON::ParseException
          return Facet::ServiceError.new(422, "Invalid JSON body: #{ex.message}")
        end

        create_from_parsed(db, domain, doc_type, document, auth_context, actioner_id, cause: cause, meta_overrides: meta_overrides, doc_id: doc_id, allow_system_writes: allow_system_writes, skip_authorization: skip_authorization, authorize_path: authorize_path)
      end

      # Core document creation pipeline from a pre-parsed JSON document.
      #
      # Shared by both `Document::Create` (simple body) and
      # `Document::CreateWithChildren` (compound body with $content).
      # Orchestrates authorization, validation, lifecycle hooks, and
      # persistence by delegating to focused private methods.
      #
      # `meta_overrides` allows extra meta fields to be injected (e.g. parent_id for children).
      #
      # `cause` / `provenance` carry the audit metadata for the mutation;
      # `nil` provenance derives from `auth_context`. The mutation ULID is
      # minted here so the create hook's Lua `document.*` writes can stamp
      # it as their `cause.parent`.
      #
      # Returns `Result` on success, `Error` on failure.
      def self.create_from_parsed(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        document : JSON::Any,
        auth_context : RBAC::AuthContext,
        actioner_id : String,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        meta_overrides : Hash(String, JSON::Any)? = nil,
        reentrant : Bool = false,
        doc_id : String? = nil,
        allow_system_writes : Bool = false,
        skip_authorization : Bool = false,
        currency_check_mode : MoneyCurrencyCheck::Mode = MoneyCurrencyCheck::Mode::Write,
        authorize_path : Array(String)? = nil,
        trusted_reference_fields : Set(String) = Set(String).new,
      ) : Result | Facet::ServiceError
        gate = authorize_create_gate(db, domain, doc_type, auth_context, skip_authorization, authorize_path)
        return gate if gate

        # Body-shape gate (B-59): the pipeline below indexes the parsed body
        # as an object (`flat_create_guards` reads `document["id"]?`). A
        # non-object body would surface as a 500 Crystal type error there —
        # answer the 422 channel the update/doctype/action paths already use.
        unless document.as_h?
          return Facet::ServiceError.new(
            422,
            "Body must be a JSON object (got #{Doctype::StrictKeys.json_kind(document)})"
          )
        end

        # 1. Fetch the doctype definition from the core.DocType projection
        doctype_id = "#{domain}.#{doc_type}"
        defn = Doctype::DefinitionStore.fetch!(db, doctype_id)
        return defn if defn.is_a?(Facet::ServiceError)

        # Sidecar flat-create block. A sidecar record is reachable only
        # through the host's nested route (`SidecarHandler`), which sets
        # the `target` reference from the path and enforces the route's
        # gates before delegating with `skip_authorization: true` — so this
        # fires only on the flat paths. Raised before validation so the
        # route hint wins over the missing-`target` schema error. (The REST
        # flat route pre-checks the same contract in
        # `Routes.nested_create_guard`, before multipart uploads.)
        if defn.sidecar && !skip_authorization
          return Facet::ServiceError.new(422, "Sidecar doctypes cannot be created through the flat route; use the nested route on the host document")
        end

        # Shared flat-create refusals (see `flat_create_guards`).
        parent_id = meta_overrides.try(&.["parent_id"]?).try(&.as_s?)
        if guard = flat_create_guards(domain, doc_type, document, defn, parent_id)
          return guard
        end

        # 2. Validate and prepare the document
        prepared = validate_and_prepare_document(db, domain, doc_type, document, defn, auth_context, allow_system_writes: allow_system_writes, currency_check_mode: currency_check_mode, parent_id: parent_id, trusted_reference_fields: trusted_reference_fields)
        case prepared
        in Facet::ServiceError
          return prepared
        in JSON::Any
          # continue
        end

        # 3. Run the create lifecycle (script, replication, computed fields).
        # The mutation ULID is minted first so the create hook's Lua
        # `document.*` writes can stamp it as their `cause.parent`.
        mut_id = Util::ScriptHelpers.ulid
        finalized = run_create_lifecycle(db, domain, doc_type, prepared, defn, actioner_id, auth_context, cause: cause.try(&.child_of(mut_id)), provenance: provenance, authorize_path: authorize_path)
        case finalized
        in Facet::ServiceError
          return finalized
        in LifecycleOutcome
          # continue
        end

        # 4. Persist and publish. A `ServiceError` here is secret adoption
        # rejecting the document; the notification queue still drains (the
        # transaction rolled back, so the create never landed).
        result = persist_and_publish(db, domain, doc_type, finalized.document, defn, actioner_id, auth_context, cause: cause, provenance: provenance, reentrant: reentrant, meta_overrides: meta_overrides, doc_id: doc_id, mutation_id: mut_id)
        return result if result.is_a?(Facet::ServiceError)

        # Parent recompute: a nested child create (meta_overrides parent_id)
        # is a mutation of a composition child. Runs inside the caller's
        # transaction; a recompute-caused driving write skips the walk.
        if recompute_error = Recompute.after_child_mutation(db, domain, doc_type, result.projection.id, result.mutation_id,
             (cause || Mutation::Cause.root(Mutation::CauseKind::Request)).resolve(result.mutation_id),
             provenance, actioner_id)
          return recompute_error
        end

        # 5. Drain the create hook's notification queue now that the
        # mutation has persisted. `doc_ref = nil` entries resolve to the
        # generated document id; explicit doc_refs resolve themselves.
        # Inside an ambient transaction the drain joins it, so an outer
        # rollback still removes the notifications.
        Notification::Queue.drain(db, finalized.pending, domain, doc_type, result.projection.id)

        result
      end

      # Shared flat-create refusals for every caller that reaches the create
      # pipeline — service callers, Lua `document.create`, compound creates.
      # The REST flat route pre-checks the first refusal the same way
      # (`Routes.nested_create_guard`); enforcing it here closes the paths
      # that skip the route.
      #
      # Owned-child guard: a `member_of` child is created through the
      # parent's nested route or a compound `$children` body, both of which
      # stage `meta_overrides["parent_id"]` — the linkage the projection's
      # meta carries and every aggregate surface reads (relations, delete
      # cascade, copy walk, `$parent_id` scopes). A create without it would
      # land orphaned. `core.DocType` is exempt: its `member_of: Domain`
      # describes the composition tree, not the create surface — the flat
      # create is the authoring API.
      #
      # Body-`id` guard: the server assigns document ids (the `doc_id`
      # parameter, an identifier sequence, or a ULID); a body `id` on a
      # non-Domain create never named the document — the validation
      # allow-list let it ride into content as a stray field. Reject it so
      # the key keeps one meaning. `core.Domain` is exempt: its create
      # branch (see `call`) reads the body id as the domain name. A
      # doctype that declares an `id` field keeps the field meaning.
      private def self.flat_create_guards(
        domain : String,
        doc_type : String,
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        parent_id : String?,
      ) : Facet::ServiceError?
        if definition.member_of && parent_id.nil? && {domain, doc_type} != {"core", "DocType"}
          return Facet::ServiceError.new(422, "Document '#{doc_type}' belongs to '#{definition.member_of}'; create it through the parent's nested route")
        end

        if {domain, doc_type} != {"core", "Domain"} && !definition.fields.has_key?("id") && document["id"]?
          return Facet::ServiceError.new(
            422,
            "Document validation failed",
            details: [ValidationError.new(
              field: "id",
              message: "is assigned by the server and cannot be set on create",
              code: "reserved",
            )],
          )
        end

        nil
      end

      # Validates and prepares a document for creation: runs the field-write
      # guard and the read-only caller-write gate on the raw caller body,
      # applies declared defaults, normalizes canonical formats, validates
      # against the doctype definition, runs authoring-time RBAC checks (for
      # `iam.Roles`), and checks unique constraints.
      #
      # Returns the prepared `JSON::Any` document on success, or a
      # `ServiceError` on failure.
      private def self.validate_and_prepare_document(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        auth_context : RBAC::AuthContext,
        allow_system_writes : Bool = false,
        currency_check_mode : MoneyCurrencyCheck::Mode = MoneyCurrencyCheck::Mode::Write,
        parent_id : String? = nil,
        trusted_reference_fields : Set(String) = Set(String).new,
      ) : JSON::Any | Facet::ServiceError
        # Hydrate the currency registry before validation: the money type's
        # `registered?` rule and the lifecycle check below read the
        # in-process snapshot. A flag check on the warm path — the registry
        # rebuilds here only after the Pub/Sub subscriber marked it stale.
        Currency::Registry.ensure_fresh(db)

        # Field-write guard before any format validation (B-325): a caller
        # whose role cannot see a field must not learn the field's type
        # contract from a 422 — the guard answers 403 first, on the raw
        # caller body. Trusted lifecycle work (defaults, hooks, computed
        # fields) populates invisible fields after this point and stays
        # outside the guard.
        if field_error = RBAC::WriteEnforcer.authorize_field_writes(definition, document, auth_context)
          return field_error
        end

        # Read-only caller-write gate on the raw caller body, before any
        # default lands (B-349): `ApplyDefaults` fills every missing key
        # that has a default, a read-only field included. A check after
        # that step would reject the platform's own write — a create of
        # `core.DomainGrant` without `active` answered 422 for a field the
        # caller never sent. The gate runs here; the validation pass below
        # skips it. System writers keep the `allow_system_writes` bypass.
        readonly_errors = Document::Validation.readonly_write_errors(document, definition, allow_system_writes: allow_system_writes)
        unless readonly_errors.empty?
          return Facet::ServiceError.new(422, "Document validation failed", details: readonly_errors)
        end

        # Apply default values for missing fields BEFORE validation (B-298):
        # a required field with a declared default is satisfiable by
        # omission — mirroring the B-57 fix on the action-args path, the
        # materialized default is normalized and type-validated like a
        # submitted value. Only absent keys are filled; an explicit `null`
        # stays a required-field refusal.
        document = Document::ApplyDefaults.call(document, definition)

        # Normalize canonical formats (e.g. \r\n → \n in longtext)
        document = Document::Normalize.call(document, definition)

        # The read-only gate already ran on the raw caller body above. The
        # materialized defaults are in the document now; the gate must not
        # re-run (B-349).
        errors = Document::Validation.validate(document, definition, allow_system_writes: allow_system_writes, check_readonly: false)
        unless errors.empty?
          return Facet::ServiceError.new(422, "Document validation failed", details: errors)
        end

        # Authoring-time validators that must run between structural
        # validation and the reference existence check: the role permission
        # shape, the role-authority boundary, and the domain-grant shape.
        # The boundary placement matters: an out-of-authority assignment
        # answers the 403 the boundary owns instead of the 422 a dangling
        # reference would produce. Independent of route-level
        # `skip_authorization` — only the System principal bypasses it.
        if authoring_error = authoring_boundary_error(db, domain, doc_type, document, definition, parent_id, auth_context)
          return authoring_error
        end

        # Check reference field filters (e.g. reference must point to a
        # document matching the declared filter). Runs after validation so
        # the document is structurally sound; null values are skipped
        # inside the check (they are valid unset sentinels). The lookup runs
        # under the caller's context, so a target the caller cannot read is
        # refused (B-356). Fields the calling route owns and authorized
        # itself (`trusted_reference_fields`) resolve under system.
        ref_errors = ReferenceCheck.check(db, definition, document, auth_context, trusted_reference_fields)
        unless ref_errors.empty?
          return Facet::ServiceError.new(422, "Document validation failed", details: ref_errors)
        end

        # Check `file` field MIME allow-lists against the artifact rows.
        # Same boundary as ReferenceCheck: runs after schema validation and
        # skips fields absent from the document.
        mime_errors = FileMimeCheck.check(db, definition, document)
        unless mime_errors.empty?
          return Facet::ServiceError.new(422, "Document validation failed", details: mime_errors)
        end

        # Lifecycle rule for `money` fields: every money value in a created
        # document must point at an active currency. Unknown tickers stay in
        # `MoneyType#validate` (schema errors); this adds the inactive case.
        # The bulk import passes `Import` so a stored-but-deactivated ticker
        # still lands — see `MoneyCurrencyCheck::Mode`.
        currency_errors = MoneyCurrencyCheck.check_create(definition, document, currency_check_mode)
        unless currency_errors.empty?
          return Facet::ServiceError.new(422, "Document validation failed", details: currency_errors)
        end

        # Check unique constraints
        unique_errors = UniqueConstraint.check(db, domain, doc_type, document, definition)
        unless unique_errors.empty?
          return Facet::ServiceError.new(422, "Document validation failed", details: unique_errors)
        end

        document
      end

      # The authoring-time validators that sit between structural
      # validation and the reference existence check. Returns the
      # `ServiceError` to surface, or `nil` when the document passes.
      private def self.authoring_boundary_error(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        parent_id : String?,
        auth_context : RBAC::AuthContext,
      ) : Facet::ServiceError?
        # Authoring-time RBAC validation for role documents — reject
        # permission lines that reference unknown scope aliases or are
        # malformed (fail closed at authoring time, never a silent empty set).
        if {domain, doc_type} == {"iam", "Roles"}
          perms_raw = document["permissions"]?.try(&.as_a) || [] of JSON::Any
          rbac_errors = RBAC::Validator.validate_permissions_for(perms_raw, db)
          return Facet::ServiceError.new(422, "RBAC permission validation failed", details: rbac_errors) unless rbac_errors.empty?
        end

        # Role-authority boundary for the IAM doctypes (create side).
        error = RBAC::RoleAuthority.authorize_transition(db, "create", domain, doc_type, nil, document, auth_context)
        return error if error

        # Authoring-time grant validation for `core.DomainGrant` documents —
        # reject self-grants, malformed resource entries, and empty tag
        # strings (see `Grants::Validator`). The producer is the parent
        # domain the grant is filed under.
        if {domain, doc_type} == {"core", "DomainGrant"}
          parent_domain = parent_id.try { |p| p.starts_with?("core.Domain.") ? p["core.Domain.".size..] : p }
          grant_errors = grant_authoring_errors(parent_domain, document)
          return Facet::ServiceError.new(422, "Grant validation failed", details: grant_errors) unless grant_errors.empty?
        end

        # Authoring-time grant validation for `app.App` documents — every
        # entry must parse as a `Grant` and name a concrete target; the
        # wildcard form is refused (see `App::GrantsAuthoring`).
        if {domain, doc_type} == {"app", "App"}
          app_grant_errors = App::GrantsAuthoring.validate(document["grants"]?)
          return Facet::ServiceError.new(422, "Grant validation failed", details: app_grant_errors) unless app_grant_errors.empty?
        end

        # Authoring-time validation for the view children of `core.DocType`
        # — `core.CollectionView` (calendar title template) and
        # `core.DocumentView` (template tree). Both check against the
        # parent doctype's definition; see `view_child_authoring_error`.
        if view_error = view_child_authoring_error(db, domain, doc_type, document, parent_id)
          return view_error
        end

        nil
      end

      # Authoring-time validation for the view children of `core.DocType`.
      # `core.CollectionView` — the `config` must be usable by its surface
      # (see `Document::CollectionViewGate`) and a calendar title template
      # must compile and reference only the parent doctype's fields (see
      # `CollectionView::TitleTemplate`). `core.DocumentView` — the template
      # tree must pass `ViewTemplateValidator` against the parent doctype
      # definition (see `Document::ViewTemplateGate`). The parent is the
      # `core.DocType` projection the view attaches to; a missing or
      # unresolvable parent skips the check (the write path's other guards
      # own that failure).
      private def self.view_child_authoring_error(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        document : JSON::Any,
        parent_id : String?,
      ) : Facet::ServiceError?
        if {domain, doc_type} == {"core", "CollectionView"}
          errors = CollectionViewGate.errors(db, parent_id, document)
          errors += collection_view_title_template_errors(db, parent_id, document["config"]?)
          return Facet::ServiceError.new(422, "Collection view validation failed", details: errors) unless errors.empty?
        end

        if {domain, doc_type} == {"core", "DocumentView"}
          errors = ViewTemplateGate.errors(db, parent_id, document)
          return Facet::ServiceError.new(422, "Document view validation failed", details: errors) unless errors.empty?
        end

        nil
      end

      # Extracts the calendar title template from a `core.CollectionView`
      # `config` value and validates it against the parent doctype's
      # definition. Returns an empty array when there is nothing to check (no
      # calendar config or no template) or when the parent definition cannot
      # be resolved.
      private def self.collection_view_title_template_errors(
        db : DB::Connection,
        parent_id : String?,
        config : JSON::Any?,
      ) : Array(ValidationError)
        return [] of ValidationError unless parent_id

        template = config.try(&.dig?("calendar", "title_template")).try(&.as_s?)
        return [] of ValidationError unless template

        case defn = Doctype::DefinitionStore.fetch!(db, parent_id)
        when Doctype::DoctypeDefinition
          Doctype::CollectionView::TitleTemplate.validate(template, defn)
        else
          [] of ValidationError
        end
      end

      # Authoring-time `core.DomainGrant` checks shared by create and
      # update. The parent domain is the producer: on create it comes from
      # the `meta_overrides["parent_id"]` link (the children system); on
      # update from the projection's `meta.parent_id`. `nil` parent skips
      # the domain rules — only the shape rules run.
      private def self.grant_authoring_errors(
        parent_domain : String?,
        document : JSON::Any,
      ) : Array(ValidationError)
        errors = [] of ValidationError
        return errors if parent_domain.nil?

        consumer = document["consumer_domain"]?.try(&.as_s?)
        Grants::Validator.validate(parent_domain, consumer, document["resources"]?, errors)
        errors
      end

      # Runs the doctype script create hook (if defined), pulls replica
      # field values from source documents, and evaluates computed fields.
      # The create hook's notification queue is captured for the caller to
      # drain after the mutation persists.
      #
      # Returns a `LifecycleOutcome` (finalized document + pending
      # notifications) on success, or a `ServiceError` on failure.
      private def self.run_create_lifecycle(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        actioner_id : String,
        auth_context : RBAC::AuthContext,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        authorize_path : Array(String)? = nil,
      ) : LifecycleOutcome | Facet::ServiceError
        final_document = document
        pending = [] of Notification::Pending

        # Run the doctype script (create hook) if defined
        if definition.script?
          script_errors = [] of ValidationError
          create_ctx = nil
          begin
            ScriptContext::Create.new(definition.script.as(String), document, actioner_id, db: db, domain: domain, doc_type: doc_type, cause: cause, provenance: provenance, auth_context: auth_context, rbac_doctype_path: authorize_path) do |ctx|
              create_ctx = ctx
              script_errors = ctx.run
              final_document = ctx.root_document
              pending = ctx.notification_queue
            end
          rescue ex : ScriptContext::Error
            # A `document.*` helper refused a nested write: surface the
            # recorded ServiceError with its native status (B-30), mirroring
            # the `ctx.error` path above. A script bug with no recorded
            # refusal becomes a 422 carrying the Lua error message (B-131).
            return ScriptContext.refusal_or_script_error(create_ctx, ex)
          end
          unless script_errors.empty?
            return Facet::ServiceError.new(422, "Script validation failed", details: script_errors)
          end

          # Re-normalize reference fields the create hook may have written back
          # onto `ctx.root`. The pre-script `Document::Normalize` ran inside
          # `validate_and_prepare_document`; values assigned by the Lua hook
          # bypass that pass, so run it again so storage stays in canonical
          # form (e.g. a hook copying a bare actor id into a reference field).
          final_document = Document::Normalize.call(final_document, definition)
        end

        # Pull replica field values from source documents. On create, every
        # replicate field with a non-null `via` value is pulled DB-direct. The
        # pulled values become part of the persisted `create` mutation.
        #
        # This runs BEFORE the compute step so that any computed field whose
        # `compute_when` includes the replica field sees the freshly-pulled
        # initial value rather than a null placeholder.
        final_document = Replication::SyncPull.call(db, definition, final_document, changed_via_fields: nil)

        # Run computed fields after the create hook. The document id is not
        # resolved yet (it is generated inside the persist transaction), so
        # a relationship-named field stages an empty `ctx.children` table
        # and `ctx.doc_id` is absent — the recompute pass re-runs the field
        # with the id set once the children land.
        if definition.script?
          final_document, compute_errors = Document::Compute.call(
            definition.script.as(String),
            definition,
            final_document,
            changed_fields: nil,
            actioner_id: actioner_id,
            db: db,
            domain: domain,
            cause: cause,
            provenance: provenance,
            children: Document::Compute.stage_children(db, domain, definition, nil, nil),
          )
          unless compute_errors.empty?
            return Facet::ServiceError.new(422, "Computed fields failed", details: compute_errors)
          end
        end

        LifecycleOutcome.new(document: final_document, pending: pending)
      end

      # Builds meta, strips write-only fields, stages projection GUCs,
      # persists the mutation, fetches the projection, and enqueues the
      # created event — all inside a single database transaction.
      #
      # When `definition.identifier` is present, a `pg_advisory_xact_lock`
      # serialises concurrent creates for this doctype; the last generated
      # identifier is read from `sequence_identifiers`, incremented via
      # `Util::Sequence`, and used as the document ID. On overflow, falls
      # back to ULID.
      #
      # Returns a `Result` on success, a `ServiceError` when secret
      # ── Doc-id resolution ─────────────────────────────────────────────

      # Resolves the document id for a create: the caller's override, the
      # named-id rule, the doctype's identifier sequence, or a ULID. Two
      # doctypes pin the identity to a business key (the named-id
      # convention the seeds and the portable bundles use):
      #
      # - `iam.Roles` → `iam.Roles.{name}`, so role references read the
      #   same everywhere (the account's `roles` array, login election,
      #   and the projections table). The `name` field's
      #   `^[a-z][a-z0-9_]*$` pattern guarantees a slug-safe suffix.
      # - `iam.Account` → the email address, lowercased. Every surface
      #   that shows a raw id (the mutation log's `actioner_id`, CSV
      #   exports of reference fields, API paths) then names the actor
      #   without a display-name lookup. The create hook lowercases the
      #   stored email, so the id and the content agree; a conflict
      #   answers `NamedIdError` (409), which doubles as the
      #   application-level email-uniqueness check.
      private def self.resolve_doc_id(
        txn : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String?,
        final_document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
      ) : String
        return doc_id if doc_id

        if {domain, doc_type} == {"iam", "Roles"}
          name = final_document["name"]?.try(&.as_s?)
          raise Facet::NamedIdError.new(422, "Role creation requires a 'name'") if name.nil? || name.empty?
          role_doc_id = "iam.Roles.#{name}"
          lock_named_id(txn, "iam", "Roles", role_doc_id)
          if Facet::Util::Projections.exists?(txn, "iam", "Roles", role_doc_id)
            raise Facet::NamedIdError.new(409, "Role '#{name}' already exists")
          end
          return role_doc_id
        end

        if {domain, doc_type} == {"iam", "Account"}
          email = final_document["email"]?.try(&.as_s?).try(&.strip.downcase)
          raise Facet::NamedIdError.new(422, "Account creation requires an 'email'") if email.nil? || email.empty?
          lock_named_id(txn, "iam", "Account", email)
          if Facet::Util::Projections.exists?(txn, "iam", "Account", email)
            raise Facet::NamedIdError.new(409, "Account '#{email}' already exists")
          end
          return email
        end

        if id_defn = definition.identifier
          SequenceId.generate(txn, domain, doc_type, id_defn) || Util::ScriptHelpers.ulid
        else
          Util::ScriptHelpers.ulid
        end
      end

      # Serialises concurrent creates that derive the same business-key id
      # (an `iam.Account` email, an `iam.Roles` name). The existence check
      # above is a plain read: without this lock two concurrent creates both
      # read "absent", both write a mutation, and the projection trigger's
      # `ON CONFLICT (domain, doc_type, id) DO UPDATE` silently folds the
      # second into the first — the caller never sees the conflict, so it
      # reports success twice (e.g. two OIDC JIT callbacks for one email
      # both emit `oidc_provisioned`). The transaction-scoped lock blocks the
      # second create until the first commits, so its re-check sees the row
      # and raises `NamedIdError` (409). Same wrapping rule as
      # `SequenceId.generate`: `String#hash` is `UInt64`, the PG lock takes a
      # signed `Int64`.
      private def self.lock_named_id(txn : DB::Connection, domain : String, doc_type : String, id : String) : Nil
        lock_key = "named-id:#{domain}:#{doc_type}:#{id}".hash.to_i64!
        txn.exec("SELECT pg_advisory_xact_lock($1)", lock_key)
      end

      # Adoption rejects the document (an unknown, expired, or forged
      # stage handle / marker).
      private def self.persist_and_publish(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        final_document : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        actioner_id : String,
        auth_context : RBAC::AuthContext,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        reentrant : Bool = false,
        meta_overrides : Hash(String, JSON::Any)? = nil,
        doc_id : String? = nil,
        mutation_id : String? = nil,
      ) : Result | Facet::ServiceError
        prov = provenance || Mutation::Provenance.from(auth_context)
        # Build meta with schema_version and optional overrides (e.g. parent_id)
        meta_hash = {"schema_version" => JSON::Any.new(definition.schema_version.to_i64)}
        if meta_overrides
          meta_overrides.each { |k, v| meta_hash[k] = v }
        end
        doc_meta = JSON::Any.new(meta_hash)

        final_document = StripWriteOnly.call(final_document, definition)

        # Stage search, links, and display_name GUCs for the projection trigger.
        # All three are transaction-local so the GUC set + mutation insert
        # + projection fetch must run inside one transaction.
        begin
          doc_id, mut_id, projection = Database.with_transaction(db, ignore_if_set: true) do |txn|
            # The doc id is generated first so secret adoption sees the final
            # identity: a `sealed` payload is re-sealed under the real
            # (doc_ref, slot) binding and the slot row is keyed by it.
            this_doc_id = resolve_doc_id(txn, domain, doc_type, doc_id, final_document, definition)

            # Resolve stage handles / verify markers BEFORE the GUCs and the
            # mutation: the content that lands must carry markers, never
            # handles (invariant 1). Failure raises `AdoptionError`, which
            # rolls the transaction back; converted to a ServiceError below.
            final_document = Secrets::Adoption.call(
              txn, definition, final_document, domain, doc_type, this_doc_id, actioner_id,
            )

            Document::ProjectionGucs.set_all(txn, definition, final_document)

            content_json = final_document.to_json
            meta_json = doc_meta.to_json

            this_mut_id = Mutation::Client.create(
              txn,
              domain,
              doc_type,
              doc_id: this_doc_id,
              content: content_json,
              meta: meta_json,
              actioner_id: actioner_id,
              provenance: prov,
              cause: cause,
              mutation_id: mutation_id,
            )

            this_proj = Mutation::Client.fetch_projection(txn, domain, doc_type, this_doc_id)

            # Reconcile `artifact_references` for the new document against
            # the post-mutation content, in the same transaction so a
            # rollback undoes both the mutation and the reference projection.
            ArtifactRefs.set_guc(txn, final_document, definition, domain, this_doc_id)

            # Re-attach: a JSON create that puts an existing artifact id into a
            # `file` field appends an owner row *only if* the actor can already
            # read the artifact. Knowing an id never confers ownership. The
            # multipart path already records owner rows via `Multipart.upload_files`;
            # this covers the JSON-only path.
            Artifact::Owners.append_readable_for_document(
              txn, auth_context, final_document, definition, domain, doc_type, this_doc_id, actioner_id,
            )

            {this_doc_id, this_mut_id, this_proj}
          end
        rescue e : Secrets::Adoption::AdoptionError
          return e.error
        rescue e : Facet::NamedIdError
          # The named-id derivation for iam.Roles raises inside the
          # transaction (missing name → 422, name conflict → 409); surface
          # it as the service error it already is instead of a 500.
          return Facet::ServiceError.new(e.status, e.message.to_s)
        end

        Event::Publisher.enqueue(
          domain: domain, doc_type: doc_type, doc_id: doc_id,
          event: "created", mutation_id: mut_id, actioner_id: actioner_id,
          cause_struct: (cause || Mutation::Cause.root(Mutation::CauseKind::Request)).resolve(mut_id),
          reentrant: reentrant,
        )

        # Aggregate push: a child create (nested route, compound create)
        # also emits one `child_changed` frame keyed to the parent.
        if parent_id = meta_overrides.try(&.["parent_id"]?).try(&.as_s?)
          Event::Publisher.enqueue_child_changed(
            db, domain, doc_type, doc_id,
            parent_doc_id: parent_id, action: "created",
            mutation_id: mut_id, actioner_id: actioner_id,
            cause: cause, reentrant: reentrant,
          )
        end

        Result.new(projection: projection, mutation_id: mut_id)
      end

      # Validates the generic domain-create body and returns the domain name,
      # or the `ServiceError` to surface. The domain name rides the body's
      # `id` or `domain` field — it becomes the document ID so that
      # `Doctype::Create.domain_exists?` can find it.
      private def self.domain_create_name(body : String) : String | Facet::ServiceError
        parsed = begin
          JSON.parse(body)
        rescue ex : JSON::ParseException
          return Facet::ServiceError.new(422, "Invalid JSON body: #{ex.message}")
        end
        parsed_h = parsed.as_h?
        unless parsed_h
          return Facet::ServiceError.new(
            422,
            "Body must be a JSON object (got #{Doctype::StrictKeys.json_kind(parsed)})"
          )
        end

        # State-machine guard (B-177): `draft` is set once at create time by
        # the dedicated draft services (`Domain::Draft.create` /
        # `create_from`). The generic create route must not mint a draft
        # with a caller-chosen id — the create-side mirror of
        # `Update.reject_draft_patch?`. The draft and publish machinery
        # writes through `Mutation::Client` directly and never reaches this
        # branch.
        if parsed_h.has_key?("draft")
          return Facet::ServiceError.new(
            422,
            "The 'draft' field cannot be set via document create — use POST /Api/core/Domain/draft"
          )
        end

        domain_name = parsed_h["id"]?.try(&.as_s?) || parsed_h["domain"]?.try(&.as_s?)
        if domain_name.nil? || domain_name.empty?
          return Facet::ServiceError.new(422, "Domain creation requires an 'id' or 'domain' field in the body")
        end
        domain_name
      end

      # Handles core.Domain creation with the domain name as document ID.
      private def self.create_domain_instance(
        db : DB::Connection,
        domain_name : String,
        body : String,
        actioner_id : String,
        provenance : Mutation::Provenance = Mutation::Provenance.internal,
        cause : Mutation::Cause? = nil,
      ) : Result | Facet::ServiceError
        # Duplicate guard. A repeated POST for a live domain appended a
        # second `create` mutation and silently overwrote the document
        # (mirrors `Doctype::Create`'s duplicate-registration guard). A
        # tombstoned (deleted) domain may be re-created — the create
        # projection trigger resurrects the row.
        if Util::Projections.exists?(db, "core", "Domain", domain_name)
          return Facet::ServiceError.new(409, "Domain '#{domain_name}' already exists")
        end

        # Authoring-time validation of context sets declared on this domain.
        # `context_sets` is free-form JSONB (field type `any`), so its field
        # names are not structurally validated by Doctype::Validation. Without
        # this check, a domain admin could inject SQL via a malicious
        # `select` or `where` field name (see RBAC::ContextResolver).
        parsed = begin
          JSON.parse(body)
        rescue ex : JSON::ParseException
          return Facet::ServiceError.new(422, "Invalid JSON body: #{ex.message}")
        end
        parsed_sets = RBAC::ContextResolver.extract_context_sets(parsed)
        rbac_errors = [] of ValidationError
        RBAC::Validator.validate_context_set_definitions(parsed, domain_name, parsed_sets, rbac_errors)
        return Facet::ServiceError.new(422, "RBAC context set validation failed", details: rbac_errors) unless rbac_errors.empty?

        # core.Domain has no doctype definition here, so set empty links/search GUCs.
        # Wrapped in a transaction so the transaction-local GUCs survive to the
        # mutation insert (see create_from_parsed for the rationale).
        mut_id, projection = Database.with_transaction(db, ignore_if_set: true) do |txn|
          Document::ProjectionGucs.clear_all(txn)
          this_mut_id = Mutation::Client.create(
            txn,
            "core",
            "Domain",
            doc_id: domain_name,
            content: body,
            actioner_id: actioner_id,
            provenance: provenance,
            cause: cause,
          )
          this_proj = Mutation::Client.fetch_projection(txn, "core", "Domain", domain_name)
          # The creator of a domain becomes its domain editor — the same
          # auto-grant the draft paths run, so "creator is editor" holds for
          # every creation path. Skipped for non-account actioners inside
          # `Editors.grant` (system, specs, internal callers).
          Domain::Editors.grant(txn, domain_name, actioner_id, actioner_id)
          {this_mut_id, this_proj}
        end

        Event::Publisher.enqueue(
          domain: "core", doc_type: "Domain", doc_id: domain_name,
          event: "created", mutation_id: mut_id, actioner_id: actioner_id,
          cause: (cause || Mutation::Cause.root(Mutation::CauseKind::Request)).resolve(mut_id).to_json_any,
        )

        Result.new(projection: projection, mutation_id: mut_id)
      end
    end
  end
end
