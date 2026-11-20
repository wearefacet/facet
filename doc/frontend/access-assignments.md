# Access assignment page

A two-mode assignment editor at `/Configure/access/assignments` that lets an operator grant or revoke roles on accounts. The page writes through the standard `PATCH /Api/iam/Account/:id` mutation; the role document itself is never mutated.

**Route:** `/Configure/access/assignments?mode=role|account&role=…&account=…`

The URL params make the view deep-linkable and survive reload and back/forward navigation.

**Source files:**

- `frontend/src/routes/Configure/access/assignments/+page.svelte` — thin page host; it owns the URL state and mounts the editor
- `frontend/src/lib/components/features/admin/RoleAssignmentEditor.svelte` — the two-mode editor (loaders, search debounce, membership mutations)
- `frontend/src/lib/authorization/roleMembership.ts` — pure helpers
- `frontend/src/lib/authorization/roleMembership.spec.ts` — Vitest unit tests

## Modes

| Mode | What it shows | What it writes |
|---|---|---|
| `role` | Pick a role → see its members (accounts with that role). Add/remove accounts. | `iam.Account.roles` of the targeted account |
| `account` | Pick an account → see its roles. Add/remove roles. | `iam.Account.roles` of the selected account |

Both modes share a single mutation path: `PATCH /Api/iam/Account/:id` with `{ set: [{ op: "replace", path: "/roles", value: [...] }] }`, optionally plus `{ op: "replace", path: "/default_role", value: ... }` when the change makes `default_role` stale (see below).

## Scaling

`iam.Account.roles` is an array of role document ids of the form `iam.Roles.{name}`. The list API has no array-contains filter, so "list accounts that have role X" cannot be answered with one filtered query. The two modes resolve this asymmetrically:

- **Mode `account`** (the scalable direction): the page fetches one account document (`GET /Api/iam/Account/:id`) and reads its `roles` array. The cost is bounded by the size of that array (typically small), not by the size of the account table. Resolves each assigned role id to its `iam.Roles` document with a single paginated `iam.Roles` list (the role table is small).
- **Mode `role`** mirrors the backend Lua delete-guard (`data/seeds/iam.Roles/script.lua`): it lists accounts once and filters client-side on `roles` membership. Facet targets mid-sized organizations where this scan is acceptable; if a single role's membership grows large, a dedicated backend endpoint is the right next step.

The two subject pickers (role / account) use `Select` in **async mode**: `onsearch` queries the server (`email__match` on accounts, `name__match` on roles), so a large account or role table does not load all rows at once. Results are debounced (200 ms) and capped at one page (25 items).

## `default_role` consistency

`iam.Account.default_role` references the same kind of id but is not auto-maintained by any backend hook. The pure helpers in `roleMembership.ts` return the next `roles` array together with the next `default_role`:

- `assignRole` / `unassignRole` return `{ roles }` always, and `defaultRole` **only when it must change** (`undefined` = unchanged — caller PATCHes only `roles`).
- When the removed role was the default, `default_role` is re-pointed to the first remaining assigned role, or cleared (`null`) when the account has no roles left.
- When the first-ever role is granted to an account with no default, that role becomes the default (matching the backend's login-time fallback so the persisted field stays consistent).

## Role id ↔ name

Role document ids follow the convention `iam.Roles.{name}`. `roleDocIdToName()` extracts the trailing `name` segment for display; the dots stay inside one URL segment, so the `[id]` route matcher does not split on them.

## Reset / refresh

The page re-fetches on:

- `page.url.pathname` change (re-entering the route tree),
- the global `facet:permissions-update` window event (token refresh / role change),
- `invalidateAll()` after each successful mutation,
- any change to the `mode` / `role` / `account` URL params (driven by the subject picker or the mode toggle).
