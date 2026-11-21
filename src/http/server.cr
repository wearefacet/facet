# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "http/params"
require "json"
require "pg"
require "kemal"
require "./helpers"
require "./responders"
require "./gates"
require "./caching"
require "./csrf_handler"
require "./auth_handler"
require "./metrics_handler"
require "./metrics_route"
require "./list_request"
require "./nested_path_resolver"
require "./rest_routes"
require "./secrets_routes"
require "./openapi"
require "./json_error_handler"
require "./domain_gate"
require "./healthcheck"
require "../telemetry"
require "../database"
require "../artifact/uploader"
require "../artifact/store"
require "../artifact/access"
require "../artifact/grants"
require "../artifact/purge"
require "../artifact/routes"
require "../app/routes"
require "../app/deploy"
require "../app/hosting"
require "../app/host_ask"
require "../document"
require "../doctype"
require "../audit"
require "../search"
require "../rbac"
require "../iam"
require "../iam/oidc/routes"
require "../settings"
require "../system_settings"
require "../notifications"
require "../dev/check_report"
require "../event"
require "../domain"
require "../grants"
require "../webhook"
require "../webhook/routes"
require "../assistant"
require "../assistant/domain_builder"
require "../assistant/workspace"
require "../oauth"
require "../mcp"
require "../agent_tools"
require "../domain/portable"
require "../import_export/routes"

module Facet
  module HTTP
    class Server
      @@routes_registered = false

      def self.routes : Nil
        return if @@routes_registered
        @@routes_registered = true

        # Request counter first — it wraps every other handler, so the
        # status it reads after `call_next` is the final one, and app-host
        # responses are counted too.
        Kemal.config.add_handler Facet::HTTP::MetricsHandler.new
        Kemal.config.add_handler Facet::Telemetry.middleware
        # Host-based dispatch of app deployments. Registered before every
        # other handler so a registered app host never reaches the API
        # middleware chain, and Facet's own hosts fall through before any
        # app lookup (see `App::Hosting` for the fixed dispatch order).
        Kemal.config.add_handler Facet::App::Hosting::Handler.new
        Kemal.config.add_handler JsonErrorHandler.new
        Kemal.config.add_handler DomainGate.new
        Kemal.config.add_handler Facet::OAuth::Cors.new
        # Global CSRF gate. Pure request inspection (method, cookie presence,
        # headers), so it sits directly in front of `AuthHandler` and never
        # depends on auth state. The per-route `require_csrf` calls stay as
        # defense in depth (see `CsrfHandler`).
        Kemal.config.add_handler CsrfHandler.new
        Kemal.config.add_handler AuthHandler.new
        Kemal.config.max_request_body_size = 200 * 1024 * 1024

        # ── Self-served error handlers ───────────────────────────────
        # Replace Kemal's default HTML `error 404` / `error 500` pages. This
        # is an API-first platform — every error is consumed by the frontend.
        #
        # The `error 404` handler is a no-op: routes render their own JSON
        # error bodies (see `Helpers.error_response` / `Helpers.write_result`),
        # and `JsonErrorHandler` renders the unmatched-route 404. Registering
        # it blocks Kemal's HTML default.
        #
        # The `error 500` handler is the catch-all for exceptions that escape
        # `JsonErrorHandler` — raised by a handler positioned before it in the
        # chain (`MetricsHandler`, the OpenTelemetry middleware,
        # `App::Hosting::Handler`), or by the error handler itself. It renders
        # the exception class as JSON and logs the full trace on `facet.http`
        # so the path stays debuggable — an empty body would give callers
        # nothing to act on.
        error 404 do |_env, _ex|
          ""
        end
        error 500 do |env, ex|
          message = ex.class.name
          Helpers::HTTP_LOG.error(exception: ex) do
            frames = ex.backtrace?.try(&.first(15))
            line = "#{env.request.method} #{env.request.path} → 500 #{message}"
            frames ? "#{line}\n#{frames.join("\n")}" : line
          end
          ({error: message}).to_json
        end

        # ── Healthcheck ────────────────────────────────────────────────
        Facet::HTTP::Healthcheck.register

        # ── Caddy On-Demand TLS ask endpoint (app hosts) ──────────────
        Facet::App::HostAsk.register

        # ── Metrics (Prometheus scrape endpoint) ──────────────────────
        Facet::HTTP::MetricsRoute.register

        # ── Document CRUD ────────────────────────────────────────────────
        Facet::Document::Routes.register

        # ── Artifacts (upload / metadata / grants / admin listing / serve) ─
        Facet::Artifact::Routes.register

        # ── Doctype ──────────────────────────────────────────────────────
        Facet::Doctype::Routes.register

        # ── Doctype maintenance (reproject / ahead migration jobs) ───────
        Facet::Doctype::MaintenanceRoutes.register

        # ── Index (managed-index status surface) ──────────────────────────
        Facet::Index::Routes.register

        # ── Audit ────────────────────────────────────────────────────────
        Facet::Audit::Routes.register

        # ── Search (cross-doctype, domain and app-wide) ──────────────────
        # Registered before the REST catch-all: the literal `search`
        # segment wins over `:doctype` by static-over-param precedence,
        # the same rule the Audit / Artifacts system routes exercise.
        Facet::Search::Routes.register

        # ── IAM ────────────────────────────────────────────────────
        Facet::IAM::Routes.register

        # ── OIDC (inbound federated login) ───────────────────
        Facet::IAM::OIDC::Routes.register

        # ── OAuth (app authorization code flow) ────────────────
        Facet::OAuth::Routes.register

        # ── MCP resource server (role-pinned endpoints) ─────────────────
        Facet::MCP::Routes.register

        # ── Settings (per-account preferences) ───────────────────────
        Facet::Settings::Routes.register

        # ── System settings (runtime platform configuration) ─────────
        # Registered before the REST catch-all: the flat
        # `/Api/SystemSettings` path is not a domain-scoped document URL.
        Facet::SystemSettings::Routes.register

        # ── Notifications (self-service inbox) ───────────────────────
        Facet::Notification::Routes.register

        # ── Dev check report (dev-only doctype validation report) ────
        Facet::Dev::CheckReportRoutes.register

        # ── OpenAPI surface (machine-readable API spec) ──────────────
        # Registered before the REST catch-all: `/Api/openapi.json` is not
        # a domain-scoped document URL (the reserved segment in the gate
        # mirrors this ordering).
        Facet::HTTP::OpenAPI.register

        # ── Assistant ────────────────────────────────────────────────
        Facet::Assistant::Routes.register
        Facet::Assistant::DomainBuilder::Routes.register
        Facet::Assistant::Workspace::Routes.register
        Facet::Assistant::App::Routes.register

        # ── Domain (draft / publish / check) ─────────────────────────────
        Facet::Domain::Routes.register

        # ── Portable-domain import/export (enqueue / status / download) ─
        # Registered BEFORE the document import/export routes: the
        # `/Api/core/Domain/import` and `/Api/core/Domain/import_export/:job_id`
        # URLs belong to the domain concern, never to the document
        # concern's flat routes for the `core.Domain` doctype.
        Facet::Domain::Portable::Routes.register

        # ── Webhook (delivery log / replay) ────────────────────────────
        Facet::Webhook::Routes.register

        # ── Secrets (out-of-band staging) ─────────────────────────────────
        Facet::HTTP::SecretsRoutes.register

        # ── App (backend-app API-key management) ────────────────────
        Facet::App::Routes.register

        # ── App (deployment: multipart build upload + activate) ────────
        Facet::App::Deploy.register

        # ── Document import/export (enqueue / status / download) ──────
        # Registered BEFORE the REST catch-all: the 4-segment
        # `import_export/:job_id` paths must not reach the nested-children
        # matcher with `import_export` read as a document id.
        Facet::ImportExport::Routes.register

        # ── Domain grants (activate / deactivate) ────────────────────
        # Registered BEFORE the REST catch-all: the 4-segment
        # `/Api/core/DomainGrant/:id/{activate,deactivate}` paths belong to
        # the grants concern, never to the nested-children matcher.
        Facet::Grants::Routes.register

        # ── REST catch-all (nested children) ─────────────────────
        Facet::HTTP::RestRoutes.register
      end
    end
  end
end
