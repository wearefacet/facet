# Access roles page

The role administration surface at `/Configure/access/roles`. The list page hosts the RBAC grants editor; each role also has a detail page with three tabs (Details / Members / Grants). Roles are application-global `iam.Roles` documents: grants are per-doctype permission lines, members are `iam.Account.roles` assignments, and the role powers (connectivity channels, assistant token budget) are fields on the role document itself.

**Routes:**

- `/Configure/access/roles?role={name}` — roles list with the grants editor; `?role=` deep-links a selection
- `/Configure/access/roles/{id}` — detail layout with the Details / Members / Grants tabs; `{id}` is the qualified role document id `iam.Roles.{name}`
- `/Configure/access/roles/{id}/details` — mutable role fields (level, description, powers)
- `/Configure/access/roles/{id}/grants` — per-doctype permissions for one role
- `/Configure/access/roles/{id}/members` — accounts holding the role

**Source files:**

- `frontend/src/routes/Configure/access/roles/+page.svelte` — roles list; hosts the editor, the new-role dialog, and the per-role member counts
- `frontend/src/routes/Configure/access/roles/[id]/+layout.svelte` — detail tab layout
- `frontend/src/routes/Configure/access/roles/[id]/details/+page.svelte` — Details tab
- `frontend/src/routes/Configure/access/roles/[id]/grants/+page.svelte` — Grants tab
- `frontend/src/lib/components/features/admin/RbacEditor.svelte` — the grants editor (shared by the list page and the Grants tab)
- `frontend/src/lib/components/features/admin/NewRoleDialog.svelte` — role creation dialog (name, level, description)
- `frontend/src/lib/components/features/admin/rbacModel.ts` — tree build, editor-state load/serialize, role content shape
- `frontend/src/lib/iam/content.ts` — shared `iam.Roles` content types and the `CONNECTIVITY_CHANNELS` vocabulary
- `frontend/src/lib/iam/roleBudget.ts`, `frontend/src/lib/iam/roleLevel.ts`, `frontend/src/lib/iam/roleTags.ts` — budget, level, and tag-union form helpers
- `frontend/src/lib/unsavedEdits.ts` — the shared unsaved-edits gate (tab navigation + `beforeunload`)

## Grants editor

`RbacEditor` renders a role picker, the per-doctype permission tree (one scope picker per grantable action), and Save / Discard / Delete. Saving issues one `iam.Roles` update that replaces the `permissions` field. Draft domains and their doctypes are excluded from the tree: a draft's doctype shape is not authoritative until published. The editor never writes role powers — `permissions` is its only write path.

## Role powers strip

Above the grants tree the editor mirrors the role's programmatic powers, read-only:

- `connectivity` — all four vocabulary channels as chips (`CONNECTIVITY_CHANNELS`): an accent chip is enabled, a struck-through chip is not. A missing or empty list renders every chip off — the same fail-closed default the backend enforces.
- `assistant_token_budget` — shown only while the `assistant` channel is enabled: `budget: unlimited` when the field is null, otherwise `budget: {n} tokens`.

The strip is a state mirror. The Details tab is the one write surface for powers; the strip's tooltip points there. The backend `RBAC::RoleAuthority` guard re-checks every powers write (see `doc/backend/rbac.md` → Role authority).

## Details tab

Edits `level` (integer 0–100, required), `description`, the `visible_tags` list, the connectivity checkboxes, and the assistant token budget with an Unlimited toggle. Save issues one `iam.Roles` update with the five fields; an explicit `null` budget means unlimited (the update pipeline restores explicit nulls). The role `name` is immutable — the backend update hook refuses it.

### Visibility tags

The tags list is an editable chip editor (`StringListEditor`). A field is visible to the role only when all its tags sit in `visible_tags`, so the editor refuses an empty list — an empty list would make the role field-blind (the backend's `default` fallback applies only when the field is absent, not when it is `[]`).

Writes follow the backend union rule (`RBAC::RoleAuthority.tag_errors`): a new tag must sit in the union of the caller's own `visible_tags` and the role's previous tags; the wildcard tag contains everything. The page mirrors the rule client-side against the active role's tags (`getVisibleTags()`, pure helper in `frontend/src/lib/iam/roleTags.ts`) for inline errors before save; the backend re-checks on save and its structured denial details land in the error banner.

## Unsaved-edits guard

While the Details form or the grants editor holds unsaved edits, the shared unsaved-edits gate (`frontend/src/lib/unsavedEdits.ts`) guards two departures: a tab click in the detail layout confirms before navigating, and a `beforeunload` handler arms the browser's leave dialog for close and refresh. Same-tab clicks and modified clicks (new tab or window) are never intercepted. The editor's own flows (role-picker switch, discard, delete) keep their dedicated confirms.

## New-role defaults

A role created through `NewRoleDialog` carries no `connectivity` value, so the definition default `[]` applies: the role is browser-only (no MCP, webhook, API, or assistant) until channels are enabled on the Details tab. The strip makes that state visible: all four chips render struck-through.
