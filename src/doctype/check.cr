# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "./doctype_definition"
require "./definition_store"
require "./view_template_validator"
require "../document/collection_view_gate"
require "../replication/validator"
require "../rbac"
require "../error"
require "../util/projections"

module Facet
  module Doctype
    # Diagnostics service for a single doctype definition.
    #
    # Runs the cross-doctype integrity checks that are intentionally NOT
    # enforced at authoring time (see `Doctype::Validation` for the
    # rationale — enforcing them would create ordering dependencies
    # between domains and prohibit legitimate forward references). The
    # runtime replication path already silently no-ops on broken configs;
    # this service surfaces the same conditions as a list of issues so an
    # author can troubleshoot at runtime via the `GET /Api/core/DocType/:id/check`
    # endpoint.
    #
    # Read-only — uses a plain `with_db` connection (no transaction, no
    # events flushed). Authorisation is the caller's responsibility
    # (the HTTP route gates it via `RBAC::WriteEnforcer.authorize_update`
    # against `core.DocType`).
    #
    # ## Issue categories
    #
    # - `:reference`  — a `reference`-typed field points at a doctype that
    #                  isn't a registered, non-deleted `core.DocType`
    #                  projection.
    # - `:replication` — a `replicate` field declaration has a structural
    #                  problem (missing `via`, missing source field, type
    #                  mismatch, missing grant, draft source for a live
    #                  consumer, etc.). Mirrors `Replication::Validator`.
    # - `:children`   — a `children` declaration points at a doctype that
    #                  isn't registered in the same domain.
    # - `:sidecar`    — a `sidecars` entry points at a doctype that isn't
    #                  registered, isn't flagged `sidecar: true`, or lacks
    #                  the reference field named by the entry's `column`.
    # - `:composition` — the owned-composition graph is inconsistent: a
    #                  child's `member_of` has no matching `children:`
    #                  entry on the parent, or a `reference` field
    #                  duplicates an owned composition edge.
    # - `:view`        — the doctype's `core.DocumentView` children have
    #                  structural problems (a malformed template tree) or
    #                  a standard view kind (`view`, `form`, `quickView`,
    #                  `inline`, `card`) is not defined. A
    #                  `core.CollectionView` child has a config its surface
    #                  cannot use (a kanban `group_by` without the `eq`
    #                  capability, a calendar `discriminator` without the
    #                  window filter) — see `Document::CollectionViewGate`.
    #                  A malformed template or an unusable view config is a
    #                  warning; a missing kind is an `:info` notice — the
    #                  frontend falls back to generic layouts for the
    #                  missing kinds, so absent optional UI is not a fault
    #                  (B-304). A doctype with zero `core.CollectionView`
    #                  children gets an `:info` notice too — the listing
    #                  shows the starter screen until a view is created.
    # - `:actions`     — the definition declares named actions but ships no
    #                  Lua script. The authoring gate rejects this state;
    #                  the warning covers definitions published before the
    #                  gate existed (B-299).
    # - `:defaults`    — notices about the effective runtime behaviour when
    #                  optional config is absent (no `display_name`
    #                  template, no `search` template). The runtime degrades
    #                  gracefully, so these are `:info` notices — with one
    #                  exception: an aggregate root that declares neither
    #                  template cannot be searched, and the authoring gate
    #                  refuses to create it, so the check reports an
    #                  `:error` (B-296). An owned child in the same state is
    #                  a notice — it is reached through its parent.
    # - `:template`    — a `search` or `display_name` template contains no
    #                  `{{` variable, so it renders one literal for every
    #                  row (the `"$name"` typo class).
    #
    # Warnings describe configurations that the runtime silently skips,
    # never hard failures. Three groups are `:info` notices instead: the
    # `:defaults` notices state what the runtime does without the optional
    # config, a missing standard view kind describes absent optional UI,
    # and a doctype with zero collection views describes a starter state
    # the listing recovers from on first view creation.
    module Check
      # A single diagnostic finding.
      record Issue,
        severity : Symbol, # `:warning` for actionable problems, `:info` for `:defaults` notices and missing standard view kinds
        category : Symbol, # `:reference`, `:replication`, `:children`, `:sidecar`, `:composition`, `:template`, `:defaults`, `:actions`, `:compute`, `:view`
        field : String?,
        message : String

      record Result,
        doctype_id : String,
        issues : Array(Issue)

      # Runs all diagnostic checks against the doctype identified by
      # `doctype_id` (e.g. `"hr.Employee"`). Reads the definition fresh
      # from the projections table (uncached) so the result reflects the
      # latest persisted state.
      #
      # Returns `Error` (404) when the doctype is missing or deleted, or
      # (500) when its stored definition is corrupt.
      def self.call(db : DB::Connection, doctype_id : String) : Result | Facet::ServiceError
        definition = Doctype::DefinitionStore.fetch_uncached(db, doctype_id)
        return Facet::ServiceError.new(404, "Doctype '#{doctype_id}' not found") if definition.nil?

        issues = [] of Issue
        check_defaults(definition, issues)
        check_templates(definition, issues)
        check_actions(definition, issues)
        check_computed_fields(definition, issues)
        check_references(db, definition, issues)
        check_replication(db, definition, issues)
        check_children(db, definition, issues)
        check_sidecars(db, definition, issues)
        check_composition(db, definition, issues)
        check_views(db, definition, issues)

        Result.new(doctype_id: doctype_id, issues: issues)
      end

      # ── Private checks ──────────────────────────────────────

      # Notices about optional config that is absent. The two single-miss
      # notices are `:info` — the runtime degrades gracefully. A doctype
      # that declares NEITHER template is invisible to every search
      # surface (the cross-doctype search endpoint skips it; the bare
      # search filter matches only the document id). An aggregate root in
      # that state is an `:error` — the authoring gate refuses to create it
      # (B-296). An owned child is a notice: it is reached through its
      # parent, so the missing label degrades the child surfaces only.
      private def self.check_defaults(
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        # No `display_name` template: the projection's `display_name` column
        # stays NULL and the UI falls back to the first non-empty of
        # `name`/`title`/`label` content fields, then to the raw document
        # id (see `Capsule.deriveFallbackLabel` / `MockDataSource`).
        display_name = definition.display_name
        display_name_missing = display_name.nil? || display_name.empty?
        if display_name_missing
          issues << Issue.new(
            severity: :info,
            category: :defaults,
            field: nil,
            message: "No display_name template: document labels fall back to the first of " \
                     "the name/title/label content fields, then to the raw document id",
          )
        end

        # No `search` template: the write path stages the folded
        # display_name as the fallback corpus (B-115), so the bare `search`
        # filter matches the label. The template stays the opt-in for the
        # cross-doctype search endpoint and the agent tools.
        search = definition.search
        search_missing = search.nil? || search.empty?
        if search_missing
          if display_name_missing
            if definition.member_of.nil?
              issues << Issue.new(
                severity: :error,
                category: :defaults,
                field: nil,
                message: "No display_name and no search template: the cross-doctype search endpoint skips " \
                         "the doctype and the bare search filter matches only the document id — " \
                         "declare display_name (search defaults to it) or a search template",
              )
            else
              issues << Issue.new(
                severity: :info,
                category: :defaults,
                field: nil,
                message: "No display_name and no search template: the child is not searchable on its own — " \
                         "it is reached through its parent; declare display_name for a readable label",
              )
            end
          else
            issues << Issue.new(
              severity: :info,
              category: :defaults,
              field: nil,
              message: "No search template declared: search defaults to the display_name corpus; " \
                       "the cross-doctype search endpoint skips this doctype",
            )
          end
        end
      end

      # Doctypes whose declared actions are served by dedicated HTTP
      # routes that run no Lua — `Grants::Routes` activate/deactivate on
      # `core.DomainGrant`. The declared names exist for the RBAC manifest
      # only, so the script gate does not apply to them.
      ROUTE_SERVED_ACTION_DOCTYPES = %w[core.DomainGrant]

      # Warns when a definition declares named actions but ships no Lua
      # script. The authoring gate rejects this state (B-299); the warning
      # covers definitions published before the gate existed.
      private def self.check_actions(
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        script = definition.script
        return if definition.actions.empty?
        return unless script.nil? || script.empty?
        return if ROUTE_SERVED_ACTION_DOCTYPES.includes?(definition.qualified_name)

        issues << Issue.new(
          severity: :warning,
          category: :actions,
          field: nil,
          message: "Actions are declared but no script is defined — invoking any action answers 422; " \
                   "add the Lua script that implements them",
        )
      end

      # Warns when a definition declares computed (`data`) fields but ships
      # no Lua script. The authoring gate rejects this state (B-274); the
      # warning covers definitions published before the gate existed. On
      # such a definition the compute pass evaluates nothing and merges a
      # nil value, so the field disappears from every document write.
      private def self.check_computed_fields(
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        script = definition.script
        return if definition.computed_field_names.empty?
        return unless script.nil? || script.empty?

        issues << Issue.new(
          severity: :warning,
          category: :compute,
          field: nil,
          message: "Computed fields are declared but no script is defined — the fields stay unset on every write; " \
                   "add the Lua script that computes them",
        )
      end

      # A template without a single `{{` variable renders one literal for
      # every row — the `"$name"` typo class, where the author typed the
      # field name as plain text. The runtime accepts it silently, so the
      # check surfaces it as a warning per template.
      private def self.check_templates(
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        check_template_variable(definition, "search", definition.search, issues)
        check_template_variable(definition, "display_name", definition.display_name, issues)
      end

      private def self.check_template_variable(
        definition : DoctypeDefinition,
        name : String,
        template : String?,
        issues : Array(Issue),
      ) : Nil
        return if template.nil? || template.empty?
        return if template.includes?("{{")

        issues << Issue.new(
          severity: :warning,
          category: :template,
          field: name,
          message: "The #{name} template contains no '{{' variable — it renders one literal value for every row; " \
                   "a field reference looks like '{{ field_name }}'",
        )
      end

      # For each `reference`-typed field, ensure the target doctype is a
      # registered, non-deleted `core.DocType` projection. Missing targets
      # are surfaced as warnings — the document layer treats them as
      # "no matches" at runtime (the UI surfaces an empty list / not-found),
      # which is the intended behaviour per the no-runtime-enforcement
      # contract.
      private def self.check_references(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        reference_fields(definition.fields).each do |field_name, field_def|
          target = field_def.qualified_doctype
          next if target.nil?

          # Skip self-references within the same doctype (the doctype
          # exists by definition — it's the one being checked).
          next if target == definition.qualified_name

          # A bare doctype name is never expanded to the owning domain —
          # every value of the field fails the qualified-reference check
          # at write time. An error, not a warning: the domain is broken
          # until the definition names the qualified `domain.Doctype` form.
          unless target.includes?('.')
            issues << Issue.new(
              severity: :error,
              category: :reference,
              field: field_name,
              message: "Reference field '#{field_name}' declares a bare doctype name '#{target}' — declare the qualified '#{definition.domain}.#{target}' form; bare names match no registered doctype and every value of this field is rejected",
            )
            next
          end

          unless doctype_exists?(db, target)
            issues << Issue.new(
              severity: :warning,
              category: :reference,
              field: field_name,
              message: reference_target_missing_message(definition, field_name, target),
            )
          end
        end
      end

      # The remedy a missing reference target names. A `PATCH` on the
      # definition replaces the stored content outright — it would drop an
      # array item's target the same way a `PUT` of the GET body would — so
      # the supported edit is the flat authoring `PATCH`, which merges a
      # `fields` map over the stored definition (`Document::Update` on
      # `core.DocType`).
      private def self.reference_target_missing_message(
        definition : DoctypeDefinition,
        field_name : String,
        target : String,
      ) : String
        "Reference field '#{field_name}' targets doctype '#{target}' which is not a registered doctype — " \
        "register it, or repair the definition with " \
        "PATCH /Api/core/DocType/#{definition.qualified_name} {\"fields\": {\"#{field_name}\": {…}}}"
      end

      # Mirrors `Replication::Validator.validate` — each returned error
      # string becomes a warning issue under the `:replication` category.
      # The validator already covers `via` field existence/type, source
      # doctype existence, source field existence, type match, grant
      # coverage, tag coverage, and the draft-source-for-live-consumer
      # isolation check. The hard invariants are enforced at doctype
      # create/update time by `Replication::Validator.validate_invariants`.
      # `/check` repeats the tag-coverage check on purpose: a producer-side
      # edit that adds a tag to a replicated source field never re-runs
      # the consumer's hard gate, so the warning is the drift backstop.
      private def self.check_replication(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        rep_errors = ::Facet::Replication::Validator.validate(definition, db)
        rep_errors.each do |err|
          issues << Issue.new(
            severity: :warning,
            category: :replication,
            field: nil,
            message: err,
          )
        end
      end

      # For each `children` declaration, ensure the target doctype is
      # registered in the same domain. `ChildrenDefinition` forbids a
      # domain prefix (children are always same-domain), so the check
      # uses `definition.domain` plus the unqualified doctype name.
      private def self.check_children(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        definition.children.each do |rel_name, child_def|
          target_id = "#{definition.domain}.#{child_def.doctype}"
          next if target_id == definition.qualified_name

          unless doctype_exists?(db, target_id)
            issues << Issue.new(
              severity: :warning,
              category: :children,
              field: nil,
              message: "Child relationship '#{rel_name}' targets doctype '#{target_id}' which is not a registered doctype",
            )
          end
        end
      end

      # For each `sidecars` entry, ensure the target doctype is registered,
      # flagged `sidecar: true`, and has a reference field named by the
      # entry's `column`. Broken configs are surfaced as warnings — the
      # runtime silently skips them, per the no-runtime-enforcement
      # contract.
      private def self.check_sidecars(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        definition.sidecars.each do |segment, entry|
          target_def = Doctype::DefinitionStore.fetch_uncached(db, entry.doctype)
          if target_def.nil?
            issues << Issue.new(
              severity: :warning,
              category: :sidecar,
              field: "sidecars.#{segment}",
              message: "sidecar doctype '#{entry.doctype}' is not registered",
            )
            next
          end

          unless target_def.sidecar
            issues << Issue.new(
              severity: :warning,
              category: :sidecar,
              field: "sidecars.#{segment}",
              message: "sidecar doctype '#{entry.doctype}' is not flagged as sidecar: true",
            )
          end

          unless target_def.fields[entry.column]?.try(&.reference?)
            issues << Issue.new(
              severity: :warning,
              category: :sidecar,
              field: "sidecars.#{segment}",
              message: "sidecar doctype '#{entry.doctype}' has no reference field named '#{entry.column}'",
            )
          end
        end
      end

      # Surfaces composition-graph inconsistencies that schema-level
      # validation deliberately does not enforce. Three diagnostics:
      #
      # 1. **Composition reciprocity** — composition has one spelling:
      #    the parent declares `children:` AND the child declares
      #    `member_of` back. A one-sided edge is half-owned at runtime
      #    (no delete cascade, no copy walk, no event fan-out, no lock
      #    coupling), so both directions are flagged: a child declaring
      #    `member_of` whose parent has no matching `children:` entry,
      #    and a parent's `children:` entry whose target declares no
      #    `member_of` (the historical `crm.Deal`/`crm.Activity` hybrid).
      #    Publish and import reject one-sided edges outright — this
      #    check also covers definitions that never pass those gates.
      # 2. **Root mislabel** — a standalone doctype (no `member_of`, not
      #    declared as a child anywhere in this domain) that does not
      #    declare `aggregate_root: true`. The struct default makes the
      #    omission easy; the runtime then treats the doctype as its own
      #    aggregate root via the `resolve_aggregate_root` fallback.
      # 3. **Reference-vs-children conflict** — a `reference` (or
      #    array-of-reference) field must not target a doctype that is an
      #    owned child of this doctype (matched by `children:` entry or by
      #    the target declaring `member_of` back at this doctype). This
      #    flags owned children modelled as reference
      #    fields (e.g. the historical `hr.Candidate` definition).
      private def self.check_composition(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        check_composition_reciprocity(db, definition, issues)
        check_root_mislabel(db, definition, issues)
        check_composition_reference_conflict(db, definition, issues)
      end

      # (1) Composition reciprocity, both directions:
      # - a child declaring `member_of: Parent` requires the parent to
      #   declare a matching `children:` entry;
      # - a parent's `children:` entry requires its target to declare
      #   `member_of` back at this doctype.
      private def self.check_composition_reciprocity(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        # Child direction: member_of must be reciprocated by the parent's
        # children entry.
        if member_of = definition.member_of
          parent_id = "#{definition.domain}.#{member_of}"
          unless parent_id == definition.qualified_name
            parent_def = Doctype::DefinitionStore.fetch_uncached(db, parent_id)
            # Missing parent left to other checks.
            if parent_def && !parent_def.children.any? { |_, c| c.doctype == definition.doctype }
              issues << Issue.new(
                severity: :error,
                category: :composition,
                field: nil,
                message: "member_of '#{parent_id}' has no matching children entry for doctype '#{definition.doctype}' — composition must be mutual (children entry on the parent, member_of on the child)",
              )
            end
          end
        else
          # Parent direction: every children entry needs a member_of back.
          definition.children.each do |rel_name, child|
            child_id = "#{definition.domain}.#{child.doctype}"
            next if child_id == definition.qualified_name
            child_def = Doctype::DefinitionStore.fetch_uncached(db, child_id)
            # Missing child left to other checks (:children category).
            next if child_def.nil?
            next if child_def.member_of == definition.doctype

            issues << Issue.new(
              severity: :error,
              category: :composition,
              field: nil,
              message: "children entry '#{rel_name}' targets doctype '#{child_id}' which does not declare member_of '#{definition.doctype}' — composition must be mutual (children entry on the parent, member_of on the child)",
            )
          end
        end
      end

      # (2) Root mislabel: a doctype with no `member_of` that nobody in
      # its domain owns must declare `aggregate_root: true`. The struct
      # default (`aggregate_root: false`) makes the omission easy; the
      # runtime then silently treats the doctype as its own aggregate
      # root via the `resolve_aggregate_root` fallback.
      private def self.check_root_mislabel(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        return unless definition.member_of.nil?
        return if definition.aggregate_root

        # Owned here = some same-domain doctype declares a children entry
        # whose target is this doctype. `children.doctype` values are
        # bare names (same domain), so a text scan of the children map
        # is enough — the target appears as `"doctype":"<Name>"`.
        owned = db.scalar(
          "SELECT count(*) FROM projections " \
          "WHERE domain = $1 AND doc_type = 'DocType' AND deleted_at IS NULL " \
          "AND EXISTS (" \
          "  SELECT 1 FROM jsonb_each(content->'children') e " \
          "  WHERE e.value->>'doctype' = $2" \
          ")",
          definition.domain, definition.doctype,
        )
        return unless owned.as(Int64) == 0

        issues << Issue.new(
          severity: :warning,
          category: :composition,
          field: nil,
          message: "doctype '#{definition.qualified_name}' declares no member_of and no aggregate_root — declare aggregate_root: true for a standalone doctype, or member_of to name the aggregate it belongs to",
        )
      end

      # (3) A reference field must not duplicate an owned composition edge.
      private def self.check_composition_reference_conflict(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        definition.fields.each do |field_name, field_def|
          target = reference_target_for(field_def)
          next if target.nil?

          qualified = qualify_reference_target(target, definition)
          next if qualified == definition.qualified_name
          next unless child_of_this_doctype?(db, definition, qualified)

          issues << Issue.new(
            severity: :warning,
            category: :composition,
            field: field_name,
            message: "Reference field '#{field_name}' targets doctype '#{qualified}' which is a composition child of #{definition.qualified_name} — model it as a children: relationship, not a reference field",
          )
        end
      end

      # Returns the reference target doctype string for a direct reference
      # field or an array-of-reference field (via `items.type == reference`),
      # else nil. Mirrors the detection logic in `Document::Links`.
      private def self.reference_target_for(field_def : FieldDefinition) : String?
        return field_def.qualified_doctype if field_def.reference?

        items = field_def.items
        return items.try(&.qualified_doctype) if items.try(&.reference?)

        nil
      end

      # Qualifies a possibly-unqualified reference target (e.g. `"Task"`
      # in the same domain) into `"domain.Doctype"` form, leaving already
      # qualified targets (`"hr.Employee"`) untouched. Children are always
      # same-domain and unqualified, so qualification uses
      # `definition.domain`.
      private def self.qualify_reference_target(
        target : String,
        definition : DoctypeDefinition,
      ) : String
        return target if target.includes?('.')
        "#{definition.domain}.#{target}"
      end

      # True when `qualified_target` is an owned composition child of
      # `definition` — either declared as a `children:` entry (a) or
      # declaring `member_of` back at this doctype in the same domain (b).
      private def self.child_of_this_doctype?(
        db : DB::Connection,
        definition : DoctypeDefinition,
        qualified_target : String,
      ) : Bool
        # (a) declared as a child by name.
        return true if definition.children.any? do |_, c|
                         "#{definition.domain}.#{c.doctype}" == qualified_target
                       end

        # (b) the target declares member_of pointing back at this doctype,
        # in the same domain.
        target_def = Doctype::DefinitionStore.fetch_uncached(db, qualified_target)
        return false if target_def.nil?
        target_def.domain == definition.domain && target_def.member_of == definition.doctype
      end

      # ── View checks ──────────────────────────────────────────────────

      # Standard DocumentView kinds every doctype is expected to ship
      # (the fixture convention: view, form, quickView, inline, card).
      STANDARD_VIEW_KINDS = %w[view form quickView inline card]

      # What the frontend degrades to when a standard kind is absent.
      VIEW_KIND_FALLBACKS = {
        "view"      => "the show page falls back to a generic layout",
        "form"      => "the create/edit form falls back to a generic field list",
        "quickView" => "the peek drawer has no template",
        "inline"    => "relation rows fall back to the quickView template",
        "card"      => "chat and kanban cards fall back to the identity body",
      }

      # Validates every live `core.DocumentView` child of this doctype and
      # reports when a standard view kind is not defined. Template
      # structural problems come from `ViewTemplateValidator.validate` (severity
      # downgraded to warning — the check endpoint never blocks); missing
      # kinds are `:info` notices — they describe absent optional UI, not a
      # schema fault, and the frontend renders fallbacks for them (B-304).
      #
      # Every live `core.CollectionView` child is then validated through
      # `Document::CollectionViewGate.validate` — the same rule set the write
      # doors enforce — and each problem is reported as a `:warning` under
      # the `:view` category. The field path and the message carry the
      # surface config path, the field name, and the capability the field
      # lacks (a kanban `group_by` without `eq`, a calendar `discriminator`
      # without the window filter). Zero children get one `:info` notice.
      private def self.check_views(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        kinds = Set(String).new

        # The rows are materialized before validation: the validator resolves
        # relation targets through `Database.with_connection`, which pins the
        # SAME read-only connection inside this loop. A nested query on an
        # open result set interleaves its wire frames with the outer response
        # — the connection desyncs and the next statement reads garbage
        # (the /check 500 a `children`-source relation trips). Read both
        # columns, close the set, then validate.
        views = db.query_all(
          "SELECT content->>'kind', content->'template' FROM projections " \
          "WHERE domain = 'core' AND doc_type = 'DocumentView' " \
          "AND meta->>'parent_id' = $1 AND deleted_at IS NULL",
          definition.qualified_name,
          as: {String?, JSON::Any?},
        )
        views.each do |(kind, template)|
          kinds << kind if kind

          template_issues = ViewTemplateValidator.validate(template, definition)
          template_issues.each do |issue|
            issues << Issue.new(
              severity: :warning,
              category: :view,
              field: issue.path,
              message: "DocumentView '#{kind}': #{issue.message}",
            )
          end

          # A structurally broken template cannot be assessed for coverage —
          # the bindings the walk cannot see may exist on nodes the frontend
          # never renders. The validator's errors already tell the author
          # what to fix; the coverage warning would only repeat the noise.
          if kind && VIEW_COVERAGE_KINDS.includes?(kind) && template_issues.none?(&.severity.==(:error))
            check_template_field_coverage(definition, kind, template, issues)
          end
        end

        STANDARD_VIEW_KINDS.each do |kind|
          next if kinds.includes?(kind)
          issues << Issue.new(
            severity: :info,
            category: :view,
            field: kind,
            message: "No '#{kind}' DocumentView defined for #{definition.qualified_name} — #{VIEW_KIND_FALLBACKS[kind]}",
          )
        end

        check_collection_views(db, definition, issues)
      end

      # ── View field coverage ──────────────────────────────────────

      # The kinds the field-coverage warning applies to: the show page
      # (`view`) and the create/edit form (`form`). quickView, inline, and
      # card are summary surfaces — showing a subset of fields is their
      # purpose.
      private VIEW_COVERAGE_KINDS = Set{"view", "form"}

      # Warns when a `view` or `form` template does not reference every
      # field of the doctype (`ViewTemplateValidator.covered_fields` does
      # the counting). The domain-builder assistant reads the check output,
      # so this warning is what tells it a doctype edit left the views
      # behind. Per kind:
      #
      # - `view`: every declared field must show, computed and read-only
      #   included — a show page that hides data is a gap. `write_only`
      #   fields are excluded: the show page must not display them.
      # - `form`: every editable field must appear. Computed (`data`),
      #   `read_only`, and typeless fields are excluded — no input node can
      #   bind them (`ViewTemplateValidator` errors on such bindings) — and
      #   `dictionary` fields too (they have no input control), so
      #   requiring them would make the warning unfixable.
      #
      # A view without a template is skipped: the generic fallback renders
      # every field, so nothing is missing. A template the validator
      # reported `:error` issues on is skipped too — the structural errors
      # already name what to fix. One warning per view, with the missing
      # names in the message — one pass fixes them all.
      private def self.check_template_field_coverage(
        definition : DoctypeDefinition,
        kind : String,
        template : JSON::Any?,
        issues : Array(Issue),
      ) : Nil
        return if template.nil? # the generic fallback renders every field

        required = definition.fields.select do |_, field|
          if kind == "form"
            !(field.computed? || field.read_only? || field.type.nil? ||
              field.type.try(&.type_name) == "dictionary")
          else
            !field.write_only?
          end
        end
        return if required.empty?

        covered = ViewTemplateValidator.covered_fields(template, definition)
        missing = required.keys.reject { |name| covered.includes?(name) }
        return if missing.empty?

        verb = kind == "form" ? "edit" : "show"
        issues << Issue.new(
          severity: :warning,
          category: :view,
          field: kind,
          message: "DocumentView '#{kind}' on #{definition.qualified_name} does not list every field — " \
                   "add nodes that #{verb}: #{missing.join(", ")}",
        )
      end

      # Reports a `core.CollectionView` config the renderer cannot use as a
      # `:view` warning. The rules come from
      # `Document::CollectionViewGate.validate` — the write doors refuse the
      # same shapes with `422`, and the check endpoint downgrades them to a
      # warning (it never blocks).
      #
      # A doctype with **zero** live CollectionView children gets an `:info`
      # notice (not a warning): the listing renders the frontend starter
      # screen and there is nothing broken to fix — but the doctype has no
      # saved listing surface until someone creates a view. The notice
      # tells the author (and the domain-builder agent, which reads the
      # check output) to create one.
      private def self.check_collection_views(
        db : DB::Connection,
        definition : DoctypeDefinition,
        issues : Array(Issue),
      ) : Nil
        view_count = 0

        db.query(
          "SELECT content->>'name', content->>'surface', content->'config' FROM projections " \
          "WHERE domain = 'core' AND doc_type = 'CollectionView' " \
          "AND meta->>'parent_id' = $1 AND deleted_at IS NULL",
          definition.qualified_name,
        ) do |rs|
          rs.each do
            view_count += 1
            name = rs.read(String?)
            surface = rs.read(String?)
            config = rs.read(JSON::Any?)
            next if config.nil?

            Document::CollectionViewGate.validate(config, surface, definition).each do |error|
              issues << Issue.new(
                severity: :warning,
                category: :view,
                field: error.field,
                message: "CollectionView '#{name || surface}': #{error.message}",
              )
            end
          end
        end

        if view_count.zero?
          issues << Issue.new(
            severity: :info,
            category: :view,
            field: nil,
            message: "No CollectionView defined for #{definition.qualified_name} — the listing shows the view starter. Create at least one collection view (table, kanban, calendar, or grid) so the doctype has a listing surface.",
          )
        end
      end

      # ── Helpers ──────────────────────────────────────────────────────

      # Every reference-typed field reachable from the top-level `fields`
      # map, keyed by its dotted content path — the `items` / `properties` /
      # `values` sub-definitions included, so an array-of-reference target is
      # checked like a scalar one. Only the outermost reference of a branch
      # is yielded: a nested sub-definition below a reference field carries
      # no own target.
      private def self.reference_fields(
        fields : Hash(String, FieldDefinition),
        prefix : String? = nil,
        collected : Hash(String, FieldDefinition) = {} of String => FieldDefinition,
      ) : Hash(String, FieldDefinition)
        fields.each do |name, field|
          path = prefix ? "#{prefix}.#{name}" : name
          if field.reference? && !field.type.nil?
            collected[path] = field
            next
          end
          collect_nested_reference_fields(field, path, collected)
        end
        collected
      end

      private def self.collect_nested_reference_fields(
        field : FieldDefinition,
        path : String,
        collected : Hash(String, FieldDefinition),
      ) : Nil
        if items = field.items
          reference_fields({"items" => items}, path, collected)
        end
        if props = field.properties
          reference_fields(props, "#{path}.properties", collected)
        end
        if dict_value = field.dictionary_value
          reference_fields({"values" => dict_value}, path, collected)
        end
      end

      # Returns true if a non-deleted `core.DocType` projection exists for
      # the qualified id (e.g. `"identity.Person"`).
      private def self.doctype_exists?(db : DB::Connection, qualified_id : String) : Bool
        Util::Projections.exists?(db, "core", "DocType", qualified_id)
      end
    end
  end
end
