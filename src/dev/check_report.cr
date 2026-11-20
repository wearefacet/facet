# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../error"
require "../http/helpers"
require "../domain/check"
require "./domain_watcher"

module Facet
  module Dev
    # In-process store of the last `Domain::Check` report per domain, fed by
    # the dev domain watcher's post-sync diagnostics. The watcher logs only
    # an issue count and the first message; this store keeps the full report
    # so the dev endpoint (`GET /Api/dev/check-report`) can serve it. When a
    # sync cycle's import fails instead, the store holds an import-failure
    # marker for the domain — the endpoint then serves the failed bundle's
    # diagnostics until a later cycle imports it or a check completes.
    #
    # Process-global and dev-only by design: the report lives in RAM (it
    # dies with the process), holds no secret material, and the endpoint
    # refuses to exist in production (the same `DomainWatcher.allowed?`
    # predicate the boot guard uses). Spec isolation relies on unique
    # domain names; `clear` exists for explicit resets.
    #
    # The issue shape mirrors the inline validation endpoint
    # (`GET /Api/core/Domain/:id/check`) one-to-one, so a client that reads
    # one reads the other.
    module CheckReport
      # A serialized diagnostic finding — the endpoint's issue shape.
      record Issue,
        severity : String,
        category : String,
        field : String?,
        message : String

      # One doctype's slice of the report: warning-severity issues and
      # informational notices, as the inline check route splits them.
      record DoctypeReport,
        doctype_id : String,
        issues : Array(Issue),
        notices : Array(Issue)

      # The full report of one completed check. `captured_at` says when the
      # watcher ran the check. A failed sync cycle replaces the report with
      # an `ImportFailure` marker, so a served report always describes the
      # store's last completed event for the domain.
      record Report,
        domain : String,
        captured_at : Time,
        issue_count : Int32,
        domain_issues : Array(Issue),
        doctypes : Array(DoctypeReport)

      # One failed bundle import, recorded by the watcher's sync cycle. A
      # diagnostic only: the failed import rolled back, so the domain keeps
      # its previous state and this marker names what the rejected bundle
      # broke. `doctypes` lists the failing bundle doctype(s) when the
      # import's error names them; `details` are the structured validation
      # errors, in the wire form every Facet error body uses.
      record ImportFailure,
        domain : String,
        captured_at : Time,
        status : Int32,
        message : String,
        doctypes : Array(String),
        details : Array(Facet::ValidationError)

      @@mutex = Mutex.new
      @@entries = {} of String => Report | ImportFailure

      # Records the result of a completed check. Clean domains store an
      # empty report too — "the last check ran and found nothing" must stay
      # distinct from "no check has run".
      def self.record(result : Domain::Check::Result) : Nil
        report = Report.new(
          domain: result.domain,
          captured_at: Time.utc,
          issue_count: result.domain_issues.size + result.doctypes.sum(&.issues.size),
          domain_issues: result.domain_issues.map { |issue| serialize(issue) },
          doctypes: result.doctypes.map do |doctype|
            DoctypeReport.new(
              doctype_id: doctype.doctype_id,
              issues: doctype.issues.map { |issue| serialize(issue) },
              notices: doctype.notices.map { |notice| serialize(notice) },
            )
          end,
        )
        @@mutex.synchronize { @@entries[result.domain] = report }
      end

      # Records a failed bundle import. Replaces any stored entry — the
      # endpoint serves the latest event for the domain, and a failed import
      # is what an operator debugs first. `doctypes` names the failing
      # bundle doctype(s); the watcher derives them from the import error.
      def self.record_import_failure(domain : String, error : Facet::ServiceError, doctypes : Array(String)) : Nil
        failure = ImportFailure.new(
          domain: domain,
          captured_at: Time.utc,
          status: error.status,
          message: error.message,
          doctypes: doctypes,
          details: error.details || [] of Facet::ValidationError,
        )
        @@mutex.synchronize { @@entries[domain] = failure }
      end

      # Drops a domain's stored entry (report or import-failure marker)
      # after a failed or raised check — a stale entry read as current
      # would misdirect debugging.
      def self.record_failure(domain : String) : Nil
        @@mutex.synchronize { @@entries.delete(domain) }
      end

      def self.fetch(domain : String) : Report | ImportFailure?
        @@mutex.synchronize { @@entries[domain]? }
      end

      # Empties the store. Spec-isolation aid, not a runtime path.
      def self.clear : Nil
        @@mutex.synchronize { @@entries.clear }
      end

      # Serializes the report in the inline check endpoint's envelope and
      # issue shape (`data` → `domain`, `issue_count`, `domain_issues`,
      # `doctypes`), plus `captured_at` — the one field the watcher report
      # has and the live check does not.
      def self.to_json(report : Report) : String
        JSON.build do |json|
          json.object do
            json.field "data" do
              json.object do
                json.field "domain", report.domain
                json.field "captured_at", report.captured_at.to_rfc3339
                json.field "issue_count", report.issue_count
                json.field "domain_issues" do
                  json.array do
                    report.domain_issues.each { |issue| write_issue(json, issue) }
                  end
                end
                json.field "doctypes" do
                  json.array do
                    report.doctypes.each do |doctype|
                      json.object do
                        json.field "doctype_id", doctype.doctype_id
                        json.field "issue_count", doctype.issues.size
                        json.field "issues" do
                          json.array do
                            doctype.issues.each { |issue| write_issue(json, issue) }
                          end
                        end
                        json.field "notices" do
                          json.array do
                            doctype.notices.each { |notice| write_issue(json, notice) }
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      # Serializes an import-failure marker. The envelope stays `data`, the
      # shape stays disjoint from the check report's, and `kind` names the
      # difference: a client branches on `kind == "import_failure"` and
      # reads `status`, `message`, `doctypes`, and `details` (the standard
      # validation-error wire form) instead of the issue arrays.
      def self.to_json(entry : ImportFailure) : String
        JSON.build do |json|
          json.object do
            json.field "data" do
              json.object do
                json.field "kind", "import_failure"
                json.field "domain", entry.domain
                json.field "captured_at", entry.captured_at.to_rfc3339
                json.field "status", entry.status
                json.field "message", entry.message
                json.field "doctypes" do
                  json.array do
                    entry.doctypes.each { |doctype| json.string(doctype) }
                  end
                end
                json.field "details" do
                  json.array do
                    entry.details.each(&.to_json(json))
                  end
                end
              end
            end
          end
        end
      end

      private def self.serialize(issue : Domain::Check::Issue) : Issue
        Issue.new(issue.severity.to_s, issue.category.to_s, issue.field, issue.message)
      end

      private def self.write_issue(json : JSON::Builder, issue : Issue) : Nil
        json.object do
          json.field "severity", issue.severity
          json.field "category", issue.category
          field = issue.field
          json.field "field", field unless field.nil?
          json.field "message", issue.message
        end
      end
    end

    # Dev-only HTTP surface for the watcher's stored check reports:
    # `GET /Api/dev/check-report?domain=<id>`.
    #
    # Guards, in order:
    #
    # 1. **Dev only.** The same `DomainWatcher.allowed?` predicate the boot
    #    guard uses — in production the route answers a bare 404, so the
    #    surface does not exist there. No per-doctype RBAC runs behind it:
    #    the report is process-local dev data, not a projection read, and
    #    the route never answers in production.
    # 2. **Authentication** — the standard `AuthHandler` chain (the path is
    #    not a public route) answers 401 for an invalid credential, and the
    #    handler adds the explicit account gate the other control-plane GETs
    #    use (`HTTP::Helpers.require_account`) — a credential-less request
    #    never reaches the body, so the anonymous principal cannot read the
    #    report (the report is unscoped per-account).
    #
    # No check yet (or a failed last check) answers 404 with the standard
    # error envelope: the store holds no report, and a fabricated empty
    # report would read as "the last check found nothing". A stored
    # import-failure marker answers 200 with the failure shape (see
    # `CheckReport.to_json(ImportFailure)`).
    module CheckReportRoutes
      def self.register : Nil
        get "/Api/dev/check-report" do |env|
          handle(env)
        end
      end

      private def self.handle(env) : Nil
        unless Facet::Dev::DomainWatcher.allowed?(Facet::Config.app_env)
          return HTTP::Helpers.error_response(env, 404, "Not found")
        end

        # Same gate as the other control-plane GETs (`HTTP::OpenAPI.handle`):
        # the `AuthHandler` chain answers 401 for an invalid credential, and
        # this guard rejects a credential-less request before the body.
        HTTP::Helpers.require_account(env) || return

        domain = env.params.query["domain"]?
        if domain.nil? || domain.empty?
          return HTTP::Helpers.error_response(env, 422, "Missing 'domain' query parameter")
        end

        report = Facet::Dev::CheckReport.fetch(domain)
        if report.nil?
          return HTTP::Helpers.error_response(
            env, 404,
            "No check report for domain '#{domain}' — the dev domain watcher has not completed a check for it yet",
          )
        end

        HTTP::Helpers.write_json(env, 200, Facet::Dev::CheckReport.to_json(report))
      end

      # Registers from `HTTP::Server.routes` next to the other route
      # modules — the explicit call keeps one registration site for every
      # Kemal route in the process.
    end
  end
end
