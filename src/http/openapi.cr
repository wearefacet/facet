# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "./helpers"

module Facet
  module HTTP
    # Machine-readable API surface: OpenAPI 3.0.3.
    #
    # v1 is a **declarative slice**: the paths, methods, summaries, and status
    # codes below are hand-maintained (the shapes live in `doc/backend/*.md`),
    # and the module mechanically validates the declarations against the live
    # Kemal route table — a Radix tree walk over
    # `Kemal::RouteHandler::INSTANCE.routes` (tree keys are `/METHOD/path`, so
    # one payload per declared method+path). A declared route missing from the
    # table, an undeclared method on a declared path, or a new route inside the
    # v1 scope raises a drift error. The check runs in `scripts/gen_openapi.cr`
    # (CI drift job), in `spec/http/openapi_spec.cr`, and on the first request
    # the served route sees after boot.
    #
    # The v1 scope covers the document CRUD routes, the audit
    # history/rollback/restore routes, four IAM account routes, secret
    # staging, document import/export, and the platform operator surfaces
    # (managed indexes, artifact administration, system settings). Roles are
    # `iam.Roles` documents — they ride the document CRUD routes, not
    # dedicated IAM paths. Everything else (nested-children catch-all,
    # actions, search, settings, notifications, webhooks, apps, the
    # assistant, OAuth, MCP, ...) is out of scope and is ignored by the
    # check.
    #
    # Three surfaces stay out by decision, not by omission:
    # - MCP (`/Api/_mcp/...`) is not an API surface — it is the agent data
    #   plane, documented in `doc/backend/mcp.md`.
    # - OAuth (`/OAuth/...`) and the assistant (`/Api/assistant/...`) are
    #   outside the declarative slice.
    # Adding a route under one of those prefixes does not raise drift.
    #
    # This module registers its route from `HTTP::Server.routes`, next to
    # the other route modules. The spec object itself is built at boot — it
    # is static and never rebuilt per request.
    #
    # The QUERY method (RFC 10008) has no operation key in OpenAPI 3.0; each
    # QUERY twin is emitted as the `x-query` extension on its path item.
    module OpenAPI
      Log = ::Log.for("facet.http.openapi")

      SPEC_PATH       = "/Api/openapi.json"
      OPENAPI_VERSION = "3.0.3"

      # One HTTP operation on one path template. `method` is the Kemal method
      # (upcase; QUERY twins live in `PathSpec#query`, not here). `forbidden`
      # overrides the default 403 response text when the route has write-plane
      # refusal classes. `body` describes the request body when the route
      # requires one; `nil` documents no body contract.
      record Op,
        method : String,
        summary : String,
        statuses : Array(Int32),
        description : String? = nil,
        forbidden : String? = nil,
        body : String? = nil

      # One path template. `query` carries the RFC 10008 QUERY twin when the
      # route family supports it.
      record PathSpec,
        kemal_path : String,
        tag : String,
        ops : Array(Op),
        query : Op? = nil

      # Shared response texts. Route-specific 403 text comes from `Op#forbidden`.
      private STATUS_TEXT = {
        200 => "Success — JSON body per the response shape noted on the operation.",
        201 => "Created — the stored document in `{ data, meta }` form.",
        202 => "Accepted — the job is queued; the body carries its id and status URL.",
        204 => "Deleted — no body.",
        304 => "Not modified — the ETag matched (see doc/backend/http-layer.md, HTTP caching).",
        400 => "Malformed request transport.",
        401 => "Authentication required — missing or invalid credential.",
        403 => "Forbidden — RBAC denial.",
        404 => "Not found — non-disclosing.",
        409 => "Conflict.",
        410 => "Gone — the document is a delete tombstone (`X-Document-Deleted: true`).",
        413 => "Payload too large — the upload exceeds `artifact.max_upload_bytes`.",
        415 => "Unsupported media type.",
        422 => "Validation failed — `{ error, details }` body.",
        502 => "Upstream failure — a remote dependency refused or failed the request; the message carries its own error.",
      }

      # The v1 scope. Status codes verified against `src/http/responders.cr`
      # and the route handlers (document CRUD: `src/document/routes.cr`; audit:
      # `src/audit/routes.cr` + `src/audit/list.cr`; IAM: `src/iam/routes.cr`;
      # secrets: `src/http/secrets_routes.cr`; import/export:
      # `src/import_export/routes.cr` + `staging.cr`; platform:
      # `src/index/routes.cr`, `src/artifact/routes.cr`,
      # `src/system_settings/routes.cr`).
      DECLARATIONS = [
        PathSpec.new(
          "/Api/:domain/:doctype", "Documents",
          [
            Op.new("GET", "List documents of one doctype",
              [200, 304, 401, 403, 404, 422],
              description: "Paginated, filtered, sorted list in `{ data, meta }` form. `?deleted=true` switches to the trash listing. ETag validators apply. `403` — the caller holds no read permission on the doctype at all; a read grant always yields the (possibly empty) scope-narrowed list.",
            ),
            Op.new("POST", "Create a document",
              [201, 401, 403, 404, 409, 422],
              description: "Creates a document and returns it in `{ data, meta }` form. `409` is doctype-registration specific: a duplicate `(domain, doctype)` on `core.DocType`.",
              forbidden: "Forbidden — RBAC denial, or the write-plane refusals: `Write refused: invisible field` and `Role authority refused this write` (IAM doctypes).",
              body: "JSON document content.",
            ),
          ],
          query: Op.new("QUERY", "List documents (QUERY variant)",
            [200, 403, 400, 415, 422],
            description: "Same list as GET with the parameters in a JSON body only — query-string parameters answer `422`, a non-JSON body media type answers `415`. The `403` matches the GET list: no read permission on the doctype at all.",
          ),
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/:id", "Documents",
          [
            Op.new("GET", "Read one document",
              [200, 304, 401, 403, 404, 410],
              description: "Single-document read in `{ data, meta }` form; lazy migration applies on read. ETag validators apply. `403` — no read permission on the doctype at all. `404` — the document is missing, or invisible to a caller that holds a read grant (non-disclosing: an inaccessible document is indistinguishable from a missing one). `410` marks a delete tombstone.",
            ),
            Op.new("PATCH", "Update a document",
              [200, 401, 403, 404, 410, 422],
              description: "JSON merge patch (RFC 7386): `null` removes a key. Returns the updated document in `{ data, meta }` form. A scoped update grant whose row check fails answers `404` — an inaccessible document is indistinguishable from a missing one; `403` is the class-level denial (no update permission on the doctype at all).",
              forbidden: "Forbidden — RBAC denial (no update permission on the doctype at all), or the write-plane refusals: `Write refused: invisible field` and `Role authority refused this write` (IAM doctypes).",
              body: "JSON merge patch body.",
            ),
            Op.new("DELETE", "Soft-delete a document",
              [204, 401, 403, 404, 410, 422],
              description: "Tombstones the document; history and rollback stay available. `422` on `core.Domain` (a lone tombstone would orphan the domain).",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/:id/history", "Audit",
          [
            Op.new("GET", "Document mutation history",
              [200, 401, 403, 404, 422],
              description: "Mutation log of one document in `{ data, meta }` form. Every row carries the out-of-band `redacted` metadata — the content paths removed from `arguments` for the calling principal; no `__redacted__` markers enter the content itself. `?include=children` merges readable child rows into the timeline. `403` — no read permission on the doctype at all; `404` — a grant holder cannot see the document (non-disclosing).",
            ),
          ],
          query: Op.new("QUERY", "Document mutation history (QUERY variant)",
            [200, 403, 404, 400, 415, 422],
            description: "Same list as GET with the parameters in a JSON body only — query-string parameters answer `422`, a non-JSON body media type answers `415`. The `403` / `404` split matches the GET history.",
          ),
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/:id/backrefs", "Documents",
          [
            Op.new("GET", "Documents referencing this document (backlinks)",
              [200, 401, 403, 404, 422],
              description: "Live documents whose `links` column contains this document's URN, in `{ data, meta: { target, total, capped } }` form with stub rows (`id`, `domain`, `doc_type`, `display_name`). Target read gate: `404` for a missing or invisible target (non-disclosing), `403` when the caller holds no read grant on the target doctype at all. Referrer rows stay inside each doctype's list visibility. `items` caps the result (server max 1000).",
            ),
          ],
          query: Op.new("QUERY", "Documents referencing this document (QUERY variant)",
            [200, 403, 404, 400, 415, 422],
            description: "Same list as GET with the parameters in a JSON body only — query-string parameters answer `422`, a non-JSON body media type answers `415`. The `403` / `404` split matches the GET backrefs.",
          ),
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/:id/rollback", "Audit",
          [
            Op.new("POST", "Roll a document back to one mutation",
              [200, 401, 403, 404, 422],
              description: "Replays the state at the named mutation. `scope: \"cluster\"` undoes the whole request cluster. Returns the restored document in `{ data, meta }` form.",
              body: "`{ \"mutation_id\": \"…\", \"scope\": \"document\"|\"cluster\" }` — `mutation_id` required.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/:id/restore", "Audit",
          [
            Op.new("POST", "Restore a deleted document",
              [200, 401, 403, 404, 409, 422],
              description: "Resolves the pre-delete mutation internally and rolls back to it. `409` when the document is not deleted; `422` when no restorable target exists. Empty body by design.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/:id/:child/:child_id/history", "Audit",
          [
            Op.new("GET", "Child document mutation history",
              [200, 401, 403, 404, 422],
              description: "Mutation log of one nested-child document — the same shape as the parent history, `redacted` metadata included. `403` — no read permission on the doctype at all; `404` — a grant holder cannot see the document (non-disclosing).",
            ),
          ],
          query: Op.new("QUERY", "Child document mutation history (QUERY variant)",
            [200, 403, 404, 400, 415, 422],
            description: "Same list as GET with the parameters in a JSON body only. The `403` / `404` split matches the GET history.",
          ),
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/:id/:child/:child_id/rollback", "Audit",
          [
            Op.new("POST", "Roll a child document back to one mutation",
              [200, 401, 403, 404, 422],
              description: "Replays the state at the named mutation. Returns the restored child document in `{ data, meta }` form.",
              body: "`{ \"mutation_id\": \"…\" }` — required.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/Audit", "Audit",
          [
            Op.new("GET", "Global audit log",
              [200, 401, 403, 422],
              description: "All mutations across domains, paginated, in `{ data, meta }` form. Requires wildcard read; rows carry the `redacted` metadata.",
            ),
          ],
          query: Op.new("QUERY", "Global audit log (QUERY variant)",
            [200, 403, 400, 415, 422],
            description: "Same list as GET with the parameters in a JSON body only.",
          ),
        ),
        PathSpec.new(
          "/Api/Audit/:mutation_id/rollback", "Audit",
          [
            Op.new("POST", "Global rollback to one mutation",
              [200, 401, 403, 404, 422],
              description: "Replays the state at the named mutation. `scope: \"cluster\"` answers `{ trace, count, documents }` instead of one document.",
              body: "`{ \"scope\": \"document\"|\"cluster\" }` — optional; defaults to `document`.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/iam/me", "IAM",
          [
            Op.new("GET", "Authenticated account profile",
              [200, 401],
              description: "Profile, token expiration, permission manifest, and assistant availability of the authenticated account.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/iam/accounts/credential-states", "IAM",
          [
            Op.new("GET", "Credential states of accounts",
              [200, 401, 403, 422],
              description: "One credential-state entry per `?id=` query parameter (repeatable). Operator read for the account admin table.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/iam/accounts/:id/temporary-password", "IAM",
          [
            Op.new("POST", "Generate a temporary password",
              [200, 401, 403, 422],
              description: "Operator action: generates a temporary password for an invited account. `422` for unknown, disabled, or service accounts.",
              body: "Empty body.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/iam/accounts/:id/invite", "IAM",
          [
            Op.new("POST", "Email a single-use invite link",
              [200, 401, 403, 422],
              description: "Operator action: emails a single-use invite link; a second invite replaces the pending one. `422` for unknown or service accounts.",
              body: "Empty body.",
            ),
          ],
        ),

        # ── Secrets ─────────────────────────────────────────────────────
        PathSpec.new(
          "/Api/secrets/stage", "Secrets",
          [
            Op.new("POST", "Stage a secret value out of band",
              [201, 401, 403, 404, 422],
              description: "Stores the value in `secret_staging` and answers `{ handle, token? }`. The handle is single-use and TTL-bound; the client puts it into the document instead of the value. `403` — the caller is the system principal or an API key (a handle is a session-bound capability), the session has no `X-Requested-With` header, or the caller holds neither `create` on the doctype nor `update` on the `doc_id` it names. `404` (non-disclosing) — unknown doctype, a field path that is not a `secret` leaf, a `view` tag the caller cannot see, or an unknown secret mode. `422` — missing or invalid body, plaintext rejected by the definition's `min`/`max`/`pattern`, or a value supplied for a server-generated `token` secret.",
              forbidden: "Forbidden — the system principal and API keys never stage a secret (a handle is user-bound), a cookie session without the `X-Requested-With` header fails the CSRF check, or the caller holds neither `create` on the doctype nor `update` on the named document.",
              body: "`{ \"domain\": \"…\", \"doctype\": \"…\", \"field_path\": \"…\", \"doc_id\": \"…\", \"value\": \"…\" }` — `domain`, `doctype`, and `field_path` required; `value` is required for `hash` / `sealed` and must be absent for `token`.",
            ),
          ],
        ),

        # ── Import/Export ────────────────────────────────────────────────
        PathSpec.new(
          "/Api/:domain/:doctype/export", "Import/Export",
          [
            Op.new("POST", "Enqueue a document export",
              [202, 401, 403, 404, 422],
              description: "Validates `?format=` (`csv` or `json`) and the filter parameters against the definition, enqueues a `document_export` job, and answers `202` with `{ job_id, status_url }`. `?wait=true` polls the job and streams the file instead (the timeout falls back to the `202` body). `422` — unknown or missing format, a reserved parameter (`sort`, `page`, `per_page`, `items`, `wait` handled, `format` handled), preview mode, a `member_of` or `sidecar` doctype, or a malformed filter. `404` — unknown doctype. `403` — no read permission on the doctype at all.",
              forbidden: "Forbidden — the caller holds no read permission on the doctype at all (the list route's class-level gate, so a doomed job is never queued).",
              body: "No body — the export is driven by the query string.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/export_view", "Import/Export",
          [
            Op.new("POST", "Enqueue a table-view export",
              [202, 401, 403, 404, 415, 422],
              description: "Exports the named columns in the caller's sort and filter order. The structured payload rides a JSON body; the response is the export enqueue body (`202` with `{ job_id, status_url }`, or the streamed CSV on `?wait=true`). `415` — the body does not declare a JSON media type. `422` — a query parameter other than `wait`, a non-object or malformed body, missing / empty / duplicate / unknown `columns`, a malformed `sort`, a non-object `filters`, an invalid `timezone`, preview mode, a `member_of` or `sidecar` doctype, or a filter that does not compile. `404` — unknown doctype. `403` — no read permission on the doctype at all.",
              forbidden: "Forbidden — the caller holds no read permission on the doctype at all.",
              body: "`{ \"columns\": [\"…\"], \"sort\": [\"-created_at\"], \"filters\": { \"field__op\": value }, \"timezone\": \"Europe/Paris\" }` — `columns` required.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/import", "Import/Export",
          [
            Op.new("POST", "Upload a file to import as documents",
              [202, 401, 403, 404, 413, 422],
              description: "Parses and validates the uploaded file synchronously, stores the file and its row-to-id manifest as artifacts, enqueues a `document_import` job, and answers `202` with the job id and the row count. `?wait=true` polls the job and answers the upsert report (`200`), the failing row (`422`), or the job id on a crash (`500`). `413` — the upload exceeds `artifact.max_upload_bytes`. `422` — no body, an undetectable format, a malformed row or header, preview mode, or a `member_of` / `sidecar` doctype. `404` — unknown doctype. `403` — no read permission on the doctype at all.",
              forbidden: "Forbidden — the caller holds no read permission on the doctype at all.",
              body: "The file itself (`text/csv` or `application/json`); `?format=` overrides the detected format.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/import_export/:job_id", "Import/Export",
          [
            Op.new("GET", "Read an import or export job status",
              [200, 401, 404],
              description: "Caller-facing job outcome in `{ id, status, error, result }` form. `result` is null while the row is pending or running. Requester-scoped: another account's job, an unknown job, or a job of another kind or doctype answers the non-disclosing `404`.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/:domain/:doctype/import_export/:job_id/download", "Import/Export",
          [
            Op.new("GET", "Download a finished export",
              [200, 401, 404],
              description: "Streams the export bytes with the stored MIME type and an attachment filename (`{domain}.{doctype}[.view].{format}`). Only a succeeded export produces a file: a pending, running, or failed job, an import job, a pruned artifact, another account's job, and an unknown job all answer the non-disclosing `404`.",
            ),
          ],
        ),

        # ── Platform ─────────────────────────────────────────────────────
        PathSpec.new(
          "/Api/Indexes", "Platform",
          [
            Op.new("GET", "List managed index status rows",
              [200, 401, 403, 422],
              description: "One row per physical PostgreSQL partial index the `Index::Manager` owns, with its lifecycle status, in `{ data, meta }` form. The path is a pseudo-doctype: indexes span every domain. Strict admission — a query parameter outside the list grammar answers `422` naming it; an unknown filter field or operator also answers `422`. `403` — the caller holds no wildcard `read` (`*.*`).",
              forbidden: "Forbidden — the caller holds no wildcard `read` (`*.*`) operator permission.",
            ),
          ],
          query: Op.new("QUERY", "List managed index status rows (QUERY variant)",
            [200, 403, 400, 415, 422],
            description: "Same list as GET with the parameters in a JSON body only — query-string parameters answer `422`, a non-JSON body media type answers `415`, an unknown body key answers `422`. The `403` matches the GET list.",
          ),
        ),
        PathSpec.new(
          "/Api/Artifacts", "Platform",
          [
            Op.new("GET", "List the artifact store",
              [200, 401, 403, 422],
              description: "Operator listing of every artifact, live rows only unless `deleted__eq` is set, in `{ data, meta }` form with owner, grant, and reference counts. Artifacts span every domain. `422` — a malformed list parameter or body. `403` — the caller holds no wildcard `read` (`*.*`).",
              forbidden: "Forbidden — the caller holds no wildcard `read` (`*.*`) operator permission.",
            ),
          ],
          query: Op.new("QUERY", "List the artifact store (QUERY variant)",
            [200, 403, 400, 415, 422],
            description: "Same list as GET with the parameters in a JSON body only — query-string parameters answer `422`, a non-JSON body media type answers `415`. The `403` matches the GET list.",
          ),
        ),
        PathSpec.new(
          "/Api/Artifacts/:id", "Platform",
          [
            Op.new("DELETE", "Force-delete an artifact",
              [204, 401, 403, 404, 422],
              description: "Security deletion: destroys the artifact row, its storage object, and every child row by cascade, and writes an `iam.ArtifactEvent` audit document. `404` — unknown artifact. `422` — a malformed JSON body. The optional `{ \"reason\": \"…\" }` body is stored on the audit event.",
              forbidden: "Forbidden — the caller is neither the system principal nor holds the `purge *.*` operator action, or a cookie session sent no `X-Requested-With` header.",
              body: "`{ \"reason\": \"…\" }` — optional.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/Artifacts/:id/grants", "Platform",
          [
            Op.new("GET", "List the grants of one artifact",
              [200, 401, 403, 404],
              description: "Every grant minted against the artifact, newest first, in `{ data, meta }` form. The listing caps at `Artifact::Admin::SUB_LIST_CAP` (500) and reports `more` on the meta. `404` — unknown artifact. `403` — the caller holds no wildcard `read` (`*.*`).",
              forbidden: "Forbidden — the caller holds no wildcard `read` (`*.*`) operator permission.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/Artifacts/:id/references", "Platform",
          [
            Op.new("GET", "List the documents that reference one artifact",
              [200, 401, 403, 404],
              description: "The `artifact_references` rows joined with the referencing document's projection, newest first, in `{ data, meta }` form. The listing caps at `Artifact::Admin::SUB_LIST_CAP` (500) and reports `more` on the meta. `404` — unknown artifact. `403` — the caller holds no wildcard `read` (`*.*`).",
              forbidden: "Forbidden — the caller holds no wildcard `read` (`*.*`) operator permission.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/SystemSettings", "Platform",
          [
            Op.new("GET", "Read the effective system settings",
              [200, 401, 403],
              description: "The operator read the settings page uses: `{ values, pinned }` — the effective non-secret values keyed by path, and the paths the settings document currently pins. Secret paths are absent; no credential material leaves through this surface. A missing settings document is tolerated (every key follows the file). `403` — the caller holds no read permission on the `core.SystemSettings` doctype (the seed posture is admin-only).",
              forbidden: "Forbidden — the caller holds no read permission on the `core.SystemSettings` doctype.",
            ),
          ],
        ),
        PathSpec.new(
          "/Api/SystemSettings/mail/test", "Platform",
          [
            Op.new("POST", "Send a test email through the saved mail connector",
              [200, 401, 403, 422, 502],
              description: "The settings page's test action. One blocking delivery through the **saved** connector — the effective document-over-file mail settings, the same path a password reset or an invite takes. Pending edits in the form do not participate. Answers `{ adapter, from_address, to }` on success. `422` — `mail.adapter` is `dev` (the \"none (no email)\" posture — it prints to stdout and delivers nothing) or `to` is missing or malformed. `502` — the transport failed; the message carries the adapter's own error (refused connection, authentication failure), which is the diagnostic the operator pressed the button for. `403` — the caller holds no update permission on the `core.SystemSettings` doctype.",
              forbidden: "Forbidden — the caller holds no update permission on the `core.SystemSettings` doctype.",
              body: "`{ \"to\": \"user@example.com\" }` — `to` required.",
            ),
          ],
        ),
      ]

      @@spec_json : String = build_spec
      @@drift_checked : Bool = false

      # The spec JSON, built once at boot (require time).
      def self.spec_json : String
        @@spec_json
      end

      # ── Spec object builder ─────────────────────────────────────────────

      # Converts a Kemal path template (`/Api/:domain/:doctype`) to the
      # OpenAPI form (`/Api/{domain}/{doctype}`).
      def self.openapi_path(kemal_path : String) : String
        kemal_path.split('/').map { |s| s.starts_with?(':') ? "{#{s[1..]}}" : s }.join('/')
      end

      private def self.path_params(kemal_path : String, json : JSON::Builder) : Nil
        json.field("parameters") do
          json.array do
            kemal_path.split('/').each do |segment|
              next unless segment.starts_with?(':')
              name = segment[1..]
              json.object do
                json.field("name", name)
                json.field("in", "path")
                json.field("required", true)
                json.field("schema") { json.object { json.field("type", "string") } }
              end
            end
          end
        end
      end

      private def self.schema_string(json : JSON::Builder) : Nil
        json.object { json.field("type", "string") }
      end

      private def self.operation_object(json : JSON::Builder, op : Op, tag : String) : Nil
        json.object do
          json.field("tags") { json.array { json.string(tag) } }
          json.field("summary", op.summary)
          if description = op.description
            json.field("description", description)
          end
          if op.body
            json.field("requestBody") do
              json.object do
                json.field("required", true)
                json.field("content") do
                  json.object do
                    json.field("application/json") do
                      json.object do
                        json.field("schema") { schema_string(json) }
                      end
                    end
                  end
                end
              end
            end
          end
          json.field("responses") do
            json.object do
              op.statuses.each do |status|
                json.field(status.to_s) do
                  json.object do
                    text = status == 403 ? (op.forbidden || STATUS_TEXT[403]) : STATUS_TEXT[status]
                    json.field("description", text)
                    if status != 204
                      json.field("content") do
                        json.object do
                          json.field("application/json") do
                            json.object do
                              json.field("schema") { schema_string(json) }
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
      end

      private def self.build_spec : String
        JSON.build do |json|
          json.object do
            json.field("openapi", OPENAPI_VERSION)
            json.field("info") do
              json.object do
                json.field("title", "Envelope API")
                json.field("version", "1.0.0")
                json.field("description", "Declarative OpenAPI slice: document CRUD, audit history/rollback/restore, the IAM account routes, secret staging, document import/export, and the platform operator surfaces (managed indexes, artifact administration, system settings). Roles are iam.Roles documents served by the document CRUD routes. Response shapes are described in doc/backend/*.md; the path/method set here is validated against the live Kemal route table. Three surfaces stay out by decision: MCP (/Api/_mcp/...) is the agent data plane, not an API surface; OAuth (/OAuth/...) and the assistant (/Api/assistant/...) are outside the declarative slice.")
              end
            end
            json.field("paths") do
              json.object do
                DECLARATIONS.each do |spec|
                  json.field(openapi_path(spec.kemal_path)) do
                    json.object do
                      path_params(spec.kemal_path, json)
                      spec.ops.each do |op|
                        json.field(op.method.downcase) { operation_object(json, op, spec.tag) }
                      end
                      if q = spec.query
                        json.field("x-query") { operation_object(json, q, spec.tag) }
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      # ── Route-table drift check ─────────────────────────────────────────

      # Walks the Kemal radix tree and returns every `(method, path)` pair.
      # Tree keys are `/METHOD/path` (see `Kemal::RouteHandler#radix_path`), so
      # concatenating node keys from the root reconstructs each registration.
      # The spec's own route is excluded — the spec documents the API, not itself.
      def self.registered_routes : Array({String, String})
        collected = [] of {String, String}
        walk(Kemal::RouteHandler::INSTANCE.routes.root, "", collected)
        collected.compact_map do |method, path|
          # The walk reconstructs the full tree key `/METHOD/path`; the
          # method segment is dropped so the pair carries the route path only.
          rest = path.split('/', 3)[2]?
          next nil if rest.nil? || rest.empty?
          route_path = "/#{rest}"
          next nil if route_path == SPEC_PATH
          {method, route_path}
        end
      end

      private def self.walk(node : Radix::Node(Kemal::Route), prefix : String, acc : Array({String, String})) : Nil
        path = prefix + node.key
        if payload = node.payload?
          acc << {payload.method, path}
        end
        node.children.each { |child| walk(child, path, acc) }
      end

      # True when a registered route belongs to the v1 scope. Exact-match on
      # the document/audit path templates; prefix-match on the audit, IAM
      # account, secrets, artifact, and system-settings namespaces, so a new
      # route in a covered concern is caught. MCP, OAuth, and the assistant
      # stay out by decision (see the module header). Public so the drift
      # boundary is testable without a live route table.
      def self.in_scope?(path : String) : Bool
        return true if path.starts_with?("/Api/Audit")
        return true if path.starts_with?("/Api/iam/accounts")
        return true if path.starts_with?("/Api/secrets")
        return true if path.starts_with?("/Api/Artifacts")
        return true if path == "/Api/iam/me"
        return true if path == "/Api/Indexes"
        return true if path == "/Api/SystemSettings"
        return true if path == "/Api/SystemSettings/mail/test"
        case path
        when "/Api/:domain/:doctype", "/Api/:domain/:doctype/:id",
             "/Api/:domain/:doctype/:id/history", "/Api/:domain/:doctype/:id/backrefs",
             "/Api/:domain/:doctype/:id/rollback",
             "/Api/:domain/:doctype/:id/restore",
             "/Api/:domain/:doctype/:id/:child/:child_id/history",
             "/Api/:domain/:doctype/:id/:child/:child_id/rollback",
             "/Api/:domain/:doctype/export", "/Api/:domain/:doctype/export_view",
             "/Api/:domain/:doctype/import",
             "/Api/:domain/:doctype/import_export/:job_id",
             "/Api/:domain/:doctype/import_export/:job_id/download"
          true
        else
          false
        end
      end

      # Compares declared (method, path) pairs against a route table.
      # Returns the drift issues; empty means clean.
      def self.check_pairs(declared : Array({String, String}), table : Array({String, String})) : Array(String)
        issues = [] of String
        table_set = table.to_set
        declared_set = declared.to_set

        declared.each do |method, path|
          unless table_set.includes?({method, path})
            issues << "declared but not registered: #{method} #{path}"
          end
        end

        table.each do |method, path|
          next unless declared_set.any? { |(_, p)| p == path }
          unless declared_set.includes?({method, path})
            issues << "registered but not declared: #{method} #{path}"
          end
        end

        table.each do |method, path|
          next if declared_set.includes?({method, path})
          next unless in_scope?(path)
          issues << "registered but not declared (in scope): #{method} #{path}"
        end

        issues.uniq
      end

      def self.declared_routes : Array({String, String})
        DECLARATIONS.flat_map do |spec|
          ops = spec.ops.map { |op| {op.method, spec.kemal_path} }
          ops << {"QUERY", spec.kemal_path} if spec.query
          ops
        end
      end

      # Runs the drift check against the live route table. Returns the issues;
      # empty means clean.
      def self.drift_check : Array(String)
        check_pairs(declared_routes, registered_routes)
      end

      # ── Served route ────────────────────────────────────────────────────

      # Registers `GET /Api/openapi.json` and builds the spec object. Called
      # from `HTTP::Server.routes` next to the other route modules.
      def self.register : Nil
        get SPEC_PATH do |env|
          handle(env)
        end
      end

      private def self.handle(env) : Nil
        # Same gate as the other control-plane GETs (`/Api/settings`,
        # `/Api/iam/me`): the AuthHandler chain answers 401 for an invalid
        # credential, and the handler requires a JWT `sub` — a credential-less
        # request never reaches the body.
        HTTP::Helpers.require_account(env) || return
        ensure_drift_checked
        HTTP::Helpers.write_json(env, 200, @@spec_json)
      end

      # Route-table cross-check on first use. At require time the table is
      # empty (routes register later, inside `Server.routes`), so the check
      # defers to the first served request. Drift raises loud there.
      private def self.ensure_drift_checked : Nil
        return if @@drift_checked
        issues = drift_check
        return if issues.empty?
        Log.error { "OpenAPI drift: #{issues.size} issue(s): #{issues.first(5).join("; ")}" }
        raise "OpenAPI drift: declared routes do not match the Kemal route table"
      end
    end
  end
end
