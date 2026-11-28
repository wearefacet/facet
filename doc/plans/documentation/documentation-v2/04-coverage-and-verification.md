# 04 — Coverage and verification

The site must stay complete while it becomes simpler. This file is the
system that guarantees it. Four mechanisms work together:

1. **The feature inventory** — every feature has an ID and at least one page.
2. **The surface ledger** — every user-visible surface (screen, command, key,
   endpoint group, tool) is reachable from at least one page.
3. **The claim ledger** — every important statement has a source in the code.
4. **The preservation checklist** — no true fact of the old site is lost.

Plus one human check at the end: **the fresh-eyes review** (WP 21).

---

## 1. The feature inventory

`site-docs/inventory.yml` holds 138 IDs in 10 areas (`AI`, `APP`, `AUD`,
`AUT`, `DOC`, `DOM`, `FE`, `IAM`, `PLT`, `RBC`). It was derived at commit
`c2f1427e`, when the product was still called Envelope. The code has moved on
since. **The inventory is not trusted until WP 10 refreshes it against the
current `HEAD`.**

The full descriptions behind each ID (what it does, entry point, sources) are
in `doc/plans/documentation/feature-list.md`. Use that file as the map from an
ID to its sources. Keep it in sync when WP 10 adds or changes IDs.

### 1.1 Coverage rules (stricter than today)

| Rule | Check | Where |
|---|---|---|
| **R1 — Every ID has a page.** Each inventory ID appears in the `features` of at least one English page, or in `coverage-exclude.yml` with a reason. | `check-coverage.mjs --strict` | exists today (warn mode); flips to strict in WP 21 |
| **R2 — Every ID has a task or explanation page.** At least one page with `type: how-to`, `tutorial` or `explanation` covers the ID. A reference page alone does not count. Exempt: IDs marked `reference-only: true` in the inventory, with a reason (for example, metric names). | new check, WP 11 | |
| **R3 — Every user-facing ID is reachable from L1.** Each ID that a user, author or admin can see is mentioned (with a link) on its tab's overview or group overview page, or on a Discover page. | WP 20 builds; WP 21 verifies by script | |
| **R4 — No unknown IDs.** Pages cite only IDs that the inventory holds. | `check-coverage.mjs` | exists today |
| **R5 — Every page cites the features it documents.** A how-to page with `features: []` fails, except overview pages. | new check, WP 11 | |

### 1.2 What "documents a feature" means

A page *documents* a feature when a reader can use the feature after reading
it: what it is for, how to turn it on or use it, its limits, and what to do
when it fails. A passing mention is not coverage; link to the documenting
page instead, and leave the ID out of `features`.

## 2. The surface ledger

Feature IDs are coarse: "FE-14 Configure platform" hides a dozen settings
screens. The surface ledger lists every concrete surface, so nothing falls
between two IDs. WP 10 builds it as
`doc/plans/documentation-v2/ledgers/surfaces.md`, one table per kind:

| Surface kind | Source of truth | Example row |
|---|---|---|
| Workspace and Builder routes | `frontend/src/routes/**` (`+page.svelte`) | `/Configure/audit` → FE-16 → `admin/history/audit.md` |
| Visible UI actions | `frontend/messages/en.json` (button and menu labels) | **Publish** → DOM-02 → `build/model/in-app/drafts-and-publishing.md` |
| HTTP route groups | `src/` route registration, `doc/api/openapi.json` | `POST /api/Audit/:id/rollback` → AUD-04 → `admin/history/roll-back.md` |
| `facet` CLI commands | the CLI registry (`doc/backend/cli.md`, `facet --help`) | `domain:export` → DOM-15 → `build/model/bundles.md` |
| `@facetapp/cli` commands | `packages/cli/` | `deploy` → APP-09 → `build/apps/host/deploy.md` |
| Config file keys | `src/config.cr` | `dev.domain_watch.path` → DOM-19 → `build/model/in-files/domain-watcher.md` |
| System settings keys | `doc/backend/system-settings.md`, source | `assistant.auto_execute_tools` → AI-08 → `admin/assistant/connect-a-model.md` |
| Account settings keys | `doc/backend/settings.md`, source | |
| Lua API functions | the Lua engine bindings (`doc/backend/lua-engine.md`) | |
| Jinja2 context variables | `doc/backend/templating.md`, source | |
| Agent tools | `src/agent_tools/` | `aggregate_documents` → AI-04 → `build/apps/agents/agent-tools.md` |
| Field types | field type sources | `money` → DOM-04, PLT-14 → `build/model/data/field-types.md` |
| Cron tasks | `src/cron/` | `mutation_compaction` → AUD-06 → `admin/history/retention.md` |
| Metrics and health names | metrics registry | |
| Error codes | error response sources | |

Each row has four columns: **surface**, **feature ID**, **page that explains
it** (L2), **reference page** (if generated). Rules:

- Every row needs an L2 page, *or* the surface is in a generated reference
  page **and** its family is explained on an L2 page (for example: every
  config key is in `reference/config-keys.md`, and each config *section* is
  explained on one how-to page).
- A surface with no ID means the inventory is missing a feature: WP 10 adds
  one.
- Content WPs update the "page" column for the rows they cover. WP 21 checks
  that no row is empty.

## 3. The claim ledger

`00-contract.md` §6 defines the format. Here is what to verify, and how.

### 3.1 Claims that must always be verified

- Every number: defaults, limits, timeouts, sizes, counts, retention days.
- Every name: UI label, config key, setting key, field, command, flag, route,
  error code, event name.
- Every security or governance statement: who can do what, what is logged,
  what is redacted, what is denied and how.
- Every "always", "never", "every", "only".
- Every behaviour across modes or channels ("the watcher also runs
  diagnostics", "API keys follow row scopes").

### 3.2 How to verify

Routing table (extends `doc/documentation.md` Rule 1):

| Claim type | Primary source | How |
|---|---|---|
| UI step, label, screen | the running app | Click through it. Paste or screenshot the result. |
| Label text | `frontend/messages/en.json` | Exact string match. |
| HTTP behaviour | `doc/api/openapi.json`, `src/` handlers | Read the handler; call the endpoint on the running instance with `curl` and paste the response. |
| CLI behaviour | `facet --help`, `@facetapp/cli --help`, source | Run the command on the running instance. |
| Config / settings key and default | `src/config.cr`, settings sources | Read the definition; note file and line. |
| Permission behaviour | `src/` RBAC/enforcement code, specs under `spec/` | Read the code and the spec that tests it. Prefer a spec as evidence: it states intended behaviour. |
| Domain definition behaviour | doctype validator, diagnostics, `doc/backend/doctype-system.md` | Build it in the Brightwater example and observe. |
| Assistant behaviour | `src/assistant/`, skill docs | Run it with a configured model when the environment has one; otherwise verify from code and mark "verified from code only". |

Evidence goes in the ledger as `path:line`, a command with its output, or
"UI @ <SHA>: <what you saw>".

### 3.3 When sources disagree

1. Code beats `doc/` concern files. Code beats the current site.
2. A spec beats a reading of the implementation, when they agree on intent.
3. If the code and its spec disagree, or the behaviour looks like a bug, do
   not document either version as fact: log a discrepancy, write the page
   around it (or leave a visible `:::caution` that says the behaviour is
   under review only if the maintainer approves), and report it.

## 4. Content preservation

Rewriting 140 pages is where facts get lost. The preservation checklist
(`00-contract.md` §5) prevents it:

- **Before** rewriting an old page, list every heading, table, aside, code
  block and limit it contains.
- **After** rewriting, each item points to its new home (this page, a deeper
  page, a reference page) or carries a reason for the cut.
- WP 11 saves a copy of every old page that is split or merged under
  `doc/plans/documentation-v2/ledgers/originals/<old path>`, so the second
  owner of a split can read the original after the first owner rewrites it.
  (The git history also holds it; the copy saves time.)
- WP 21 samples 20 old pages at random and checks their checklists against
  the new site.

Allowed reasons to cut a fact: it is false at the verified commit; it
duplicates a fact on another page (name it); it describes engineering
internals with no user-visible effect (move to a `doc/` concern file link
instead, never mirror).

## 5. Staleness

The existing staleness report (90 days since `verified_at`) stays. In v2,
every rewritten page gets a fresh `verified_at`. A `move` with no rewrite
keeps the old value — and so will show as stale sooner, which is correct.

## 6. The fresh-eyes review

Automated checks prove that features are *present*. Only a reader proves
they are *understandable*. WP 21 runs a review agent that has never seen the
code or this plan, gives it only the built site, and asks it to complete the
newcomer tasks listed in `21-wp-review.md`. Every place it gets lost becomes a
fix.
