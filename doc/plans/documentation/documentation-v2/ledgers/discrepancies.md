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

## #19 — Compare pages offer managed hosting and design services the repo cannot source

Where: `site-docs/src/content/docs/discover/compare/index.md` (closing
bullet), `compare/vs-ai-built-apps.md` (table row "Hosting & data residency",
FAQ "Who maintains it after launch?"), `compare/vs-airtable-notion.md` (table
row "Hosting", FAQ "Is Facet a self-hosted Airtable?", FAQ "Can I import…?",
FAQ "What does Facet cost…?"), `compare/vs-odoo-erp.md` (table rows "Who
builds" and "Hosting", FAQ "Does Facet import Odoo data?", "What Facet does
not do" list), `compare/vs-retool-lowcode.md` (table row "Hosting", FAQ "Is
the per-user pricing a problem?"), `compare/vs-supabase-firebase.md` (table
row "Hosting").

Docs say: "we offer managed hosting, with your choice of location, and domain
design and migration services" / "our team designs it" / "our team can run
the migration" / "our team can take it on" / "by us with managed hosting" /
"or that we run for you".

Code does: the repository contains no support, hosting or services URL, offer
or product (D10 checked by grep at `8fb69df`; re-checked at `eee55a2`).
`LICENSING.md` only permits *third parties* to sell such services under the
Additional Use Grant. The WP 10 audit (batch E) had flagged these claims as
unsourceable; decision D10 keeps them out of the docs until the maintainer
supplies wording and links.

Evidence: `grep -ri "managed hosting\|design services" src/ packages/ docker/
README.md` → no offer; `doc/plans/documentation/documentation-v2/99-decisions.md`
→ D10 decision note.

Found by WP 13 (batch B). Fix applied in the WP 13 voice pass: the offers are
cut, the self-hosting claim stays. If the maintainer later supplies a
services page, re-add with links.

## #20 — Compare pages promise a domain marketplace that is not shipped

Where: `compare/vs-odoo-erp.md` (table row "Ready-made business modules", FAQ
"Can Facet do accounting?", FAQ "Will Facet become an ERP?", "What Facet does
not do" list), `compare/vs-supabase-firebase.md` (table row "Ready-made
business modules").

Docs say: "A marketplace of one-click domains, with apps and roles, is
planned" / "Ready-made domains are on the roadmap" / "The plan is a
marketplace of ready-made domains … each installed in one click".

Code does: no marketplace exists — `grep -ri marketplace src/ packages/`
returns nothing, and `00-contract.md` §2 rule 2 lists the domain marketplace
among known unshipped features. The contract bans roadmap claims.

Evidence: the grep; `00-contract.md` §2.

Found by WP 13 (batch B). Fix applied: roadmap sentences cut; the pages now
state the present fact ("none prebuilt; you model what is specific to you
with the assistant") and keep the verdict (an ERP for standard processes,
Facet for your own domains).

## #21 — Login-event log claim includes refreshes; code writes no event for them

Where: old `start/security-governance.md` (now
`discover/security.md`, rewritten by WP 13).

Docs say: "Every authentication event — sign-in, sign-out, denial, refresh —
lands in an append-only login-event log."

Code does: a successful token refresh writes no LoginEvent, on purpose — a
session refreshes on a clock, so the log would fill with rows retention would
have to keep (comment at `src/iam/refresh.cr:26` and `134-139`). The events
written are: `login`, `logout`, `lockout`, `refresh_reuse`, `oidc_login`,
`oidc_denied`, `oidc_provisioned`, `layer1_denied` (app-attributed denials
only — ordinary browser-session denials write none, `src/iam/helpers.cr:127-141`),
plus security changes (`password_change`, `mfa_enabled/disabled`,
`api_key_created/revoked`, `session_revoked`, `invite_sent`,
`password_reset_*`).

Evidence: the `write_login_event` call sites listed above
(`grep -rn "write_login_event" src/`).

Found by WP 13 (batch B). Fix applied: `discover/security.md` now says the
log records sign-ins, sign-outs, lockouts and security changes, with app and
SSO denials — it no longer claims routine refreshes.

## #22 — Compare pages call the built-in UI "the portal"; the product word is "workspace"

Where: `compare/index.md`, `vs-ai-built-apps.md`, `vs-airtable-notion.md`,
`vs-retool-lowcode.md`, `vs-supabase-firebase.md` (13 occurrences of
"portal" for Facet's own UI; one more in `vs-odoo-erp.md` refers to Odoo's
portal feature and is correct).

Docs say: "Facet's portal gives list, calendar and kanban views…" / "the
portal and app hosting come with the software".

Code does: the UI has no "portal" label. `frontend/messages/en.json` contains
no portal string; the main data surface is the workspace (`AGENTS.md` →
fullpage layout "sidebar, top bar, workspace, peek drawer"; the Use tab's
tour page is "A tour of the workspace").

Evidence: the en.json grep; `doc/frontend/workflow.md` vocabulary.

Found by WP 13 (batch B). Fix applied: "portal" → "workspace" for Facet's UI
across the five pages; Odoo's own portal untouched.

## #23 — Old "decide in one afternoon" command cannot run in the release image

Where: old `start/is-facet-right-for-you.md` (now
`discover/is-it-right-for-you.md`, rewritten by WP 13).

Docs say: `docker compose -f docker/compose.prod.yml exec backend facet
seed:admin …`.

Code does: the release image puts the binary at `/app/facet` and never on
`PATH` (`docker/backend.Dockerfile:46`, no symlink; the entrypoint itself
calls `./facet`, `docker/backend-entrypoint.sh:60`). A bare `facet` inside
`exec` does not resolve, so the command fails with "facet: not found". The
shipped runbook uses `docker compose -f docker/compose.prod.yml run --rm
backend seed:admin …` (`admin/install/production.md:42`), which works: the
entrypoint skips the server branch and execs `./facet seed:admin`.

Evidence: the Dockerfile and entrypoint lines above; the production runbook.

Found by WP 13 (batch B). Fix applied: the rewritten page uses the runbook's
exact command.

## #24 — Two D2 diagram ids do not match the sha256 of their own sources

Where: `build/deeper/schema-evolution.md` (id `9bdb23d4`, sha256 of source
`ad5f626b`) and `build/deeper/cross-domain-replication.md` (id `f1eb9af1`,
sha256 of source `dc32efd4`). The mismatch exists since the original
`concepts/` pages (release commit 037187e carries the same pairs).

Docs say: the house rule (`scripts/build-diagrams.mjs:55-57`) derives the id
from the embedded source: `sha256(source)[:8]`, source = the lines between
the fences.

Code does: the two image blocks above carry ids that their own sources do
not hash to. The build tolerates it: `public/diagrams/` is gitignored, so
every clean build re-renders the SVGs from the embedded sources under the
ids the img srcs name (`ensureRendered`) — what ships is always correct.
The cost is future edits: an agent that follows the house rule computes a
"new" id, sees it differ from the shipped one, and cannot tell which side
is stale.

Evidence: `sha256` computed over both embedded sources at HEAD and at
037187e; `git ls-files site-docs/public/diagrams/` returns nothing;
`site-docs/.gitignore:4`.

Found by WP 16 (batch A). Not fixed: batch A keeps the blocks byte-identical
per the handoff. Suggested fix: re-render and rename the ids to the true
hashes in one mechanical pass (diagram only, no prose change).

## #35 — Voice-plan example overstates publish: "never the test documents"

Where: `doc/plans/documentation/documentation-v2/01-voice-and-vibe.md` §4.3
(the after-example sentence meant as a model for L1/L2 copy). Also relevant
to any page that copies it verbatim.

Docs say: "Publishing copies the structure only, never the test documents you
created in the draft. That way, nothing you typed while experimenting ends up
in production data."

Code does: structure-only is the publish **default**, not the rule. The
publish route accepts an optional `documents` field
(`{\"import\": true, \"doctypes\": [...]}`) that carries draft documents into
the target — every doctype by default, or a named list (`doc/backend/
draft-domains.md` → Publish — copy-and-drop). An overwrite publish refuses to
merge a draft doctype into live rows (422), but a fresh publish can import.

Evidence: `doc/backend/draft-domains.md:89-101` (`documents` field, import
modes, `documents_imported` in the response); `Domain::Publish` service.

Found by WP 13 (batch A). Fix applied: `discover/how-it-works/domains.md`
says "Publishing copies the structure; the practice records you typed while
experimenting stay behind unless you choose to bring them along." WP 16
(`build/model/in-app/how-drafts-work.md`) should keep the opt-in explicit.

## #25 — SDK types an aggregate answer as a row list; the wire carries an object

Where: `site-docs/src/content/docs/build/apps/data/sdk.md` §Documents and
queries (the aggregate example); `packages/sdk/src/client.ts` (the
`ListPage<T>` type). WP 17 batch B documents the gap; no product change
requested.

Docs say (the natural reading of the types): `list({ aggregate: 'sum',
field: ... })` returns `ListPage<T>` whose `data` is `ListItem<T>[]`.

Code does: the aggregate wire shape is `{data: {value: …}, meta}` — an
object, not an array. At runtime `agg.data.value` holds the money bag
(`{"EUR": "72076.00"}` on the Brightwater instance), but TypeScript reads
`data` as `ListItem[]` and rejects `.value` (`TS2551`). The SDK's own doc
comment acknowledges the shape shift for `next()` only, not for `data`.

Evidence: `packages/sdk/dist/client.d.ts` (`ListPage extends
ListResponse`, `data: ListItem<T>[]`); live call
`GET /Api/equipment/Item?aggregate=sum&field=purchase_price` answers
`{"data":{"value":{"EUR":"72076.00"}},"meta":{"count":40,...}}`; scratch
type-check `tmp/sdk-check/` fails on `agg.data.value` with the plain types.
The page casts (`agg.data as unknown as { value: Record<string, string> }`)
until the SDK grows an aggregate result type.

Found by WP 17 (batch B). Suggested fix: a `AggregateResult<T>` return type
on `CollectionHandle.list` when `aggregate` is set (discriminated union on
`params.aggregate`), or a dedicated `aggregate()` method.

## #26 — REST filter grammar takes one bracket level; an old page shape still ranks in search

Where: `site-docs/src/content/docs/build/apps/data/rest-api.md` §List and
filter (fixed this batch). Logged because the wrong form is easy to
reintroduce: it looks like the Rack/Rails nested-params convention.

Docs said (old page): `filters[status][eq]=active` — nested brackets.

Code does: the query parser strips exactly one bracket pair and reads the
inside as the whole key (`src/http/list_request.cr`, "strip \"filters[\"
prefix and "]\" suffix"). The nested form reaches the filter compiler as the
field name `name][match` and answers `422 Unknown filter field 'name][match'
(filterable: …)`. The correct form is `filters[name__match]=Lumi` — the
`__op` suffix rides inside the brackets.

Evidence: live call `?filters[name][match]=Lumi` → `422` with the error
above; `?filters[name__match]=Lumi` → `200`; `src/http/list_request.cr:294-296`.

Found by WP 17 (batch B). Fixed in this batch; no product change needed.

## #27 — Writes silently ignore If-Match; no 409 concurrency conflict exists on document routes

Where: the old `build/apps/rest-api.md` (§Errors table: "`409` | Concurrent
write on the document. Re-issue the same request.") claimed a concurrency
`409`. The rewritten page drops the claim; logged so nobody restores it.

Docs said: a concurrent write on a document answers `409`.

Code does: no route in `src/` reads `If-Match` on writes (`grep -rn
'If-Match' src/` answers nothing). Live checks on the Brightwater instance:
a `PATCH` with a stale ETag answers `200`, a `PATCH` with `If-Match:
"bogus"` answers `200`, a `DELETE` with `If-Match: "bogus"` answers `204`.
The ETag is a read-side validator only (`If-None-Match` → `304`; writes
mint a fresh `mid`). No write path returns `409` on document routes.

Evidence: `curl` transcripts in the WP 17 ledger (`ledgers/17b.md`, claim
rows for rest-api.md); `src/http/caching.cr` handles `If-None-Match` for
lists; `grep -c If-Match src/` = 0.

Found by WP 17 (batch B). Fix applied (docs): the errors table and
troubleshooting no longer mention a write-side `409`. If optimistic
concurrency is wanted on writes, that is a product decision — raise it as a
feature, not a doc fix.

## #28 — The `lua:` config section loads but never reaches the sandbox

Where: `reference/limits.md` (new in WP 19) lists the Lua sandbox budgets.
The limits page states the values the engine actually enforces and notes the
gap; logged so a reader who raises `lua.instruction_limit` knows why
nothing changes.

Docs would say: raising `lua.instruction_limit` / `lua.memory_limit_mb` /
`lua.time_limit_s` in `config.{env}.yml` raises the sandbox budgets (the
0.2.1 changelog even instructs operators to raise these keys).

Code does: the `lua:` section loads into `Config::LuaConfig`
(`src/config.cr:168-171,603-612`), but nothing wires it into the sandbox —
`src/lua/sandbox.cr:33-35` always calls `Engine.new` with the engine
defaults (1,000,000 instructions / 32 MB / 0.5 s, `src/lua/engine.cr:82-84`).
Only the spec suite reads `cfg.lua` (`spec/config_spec.cr:966-968`).
Behaviour matches the defaults by accident, not by wiring.

Evidence: `grep -rn "config.lua" src/` finds no consumer outside the loader;
`grep -n "Engine.new" src/lua/sandbox.cr` shows the call site with no
class-level state; the 0.2.1 CHANGELOG (line 56) tells operators to raise
the keys.

Found by WP 19 (limits page, reference batch). Docs impact: the limits page
cites the enforced engine defaults, not the config keys, and carries an
explicit note. Product fix (wiring the section into `Lua::Sandbox`) is the
maintainer's call.

---

## #29 — MFA setup route demands a request body it does not use

Where: `site-docs/src/content/docs/admin/people/mfa.md` (enrollment steps);
any integrator scripting enrollment.

Docs say (old page and new page): the account enrolls through
`POST /Api/iam/mfa/totp/setup`, which returns `{secret, otpauth_uri}`; no
request fields are documented.

Code does: the route requires a JSON object body even though it carries no
required field — the only optional key is `account`, which sets the label in
the `otpauth://` URI. A bodiless POST (the natural REST call) answers an
error instead of the setup payload.

Evidence: live on `https://facet.localhost:3443`, 2026-11-26 —
`POST /Api/iam/mfa/totp/setup` with no body → `{"error":"Request body is
required"}`; with `-d '{}'` → `200 {"secret":"…","otpauth_uri":"otpauth://totp/Facet:…"}`.
`src/iam/routes.cr:703-708` (`handle_mfa_setup` calls `parse_json_object`
unconditionally; `account_name` falls back to the account id when `account`
is absent).

Found by WP 18 batch A (people pages). Docs impact: the new mfa page shows
the working call (`-d '{}'`). Product fix (treat an absent body as `{}`, or
document the required body) is the maintainer's call.

## #32 — `allowed_origins` description claims origins must equal the app's own host

Where: `data/seeds/app.App/definition.yml` (field description for
`allowed_origins`); surfaced in the app registration wizard help.

Docs say: each origin's scheme and host "must equal the app's own host" —
implying one origin, tied to where the app is served.

Code does: the create/update hook validates shape only — a bare origin
(scheme, host, optional port), no wildcard, no path. Multiple entries are
allowed and expected (production plus dev origins on one app); nothing ties
an entry to the app's serving host. `doc/backend/oauth.md` and the CORS
handler (`src/oauth/cors.cr`, `src/oauth/origin_cache.cr`) treat the list as
a free allowlist of exact origins echoed back.

Evidence: hook validation at `data/seeds/app.App/script.lua` (origins
section — shape checks only, loop over any number of entries); the seeded
`bfr-checkout` example carries `http://localhost:5173` while its build is
served by the CLI deploy flow, and a second origin can be PATCHed freely.

Found by WP 17 batch A (apps pages). Docs impact: the rewritten CORS and
register pages document the shape-only rule. Product fix (reword the field
description) is the maintainer's call.

## #33 — `assistant_enabled` description claims a confidential app cannot enable it

Where: `data/seeds/app.App/definition.yml` (field description for
`assistant_enabled`).

Docs say: a confidential app cannot enable the assistant — "the Lua hook
refuses" it.

Code does: no such refusal exists. The seeds hook validates nothing about
`assistant_enabled` against `client_type`; `doc/backend/app-system.md` says
both client types may enable the assistant; and the runtime gate
(`src/assistant/app/gate.cr`) checks the flag and the caller's token, never
the client type.

Evidence: `grep -n assistant_enabled data/seeds/app.App/script.lua` finds no
client-type branch; `src/assistant/app/gate.cr` has no `client_type` read;
a confidential `bfr-stock-sync` create returned `"assistant_enabled": false`
with no complaint, and flipping it is not guarded.

Found by WP 17 batch A (apps pages). Docs impact: the rewritten pages stay
silent on a restriction that does not exist. Product fix (reword the field
description) is the maintainer's call.

## #34 — Domain-wide role lines never cover concrete grant targets on app channels

Where: app consent (`src/oauth/authorize.cr` `build_consent`), app API-key
issuance (`src/app/api_keys.cr` `grant_intersection_gate`), and the
app-channel request path — all via `RBAC::GrantResolver` / `Grant#covers?`
(`src/rbac/grant.cr`).

Docs say: the consent screen lists the roles the account holds, and an app
acts with grant ∩ role (`doc/backend/oauth.md`, `doc/backend/app-system.md`).
Neither page states that a role line on a bare domain (`{"on": "equipment",
"action": "*"}`) fails to cover a concrete grant target (`equipment.Item`),
while the same line fully covers the domain for a person calling without an
app.

Code does: `Grant#covers?` requires the permission path to be equal or
deeper than the grant target path; a domain-wide line has an empty path and
never matches (`src/rbac/grant.cr:159-192`). The consent screen silently
drops such roles (an account can see `roles: []` with no reason), and key
issuance refuses with `422` naming the remedy. Person channels are lenient
(`Permission#matches_path?`, `src/rbac/permission.cr:126-140`), so the same
role works fine outside apps. The three app-channel surfaces are internally
consistent — the gap is versus person channels and versus the docs' silence.

Evidence: live on the Brightwater example at `eee55a2` — the check-out app
(grants: `rentals.Booking`, `rentals.BookingLine`, `equipment.Item`) lists
only the admin role for Ravi; Lucía (warehouse, domain-wide equipment line)
and Nadia (manager) get `roles: []` on the same consent payload; api-key
issuance with `service_role_id: iam.Roles.warehouse` refuses with `The
app's grants do not intersect the service role iam.Roles.warehouse's
permissions — the key would be refused at every request. Repeat each grant
target as a concrete role permission line (e.g. {"on": "equipment.Item",
"action": "*"}) or widen the role.`; the same warehouse role reads and
writes items fine over a plain session.

Found by WP 17 batch A (apps pages). Docs impact: user-login carries a
troubleshooting row for the empty consent list; backend-apps carries the
exact issuance error. Intent is unknown — if domain-wide coverage is meant
to work, this is a product bug; if the strict rule is meant, the consent
screen should say why a role is absent. Maintainer triage.

## #36 — Builder qualifies reference targets to the draft id, not the publish-target name

Where: the doctype editor's reference target input
(`frontend/src/lib/components/features/configure/DoctypeTypeEditor.svelte:36-48`),
and the old tutorial `build/first-hour/first-domain.md` (verified_at
e7c24a4) which taught the opposite.

Docs said: "The editor qualifies the bare target to `inventory.Supplier`
(the publish-target domain, not the draft id) — that qualified form is what
the publish step needs."

Code does: the editor qualifies a bare target to the **draft's own id** on
commit (`qualifyReferenceTarget` prefixes the domain prop, which is the
open draft, e.g. `_06h1gc0yjgkj.Gadget`). The rewrite to the published name
happens at publish: `Domain::Copy` relinks same-domain reference targets
through `PublishGate.domained_content` (`doc/backend/draft-domains.md` →
§Reference-target relink).

Evidence: live run WP 14 batch B (`ledgers/14b.md` §3 rows 15, 28) — the
input showed `_06h1gc0yjgkj.Gadget` before publish; after publishing to
`wp14b-demo`, `GET /Api/core/DocType/wp14b-demo.Ticket` returned
`"doctype": "wp14b-demo.Gadget"`.

Found by WP 14 batch B. Docs impact: the rewritten tutorial describes the
draft-id qualification and the publish-time relink. No code change
requested — the two-step behaviour is sound; only the old page was wrong.

## #37 — View starter hint promises sharing; the view editor forbids it

Where: the collection-view starter screen
(`frontend/src/lib/components/primitives/data/CollectionViewStarter.svelte`,
`list_view_starter_hint`) versus the view editor's scope helper
(`list_editor_personal_edit_helper`).

One label says: "A new view starts personal — only you see it until you
share it." The other says: "Visible only to you. General↔personal cannot
be changed after creation." (and the caution is repeated in the docs:
`build/model/views/lists-boards-calendars.md` → §4).

Code does: `general`/`owner_id` are fixed at creation; there is no share
action for a personal view (`doc/backend/collection-view.md`; the editor
radio group only renders at create time).

Evidence: label strings side by side in `frontend/messages/en.json`
(`list_view_starter_hint` vs `list_editor_personal_edit_helper`); no share
control found in the list view UI (WP 14 batch B, grep + live run).

Found by WP 14 batch B. Docs impact: the tutorial avoids the word
"share"; a maintainer may want the starter hint reworded ("create it again
as a general view").

## #38 — Team-access tutorial's audit step names Lucía; the tutorial creates Pat

Where: `site-docs/src/content/docs/build/first-hour/team-access.md`
(WP 14 batch A rewrite), §5 "Check the record".

Docs say: "Open **Configure → Audit** and find the day's entries:
Lucía's account created, the role assigned, her first sign-in and
password change."

Code does (and the tutorial does): the same page's step 1 creates
**Pat Mardell** (`pat@brightwater.example`) and assigns him the
`warehouse` role; Lucía Ferrer is a pre-existing Brightwater persona
created by the example's `load.sh` long before the tutorial runs
(`site-docs/examples/brightwater/load.sh:196`), so her account creation
is not among "the day's entries" a reader of this tutorial produced.
The sentence reads as if the tutorial created Lucía.

Evidence: `team-access.md` §1 (New Account form filled with
`pat@brightwater.example` / "Pat Mardell", shots team-access-3/4/5 show
Pat); capture log `tmp/wp14-t4-pat-final.log` (account created, role
assigned, one-time password generated); live check 2026-11-26 —
`pat@brightwater.example` absent (deleted after the shot run),
`lucia@brightwater.example` present as a warehouse persona from the
example load.

Found by WP 14 (batch A, reconstructed ledger ledgers/14a.md). Fix
status: docs fix owed — the sentence must name Pat (page edit outside
the recovery scope; flagged to the orchestrator).

## #39 — First-hour index says "Tutorial 3 needs Node.js 20+"; its route table numbers the app tutorial 4

Where: `site-docs/src/content/docs/build/first-hour/index.md`
(WP 14 batch A rewrite), "Before you start" paragraph.

Docs say: "Tutorial 3 needs Node.js 20+; the rest need nothing beyond a
browser."

Code does (the page's own route table contradicts it): row 3 is
"The same domain in files", which needs a full dev environment
(Crystal, PostgreSQL, Redis, Caddy, Lua headers — see
`build/dev-environment.md`), not Node.js and not "nothing beyond a
browser"; the Node-dependent tutorial is row 4, "Ship your first app"
(the `@facetapp/cli` scaffold needs Node 20+). A reader following the
table prepares the wrong prerequisite for the wrong tutorial.

Evidence: `index.md` §The route table (rows 3 and 4);
`build/first-hour/first-domain-in-files.md` "You need" (dev
environment); Node requirement surfaces in the app toolchain
(`site-docs/package-lock.json` engines `>=20.9.0`).

Found by WP 14 (batch A, reconstructed ledger ledgers/14a.md). Fix
status: docs fix owed — either renumber the sentence to the app
tutorial or reword the prerequisites per row (page edit outside the
recovery scope; flagged to the orchestrator).

## #40 — Secret-store docs name `SECRETS_MASTER_KEY`; the shipped stack requires `FACET_SECRETS_MASTER_KEY`

Where: `scripts/gen_docs/config_keys.cr:154` → the generated
`site-docs/src/content/docs/reference/config-keys.md` (secrets row), and
`doc/backend/secrets.md:165`.

Docs say: "production supplies it via !env SECRETS_MASTER_KEY".

Code does: the shipped production config resolves the secret with the
`FACET_`-prefixed variable, and the compose stack requires it by that
name: `docker/config.production.example.yml:196`
(`master_key: !env FACET_SECRETS_MASTER_KEY`), `docker/compose.prod.yml:64`
(`FACET_SECRETS_MASTER_KEY: ${FACET_SECRETS_MASTER_KEY:?…required…}`),
`docker/.env.example:54`. An operator who exports `SECRETS_MASTER_KEY`
per the docs hits the fail-loud boot error
`!env 'FACET_SECRETS_MASTER_KEY' is not set in the environment`
(`src/util/yaml_tag.cr:186-189`). The dev config comment
(`config.dev.yml:263`) also says `SECRETS_MASTER_KEY`, but dev carries a
literal key so it never fires.

Evidence: grep across `docker/` — no `SECRETS_MASTER_KEY` without the
prefix exists in any shipped file; the generated reference page row
matches the generator string verbatim.

Found by WP 18 batch B2 (backup-restore page). Docs impact: the rewritten
backup page documents the verified `FACET_SECRETS_MASTER_KEY` name and
links this entry. Fix is in the generator and `doc/backend/secrets.md` —
maintainer triage.

## #41 — The site states the static default timezone is UTC; the code default is `auto`

Where: `site-docs/src/content/docs/admin/configure/languages.md` (old
`operate/localization.md`); any reader deciding whether a fresh install
shows UTC.

Docs say: "The section is optional. The defaults are `UTC` and `en`" and
"The static default: `UTC` for the timezone, `en` for the language."

Code does: the built-in `localization.default_timezone` is `auto` (follow
each account's browser). `UTC` is only what the shipped config examples
set explicitly. The static last tier of the resolution chain is `auto`,
not `UTC`.

Evidence: `src/config.cr:157-159` (`LocalizationConfig … default_timezone :
String = "auto"`), `src/settings/keys.cr:29-34` (`AUTO_TIMEZONE = "auto"`;
"the same value is the built-in default at every tier"), and the load
fallback at `src/config.cr:535` (`|| Facet::Settings::Keys::AUTO_TIMEZONE`).
`config.dev.yml:164-166` and `docker/config.production.example.yml:94-96`
both set `default_timezone: UTC` explicitly — the examples pin UTC, the
code does not. Live: `GET /Api/SystemSettings` on the instance returns
`localization.default_timezone = UTC` because the dev file sets it.

Found by WP 18 batch B (install/configure). Docs impact: the rewritten
languages page states the `auto` default and credits the shipped examples
for the UTC posture. The batch A `use/account`-adjacent pages that repeat
the UTC-default claim (if any) need the same one-line fix.

## #42 — The old email page claims Facet emails "multi-factor setup links"; no MFA email exists

Where: old `operate/email.md` (now
`site-docs/src/content/docs/admin/configure/email.md`, rewritten).

Docs say: "Facet sends email for the credential flows: password reset,
invites, first credentials, and multi-factor setup links."

Code does: the email module holds exactly three classes — invite,
password reset, and a test probe. MFA enrollment is TOTP-only: the setup
route returns the secret and the `otpauth://` URI in the API response; no
email leaves the server for MFA.

Evidence: `src/emails/` contains `base_email.cr`, `email_adapter_registry.cr`,
`invite_email.cr`, `password_reset_email.cr`, `test_email.cr`,
`config.cr`, `templates/` — no MFA class. `src/iam/routes.cr` (mfa
endpoints, also discrepancy #29) returns the secret in the response body.

Found by WP 18 batch B (install/configure). Docs impact: the rewritten
email page lists only invites and password resets, and cites the file
listing.

## #45 — Assistant availability comment says "any held role"; the code checks only the active role

Where: `src/assistant/workspace/routes.cr:89` (comment on the create-route
gate).

Docs say (the code comment): "any authenticated caller whose held roles do
not enable the assistant gets a 403" — availability aggregates over the
roles the account holds.

Code does: `Assistant::Access.allowed?`
(`src/assistant/access.cr:60-68`) resolves exactly one role —
`principal.active_role` — and checks its `connectivity` list for the
`assistant` channel. The `/Api/iam/me` gate agrees
(`src/iam/routes.cr:339-346`, same `Access.role_enabled?` on the active
role), and the UI hides the button on that answer. So an account holding
`sales` (assistant enabled) and `warehouse` (not) gets no assistant while
acting as `warehouse`, whatever the comment promises. Only the token
budget aggregates over held roles (`Access.effective_budget`, max over
enabling roles) — the asymmetry is documented in `access.cr:19-23`
itself.

Evidence: `src/assistant/access.cr:60-68`, `src/assistant/access.cr:19-23`,
`src/iam/routes.cr:339-346`, `src/assistant/workspace/routes.cr:86-95`;
live check 2026-11-26 as Tom — `/Api/iam/me` answers
`assistant.access: true` with the single `sales` role held.

Found by WP 15 batch B. Docs impact: none — the use/assistant.md page
documents the active-role rule. Fix status: code comment owed (route
handler comment should read "whose active role does not enable the
assistant"); maintainer triages.

## #43 — Old view-templates page called a read-only input binding an error

Where: `site-docs/src/content/docs/build/view-templates.md` (old page, at
`fd345fe3`; rewritten this batch as
`build/model/views/document-pages.md`).

Docs said: "Facet validates it against the doctype: an input bound to an
unknown field or a read-only field is an error."

Code does: the validator splits severity by consequence. An input bound to
an unknown field, a dotted path, or a container/computed field is an
`:error` (the form could never save the value). An input bound to a
`read_only` field is a `:warning` — the node renders but the value can
never be saved.

Evidence: `doc/backend/doctype-system.md` → Doctype::ViewTemplateValidator
severity table (`:warning` row: "any `input` / `input-*` node bound to a
**`read_only` field**"); `src/doctype/view_template_validator.cr`.

Found by WP 16 batch C. Docs impact: fixed in the rewrite — the page now
lists the error set and the warning set separately.

## #44 — Old display-names page understated the "neither template" check severity

Where: `site-docs/src/content/docs/build/display-names-search-text.md`
(old page, at `fd345fe3`; rewritten this batch as
`build/model/views/names-and-search.md`).

Docs said: a doctype declaring neither `display_name` nor `search` makes
"the check raise a warning" while a search term matches only the id.

Code does: for an **aggregate root** the check raises a `:defaults`
**`:error`** that counts toward `issue_count`, and the authoring gate
refuses to create or publish such a doctype (B-296 — the reference picker
would answer "no matches" while rows exist). An **owned child** is exempt
and gets an `:info` notice instead.

Evidence: `doc/backend/doctype-system.md` → Doctype::Check (`:defaults`
row) and Doctype::Validation (label gate B-296);
`src/doctype/validation.cr`.

Found by WP 16 batch C. Docs impact: fixed in the rewrite — the page now
splits the three cases (no `display_name`, no `search`, neither) with the
root/child severity difference.
