# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/doctype_definition"
require "../mutation/json_diff"
require "../mutation/client"
require "./script_context"
require "./strip_write_only"
require "./normalize"
require "./search"
require "./links"
require "../iam/helpers"
require "../rbac"
require "../event"
require "../error"
require "../secrets/adoption"
require "opentelemetry"

module Facet
  module Document
    # Service for executing a named action on an existing document.
    #
    # The action is defined in the doctype's Lua script. The service:
    # 1. Fetches the doctype definition and the current projection
    # 2. Runs the named action function in a Lua context via
    #    `ScriptContext::Action`
    # 3. Computes a JsonDiff between the original and resulting changeset
    # 4. Persists the diff as an `update` mutation
    # 5. Returns the updated projection
    module Action
      # Unified result type.
      record Result,
        projection : Mutation::Client::Projection,
        mutation_id : String

      # Executes a named action on a document.
      #
      # Requires an `auth_context` for RBAC authorization.
      # Returns `Result` on success, `Error` on failure.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        action_name : String,
        args_body : String = "{}",
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        reentrant : Bool = false,
      ) : Result | Facet::ServiceError
        actioner_id = auth_context.account_id

        Facet::Telemetry.trace "document.action" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["doc_id"] = doc_id
          span["action_name"] = action_name

          prepared = prepare_action(db, domain, doc_type, doc_id, action_name, args_body, auth_context, span)
          return Telemetry.record_error(span, prepared) if prepared.is_a?(Facet::ServiceError)
          defn, proj, args, event_name, script = prepared

          # The mutation ULID is minted before the Lua runs: every nested
          # `document.*` write stamps it as its `cause.parent`, so the audit
          # log links each side effect to this exact mutation even though it
          # is inserted only after the script completes.
          action_mut_id = Util::ScriptHelpers.ulid
          prov = Mutation::Provenance.from(auth_context)
          root_cause = Mutation::Cause.new(
            kind: Mutation::CauseKind::Action,
            name: action_name,
            event: event_name,
            source: "#{domain}.#{doc_type}:#{doc_id}",
          ).resolve(action_mut_id)
          # Cause template for the script's nested writes: same
          # kind/name/event/source, `parent` bound to this action's mutation.
          child_cause = root_cause.child_of(action_mut_id)

          # 6. Run the action in the Lua context
          errors = [] of ValidationError
          final_document = proj.content
          pending = [] of Notification::Pending
          action_ctx = nil

          begin
            ScriptContext::Action.new(script, action_name, proj.content, args, actioner_id, db: db, domain: domain, doc_type: doc_type, doc_id: doc_id, cause: child_cause, provenance: prov, auth_context: auth_context) do |ctx|
              action_ctx = ctx
              action_errors = ctx.run
              if action_errors.empty?
                final_document = ctx.root_document
                pending = ctx.notification_queue
              else
                errors.concat(action_errors)
              end
            end
          rescue ex : ScriptContext::Error
            # A `document.*` helper refused a nested write (flat-create
            # guard, validation, missing target): surface the recorded
            # ServiceError with its native status instead of an opaque 500
            # (B-30). A script bug with no recorded refusal becomes a 422
            # carrying the Lua error message (B-131).
            return Telemetry.record_error(span, ScriptContext.refusal_or_script_error(action_ctx, ex))
          end

          unless errors.empty?
            return Telemetry.record_error(span, Facet::ServiceError.new(422, "Action '#{action_name}' failed", details: errors))
          end

          # 6b. Re-normalize reference fields the script may have written back
          # onto `ctx.root`. The create-time `Document::Normalize` runs before
          # the script; values assigned by the Lua action (e.g. assignments
          # from an action arg that was just qualified above) bypass the
          # earlier pass. Run it again so storage stays in canonical form.
          final_document = Document::Normalize.call(final_document, defn)

          # 7. Run computed fields based on what changed
          changed_fields = Mutation::JsonDiff.changed_fields(proj.content, final_document)
          final_document, compute_errors = Document::Compute.call(
            script,
            defn,
            final_document,
            changed_fields: changed_fields,
            actioner_id: actioner_id,
            db: db,
            domain: domain,
            cause: child_cause,
            provenance: prov,
            children: Document::Compute.stage_children(db, domain, defn, doc_id, changed_fields),
            doc_id: doc_id,
          )
          unless compute_errors.empty?
            return Telemetry.record_error(span, Facet::ServiceError.new(422, "Computed fields failed", details: compute_errors))
          end

          # 8. Strip write_only fields from the final document.
          final_document = StripWriteOnly.call(final_document, defn)

          # 8a. Role-authority boundary for the IAM doctypes: the complete
          # IAM transition (target protection plus the final-roles / role-
          # power rules) on the document the action would land, before any
          # persistence. Only the System principal bypasses it.
          if auth_error = RBAC::RoleAuthority.authorize_transition(db, "action", domain, doc_type, proj.content, final_document, auth_context)
            return Telemetry.record_error(span, auth_error)
          end

          # 8b. Field-write guard on the action's final diff: action
          # arguments are not document fields, but the resulting content
          # diff is subject to the same invisible-field refusal, checked
          # before persistence. A legitimate blind-write action that
          # cannot satisfy this guard is a design concern, not a bypass.
          if field_error = RBAC::WriteEnforcer.authorize_field_changes(defn, proj.content, final_document, auth_context)
            return Telemetry.record_error(span, field_error)
          end

          # 8–9. Secret adoption, diff, and the mutation all run inside the
          # same transaction: the diff must reflect substituted markers
          # (never handles), and the slot upserts stay atomic with the
          # mutation. An empty diff returns the existing projection — the
          # no-change branch writes nothing, and adoption only writes when
          # a handle is present (a handle always bumps the marker, so a
          # staged change never lands in the empty branch). Adoption
          # failure rolls the transaction back and surfaces as a
          # ServiceError.
          persisted = persist_document_update(
            db, domain, doc_type, doc_id, defn, final_document,
            actioner_id, proj, action_mut_id, prov, root_cause, span,
          )
          return Telemetry.record_error(span, persisted) if persisted.is_a?(Facet::ServiceError)

          unless persisted
            # 8. Nothing changed — return success with the same projection.
            span["mutation_id"] = proj.state
            Notification::Queue.drain(db, pending, domain, doc_type, doc_id)
            return Result.new(projection: proj, mutation_id: proj.state)
          end

          mut_id = persisted[0]
          updated_proj = persisted[1]

          Event::Publisher.enqueue(
            domain: domain, doc_type: doc_type, doc_id: doc_id,
            event: event_name, mutation_id: mut_id, actioner_id: actioner_id,
            cause: root_cause.to_json_any, reentrant: reentrant,
          )

          # Aggregate push: an action on a child (meta.parent_id rides the
          # projection row) also emits one `child_changed` frame keyed to
          # the parent. The frame's action is the mutation kind — an action
          # persists an update mutation.
          if parent_id = proj.meta["parent_id"]?.try(&.as_s?)
            Event::Publisher.enqueue_child_changed(
              db, domain, doc_type, doc_id,
              parent_doc_id: parent_id, action: "updated",
              mutation_id: mut_id, actioner_id: actioner_id,
              cause: root_cause, reentrant: reentrant,
            )
          end

          # Parent recompute: an action that mutated a composition child is
          # a mutation of that child — the same trigger rule the create /
          # update / delete services apply. A recompute-caused write skips
          # the walk (the loop guard).
          if recompute_error = Recompute.after_child_mutation(db, domain, doc_type, doc_id, mut_id, root_cause, prov, actioner_id)
            return Telemetry.record_error(span, recompute_error)
          end

          span["mutation_id"] = mut_id

          # Drain the action's notification queue now that the mutation
          # persisted. `doc_ref = nil` entries resolve to the actioned
          # document.
          Notification::Queue.drain(db, pending, domain, doc_type, doc_id)

          Result.new(projection: updated_proj, mutation_id: mut_id)
        end
      end

      # ── Private helpers ──────────────────────────────────────────

      # Steps 0–5: authorize the action, fetch the definition and the
      # current projection, resolve the event name, and parse/normalize/
      # validate the arguments. Returns the inputs the script phase needs
      # (definition, projection, args, event name, script), or the
      # `Facet::ServiceError` to surface.
      private def self.prepare_action(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        action_name : String,
        args_body : String,
        auth_context : RBAC::AuthContext,
        span : OpenTelemetry::API::Span,
      ) : {Doctype::DoctypeDefinition, Mutation::Client::Projection, JSON::Any, String, String} | Facet::ServiceError
        doctype_id = "#{domain}.#{doc_type}"

        # 0. Authorize the action. A class-level denial — no permission for
        # the action on the doctype at all — answers 403 before any row
        # state is read. A scoped caller whose row check fails answers
        # 404: an inaccessible document is indistinguishable from a
        # missing one.
        if RBAC::WriteEnforcer.action_denied?(action_name, domain, doc_type, auth_context)
          IAM::Helpers.write_layer1_denial(db, auth_context, action_name, domain, [doc_type])
          return Facet::ServiceError.new(403, "Forbidden")
        end
        unless RBAC::WriteEnforcer.authorize_action(db, domain, doc_type, doc_id, action_name, auth_context)
          IAM::Helpers.write_layer1_denial(db, auth_context, action_name, domain, [doc_type])
          return Facet::ServiceError.new(404, "Document #{domain}.#{doc_type}##{doc_id} not found")
        end

        # 1. Fetch the doctype definition
        defn = Doctype::DefinitionStore.fetch!(db, doctype_id)
        return defn if defn.is_a?(Facet::ServiceError)

        # 2. Validate the action exists and resolve the event name
        unless defn.actions.has_key?(action_name)
          return Facet::ServiceError.new(404, "Unknown action '#{action_name}' for #{doctype_id}")
        end
        # The action's resolved event name is the `event` stamped on the
        # resulting update mutation's cause, and is propagated to any
        # mutations the Lua action drives via `document.*` helpers.
        event_name = defn.actions[action_name].resolved_event_name(action_name)

        # 3. Fetch the current projection
        proj = Mutation::Client.fetch_projection_or_404(db, domain, doc_type, doc_id, "Document #{domain}.#{doc_type}##{doc_id} not found")
        return proj if proj.is_a?(Facet::ServiceError)

        # 3a. Role-authority target protection for the IAM doctypes: an
        # action on an account or role whose current ceiling is above the
        # caller's level refuses before the script runs. The complete
        # transition check runs on the final document before persistence.
        if auth_error = RBAC::RoleAuthority.authorize_transition(db, "action", domain, doc_type, proj.as(Mutation::Client::Projection).content, nil, auth_context)
          return auth_error
        end

        # 3b. State gate: an action that declares `states` runs only when
        # every gated field carries a listed value in the current content
        # (B-323). The menu hides the entry; this 422 bounds API callers.
        unless defn.actions[action_name].state_allowed?(proj.as(Mutation::Client::Projection).content)
          return Facet::ServiceError.new(422, "Action '#{action_name}' is not available in the current state")
        end

        # 4. Check that a script is defined. Authoring rejects a definition
        # that declares actions without a script (B-299); this 422 keeps
        # legacy definitions from reaching the Lua engine.
        script = defn.script
        if script.nil? || script.empty?
          return Facet::ServiceError.new(422, "No script defined for #{doctype_id}")
        end

        # 5. Parse the action arguments
        args = begin
          JSON.parse(args_body)
        rescue ex : JSON::ParseException
          return Facet::ServiceError.new(422, "Invalid JSON in action arguments: #{ex.message}")
        end

        # 5a. Resolve the action definition and normalize action arguments.
        #
        # Normalization runs *before* validation, mirroring the document
        # create path (`Normalize.call` → `Validation.validate`): API callers
        # may send bare ids for reference args, and qualification must land
        # before the strict-format reference check runs. The Lua script then
        # sees the same qualified storage form `ctx.root` carries.
        action_def = defn.actions[action_name]
        args = Document::Normalize.action_args(args, action_def)

        # 5b. Validate action arguments against the action definition.
        arg_errors = validate_action_args(args, action_def)
        unless arg_errors.empty?
          return Facet::ServiceError.new(422, "Invalid action arguments", details: arg_errors)
        end

        {defn, proj, args, event_name, script}
      end

      # Step 8: secret adoption, diff, and the mutation all run inside the
      # same transaction: the diff must reflect substituted markers
      # (never handles), and the slot upserts stay atomic with the
      # mutation. An empty diff returns nil — the no-change branch writes
      # nothing, and adoption only writes when a handle is present (a
      # handle always bumps the marker, so a staged change never lands in
      # the empty branch). Adoption failure rolls the transaction back and
      # surfaces as a ServiceError.
      private def self.persist_document_update(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        defn : Doctype::DoctypeDefinition,
        final_document : JSON::Any,
        actioner_id : String,
        proj : Mutation::Client::Projection,
        action_mut_id : String,
        prov : Mutation::Provenance,
        root_cause : Mutation::Cause,
        span : OpenTelemetry::API::Span,
      ) : {String, Mutation::Client::Projection}? | Facet::ServiceError
        begin
          txn_result = Database.with_transaction(db, ignore_if_set: true) do |txn|
            final_document = Secrets::Adoption.call(
              txn, defn, final_document, domain, doc_type, doc_id, actioner_id,
              previous: proj.content,
            )

            diff = Mutation::JsonDiff.diff(proj.content, final_document)
            if diff.empty?
              nil
            else
              diff_json = diff.to_json

              # Stage search, links, and display_name GUCs for the
              # trigger. `final_document` is the post-diff content.
              Document::ProjectionGucs.set_all(txn, defn, final_document)

              # The action's cause is stamped on the update mutation so
              # audit consumers can trace this update back to the action
              # that produced it (rather than a raw PATCH).
              this_mut_id = Mutation::Client.update(
                txn, domain, doc_type, doc_id,
                diff_json: diff_json,
                actioner_id: actioner_id,
                provenance: prov,
                cause: root_cause,
                mutation_id: action_mut_id,
              )

              this_proj = Mutation::Client.fetch_projection(txn, domain, doc_type, doc_id)
              {this_mut_id, this_proj}
            end
          end
        rescue e : Secrets::Adoption::AdoptionError
          return Telemetry.record_error(span, e.error)
        end

        txn_result
      end

      # Validates action arguments against the action definition. A
      # `collection: true` arg must carry a JSON array whose elements each
      # match the declared type; a scalar arg matches the declared type
      # directly.
      private def self.validate_action_args(
        args : JSON::Any,
        action_def : Doctype::ActionDefinition,
      ) : Array(ValidationError)
        errors = [] of ValidationError

        args_h = args.as_h?
        if args_h.nil?
          errors << ValidationError.new(
            field: nil,
            message: "Action arguments must be a JSON object",
            code: "argument",
          )
          return errors
        end

        arg_keys = args_h.keys.to_set

        action_def.args.each do |arg_name, arg_def|
          # Check required fields
          if arg_def.required && !arg_keys.includes?(arg_name)
            errors << ValidationError.new(
              field: arg_name,
              message: "is missing",
              code: "required",
            )
            next
          end

          # Check argument exists to validate type
          value = args_h[arg_name]?
          next if value.nil? || value.raw.nil?

          # Validate type
          if field_type = arg_def.type
            # Use existing field validation by wrapping arg_def into a temporary FieldDefinition.
            # `doctype` is forwarded so reference-type validation can resolve the
            # declared target doctype (`FieldDefinition#qualified_doctype`), and
            # `min` / `max` so integer args enforce the declared bounds with the
            # same `out_of_range` errors fields produce (B-51). The descriptor
            # stays `collection: false`: the array shape check lives in
            # `validate_collection_arg`, and the elements it validates one by
            # one are scalar values — a collection-carrying descriptor would
            # make `ReferenceType#validate` demand an array per element.
            field_def = Doctype::FieldDefinition.new(
              type: field_type,
              doctype: arg_def.doctype,
              required: arg_def.required,
              default: arg_def.default,
              min: arg_def.min,
              max: arg_def.max,
              tags: [] of String,
            )

            if arg_def.collection
              # A `collection: true` arg carries a JSON array (B-52): a scalar
              # is a type error, and each element is validated against the
              # declared type with an `arg.<idx>` error path.
              validate_collection_arg(value, arg_name, field_type, field_def, arg_def.values, errors)
            else
              field_type.validate(value, field_def, arg_name, errors)
              validate_enum_value(arg_def.values, value, arg_name, errors)
            end
          end
        end

        errors
      end

      # Validates a `collection: true` action argument. The submitted value
      # must be a JSON array — a scalar is a type error. Each element is
      # validated against the declared argument type (and the argument's
      # `values` set) with an `arg.<idx>` error path, mirroring
      # `ArrayType#validate`. Null elements pass through, like array fields.
      private def self.validate_collection_arg(
        value : JSON::Any,
        arg_name : String,
        field_type : Doctype::FieldType,
        field_def : Doctype::FieldDefinition,
        values : Array(String)?,
        errors : Array(ValidationError),
      ) : Nil
        arr = value.as_a?
        if arr.nil?
          errors << ValidationError.new(
            field: arg_name,
            message: "must be an array",
            code: "invalid_type",
            params: {"expected" => "an array"},
          )
          return
        end

        arr.each_with_index do |item, idx|
          next if item.raw.nil?

          item_path = "#{arg_name}.#{idx}"
          field_type.validate(item, field_def, item_path, errors)
          validate_enum_value(values, item, item_path, errors)
        end
      end

      # Checks one submitted value against an argument's `values` set.
      # No-op when the argument declares no closed set.
      private def self.validate_enum_value(
        values : Array(String)?,
        value : JSON::Any,
        field : String,
        errors : Array(ValidationError),
      ) : Nil
        return if values.nil? || values.empty?

        val_str = value.raw.to_s
        return if values.includes?(val_str)

        allowed = values.join(", ")
        errors << ValidationError.new(
          field: field,
          message: "must be one of: #{allowed}",
          code: "invalid_format",
          params: {"value" => val_str, "allowed" => allowed, "format" => "one of: #{allowed}"},
        )
      end
    end
  end
end
