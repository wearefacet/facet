# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/check"
require "../doctype/definition_store"
require "../doctype/doctype_definition"
require "../doctype/validation"
require "../hooks/validator"
require "../error"
require "../util/projections"
require "./publish_gate"

module Facet
  module Domain
    # Aggregate diagnostics for a draft domain.
    #
    # Runs `Doctype::Check.call` for every non-deleted `core.DocType`
    # projection whose `content->>'domain'` matches the supplied domain id
    # and collects the per-doctype issues into a single result. The domain
    # itself may be live or draft — the service is read-only and has no
    # opinion on the draft flag — but it is consumed today by the Builder
    # editor and dashboard, which only surface it for drafts.
    #
    # Read-only — uses a plain `Database.with_db` connection (no transaction,
    # no events flushed). Authorisation is the caller's responsibility (the
    # HTTP route gates it via `RBAC::WriteEnforcer.authorize_update` against
    # `core.Domain`, mirroring the publish endpoint's audience).
    #
    # ## Domain-level warnings
    #
    # A small set of domain-level diagnostics that do not belong to any
    # single doctype are surfaced under `domain_issues`:
    #
    # - `:no_doctypes` — the domain has zero registered doctypes (a draft
    #   with no structure to publish).
    # - `:hooks` — any hook declared on the domain fails authoring-time
    #   validation (script compile, required export, cron shape). Mirrors
    #   how `:replication` mirrors `Replication::Validator`.
    # - `:rbac` — a role permission line carries a scope on the literal
    #   `create` action. The enforcer never applies a scope at create time
    #   (no row exists); the line is an intent channel a Lua create hook or
    #   a Crystal create gate must implement. Runs for the `iam` domain
    #   check only — role permissions are installation-global, and
    #   surfacing them on every domain check would pollute unrelated
    #   drafts.
    #
    # Per-doctype results split `Doctype::Check` output into two lists:
    # `issues` (non-informational severities — what the aggregate's
    # `issue_count` counts) and `notices` (informational `:defaults`
    # notices and missing standard view kinds). An `:error` issue (the
    # B-296 template gate on an aggregate root) stays in `issues` with its
    # severity intact.
    module Check
      # A single diagnostic finding, mirroring `Doctype::Check::Issue`.
      record Issue,
        severity : Symbol, # `:error` for the template gate (B-296), `:warning` for actionable problems, `:info` for `:defaults` notices
        category : Symbol, # `:reference`, `:replication`, `:children`, `:composition`, `:defaults`, `:no_doctypes`, `:publish_gate`, `:hooks`, `:rbac`
        field : String?,
        message : String

      # Per-doctype slice of the aggregated result.
      record DoctypeResult,
        doctype_id : String,
        issues : Array(Issue), # non-informational issues only
        notices : Array(Issue) # informational notices only (`:defaults`, missing standard view kinds)

      record Result,
        domain : String,
        domain_issues : Array(Issue),
        doctypes : Array(DoctypeResult)

      # Runs all diagnostic checks against the doctypes owned by `domain`.
      # Returns `Error` (404) if the `core.Domain` document does not exist
      # or is deleted.
      def self.call(db : DB::Connection, domain : String) : Result | Facet::ServiceError
        # True when a non-deleted `core.Domain` projection owns the id.
        unless Util::Projections.exists?(db, "core", "Domain", domain)
          return Facet::ServiceError.new(404, "Domain '#{domain}' not found")
        end

        doctype_ids = list_doctype_ids(db, domain)
        domain_issues = [] of Issue
        if doctype_ids.empty?
          domain_issues << Issue.new(
            severity: :warning,
            category: :no_doctypes,
            field: nil,
            message: "Domain '#{domain}' has no registered doctypes",
          )
        end

        # Domain-level hook validation — read-only, no DB. Mirrors the
        # authoring-time gate in `Document::Update.validate_domain_hooks?`
        # but as a diagnostic rather than a hard 422.
        domain_issues.concat(check_hooks(db, domain))

        # Role-permission lint: scoped create lines are legal intent
        # channels, but the enforcer never applies them — role authors get
        # one warning per line. Runs for the `iam` domain check only.
        domain_issues.concat(check_role_permissions(db)) if domain == "iam"

        doctype_results = doctype_ids.map do |doctype_id|
          # A corrupt or unparseable definition raises from
          # `DoctypeDefinition.from_json` inside `DefinitionStore.fetch_uncached`.
          # Surface it as a single :composition warning so the aggregate call
          # never hard-fails on one bad doctype. A missing doctype returns
          # `Doctype::Check::Error` via the normal `case` dispatch below.
          res_or_err = begin
            Doctype::Check.call(db, doctype_id)
          rescue ex : Exception
            Facet::ServiceError.new(500, ex.message || "unknown error")
          end
          issues = case res_or_err
                   when Doctype::Check::Result
                     res_or_err.issues
                       .reject { |i| i.severity == :info }
                       .map { |i| Issue.new(i.severity, i.category, i.field, i.message) }
                   else
                     [
                       Issue.new(
                         severity: :warning,
                         category: :composition,
                         field: nil,
                         message: "Could not load definition for '#{doctype_id}': #{res_or_err.message}",
                       ),
                     ]
                   end
          notices = case res_or_err
                    when Doctype::Check::Result
                      res_or_err.issues
                        .select { |i| i.severity == :info }
                        .map { |i| Issue.new(i.severity, i.category, i.field, i.message) }
                    else
                      [] of Issue
                    end

          # Append publish-gate diagnostics when the draft was derived from
          # a live source domain.
          if source_domain = check_source_domain(db, domain)
            if gate_issues = check_publish_gate(db, source_domain, doctype_id)
              issues.concat(gate_issues)
            end
          end

          DoctypeResult.new(doctype_id: doctype_id, issues: issues, notices: notices)
        end

        Result.new(domain: domain, domain_issues: domain_issues, doctypes: doctype_results)
      end

      # ── Hooks diagnostics ─────────────────────────────────────────────

      # Loads the `core.Domain` projection content and runs `Hooks::Validator`
      # against any declared `hooks`. Each resulting `ValidationError` becomes
      # a `:hooks` warning. Returns an empty array when the domain has no
      # `hooks` field or all hooks are valid.
      private def self.check_hooks(db : DB::Connection, domain : String) : Array(Issue)
        content = db.query_one?(
          "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL",
          domain,
          as: JSON::Any,
        )
        return [] of Issue if content.nil?

        hooks, parse_errors = Facet::Hooks::Definition.parse(content)
        validation_errors = Facet::Hooks::Validator.validate(hooks)
        (parse_errors + validation_errors).map do |err|
          Issue.new(
            severity: :warning,
            category: :hooks,
            field: err.field,
            message: err.message,
          )
        end
      end

      # ── Role-permission diagnostics ─────────────────────────────────────

      # Scans the live `iam.Roles` documents for permission lines whose
      # action is the literal `create` and whose scope is non-empty, and
      # maps each `RBAC::Validator.scoped_create_warnings` result to an
      # `:rbac` warning naming the role. Role content that holds no
      # `permissions` array, or lines that fail to parse, are skipped — the
      # authoring-time validator rejects those shapes on the write path.
      private def self.check_role_permissions(db : DB::Connection) : Array(Issue)
        sql = <<-SQL
          SELECT id, content->'permissions' FROM projections
          WHERE domain = 'iam' AND doc_type = 'Roles'
            AND deleted_at IS NULL
          ORDER BY id ASC
        SQL
        roles = db.query_all(sql) do |rs|
          rs.read(String, JSON::Any?)
        end

        issues = [] of Issue
        roles.each do |role_id, perms_raw|
          next unless perms = perms_raw.try(&.as_a?)
          warnings = [] of Facet::ValidationError
          RBAC::Validator.scoped_create_warnings(perms, warnings)
          warnings.each do |warning|
            issues << Issue.new(
              severity: :warning,
              category: :rbac,
              field: warning.field,
              message: "Role '#{role_id}': #{warning.message}",
            )
          end
        end
        issues
      end

      # ── Publish-gate diagnostics ─────────────────────────────────────────

      # Returns the `source_domain` value from the domain's `core.Domain`
      # content when the domain is a draft derived from a live domain, or
      # `nil` for freestanding drafts (no publish-overwrite gate to check).
      private def self.check_source_domain(db : DB::Connection, domain : String) : String?
        row = db.query_one?(
          <<-SQL,
            SELECT content->>'source_domain' FROM projections
            WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1
              AND content->>'draft' = 'true'
              AND content->>'source_domain' IS NOT NULL
              AND deleted_at IS NULL
          SQL
          domain,
          as: String?,
        )
        row
      end

      # Runs the same version gate as the publish action but as a read-only
      # diagnostic. Compares the draft doctype definition against the live
      # source domain's definition. Returns an array of `:publish_gate`
      # issues (may be empty) or `nil` when the target doctype does not
      # exist in the source (no gate to report).
      private def self.check_publish_gate(
        db : DB::Connection,
        source_domain : String,
        doctype_id : String,
      ) : Array(Issue)?
        # doctype_id is "{draft}.{Doctype}" — extract the doctype name.
        parts = doctype_id.split('.', 2)
        return nil if parts.size < 2
        doctype = parts[1]

        live_id = "#{source_domain}.#{doctype}"
        live_def = Doctype::DefinitionStore.fetch_uncached(db, live_id)
        return nil if live_def.nil?

        # Load the draft definition. If it fails to parse, skip (the parent
        # loop already surfaced the corrupt-definition issue).
        draft_def = Doctype::DefinitionStore.fetch_uncached(db, doctype_id)
        return nil if draft_def.nil?

        # The gate names the doctype by its draft-qualified id and scopes
        # the message to the source domain — the diagnostic wording.
        problems = PublishGate.check(
          db, live_def, draft_def, source_domain,
          subject_id: doctype_id,
          context: "'#{source_domain}'",
        )
        return nil if problems.empty?

        issues = [] of Issue
        problems.each do |problem|
          if problem.kind == :schema_version
            issues << Issue.new(
              severity: :warning,
              category: :publish_gate,
              field: nil,
              message: problem.message,
            )
          else
            issues << Issue.new(
              severity: :warning,
              category: :publish_gate,
              field: problem.field,
              message: "Doctype '#{doctype_id}': #{problem.message}",
            )
          end
        end
        issues
      end

      # ── Private ──────────────────────────────────────────────────────

      # Lists the qualified ids (`{domain}.{Doctype}`) of every non-deleted
      # `core.DocType` projection whose content declares itself a member of
      # `domain`. The id stored on `core.DocType` is the qualified form
      # (e.g. `_abc.Order`) so the result is taken straight from `id`.
      private def self.list_doctype_ids(db : DB::Connection, domain : String) : Array(String)
        db.query_all(
          <<-SQL,
            SELECT id FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType'
              AND content->>'domain' = $1
              AND deleted_at IS NULL
            ORDER BY id ASC
          SQL
          domain,
          as: String,
        )
      end
    end
  end
end
