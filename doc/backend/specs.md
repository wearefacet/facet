# Specs

**File:** `spec/`

The backend `src/` layout broadly mirrors `spec/`. Some source files are exercised indirectly through integration or HTTP specs rather than having a direct 1:1 spec file.

| Spec | Tests |
|---|---|
| `spec_helper.cr` | Sets `APP_ENV=test`, loads `.env` / `.env.test`, runs `db_reset` before suite. Runs against the throwaway test PostgreSQL (port 5433) — see [`test-database.md`](test-database.md) |
| `database_spec.cr` | `Database.with_transaction` atomicity, rollback, and connection-per-call behaviour |
| `migrate/db_reset_spec.cr` | `Migrate.db_reset` end-to-end: drop → create → migrate → seed → warm currency registry, against a scratch database |
| `migrate/down_spec.cr` | `Migrate.down` scenario: full chain up → one-step revert → down-to-prefix target → unknown / not-applied errors → full revert to an empty `_migrations`; plus `up_section` / `down_section` splitting |
| `doc_citations_spec.cr` | Doc lint — every migration file name or bare number cited in `doc/**` + `AGENTS.md` resolves to a real file in `db/migrations/` (pure file-system spec, no database) |
| `doctype/doctype_definition_spec.cr` | JSON parsing of `DoctypeDefinition`, format validation (CamelCase, domain rules) |
| `doctype/composition_spec.cr` | `Doctype::Composition.validate`: mutual children/member_of reciprocity over a domain bundle, missing targets, one-sided edges |
| `doctype/doctype_validation_service_spec.cr` | Schema-level validation: field names, reserved actions, schema_version, member_of, references, the `aggregate_root`/`member_of` exclusivity |
| `document/validation_spec.cr` | Document validation: required fields, types, enums, children, references, computed fields, unknown fields |
| `document/create_spec.cr` | `Document::Create` core.DocType delegation and general document creation |
| `document/create_with_script_spec.cr` | Script integration during document creation: valid/invalid scripts, exposed fields, syntax errors |
| `document/script_context_spec.cr` | `ScriptContext::Create`, `ScriptContext::Update`, `ScriptContext::Delete`, `ScriptContext::Action` Lua execution contexts |
| `document/update_spec.cr` | `Document::Update`: partial update, no-op, write_only stripping, deleted-document guard, Lua update lifecycle hook, computed field re-evaluation |
| `document/delete_spec.cr` | `Document::Delete`: soft-delete, not-found guard, already-deleted guard, Lua delete lifecycle hook |
| `http/list_request_spec.cr` | JSON and query-string parsing of pagination/filters/sort, sanitization |
| `lua/engine_spec.cr` | 28 examples: lifecycle, arithmetic, strings, booleans, nil, tables, Crystal proc registration, globals, errors, stdlibs |
| `document/strip_write_only_spec.cr` | `StripWriteOnly` — strips write_only fields, passes through non-write-only documents, handles empty/primitives |
| `mutation/json_diff_spec.cr` | Diff computation (set/unset), nested changes, arrays treated atomically, type changes, JSON serialization |
| `mutation/mutations_spec.cr` | 15 integration specs: trigger-driven projection updates via raw SQL for create, update, delete, snapshot, cross-cutting |
| `artifact/routes_spec.cr` | Config loading, shrine storage setup, artifact upload through HTTP |
| `artifact/admin_spec.cr` | Artifact admin surface: `Artifact::Admin` listing (counts, filters, tombstone default, pagination, wildcard-read gate), `GET /Api/Artifacts` + grants/references sub-routes, the `revoke *.*` operator branch of `Grants.revoke` |
| `integration/hr_doctype_spec.cr` | End-to-end integration: registers HR doctypes (Person, Employee, CareerEvent), creates documents, executes actions via HTTP |

## Spec support (`spec/support/`)

| File | Contents |
|---|---|
| `db_helper.cr` | `with_db`, `db_open`, `db_truncate_mutations`, `with_temp_doctype` |
| `doctype_helper.cr` | `load_doctype_schema`, `load_doctype_script`, `build_doctype_definition`, `create_doctype`, `create_doctype_from_data`, `register_hr_doctypes`, `ensure_domain` |
| `iam_helper.cr` | `create_test_account`, `seed_test_roles`, `ensure_seed_roles_with_dependencies`, `create_session_and_refresh_token`, `create_mfa_account` |
| `app_helper.cr` | `seed_app_doctypes`, `seed_iam_doctypes` — re-register the `app.App` + `core.DocType` + `core.Domain` + `iam.*` definitions wiped by the per-example TRUNCATE |
| `oauth_helper.cr` | `create_test_app`, `create_test_role`, `oauth_grant`, `oauth_action`, `oauth_perm`, `s256_challenge`, `make_authorize_params`, `sign_app_token` — shared OAuth fixtures |
| `result_helper.cr` | `expect_create_success`, `expect_create_error`, `expect_action_success`, `expect_action_error` |
| `wait_helper.cr` | `wait_for`, `assert_eventually` — polling helpers for async conditions |
| `money_helper.cr` | `money`, `money_json`, `register_seed_currencies` — money payload builders plus the in-memory currency-registry registration the suite relies on |
| `seeded_baseline_helper.cr` | `restore_seeded_baseline` — copies the seeded baseline back from snapshot tables after the per-example TRUNCATE (~13 ms vs ~320 ms for a full `Seed.seed`); falls back to the real seed on databases without a snapshot |
| `webhook_helper.cr` | `with_webhook_config`, `with_webhook_config_raw`, `with_fake_resolver`, `seed_webhook_source`, `seed_role`, `create_bound_webhook` — shared webhook fixtures and the DNS fake for `Webhook::TargetCheck` |
| `http_helper.cr` | `call_api`, `chain_handlers`, `HTTPTest` — shared Kemal handler chain for HTTP specs |
| `http_helpers.cr` | `bearer_headers`, `with_xrw`, `with_form_auth`, `create_domain_http`, `create_doctype_http`, `create_document_http`, `create_child_document_http`, `execute_action_http`, `get_document_http`, `list_documents_http`, `list_nested_http`, `read_nested_http`, `patch_document_http`, `delete_document_http`, `parse_body` — auth-header builders plus convenience wrappers around `call_api` for common REST operations |

### HTTP test helpers (`spec/support/http_helper.cr`)

The `call_api` helper dispatches requests through the full Kemal middleware/route stack without starting a real server. It is used by `spec/http/` and `spec/integration/`. Usage:

1. `require "../../src/http/server"` and `require "../support/http_helper"` at the top of the spec file.
2. Call `Facet::HTTP::Server.routes` to register routes, then `Kemal.config.setup`, then `chain_handlers` — all at the top level, **not** inside `before_all`.
3. `require "../support/http_helpers"` alongside `http_helper` to get the REST convenience wrappers.
4. Use `call_api(request)` in individual tests, or use the convenience helpers from `http_helpers.cr` (e.g. `create_document_http`, `get_document_http`).
5. For `before_all` setup, use direct DB calls (`ensure_domain`, `create_doctype` via the service layer) — never call `call_api` or `Kemal.config.setup` inside a `before_all` hook.

> **Why?** Kemal handlers are singletons. Re-chaining them (via `handler.next = ...`) while a request is being processed overwrites `next` pointers mid-walk, causing a stack overflow.

## Conventions

- Tests run against a real PostgreSQL database. `spec_helper.cr` runs `db_reset` (drop + recreate + migrate) before the suite.
- Mutation-to-projection integration tests (`spec/mutation/mutations_spec.cr`) use raw SQL via a direct `PG` connection to test the PL/pgSQL trigger logic independently of Crystal's mutation API.
- Each test in `spec/mutation/mutations_spec.cr` uses a unique `doc_id` (ULID) to avoid cross-contamination — no per-example DB reset since migrations are stateful.
- Use `unique_suffix` (from `spec/support/db_helper.cr`) for short unique fixture names. It draws from the random portion of a ULID — the timestamp portion alone would collide under tight loops.
- When writing a spec that exercises a PL/pgSQL function, prefer the `db.query_one(...) do |rs|` block form with explicit `rs.read(Type)` calls rather than the `as:` shorthand, because the result set may contain nullable columns (e.g. `deleted_at timestamp`).
