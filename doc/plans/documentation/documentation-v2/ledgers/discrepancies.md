# Discrepancy log (shared, append only)

Format per `00-contract.md` §6: `## #<n> — <short title>` then `Where`,
`Docs say`, `Code does`, `Evidence`, `Found by WP <nn>`. Never fix the code;
the maintainer triages.

Found during WP 10 (inventory refresh + content audit), commit `8fb69df`,
2026-11-26. Entries #1–#12 are current-site claims checked against the code;
#13–#14 are `doc/` concern files contradicting the code; #15 is a site
falsehood of the small kind, listed for completeness.

---

## #1 — Denied single read answers 403, not 404, for class denial

Where: `site-docs/src/content/docs/start/architecture.md` (hop 4),
`start/security-governance.md` (§Non-disclosing reads, single-read and
nested-parent claims), `concepts/authorization-enforcement.md`,
`concepts/auth-contexts.md`.

Docs say: a denied single read (and a denied nested parent) answers the same
non-disclosing `404` as a missing document, on every channel.

Code does: the read path answers `403 Forbidden` when the caller holds no
`read` grant on the doctype at all (class denial), and when the app-grant
ceiling blocks, before any row check. `404` is only the row-level denial
answer (caller may read the doctype, not the row).

Evidence: `src/document/read.cr:175-181` (`if RBAC::ReadEnforcer.read_denied?(…) return Facet::ServiceError.new(403, "Forbidden")`, comment "Knowing the doctype exists is acceptable"); `doc/backend/rbac.md:287` ("drives the single-read 403, the nested parent gate 403"); `doc/backend/http-layer.md:155` ("the non-disclosing 404 … for a caller that holds a read grant, and the 403 class denial for a caller that holds none").

Found by WP 10 (audit A). Security-summary tone: the pages overstate
non-disclosure; either scope the claim to "holds read on the doctype, not the
row", or revisit the class-denial design.

## #2 — CSV formula guard also prefixes a leading tab

Where: `site-docs/src/content/docs/workspace/import-export.md` (Example +
Limits sections).

Docs say: text starting with `=`, `+`, `-` or `@` is written with a `'`
prefix.

Code does: `FORMULA_TRIGGERS` also contains `"\t"` — a tab-leading cell gets
the prefix too.

Evidence: `src/import_export/csv_serializer.cr:38`.

Found by WP 10 (audit B).

## #3 — Reserved action names are eight, not three

Where: `site-docs/src/content/docs/build/designing-doctypes.md` (Before you
start).

Docs say: the reserved action names are `validate`, `create`, `update` ("they
name lifecycle hooks").

Code does: eight names are reserved: `validate`, `create`, `update`, `delete`,
`migrate`, `snapshot`, `history`, `rollback`.

Evidence: `src/doctype/doctype_definition.cr:202`.

Found by WP 10 (audit B).

## #4 — `?per_page=` is not a list parameter

Where: `site-docs/src/content/docs/apps/service-accounts.md` (step 3 +
example), `apps/cors-origins.md` (Example fetch), `apps/dpop.md` (step 4
illustration).

Docs say: call a list route with `?per_page=5` (or `?per_page=1`).

Code does: the list grammar accepts `page, items, sort, select, aggregate,
field, scope, deleted`; any unknown parameter answers `422 Unknown parameter`.
The export route even lists `per_page` among refused parameters.
`apps/rest-api.md` documents `items` correctly.

Evidence: `src/http/list_request.cr:58-59`, `src/http/list_request.cr:476`,
`src/http/openapi.cr:287`.

Found by WP 10 (audit C).

## #5 — CLI error example shows lowercase `/api/app/…/deploy`

Where: `site-docs/src/content/docs/apps/quickstart-dev-cli.md` (error table).

Docs say: the CLI prints `HTTP 422 from /api/app/…/deploy: …`.

Code does: the CLI prints `HTTP ${status} from ${url.pathname}` and the deploy
path is `/Api/app/${appId}/deploy` (PascalCase; routes are case-sensitive).

Evidence: `packages/cli/src/api.ts:164`, `packages/cli/src/api.ts:300`.

Found by WP 10 (audit C).

## #6 — Usage-budget window minimum is 31 days, not 30

Where: `site-docs/src/content/docs/govern/governing-assistant.md` (§4).

Docs say: "If you set a window, keep it at 30 days or more."

Code does: 31 or more is always safe; a window of 1–30 under-counts every
live budget. `operate/assistant-config.md` states the 31+ rule correctly —
the two pages contradict each other and this page is the false one.

Evidence: `src/assistant/config.cr:68-69`; `src/cron/assistant_usage_prune.cr:27`.

Found by WP 10 (audit D).

## #7 — Edge routing list is wrong (`/app`, `/a`), omits `/OAuth`

Where: `site-docs/src/content/docs/operate/containers-tls.md` (§4 edge
routing table).

Docs say: `/Healthcheck`, `/Api`, `/app`, `/.well-known`, `/a` and `/Ws` go to
the backend.

Code does: the prod edge routes only `^/(Api|OAuth|A|Ws|Healthcheck|auth)(/|$)`
plus a dedicated `/.well-known/*` handle. `/app` falls through to the frontend
default; lowercase `/a` is a domain id → frontend (only uppercase `/A`, the
artifact stream, reaches the backend). `/OAuth` is missing from the page.

Evidence: `docker/Caddyfile.prod:72`, `docker/Caddyfile.prod:110`.

Found by WP 10 (audit D).

## #8 — Timezone default is `auto`, not `UTC`

Where: `site-docs/src/content/docs/operate/localization.md` (§1 static
defaults).

Docs say: "The defaults are `UTC` and `en`" / "The static default: `UTC` for
the timezone."

Code does: the config default is the `auto` sentinel
(`default_timezone: "auto"`), which the frontend resolves to the browser
zone; the server pins its session to UTC separately. Language default `en` is
correct.

Evidence: `src/config.cr:158`; `doc/frontend/settings.md` (timezone contract).

Found by WP 10 (audit D).

## #9 — Generated account-settings page: `core.timezone` default drifted

Where: `site-docs/src/content/docs/reference/account-settings-keys.md`
(generated).

Docs say: `core.timezone` default `"UTC"`.

Code does: the registered default is `"auto"`.

Evidence: `src/settings/keys.cr:34,39`; `src/config.cr:158`. The generator
renders `descriptor.default.to_json` (`scripts/gen_docs/account_settings.cr`),
so a fresh run emits `"auto"` — the checked-in page is stale.

Found by WP 10 (audit E). Fix path: run `make gen-docs`, do not hand-edit
(contract §7).

## #10 — `rest-api.mdx` route-group note drifted from the spec

Where: `site-docs/src/content/docs/reference/rest-api.mdx` (note under the
embed).

Docs say: the spec serves only document CRUD / history / backlinks / audit /
IAM-account routes; "webhooks, files, secrets, search, WebSocket and
authentication" are on hand-written pages.

Code does: the vendored spec contains `/Api/Artifacts` (+ grants/references),
`/Api/secrets/stage`, `/Api/Indexes`, `/Api/SystemSettings`, and document
export/import routes.

Evidence: `doc/api/openapi.json`; vendored copy
`site-docs/public/api/openapi.json`.

Found by WP 10 (audit E).

## #11 — Retention is per-doctype, not "per document"

Where: `site-docs/src/content/docs/compare/vs-airtable-notion.md`,
`compare/vs-odoo-erp.md`, `compare/vs-retool-lowcode.md`,
`compare/vs-supabase-firebase.md` (all four repeat the phrase).

Docs say: "You set the retention, globally or per document."

Code does: one global window plus per-doctype overrides keyed by qualified
doctype name. No per-document knob exists.

Evidence: `src/config.cr:263-266`; `doc/backend/mutation.md:333`.

Found by WP 10 (audit E).

## #12 — Legacy string scope is accepted, not refused

Where: `site-docs/src/content/docs/reference/permission-syntax.md`.

Docs say: a role write with a string scope fails with `must be an array`.

Code does: the permission parser accepts the legacy single-string form on
every parse (both the legacy form and the canonical array form are valid); no
write-path check rejecting string scopes was found.

Evidence: `src/rbac/permission.cr:56-79`; grep over `src/rbac/validator.cr`,
`src/iam/` for "must be an array" finds only grants/hooks/actions/oauth hits.

Found by WP 10 (audit E).

## #13 — `doc/backend/doctype-system.md` lists a removed source file

Where: `doc/backend/doctype-system.md:12-13` (source tree section).

Docs say: the tree contains `src/doctype/collection_view/defaults.cr`
("CollectionView::Defaults — default core.CollectionView row").

Code does: the directory is gone; default-view creation was removed in
0.2.2 ("No default view", `doc/backend/collection-view.md:161-193`;
`spec/doctype/collection_view_no_seed_spec.cr`).

Evidence: `git log` 4574e74; absence of `src/doctype/collection_view/`.

Found by WP 10 (inventory, DOM).

## #14 — `doc/frontend/grid.md` describes a surface the backend cannot persist

Where: `doc/frontend/grid.md:5,47`.

Docs say: `grid` is "one of the `core.CollectionView` listing surfaces" and
shows a `surface: grid` config.

Code does: the surface enum is `[table, calendar, kanban]`
(`data/seeds/core.CollectionView/definition.yml:16-18`), so the write gate
rejects a grid view; no app surface mounts the grid component (only the view
editor's authoring step and stories exist). The doc describes a surface the
backend would refuse.

Evidence: `data/seeds/core.CollectionView/definition.yml:16-18`;
`frontend/src/lib/components/.../CollectionViewSurfaceStep.svelte:12` (picker
keeps grid disabled); `doc/frontend/grid.md:10-13` concedes no surface mounts
it.

Found by WP 10 (inventory, DOM + FE). The grid is inventoried as FE-23
(dormant) and excluded from the coverage check until a surface mounts it.

## #15 — "Platform routes start with an uppercase segment" has one exception

Where: `site-docs/src/content/docs/start/architecture.md`.

Docs say: platform routes start with an uppercase segment.

Code does: `/metrics` is lowercase (`/Api/…`, `/Ws`, `/Healthcheck`,
`/Healthcheck/live`, `/auth/oidc/…`, `/OAuth/…`, `/Edge/HostAsk` are
PascalCase; `/metrics` is not).

Evidence: `src/http/metrics_handler.cr:24`; `src/http/auth_handler.cr:65-68`.

Found by WP 10 (audit A).

## #16 — Filter compiler compiles only via require order

Where: `src/document/filter_compiler.cr`, `src/rbac/read_enforcer.cr`.

Docs say: (nothing — this surfaced as a tooling break, not a doc claim).

Code does: `src/rbac/read_enforcer.cr` references `RBAC::AuthContext` without
a `require "../rbac/auth_context"`. The type resolves only when some other
file in the require chain happens to load `auth_context` first. Any minimal
compilation unit that needs the filter compiler alone — for example
`scripts/gen_docs/filter_operators.cr`, which reads the operator table from
the compiler — fails with `undefined constant RBAC::AuthContext` unless it
adds the missing require itself (which the generator now does).

Evidence: `scripts/gen_docs/filter_operators.cr` (header comment, the added
require); `src/rbac/read_enforcer.cr` (uses `RBAC::AuthContext`, no require);
`src/document/filter_compiler.cr` (no require of `auth_context`).

Found by WP 11 (generator fixes). Maintainer triage: add the require to
`read_enforcer.cr` (or to `filter_compiler.cr`) so the compiler compiles
standalone. Code untouched by WP 11.

## #17 — Update guards cannot read the state before the patch

Where: `src/document/script_context/base.cr` (setup_ctx), doctype Lua scripts.

Docs say: nothing yet — the gap surfaced while building the Brightwater
example (WP 12), whose Item docttype wanted the classic lifecycle guard "an
item in repair cannot be booked out".

Code does: the `update` script context exposes `ctx.root` as the MERGED
document (current content with the patch applied) and `ctx.patch` as the
partial body — but no pre-merge state. A transition guard like
`ctx.patch.status == "out" and ctx.root.status == "in_repair"` is
self-contradictory: after the merge, `ctx.root.status` is already `"out"`,
so the condition can never fire. The script's `validate` hook sees the same
ctx. Old→new transition guards are not expressible in doctype Lua today.

Evidence: `spec/document/script_context_spec.cr` ("exposes ctx.patch as the
partial PATCH body", "does not set ctx.patch when no patch is supplied");
`src/document/update.cr` (run_script_update passes `merged` as root); the
Brightwater Item guard, which silently passed the hook's write until the
check moved into the hook (`site-docs/examples/brightwater/equipment/
facet-domain/doctypes/equipment.Item.lua`, `hooks/1-booking-drives-stock.lua`).

Found by WP 12. Maintainer triage: either expose the pre-merge document
(e.g. `ctx.previous`) to update hooks, or document that transition guards
belong in the writing side (actions, hooks) — the example now does the
latter. Code untouched by WP 12.

## #18 — Auto-filed grant tickets are narrower than a hook's runtime reads, and depend on import order

Where: `src/grants/publish_tickets.cr` (group_edges),
`src/domain/portable/import.cr` (file_grant_tickets, the liveness check).

Docs say: nothing yet — same origin as #17, the Brightwater example.

Code does: the ticket scan derives cross-domain edges from (a) `replicate`
fields and (b) event hooks' declared `source` (producer doctype, `default`
tag). It cannot see the doctypes a hook's Lua reads at runtime — the
Brightwater hook declares source `rentals.Booking` but also lists
`rentals.BookingLine` through `document.list`, so the auto-filed grant is
missing BookingLine and the hook's reads fail until the grant is widened by
hand (or by the example's loader). Second edge: tickets file only into LIVE
producer domains, so importing bundles in an order where the producer lands
after the consumer silently drops that ticket (the import answer shows no
hint; a later re-sync or re-import files it).

Evidence: `site-docs/examples/brightwater/load.sh` (ensure_grant widens the
resource set and logs "widened (added: BookingLine)"); the fresh-instance
repro: import → boot → load → seed leaves all 40 items available with
"no active grant ... on BookingLine" warnings in the backend log, fixed by
the widen; the import log for the same order shows only the clients ticket
filed.

Found by WP 12. Maintainer triage: widen the scan (parse `document.list` /
`document.get` literals out of hook scripts — best effort), or document that
a hook's runtime reads need a hand-widened grant. The import-order drop
could surface as a `/check` warning (the code's own comment says draft
producers surface there). Code untouched by WP 12.
