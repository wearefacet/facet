# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "pg"
require "../database"
require "./copy"
require "./scratch"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../doctype/composition"
require "../doctype/validation"
require "../document/update"
require "../document/delete"
require "../document/create"
require "../mutation/client"
require "../replication"
require "../grants"
require "../error"
require "../util/projections"
require "./publish_gate"
require "./view_reconciler"
require "./editors"
require "./publish_documents"

module Facet
  module Domain
    # Publishes a draft domain into a real-named domain.
    #
    # Two modes:
    #
    # - **Fresh publish** (`overwrite: false`, default): the target domain
    #   must not exist. The draft's structure (doctype definitions +
    #   DocumentViews) is copied into the new target; the draft's projections
    #   are soft-deleted while its mutation history is preserved.
    # - **Overwrite publish** (`overwrite: true`): the target domain exists.
    #   The draft's doctype definitions replace the live ones, subject to a
    #   version gate: a doctype whose *structure* changed must bump its
    #   `schema_version` by exactly one and carry a migration function for
    #   that gap (a no-op Lua function is acceptable). DocumentViews are
    #   reconciled per `(doctype, kind)` — the live view set converges to
    #   the draft's. CollectionViews are live-authored and never touched.
    #
    #   The live `core.Domain` document is never rewritten, so the draft's
    #   hooks do not carry (fresh publish copies them). When the draft
    #   declares hooks the live domain does not carry, the response carries
    #   a `warnings` entry naming them and the server logs one WARN line
    #   (B-352). The workaround is a patch of the live domain's `hooks`
    #   field.
    #
    # ## Shape: copy-and-drop
    #
    # Publish does not rename or flag-flip the draft. It copies the draft's
    # doctype definitions into the target domain, then soft-deletes the
    # draft's projections via `Domain::Scratch.drop`. Both run inside a
    # single transaction; a crash before commit rolls back to an intact draft.
    #
    # `(domain, doc_type)` is the compound primary key on `projections`/`mutations`,
    # and the mutation log is append-only — a rename in place would either
    # rewrite historic mutation rows (breaking audit) or orphan them. Copy-and-
    # drop avoids that entirely: the target gets fresh rows under the new
    # identity; the source's projections are soft-deleted (mutation log intact).
    #
    # ## Authorisation
    #
    # The draft row is gated by the caller (the HTTP route checks
    # `RBAC::WriteEnforcer.authorize_update` against `core.Domain` on the
    # draft). Overwrite publish additionally replaces a live target's
    # definition, so the service itself enforces the target side:
    # `authorize_update` on the target's `core.Domain` row must pass — an
    # editor must edit the target domain too, not just the draft. Admin
    # passes as always. The draft creator is the publisher — no separate
    # `publish` meta-permission.
    #
    # ## Post-commit wiring
    #
    # After commit, `Event::Publisher.flush` (called by the HTTP route)
    # delivers the `core.Domain` `created` event and each `core.DocType`
    # event enqueued by `Domain::Copy`. The `Subscriber::DoctypeCache`
    # Pub/Sub subscriber receives each `core.DocType` fanout event and
    # **invalidates** both the doctype definition cache and the replication
    # registry (via `Replication::Manager#mark_registry_stale`). The next
    # read recovers the fresh state from the DB — no direct manager call is
    # needed here, and no eager rebuild runs on the publish path.
    module Publish
      record Result,
        target_domain : String,
        # Grant tickets filed or merged at publish, for the publish report.
        # One entry per touched producer domain; empty when the draft
        # declares no outbound cross-domain edge.
        grant_tickets : Array(Grants::PublishTickets::Ticket) = [] of Grants::PublishTickets::Ticket,
        # Overwrite-mode warnings (B-352): one entry when the draft declares
        # hooks the live domain does not carry — overwrite publish does not
        # copy hooks. Empty otherwise; fresh publish never warns here.
        warnings : Array(String) = [] of String,
        # Documents carried from the draft's selected doctypes. Zero when the
        # publish carried none.
        documents_imported : Int32 = 0

      # Publishes `draft_domain_id` into a real-named domain.
      #
      # `target_name` is the real domain name (must not start with `_`).
      # When `overwrite` is `false` the target must not exist (409 if it
      # does). When `overwrite` is `true` the target may exist; each draft
      # doctype whose structure differs from the live one must carry a
      # `schema_version` of exactly `live + 1` and a migration entry for
      # that gap (enforced by the publish gate — see
      # `#gate_draft_against_target`).
      #
      # `documents` selects draft doctypes whose documents travel with the
      # publish (see `PublishDocuments`). `nil` carries no documents — the
      # default, and the only mode for a draft used purely as a design
      # sandbox.
      def self.call(
        db : DB::Connection,
        draft_domain_id : String,
        target_name : String,
        actioner_id : String = "system:publish",
        overwrite : Bool = false,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        documents : PublishDocuments::Selection? = nil,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "domain.publish" do |span|
          span["draft_domain"] = draft_domain_id
          span["target_domain"] = target_name
          span["overwrite"] = overwrite.to_s
          span["documents"] = documents.nil? ? "false" : "true"

          # 1. Validate inputs.
          if error = validate_target_name(target_name)
            return Telemetry.record_error(span, error)
          end

          # Locks the core.Domain row FOR UPDATE so we serialise against
          # any concurrent publish attempt on the same draft.
          unless Util::Projections.draft_domain?(db, draft_domain_id, lock: true)
            return Telemetry.record_error(span, Facet::ServiceError.new(422, "Source domain '#{draft_domain_id}' is not a draft"))
          end

          # A live domain name is "taken" if a non-deleted core.Domain
          # projection already exists with that id.
          target_exists = Util::Projections.exists?(db, "core", "Domain", target_name)
          if conflict = target_conflict(target_name, target_exists, overwrite)
            return Telemetry.record_error(span, conflict)
          end

          # 2. Load the draft's doctype definitions. They are the source of
          #    truth for what gets published. Shared with `Domain::Copy` —
          #    same SQL, same parse loop, same corrupt-projection skip.
          draft_definitions = Copy.fetch_source_doctype_definitions(db, draft_domain_id)

          # 2.5 Close the composition graph before anything is copied: every
          #    `children` entry must be reciprocated by a `member_of` on its
          #    target and vice versa. A one-sided edge would publish a
          #    half-owned relationship (no cascade, no copy) — reject it
          #    while the whole bundle is still in hand.
          composition_problems = Doctype::Composition.validate(draft_definitions)
          unless composition_problems.empty?
            return Telemetry.record_error(span, Facet::ServiceError.new(
              422,
              "Domain '#{draft_domain_id}' has an inconsistent composition graph: #{composition_problems.first.message}",
            ))
          end

          # 2.6 The draft's hooks — the second edge source for grant ticket
          #    filing (event hooks whose source domain is foreign), and the
          #    input for the overwrite hook-carry warning below.
          draft_hooks = fetch_domain_hooks(db, draft_domain_id)

          # 2.7 The document selection must name draft doctypes only, and on
          #    an overwrite it must not name a doctype the live target already
          #    carries — importing draft rows into a production doctype would
          #    mix test data with live data.
          if documents_error = validate_documents_selection(
               db, draft_domain_id, target_name, draft_definitions, documents, target_exists
             )
            return Telemetry.record_error(span, documents_error)
          end

          # 3. When overwriting an existing domain, run the version gate on
          #    every doctype the draft defines, then publish doctypes one by
          #    one. When the target is fresh, fall back to the bulk
          #    `Copy.structure` (which also creates the target core.Domain
          #    document).
          if target_exists
            # Overwrite guard: the live target's definition is replaced, so
            # the caller must also edit the target domain — not just the
            # draft. The route already gated the draft row.
            unless RBAC::WriteEnforcer.authorize_update(db, "core", "Domain", target_name, auth_context)
              return Telemetry.record_error(span, Facet::ServiceError.new(403, "Forbidden"))
            end

            gate_result = gate_draft_against_target(db, draft_definitions, draft_domain_id, target_name)
            return gate_result if gate_result.is_a?(Facet::ServiceError)

            publish_overwrite(db, draft_definitions, draft_domain_id, target_name, actioner_id)

            # 3.1 Overwrite keeps the live `core.Domain` document as it is,
            #    so the draft's hooks do not land on the target (fresh
            #    publish copies them). The drop must not be silent: one
            #    response warning + one WARN line when the draft declares
            #    hooks the live domain lacks (B-352).
            warnings = hook_carry_warnings(db, draft_hooks, target_name)
            warnings.each { |message| Log.warn { message } }
          else
            warnings = [] of String
            Copy.structure(db, from: draft_domain_id, to: target_name, draft: false, actioner_id: actioner_id)
          end
          span["hook_warnings"] = warnings.size.to_s

          # 3.2 Re-run the hard replication invariants over the whole
          # published set (B-374). The authoring-time check self-skips any
          # source it cannot resolve, so a replica-of-replica field authored
          # before its source exists — the natural order inside a draft —
          # lands unchecked, and publish used to copy it live. Now every
          # bundled doctype has landed under the target name, so the same
          # invariant check resolves the sources it could not see. The
          # check is definition-set-wide, not draft-only: a live doctype may
          # hold an edge whose source resolves only once this publish
          # lands. A violation refuses the publish; the route's
          # transaction rolls the whole copy back.
          if invariant_error = validate_replication_invariants(db, target_name)
            return Telemetry.record_error(span, invariant_error)
          end

          # 3.5 Editor carry-over: co-editors of the draft keep their rights
          # on the published domain (fresh and overwrite both). Runs inside
          # the same transaction as the copy.
          Editors.transfer(db, draft_domain_id, target_name, actioner_id)

          # 3.6 Grant ticket filing: scan the published edges (replicate
          #    fields + foreign-source hooks) and file/merge tickets inside
          #    each producer's subtree. D11: a publisher holding the
          #    acceptance right files active; anyone else files inactive.
          #    A system-attributed publish (no real caller) files inactive.
          publisher_holds_acceptance = publisher_holds_acceptance_right?(db, auth_context)
          grant_tickets = Grants::PublishTickets.file(
            db, target_name, draft_definitions, draft_hooks,
            publisher_holds_acceptance, actioner_id,
          )
          span["grant_tickets"] = grant_tickets.size.to_s

          # 3.7 Document carry-over: the selected draft doctypes' rows land
          #    under the target name. Runs after the structure copy so every
          #    target definition resolves for the document gates, and before
          #    the drop so the draft rows are still readable. A refused row
          #    answers 422 and the route's transaction rolls the whole
          #    publish back.
          documents_imported = carry_documents(
            db, draft_domain_id, target_name, draft_definitions, documents, actioner_id,
          )
          if documents_imported.is_a?(Facet::ServiceError)
            return Telemetry.record_error(span, documents_imported)
          end
          span["documents_imported"] = documents_imported.to_s

          drop_draft(db, draft_domain_id)

          span["outcome"] = "published"
          Result.new(
            target_domain: target_name,
            grant_tickets: grant_tickets,
            warnings: warnings,
            documents_imported: documents_imported,
          )
        end
      end

      # The 409 a fresh publish answers when the target name is taken. A
      # live domain name is "taken" when a non-deleted `core.Domain` owns it;
      # overwrite publish accepts a taken name by design.
      private def self.target_conflict(target_name : String, target_exists : Bool, overwrite : Bool) : Facet::ServiceError?
        return nil if overwrite || !target_exists

        Facet::ServiceError.new(
          409,
          "Target name '#{target_name}' is already in use — resend with overwrite:true to " \
          "replace it (structural changes still require a schema_version bump)",
        )
      end

      # Drops the draft after its structure and selected documents have
      # landed. Its mutation log is preserved for audit.
      private def self.drop_draft(db : DB::Connection, draft_domain_id : String) : Nil
        Scratch.drop(db, draft_domain_id)
      end

      # Validates the publish body's document selection. `nil` selects no
      # documents and always passes.
      private def self.validate_documents_selection(
        db : DB::Connection,
        draft_domain_id : String,
        target_domain : String,
        definitions : Array(Doctype::DoctypeDefinition),
        documents : PublishDocuments::Selection?,
        target_exists : Bool,
      ) : Facet::ServiceError?
        return nil if documents.nil?

        PublishDocuments.validate(db, draft_domain_id, target_domain, definitions, documents, target_exists)
      end

      # Carries the selected draft documents onto `target_domain`. `nil`
      # carries none. A refused row raises `Portable::Import::ImportError`
      # from the shared document pass; this converts it to the `ServiceError`
      # the route renders, so a collision answers 422 instead of a 500.
      private def self.carry_documents(
        db : DB::Connection,
        draft_domain_id : String,
        target_domain : String,
        definitions : Array(Doctype::DoctypeDefinition),
        selection : PublishDocuments::Selection?,
        actioner_id : String,
      ) : Int32 | Facet::ServiceError
        return 0 if selection.nil?

        PublishDocuments.import(db, draft_domain_id, target_domain, definitions, selection, actioner_id)
      rescue ex : Portable::Import::ImportError
        ex.to_service_error
      end

      # ── Body parsing ───────────────────────────────────────────────────

      # Parses the publish body's `documents` field into a selection.
      #
      # ```json
      # { "import": true, "doctypes": ["Status"] }
      # ```
      #
      # `import: false` (or an absent field) carries no documents. `import:
      # true` with an absent `doctypes` carries every draft doctype; an empty
      # list carries none.
      def self.parse_documents_field(raw : JSON::Any?) : {PublishDocuments::Selection?, Facet::ServiceError?}
        return {nil, nil} if raw.nil? || raw.raw.nil?

        object = raw.as_h?
        unless object
          return {nil, Facet::ServiceError.new(422, "'documents' must be a JSON object")}
        end

        return {nil, nil} unless object["import"]?.try(&.as_bool?) == true

        doctypes = case list = object["doctypes"]?
                   when Nil
                     nil
                   else
                     entries = list.as_a?
                     unless entries
                       return {nil, Facet::ServiceError.new(422, "'documents.doctypes' must be an array of doctype names")}
                     end
                     names = entries.compact_map(&.as_s?)
                     unless names.size == entries.size
                       return {nil, Facet::ServiceError.new(422, "'documents.doctypes' must contain only strings")}
                     end
                     names
                   end

        {PublishDocuments::Selection.new(doctypes), nil}
      end

      # Post-commit `display_name` backfill for the documents a publish
      # carried. Called by the route after the transaction commits and after
      # `Event::Publisher.flush`.
      def self.backfill_imported_documents(
        db : DB::Connection,
        draft_domain_id : String,
        target_domain : String,
        definitions : Array(Doctype::DoctypeDefinition),
        documents : PublishDocuments::Selection?,
      ) : Nil
        return if documents.nil?

        PublishDocuments.backfill_display_names(db, draft_domain_id, target_domain, definitions, documents)
      end

      # ── Private ────────────────────────────────────────────────────────

      # The D11 verdict: does the publishing caller hold the producer's
      # acceptance right (`activate` on `core.DomainGrant`)? The verdict is
      # doctype-global by design (D5), so the check runs against the
      # doctype with the wildcard id. A system principal holds no named
      # actions — it files inactive.
      private def self.publisher_holds_acceptance_right?(db : DB::Connection, auth_context : RBAC::AuthContext) : Bool
        return false if auth_context.system?
        case auth_context.can?("activate", "core.DomainGrant")
        when RBAC::CanResult::All, RBAC::CanResult::Scoped then true
        else                                                    false
        end
      end

      # Parses a domain's hooks from its `core.Domain` content. Serves two
      # readers: the draft (the second edge source for grant ticket filing)
      # and the overwrite target (the hook-carry warning, B-352). A
      # malformed hooks array returns an empty list — the hooks authoring
      # gate already rejected malformed shapes at write time.
      private def self.fetch_domain_hooks(db : DB::Connection, domain_id : String) : Array(Hooks::Definition::Hook)
        content_row = db.query_one?("SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL", domain_id) { |rs| rs.read(JSON::Any) }
        return [] of Hooks::Definition::Hook if content_row.nil?

        hooks, errors = Hooks::Definition.parse(content_row)
        errors.each { |e| Log.warn { "Publish hook scan skips malformed hook: #{e.message}" } }
        hooks
      end

      # B-352: overwrite publish never rewrites the live `core.Domain`
      # document, so the draft's hooks do not land on the target — while
      # the grant-ticket scan still reads them. When the draft declares
      # hooks the live domain does not carry (by hook id), the publish
      # must not be silent: the response carries one warning naming the
      # dropped hook ids, and the caller logs the same line. The
      # workaround is a patch of the live domain's `hooks` field.
      private def self.hook_carry_warnings(
        db : DB::Connection,
        draft_hooks : Array(Hooks::Definition::Hook),
        target_name : String,
      ) : Array(String)
        return [] of String if draft_hooks.empty?

        live_hooks = fetch_domain_hooks(db, target_name)
        live_ids = live_hooks.map(&.id)
        dropped = draft_hooks.reject { |hook| live_ids.includes?(hook.id) }
        return [] of String if dropped.empty?

        ids = dropped.map { |hook| "'#{hook.id}'" }.join(", ")
        [
          "Overwrite publish does not copy hooks — the live domain '#{target_name}' keeps its own hooks. Draft hooks not carried: #{ids}. To add them, patch the live domain's 'hooks' field.",
        ]
      end

      # Re-runs the hard replication invariants over the whole published
      # definition set (B-374). Returns `nil` when the set is clean, or a
      # `422` naming the first violation — the message is the validator's
      # own (e.g. "Cannot replicate from a replica.").
      private def self.validate_replication_invariants(
        db : DB::Connection,
        target_name : String,
      ) : Facet::ServiceError?
        violations = Copy.fetch_source_doctype_definitions(db, target_name).flat_map do |definition|
          Replication::Validator.validate_invariants(definition, db)
        end
        return nil if violations.empty?

        Facet::ServiceError.new(422, "Publish refused: #{violations.join("; ")}")
      end

      # Target name must match the live-domain naming convention used by
      # the doctype validator: lowercase alphanumeric + dashes. The `_`
      # prefix is reserved for drafts and must not leak into live names.
      # We check the prefix first so the error message is specific.
      private def self.validate_target_name(name : String) : Facet::ServiceError?
        if name.starts_with?('_')
          return Facet::ServiceError.new(422, "Target name '#{name}' must not start with '_' — that prefix is reserved for drafts")
        end
        unless name.matches?(/^[a-z][a-z0-9\-]*$/)
          return Facet::ServiceError.new(
            422,
            "Target name '#{name}' is invalid — must be lowercase alphanumeric (a-z, 0-9, -) and start with a letter"
          )
        end
        nil
      end

      # ── Overwrite-publish helpers ────────────────────────────────────────

      # Runs the version gate: every draft doctype whose structure differs
      # from the live target's must carry `schema_version = live + 1` and a
      # migration entry (with a Lua function) for that gap. Returns `nil`
      # when the gate passes, or a `422` listing the first offending doctype.
      private def self.gate_draft_against_target(
        db : DB::Connection,
        draft_definitions : Array(Doctype::DoctypeDefinition),
        draft_domain : String,
        target_name : String,
      ) : Facet::ServiceError?
        draft_definitions.each do |definition|
          live_id = "#{target_name}.#{definition.doctype}"
          live_def = Doctype::DefinitionStore.fetch_uncached(db, live_id)
          next unless live_def

          problems = PublishGate.check(db, live_def, definition, target_name)
          next if problems.empty?

          # The gate reports a wrong schema_version alone and first — the
          # migration-gap check is meaningless until the version is right.
          version_problem = problems.first
          if version_problem.kind == :schema_version
            return Facet::ServiceError.new(422, version_problem.message)
          end

          message = problems.map(&.message).join("; ")
          return Facet::ServiceError.new(
            422,
            "Doctype '#{live_id}' cannot be published over the existing domain: #{message}"
          )
        end
        nil
      end

      # Publishes the draft's doctypes over the existing target domain:
      # each definition is upserted, then its DocumentViews are reconciled
      # per `(doctype, kind)`. CollectionViews are never touched.
      private def self.publish_overwrite(
        db : DB::Connection,
        draft_definitions : Array(Doctype::DoctypeDefinition),
        draft_domain : String,
        target_name : String,
        actioner_id : String,
      ) : Nil
        draft_definitions.each do |definition|
          live_id = "#{target_name}.#{definition.doctype}"
          live_def = Doctype::DefinitionStore.fetch_uncached(db, live_id)

          event = live_def ? "updated" : "registered"
          Copy.upsert_doctype_definition(
            db, JSON.parse(definition.to_json), definition.doctype, target_name, actioner_id,
            event: event,
          )

          reconcile_document_views(
            db,
            draft_domain: draft_domain,
            target_name: target_name,
            doctype: definition.doctype,
            actioner_id: actioner_id,
          )
        end
      end

      # Makes the live target's DocumentView set for a doctype converge to
      # the draft's through the shared `ViewReconciler`: views are matched
      # by `kind`; a draft view whose template differs from the live one
      # updates the live row in place; a draft-only kind is created; a
      # live-only kind is deleted. CollectionView rows are never touched.
      private def self.reconcile_document_views(
        db : DB::Connection,
        draft_domain : String,
        target_name : String,
        doctype : String,
        actioner_id : String,
      ) : Nil
        draft_views = fetch_document_views(db, "#{draft_domain}.#{doctype}")
        live_views = fetch_document_views(db, "#{target_name}.#{doctype}")

        desired = draft_views.compact_map do |draft_view|
          kind = draft_view["kind"]?.try(&.as_s?) || next
          template = draft_view["template"]?
          template = nil if template.try(&.raw).nil?
          ViewReconciler::Desired.new(
            kind,
            template || JSON::Any.new(nil),
            JSON::Any.new(nil),
          )
        end

        ViewReconciler.converge(
          live_views.map { |v| ViewReconciler::Live.new(v["id"].as_s, v["kind"].as_s?, v["template"]) },
          desired,
          ViewReconciler::Ops.new(
            equal: ->(live_template : JSON::Any, want_template : JSON::Any) { live_template.to_json == want_template.to_json },
            create: ->(kind : String, template : JSON::Any, _meta : JSON::Any) {
              create_document_view(db, target_name, doctype, kind,
                template.raw.nil? ? nil : template, actioner_id)
            },
            update: ->(doc_id : String, _live_template : JSON::Any, template : JSON::Any) {
              update_document_view(db, doc_id, template, actioner_id)
              true
            },
            delete: ->(doc_id : String) { delete_document_view(db, doc_id, actioner_id) },
          ),
        )
      end

      # Fetches the live DocumentView rows for a qualified doctype id
      # (`meta.parent_id` is the source of truth for the parent link).
      # Returns `{id, kind, template}`-shaped hashes; a missing template is
      # stored as JSON null.
      private def self.fetch_document_views(
        db : DB::Connection,
        qualified_doctype : String,
      ) : Array(Hash(String, JSON::Any))
        db.query_all(
          <<-SQL,
            SELECT id, content->>'kind', content->'template' FROM projections
            WHERE domain = 'core' AND doc_type = 'DocumentView'
              AND meta->>'parent_id' = $1
              AND deleted_at IS NULL
            ORDER BY id ASC
          SQL
          qualified_doctype,
        ) do |rs|
          id = rs.read(String)
          kind = rs.read(String?)
          template = rs.read(JSON::Any?)
          h = {
            "id"   => JSON::Any.new(id),
            "kind" => JSON::Any.new(kind),
          }
          h["template"] = template ? template : JSON::Any.new(nil)
          h
        end
      end

      # Updates an existing live DocumentView in place (same doc_id) when
      # the draft's template differs.
      private def self.update_document_view(
        db : DB::Connection,
        doc_id : String,
        template : JSON::Any?,
        actioner_id : String,
      ) : Nil
        body = JSON.build do |json|
          json.object do
            json.field "template", template
          end
        end
        Document::Update.call(
          db, "core", "DocumentView", doc_id, body,
          Facet::RBAC::AuthContext.system,
          actioner_id: actioner_id,
        )
      end

      # Creates a new live DocumentView with a fresh ULID, rewriting
      # `parent_doctype` and `meta.parent_id` to the target qualified id.
      private def self.create_document_view(
        db : DB::Connection,
        target_name : String,
        doctype : String,
        kind : String,
        template : JSON::Any?,
        actioner_id : String,
      ) : Nil
        qualified = "#{target_name}.#{doctype}"
        body_obj = {
          "parent_doctype" => JSON::Any.new(qualified),
          "kind"           => JSON::Any.new(kind),
        }
        body_obj["template"] = template if template
        Document::Create.call(
          db, "core", "DocumentView", body_obj.to_json,
          Facet::RBAC::AuthContext.system,
          meta_overrides: {"parent_id" => JSON::Any.new(qualified)},
        )
      end

      # Soft-deletes a live DocumentView that no longer exists in the draft.
      private def self.delete_document_view(
        db : DB::Connection,
        doc_id : String,
        actioner_id : String,
      ) : Nil
        Document::Delete.call(
          db, "core", "DocumentView", doc_id,
          Facet::RBAC::AuthContext.system,
          actioner_id: actioner_id,
        )
      end
    end
  end
end
