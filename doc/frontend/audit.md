# Audit Pages

**Files:** `frontend/src/routes/Configure/audit/+page.svelte`, `frontend/src/lib/components/features/audit/` (`GlobalAuditTable.svelte`, `AuditDetail.svelte`, `History.svelte`, `HistoryDetailPane.svelte`, `historyDetail.ts`, `AuditSource.ts`, `auditDiff.ts`, `auditFilters.ts`)

Two audit surfaces share the change-inspection machinery in `auditDiff.ts` and `ChangeList.svelte`:

- The **global audit log page** (`/Configure/audit`) — every mutation across all domains, with filters and global rollback.
- The **document history page** (`/{domain}/{doctype}/{id}/history`) — one document's mutation timeline, with revert (see the section at the end).

The global audit log page renders the append-only `mutations` log across all domains. It is the Configure-shell surface for `GET /Api/Audit` (global list) and `POST /Api/Audit/:mutation_id/rollback` (global rollback), both provided by `Audit::List` and `Audit::Rollback` on the backend (see [`backend/audit.md`](../backend/audit.md)).

The page owns filter and pagination state and delegates rendering: `GlobalAuditTable` renders the table, filter bar, and prev/next pagination; `AuditDetail` renders the change inspector and the rollback action with a confirm dialog. A `QuickViewHost` wraps the layout: clicking a document capsule (in a row or in the detail panel) opens the document in the QuickView peek drawer through `openReference`; clicking the row itself selects it for the detail panel.

## Data layer (`AuditSource.ts`)

| Export                                   | Description                                                                      |
| ---------------------------------------- | -------------------------------------------------------------------------------- |
| `listAudit(params, fetchFn?)`            | `GET /Api/Audit` via `apiFetch`; returns `HistoryResponse`.                      |
| `rollbackMutation(mutationId, fetchFn?)` | `POST /Api/Audit/:mutation_id/rollback`; returns `RollbackResponse`.             |
| `buildAuditQuery(params)`                | Builds the query string (`page`, `items`, `sort` joined by `,`, `filters[key]`). |
| `normalizeDocId(docId)`                  | Strips a qualified `domain.Doctype.id` form to the bare id.                      |
| `docHref(m)`                             | Builds the live-document link `/{domain}/{doctype}/{id}`.                        |
| `AuditError`                             | `Error` carrying the HTTP `status`, so the page renders `403` distinctly.        |
| `AuditFetch`                             | Fetcher type; injectable for tests.                                              |

## Table

Columns: Action (badge), Document, Actor, Channel, When. Both the document and the actor render as doctype `Capsule`s (hydrated `display_name` + doctype tint via the driver; the actor capsule resolves `iam.Account` from the bare id with a `qualifiedDoctype` hint). An actor capsule whose actioner is an account (bare ULID or qualified `iam.Account.id`) is clickable and opens the account in the QuickView peek drawer; machine principals (`system`, `system:rollback`, …) render as plain mono text instead of a failed capsule (see `isAccountActioner` in `auditDiff.ts`). The Channel cell renders `channelLabel(m.channel)` — the `session` channel shows as `facet`, every other channel verbatim — in plain mono with the wire value on the hover title (categorical, so no tint). The `AuditDetail` panel is sticky with an internal scroll region, so long change lists do not push it out of the viewport.

## Filters

The table renders the shared, schema-aware `FilterBar` (`+ Add filter` menu + one chip per active filter, each chip with an operator dropdown and a value control) — the same filter surface the listing tables use. The schema comes from `auditFilters.ts`: `auditFilterDoctype({ domains, doctypes, apps })` builds a `DoctypeDef`-shaped schema whose fields map 1:1 to the filter grammar `Audit::List.build_column_filter` answers (`src/audit/list.cr`). The bar renders no search box: no audit field declares `match`, so the bar can never emit a key the backend silently drops. The page passes `showSystemTimestamps={false}` — the audit backend has no `created_at`/`updated_at` branch, so the bar must not offer them.

| Field         | Type                      | Operators    | Values                                                                                                                                                                                                            |
| ------------- | ------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `action`      | enum                      | `eq`, `ne`   | create / update / delete / snapshot                                                                                                                                                                               |
| `channel`     | enum                      | `eq`, `ne`   | `session` (labeled `facet`), `oauth_app`, `app_api_key`, `api_key`, `mcp`, `internal`                                                                                                                             |
| `kind`        | enum                      | `eq`, `ne`   | the full `Mutation::CauseKind` vocabulary (`request`, `action`, `hook_event`, `hook_schedule`, `replication`, `cascade`, `rollback`, `migration`, `periodic_snapshot`, `webhook_test`, `assistant`, `compaction`, `seed`) |
| `domain`      | enum                      | `eq`         | dynamic — registry domains                                                                                                                                                                                        |
| `doc_type`    | enum                      | `eq`         | dynamic — registry doctypes in the qualified `domain.Doctype` form; one pick pins domain and doctype at once (the backend splits the value into the conjunct — the bare column is ambiguous across domains)       |
| `app`         | enum                      | `eq`, `ne`   | dynamic — `app.App` documents                                                                                                                                                                                     |
| `actioner_id` | reference → `iam.Account` | `eq`, `ne`   | server-searched combobox (the account's first `string` field is `email`, the one field declaring `text_search`); machine principals are not documents and cannot be picked                                        |
| `trace`       | string                    | `eq`         | causal cluster id (paste a `cause_trace` ULID)                                                                                                                                                                    |
| `emitted_at`  | datetime                  | `gte`, `lte` | `DatetimePicker` chips — wall time in the user's `core.timezone`, committed value UTC RFC-3339                                                                                                                    |

The domain, doctype, and app enums start empty and fill from the `core.DocType` registry and the `app.App` list on mount; the schema rebuilds and the pickers update reactively. Default sort: `-emitted_at`. The doctype picker lists qualified `domain.Doctype` entries, so filtering `crm.Invoice` constrains domain and doctype in one chip; the domain chip stays for domain-only filtering. The chips are independent and AND together — a stale combination (doctype `crm.Invoice` with domain `erp`) simply returns no rows.

- The `emitted_at` bounds use the `DatetimePicker` (compact mode, see [`datetime-picker.md`](datetime-picker.md)): the user enters wall time in their `core.timezone` zone and the committed value is UTC RFC-3339 — no further conversion before the request.
- The detail panel shows the actor as an `iam.Account` capsule (clickable → QuickView through `onOpenActor`; machine principals render as plain text), then the mutation's `channel` and `app` (resolved to the app display name) in a metadata row. The `session` channel label (filter option, table cell, and the `via` line) renders as `facet` — the wire value stays canonical (`channelLabel` in `auditDiff.ts`).

## Change list (`ChangeList.svelte`)

`AuditDetail` renders the mutation's diff through the shared `ChangeList` (the document history drawer uses the same component in `side` layout; the audit panel uses `stacked`). Rendering rules, all driven by `auditDiff.ts`:

- Entries group by kind — one kind badge per group, ordered `init` → `set` → `patch` → `unset` → `redacted` (`groupChanges`); the within-group order stays the diff's original order.
- Values longer than `VALUE_PREVIEW_LIMIT` (1024 characters) truncate with a trailing ellipsis; the hover `title` carries the full text (`truncateValue`).
- `unset` entries show the removed note; `patch` entries show the patch-applied note (the raw patch object never renders).
- `redacted` entries — the server removed the value because the caller's role cannot see the field. The row carries the mutation record's `redacted` metadata (arrays of path segments, `MutationRecord.redacted`); a `set`/`patch` entry whose path appears there renders as a valueless "Value hidden" chip (localized, `audit_change_redacted`), and create/snapshot hidden fields render the same way. `unset` entries never become redacted rows (no duplicate). Rollback eligibility ignores the redaction metadata — the server re-checks the actual transition.

## Rollback gating (UI hints only — the backend re-checks)

- Per-row gate on `can(domain.doc_type, 'update')`.
- Disabled for `delete` targets (backend returns `422` for tombstone targets) and `snapshot` mutations.
- Disabled for the document's newest mutation in the loaded page (rollback would be a no-op).
- Confirm dialog names the target document and mutation id; backend errors (`403`/`422`) surface inline.
- After a successful rollback the page reloads the list (the rollback writes a new `snapshot` mutation).

## Capped count behaviour

`meta.count` is capped at 1000 and `more` signals rows past the cap. The page never displays an exact total when `more` is true; pagination is prev/next driven by `more`.

## Authorization

The global list requires wildcard `read` on `*.*`. `can('*.*', 'read')` cannot express this client-side, so the page renders and fails honestly on `403` with a permission message (matching the "UI hints, backend decides" doctrine in `permissions.svelte.ts`).

## Testing

- `AuditSource.spec.ts` — pure-logic Vitest (`server` project): query building, response parsing, error mapping, `docHref`/`normalizeDocId`, `datetimeLocalToUtc`.
- `auditFilters.spec.ts` — pure-logic Vitest (`server` project): the filter schema's keys, operators, control kinds, and enum vocabularies — including the guard that every emittable `field__op` key is one the audit backend answers.
- `auditDiff.spec.ts` — pure-logic Vitest (`server` project): change grouping, value truncation, channel labels, account-actioner detection, cause-kind provenance rule.
- `historyDetail.spec.ts` — pure-logic Vitest (`server` project): derivations behind the history detail pane (cause chips, actor labels, child rows).
- Stories (`GlobalAuditTable.stories.svelte`, `AuditDetail.stories.svelte`, `ChangeList.stories.svelte`, `History.stories.svelte`) — component tests via play functions: rows/badges and capsules (including the actor capsule's QuickView click), row select, filter-chip rendering from a seeded filter map (chip interaction lives in the FilterBar's own stories), the channel column, `more`-driven pagination, grouped/truncated change rendering, rollback gating and confirm flow, cause badges, the detail header's channel/cause chips, version chip, and change stats, controlled selection, deep-link resolution.

## Document history page (`/{domain}/{doctype}/{id}/history`)

**Files:** `frontend/src/routes/[domain=notApi]/[doctype]/[id]/history/{+page.svelte,+page.ts}`, `frontend/src/lib/components/features/audit/` (`History.svelte`, `HistoryDetailPane.svelte`, `historyDetail.ts`)

The document history page renders one document's mutation timeline through the `History` component: timeline rows (action badge, child-document badge, summary, actor, relative time) and a detail pane (rendered by `HistoryDetailPane.svelte`; its derivations live in `historyDetail.ts`) whose header is four rows — **what** (action badge, doctype, document label, `v{idx}` version chip), **who** (actor capsule, `via` + a channel/cause chip), **when** (full date in the viewer's timezone, relative time), and **ref** (truncated mutation id with a `CopyButton`, set/patch/unset counts) — followed by the `ChangeList` and the revert action. The page load resolves the doctype definition plus the document's display name and version for the header (the name rides into the component as `documentLabel`, the fallback when the loaded records carry no `display_name`); the component fetches the history through `documentRef.history()` in aggregate mode (`include=children`), with the `driver` used to route child-row reverts.

The revert action is gated by a confirm dialog — the same rule the global audit page applies (see **Rollback gating** above). The dialog names the target document (`domain.doctype`, document id) and the mutation id, states that a new snapshot mutation will be written, and offers Cancel and Roll back. Cancel closes the dialog and makes no request; Roll back runs the same revert flow (child rows through the driver-resolved ref). The dialog lives in `HistoryDetailPane.svelte` beside the revert button and reuses the global page's confirm wording (`audit_confirm_single_title`, `audit_confirm_update_desc`, `audit_confirm_delete_desc`). As on the global page, the dialog stays open while the rollback runs (the confirm button disables), and the inline `revertError` line in the actions footer shows a backend error once the dialog closes.

### Cause provenance

Every row whose `cause_kind` is not `request` carries a `via <…>` badge. An action write names the transport and rides the action name alongside — `via facet · confirm` (`cause_name` as the sub-label; `viaLine` in `auditDiff.ts`, the same rule the detail chip applies) — while the other kinds keep the humanized kind label: `via Assistant` for a workspace-assistant write, `via Rollback`, `via Cascade`, `via Hook Event`, … The detail header's who row mirrors the badge in its `via` chip (`viaChip` in `historyDetail.ts`): the transport with `cause_name` as the sub-label for actions, the humanized kind with `cause_name` for the rest. A plain request falls through to the auth channel: the chip shows `channelLabel` (`session` renders as `facet`) with the elected `acting_role` as the sub-label (stamped on every authenticated channel; on `api_key` / `app_api_key` rows the masked key tail wins the sub-label slot). The badge is what tells an LLM-driven write apart from a plain session edit: a workspace-assistant document write records the caller's own account as the actor and the session channel, with `cause_kind = assistant` as the only distinguishing mark (see [`backend/workspace-assistant.md`](../backend/workspace-assistant.md)).

### Shareable selection (`?mutation=<ulid>`)

The page owns the selection through the URL. `?mutation=` names the inspected mutation; every selection — deep link included — mirrors back into the address bar through `setSearchParams` (a `replaceState` navigation, so no history entries pile up). Opening a shared link selects that mutation directly; the component receives it through its controlled `selected` prop and reports row clicks through `onSelect`.

When the URL names a mutation the first page does not hold, the component keeps fetching older pages (`HistoryParams.page`) until the mutation appears, bounded at 10 pages. A selection that stays unresolved after that bound shows a dedicated message ("not in the loaded history") instead of the generic select hint.
