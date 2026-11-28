# Collection View

A CollectionView is a saved **listing surface configuration** for a doctype's document listing — the set of tabs shown above the table on a `[domain]/[doctype]` listing page. Each view carries a tab label (`name`) and a surface-specific `config`. Four surfaces exist: **table** (an ordered column set), **calendar** (a date-based grid), **kanban** (lane-based cards), and **grid** (spreadsheet-style cells). Views are either **general** (shared, `owner_id` absent) or **personal** (`owner_id` bound to the creator's account).

`core.CollectionView` is a child doctype of `core.DocType` (`member_of: DocType`). Parent linkage is carried by the system-managed `meta->>'parent_id'`; there is deliberately **no `parent_doctype` content field** — the children system already encodes the parent.

This is distinct from `core.DocumentView` (the per-**document** presentation template: `view`/`form`/`inline`/`card`/`quickView`). CollectionView governs the **listing** surface; DocumentView governs single-document render modes. Do not overload one for the other.

## Source files

| File                                                                  | Role                                                                                   |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `data/seeds/core.CollectionView/definition.yml`                       | Doctype definition — fields, scopes, child declaration                                 |
| `data/seeds/core.CollectionView/script.lua`                           | Lua lifecycle hooks: `export.create`, `export.update`                                  |
| `data/seeds/core.DocType/definition.yml` (`children.collection_view`) | Declares CollectionView as a child of `core.DocType`                                   |
| `src/doctype/collection_view_title_template.cr`                       | `CollectionView::TitleTemplate` — authoring-time calendar title-template validation    |
| `src/document/collection_view_gate.cr`                                | `Document::CollectionViewGate` — per-surface `config` rules at the write doors and in `/check` |
| `src/rbac/read_enforcer.cr`                                           | OR-joined scope expansion (general + personal) via `list_where_clauses`                |
| `src/document/list.cr`                                                | Threads RBAC scope clauses into the listing SQL                                        |
| `spec/integration/collection_view_spec.cr`                            | Schema, HTTP child CRUD, RBAC scoped behavior                                          |
| `spec/doctype/collection_view_no_seed_spec.cr`                        | No default view: doctype create and boot seed leave doctypes viewless                  |
| `spec/doctype/collection_view_title_template_spec.cr`                 | Title-template validator unit rule set                                                 |
| `spec/doctype/collection_view_title_template_gate_spec.cr`            | Write-path gate: create / update / rename on the merged document                       |
| `spec/document/collection_view_gate_spec.cr`                          | Write-path `config` gate: per-surface rules, replace-on-write                          |

## Routes

CollectionView is reached as a **child collection** of its parent `core.DocType`:

| Method   | Path                                              | Action                                   |
| -------- | ------------------------------------------------- | ---------------------------------------- |
| `GET`    | `/Api/core/DocType/:id/collection_view`           | List views (general + caller's personal) |
| `POST`   | `/Api/core/DocType/:id/collection_view`           | Create a view                            |
| `GET`    | `/Api/core/DocType/:id/collection_view/:child_id` | Read a view                              |
| `PATCH`  | `/Api/core/DocType/:id/collection_view/:child_id` | Update a view                            |
| `DELETE` | `/Api/core/DocType/:id/collection_view/:child_id` | Delete a view                            |

The `:id` is the parent `core.DocType` projection id. Nested routing gates the immediate parent via `ReadEnforcer.parent_authorized?` before delegating to `Document::List` / `Document::Read`.

**Authorization.** The child gate runs on the composition path `["DocType", "CollectionView"]`. Reading the doctype implies reading its views: a role holding only `read {domain}.{Doctype}` lists and reads every view of that doctype without a grant on `core.DocType.CollectionView` (see [`rbac.md`](rbac.md) → Definition and domain visibility). Writes keep their own grants — `create`, `update`, and `delete` on the composition path are required to author a view.

The list route serves the whole child collection: it takes no `page` / `items` (a caller-supplied `items` is not forwarded).

## Fields

| Field      | Type                        | Required | Description                                                                                                                                                                                                                                                                                                         |
| ---------- | --------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`     | `string`                    | yes      | Tab label shown in the listing UI (e.g. "All", "My Pipeline")                                                                                                                                                                                                                                                       |
| `surface`  | `enum`                      | yes      | Presentation layout: `table`, `calendar`, `kanban`, or `grid`                                                                                                                                                                                                                                                       |
| `config`   | `object`                    | —        | Surface-specific config. For `table`: `{ columns: [{ key, label?, width?, editable? }] }`. For `calendar`: `{ calendar: { discriminator, end_field?, color_by?, title_template?, week_start } }`. For `kanban`: `{ kanban: { mode, group_by?, lane_order?, hidden_lanes?, lanes?: [{ label, color?, filter }], filters?, sort?, page_size?, allow_move? } }`. For `grid`: `{ columns: [{ key, label?, width?, summary?, editable? }], grid: { frozen?, filters?, sort?, allow_create? } }` |
| `owner_id` | `reference` (`iam.Account`) | —        | Creator account id for personal views; null for general views. Forced by the Lua create hook from the matched permission's scope; **immutable** after create                                                                                                                                                        |

## Config validation

On every create, and on an update whose patch carries `config`, the `config`
is validated against the **parent** doctype's definition
(`Document::CollectionViewGate`). An unusable config answers `422` with field
paths instead of landing and rendering an empty surface. The rules, per
`surface`, mirror the frontend editor (`frontend/src/lib/collectionView/config.ts`):

| Surface    | Rule |
|---|---|
| `table`    | at least one column; every column `key` is a declared parent field or a system timestamp (`created_at` / `updated_at`) |
| `calendar` | `discriminator` exists and serves the window filter — a `period` / `dateperiod` range type, or a `date` / `datetime` field with both `gte` and `lte` |
| `kanban`   | `mode` is `values` or `custom`; `values` needs a `group_by` that exists, is writable, is `enum` / `boolean`, and serves `eq`; `custom` needs at least one lane |
| `grid`     | at least one column; every column `key` is a declared parent field or a system timestamp; a `summary` needs an aggregate-able type (`count`, or `sum`/`avg`/`min`/`max` on `integer`/`duration`/`money`); `editable: true` only on a writable field; `grid.frozen` is an integer in `0..columns`; `grid.filters` keys serve their operators; `grid.sort` entries exist and are sortable |

The public entry points are `CollectionViewGate.errors(db, parent_id, document)`
(reads `config` and `surface` from the content) and
`CollectionViewGate.errors(db, parent_id, config, surface)` (the update door,
which passes the submitted config). `CollectionViewGate.validate(config,
surface, definition)` is the pure rule set with no database access.

`config` **replaces on write**: a PATCH that carries `config` replaces the
stored object instead of merging into it (see [mutation.md](mutation.md) →
Write-time coalescing and the `Document::Update` replace-on-write set), so the
gate validates the submitted config, never a merge product.

## Title template validation

On every create, and on an update whose patch touches `config`, the calendar
`config.calendar.title_template` is validated against the **parent** doctype's
definition (`Doctype::CollectionView::TitleTemplate`): the template must
compile, and every root variable must reference a declared field of the parent
doctype, the reserved `content` variable, or a system timestamp
(`created_at` / `updated_at`). The `display_name` root is rejected — the client
renderer does not bind it, and the display name is what a chip shows when the
view stores no template. Failures answer `422` with `code: "template"` on
`config.calendar.title_template`.

A patch that does not touch `config` skips the check, so a rename of a view
whose template went stale after a parent-doctype change still passes (the
client renderer tolerates unknown fields, rendering them empty). The portable
import runs the same gate per bundled row, so an import cannot land a state
the API refuses to re-save.

The template renders client-side only — see
[`frontend/templating.md`](../frontend/templating.md) for the render rules.

## Config validation

`Document::CollectionViewGate` validates the `config` against the parent doctype's definition on create, and on an update whose patch touches `config`. Each surface has its own rule, mirroring the frontend editor (`frontend/src/lib/collectionView/config.ts`):

| Surface    | Rule |
| ---------- | ---- |
| `table`    | at least one column; every column `key` is declared on the parent doctype (or is `created_at` / `updated_at`) |
| `calendar` | `discriminator` exists and serves the window filter — a `period` / `dateperiod` range type, or a `date` / `datetime` that serves `gte` + `lte` (the `comparison` capability) |
| `kanban`   | `mode` is `values` or `custom`; `values` needs a `group_by` that exists, is writable, is `enum` / `boolean`, and serves `eq` (the `equality` capability); `custom` needs at least one lane |
| `grid`     | at least one column; every column `key` is declared on the parent doctype (or is `created_at` / `updated_at`); a `summary` needs an aggregate-able type (`count`, or `sum`/`avg`/`min`/`max` on `integer`/`duration`/`money`); `editable: true` only on a writable field; `grid.frozen` is an integer in `0..columns`; `grid.filters` keys serve their operators; `grid.sort` entries are known and sortable |

A failure answers `422` with the `config.…` field path and a code (`required`, `unknown_field`, `unsupported_field`, `invalid_value`).

`GET /Api/core/DocType/:id/check` runs the same rule set (`CollectionViewGate.validate`) on every live view and reports each failure as a `:view` **warning**, naming the view, the field, and the capability it lacks — the check endpoint never blocks. See [`doctype-system.md`](doctype-system.md) → Doctype::Check.

## Scopes

Two named scopes are declared on the doctype:

```yaml
scopes:
  mine:
    description: "Personal views owned by the actioner"
    where: { owner_id: "$self" }
  general:
    description: "General (shared) views with no owner"
    where: { owner_id: "$null" }
```

- `$self` — resolves to the actioner's account id.
- `$null` — matches rows whose `owner_id` is absent or JSON null (general/shared views).

## RBAC behavior

A read role typically declares a single `read` permission whose `scope` is the combined alias array `["$mine", "$general"]`. The enforcer expands each alias into its own OR clause inside one parenthesised group, so the listing SQL returns the union of the caller's personal views and every general view — one round trip, no client-side merge.

### Create

RBAC `create` does **not** consult `scope` (the row does not exist yet). Instead, the Lua `export.create(ctx)` hook coerces `owner_id` based on the matched `create` permission's scope alias, surfaced on `ctx.actor.scope`:

- `ctx.actor.scope == "mine"` → the hook force-sets `ctx.root.owner_id = ctx.actor.id`. Any caller-supplied `owner_id` that is non-nil and not equal to the caller is rejected (prevents hijacking another account's personal view).
- `ctx.actor.scope == nil` (unrestricted) → `owner_id` is left as-is; the caller may create a general view (omit `owner_id`) or a personal view (any account id) — unrestricted create doubles as both.

See [`rbac.md`](rbac.md) → Enforcement rules → WriteEnforcer for the general create/scope contract.

### Update / Delete

Update and delete use their own `update`/`delete` permissions, scoped `$mine` for self-only or unrestricted for admins. The Lua `export.update(ctx)` hook makes `owner_id` **immutable**: it re-fetches the persisted original via `document.get` (because `ctx.root` on update is the patch-merged document) and rejects any change to `owner_id`. To switch a view between general and personal, create a new view and delete the old one.

## Frontend consumption

The listing route `frontend/src/routes/[domain]/[doctype]/+page.ts` resolves the parent `core.DocType` projection and hands a `DocumentDataDriver` + the projection id to `frontend/src/lib/components/primitives/data/ListView.svelte`. `ListView` fetches the `collection_view` children itself (so an editor save can refetch without a full page reload) and renders one tab per view. The `?view=` query param deep-links a tab: `ListView` matches the param against each view's URL slug, and the dashboard's pinned-view cards and saved-view sub-links (`DomainDashboard.svelte`) build their listing links with the same helper (`frontend/src/lib/collectionView/slug.ts`). The slug comes from the view's `name` — lowercased, runs of non-alphanumerics folded to one `_` (`All Records` → `all_records`). Runtime view ids are ULIDs (the fixture import and the HTTP create mint fresh ids), so the id carries no slug; a view id that still follows the `<qualified>.collection_view.<slug>` authoring convention (fixture bundles, mock data) answers to its id slug first, so older links keep working. A `showTabs={false}` prop skips the fetch and the strip entirely — the listing renders the fallback columns straight away with no saved-view affordances (used by the accounts admin surface, see `doc/frontend/access-accounts.md`). A doctype with **zero** views renders the starter screen (`CollectionViewStarter.svelte`) instead of a strip — there is no synthetic tab and no view row is ever created implicitly (see [No default view](#no-default-view) below). For the `table` surface, columns come from `view.config.columns`, falling back to the doctype's first eight flat fields when `config.columns` is absent. For the `calendar` surface, `ListView` renders `frontend/src/lib/calendar/Calendar.svelte` with `view.config.calendar`. For the `kanban` surface, `ListView` renders `frontend/src/lib/kanban/Kanban.svelte` with `view.config.kanban` — one `list()` call per lane, cards rendered through the doctype's `card` view template (see `frontend/kanban.md`). For the `grid` surface, `ListView` renders `frontend/src/lib/grid/Grid.svelte` with the shared `view.config.columns` (plus the grid-only `summary` / `editable` flags) and `view.config.grid`; trash mode falls back to the table (see `frontend/grid.md`). See `frontend/src/lib/collectionView/types.ts` for the TypeScript shape.

The `CollectionViewEditor` column picker lists the doctype's flat fields plus the system-managed timestamp columns `created_at` and `updated_at`, marked `Created At` / `Updated At` (`SYSTEM_TIMESTAMP_FIELD_DEFS` — the same virtual field defs the filter bar uses). The editor's pure config logic lives in `frontend/src/lib/collectionView/config.ts` (`pickableFields`, `defaultColumns`, `dropUnknownFilter`, `buildConfig`, `buildPayload`, `validateDraft` — Vitest-tested), and the wizard steps render through `CollectionViewSurfaceStep` / `CollectionViewColumnsForm` / `CollectionViewCalendarForm` / `CollectionViewKanbanForm` / `CollectionViewGridForm` co-located with the editor. A saved column with one of those keys reads the row's `meta` timestamps, which the table flattens onto each row, and the backend list endpoint sorts on the `projections` columns directly.

The calendar surface is offered for **every** doctype: the editor's discriminator picker (`discriminatorFields`) lists the schema's date/datetime/period/dateperiod fields plus the two system timestamps, so a doctype with no date field of its own anchors its calendar on `created_at` or `updated_at` (either can also serve as an `end_field` range bound for the other). Each candidate must serve the filter the surface emits for it: a date/datetime discriminator window-filters `__gte`/`__lte` on the field itself and so needs the backend's `comparison` capability, while `period` / `dateperiod` take the native-range path (no window filter — the grid narrows client-side) and carry no operator requirement. The end-field picker (`endFields`) applies the same rule to the range bound (`end_field__gte`). A stored view whose discriminator or end field lost its capability since it was saved fails `validateDraft` and cannot re-save. `Calendar.svelte` resolves the same defs as virtual fields and flattens the row's `meta` timestamps onto the document content before rendering chips — the same loader contract the table uses — and the window filters (`created_at__gte` / `__lte`) compile on the backend through `Document::FilterCompiler.SYSTEM_TIMESTAMP_FIELDS`.

### Inline-edit columns

A table column may carry `editable: true` (the CollectionViewEditor exposes an **Inline edit** checkbox on boolean columns). When the column resolves to a plain `boolean` field of the doctype — not `read_only` / `write_only` — and the active role holds `update` on the doctype (`can()` from `$lib/permissions.svelte`; the backend WriteEnforcer re-checks every mutation), the `Table` renders the cell as a toggle (green `✓` / red `✕`, matching `DvtValue`) that PATCHes `{ [key]: next }` straight through the DataSource. The flip is optimistic and reverts with an error toast when the update fails; a cell toggle never triggers the row's peek (`stopPropagation`). Read-only boolean cells render the same green/red marks without the toggle. Trash-mode listings never offer the toggle (tombstones cannot be updated).

The `+` (create) and edit affordances are gated by `<Can doctype="core.CollectionView" action="create"|="update">`. The General-vs-Personal toggle inside the editor (`CollectionViewEditor.svelte`) is gated by `<Can ... scope="unrestricted">` and reflects the **same** scope info the Lua `export.create(ctx)` hook uses: the IAM permission manifest now ships a parallel `scopes` map (see [`iam.md`](iam.md)) whose `scopes["core.CollectionView"]["create"]` is `[]` when the `create` permission is unrestricted (general-capable) or `["mine", …]` when scoped (personal-only). The frontend `canScope(doctype, action)` helper reads it; `owner_id` is set client-side for personal views only because the Lua hook only force-binds it for `$mine`-scoped creators — an unrestricted creator must opt in explicitly.

## No default view

A doctype starts with **zero** collection views. Nothing creates a view
implicitly — not the doctype create transaction, not the boot seed, no
code path. Views are always user-authored: from the frontend starter
screen, the view editor, REST, or an agent tool.

The frontend listing renders the **starter screen** (`CollectionViewStarter.svelte`)
when a doctype has no views — live listing and trash mode alike. It offers
one card per surface (table, kanban, calendar); picking one opens the view
editor with that surface preselected. The editor's create default is a
**personal** view (`owner_id` = the viewer) — a `$mine`-scoped creator can
only create personal views (the Lua hook force-binds `owner_id`), and an
unrestricted creator can flip the toggle to general before saving. Without
the `create` permission on `core.CollectionView` the starter shows an
explanatory note instead of the cards.

The check service reports the viewless state as an `:info` notice (category
`:view`): `No CollectionView defined for <qualified> — the listing shows the
view starter. Create at least one collection view (table, kanban, or
calendar) so the doctype has a listing surface.` The notice is not a
warning — nothing is broken. The domain-builder agent reads the check
output and creates views for the doctypes it authors.

Deleting the last view of a doctype is final: the starter screen returns,
and nothing recreates the view. The frontend fallback column rule in
`ListView.fallbackColumns()` applies only to a saved view whose
`config.columns` is absent or empty, and to the tab-less admin listings
(`showTabs={false}`) — never to a viewless doctype.

Existing databases upgraded from releases that seeded an `All Records` view
keep those rows: they are ordinary views from now on, editable and
deletable like any other, and a delete stays deleted.

## Pinning

A view's **pinned** state is a personal, per-account preference, distinct from
the view's own general/personal ownership. Pinned views are recorded in account
settings under the `core.pinned_collection_views` key as an array of
CollectionView projection ids (see [`settings.md`](settings.md)), so an account can
pin either a general or a personal view. The pin is not a field on
`core.CollectionView` and does not affect its RBAC; it is the frontend
`ListView` that renders the pin toggle and persists it via the settings store.

Every listing tab is a real CollectionView row with a projection id, so any
tab can be pinned. A doctype with zero views has no tabs — the starter
screen offers to create the first one.
