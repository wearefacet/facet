# Access accounts page

An admin surface at `/Configure/access/accounts` where an operator creates accounts,
bootstraps their first credential, and reads each account's sign-in state. Accounts are
ordinary `iam.Account` documents, so the page renders the standard document listing
stack; the account-specific bootstrap actions live on the account show page (see
[`backend/iam.md`](../backend/iam.md)).

**Route:** `/Configure/access/accounts`

**Source files:**

- `frontend/src/routes/Configure/access/accounts/+page.ts` — doctype resolution load
  (60s-TTL cached registry, shared with the live doctype routes)
- `frontend/src/routes/Configure/access/accounts/+page.svelte` — the page: header,
  Live/Deleted toggle, tab-less `ListView`
- `frontend/src/lib/components/primitives/data/ListView.svelte` — the standard listing
  host (`showTabs={false}` here), with the shared filter toolbar, sorting, pagination,
  trash mode, and the QuickView peek
- `frontend/src/lib/components/features/admin/AccountCredentialActions.svelte` — the
  credential action panel on the show page
- `frontend/src/lib/components/features/admin/TemporaryPasswordPanel.svelte` —
  reveal-once password panel, reused by the action panel

The page and the action panel have co-located `.stories.svelte` whose `play` functions
assert the behaviour.

## Listing

The page mounts `ListView` with `showTabs={false}`: no saved-view strip and no
`core.CollectionView` CRUD affordances — the columns always come from the doctype's
fallback rule (flat scalar fields, cap 8): email, Display Name, Status (enum),
Default Role (reference), MFA Enabled, Must Change Password, Service Account, and
Organizational Unit. The `TableToolbar` (search box + filter chips) renders because
`ListView` passes the `doctype` definition and driver to `Table`: search runs over the
declared `search` template (`email`, `name`) via the bare `search` operator key;
filter chips come from the field operators (`email`, `status`, `organizational_unit`).

Trash mode rides the `?deleted=` URL param (same pattern as the live doctype listing
page): Deleted lists tombstones and renders a Restore action per row.

Row click opens the QuickView peek, whose header links to the edit form and to the
full show page. There is no per-row action column — the account-specific actions are
on the show page.

## Create and edit

The New button navigates to `/iam/Account/new`; Edit goes to
`/iam/Account/{id}/edit`. Both are the standard `DocumentForm` routes driven by the
doctype's `kind: form` template (fallback form when none exists). The backend create
hook in `data/seeds/iam.Account/script.lua` enforces the plan §4.6 status rule
server-side: a freshly created human account starts `pending` (even when `active` is
submitted), while service accounts and JIT-provisioned OIDC accounts (which carry
`federated_identities`) keep `active`. An explicit `suspended` / `disabled` status is
honoured.

## Credential actions (show page)

`AccountCredentialActions` renders below the document view on
`/iam/Account/{id}`. It fetches the account's credential state once on mount
(`GET /Api/iam/accounts/credential-states?id=…`), derives the action labels from it,
and renders nothing when the active role holds no relevant permission.

| Action | Calls | Visible when |
|---|---|---|
| Send invite / Resend invite | `POST /Api/iam/accounts/:id/invite` | `provision_credentials` on `iam.Account`; not a service account. Label comes from `invite_pending` |
| Generate / Regenerate password | `POST /Api/iam/accounts/:id/temporary-password` | `provision_credentials`; not service, `suspended`, or `disabled` (the backend refuses those). Label comes from `has_password` |
| Reset MFA | `POST /Api/iam/mfa/disable` with `{account_id}` | `mfa_disable`, `mfa_enabled: true`, and not purely federated (`federated && !has_password` hides it — a federated account with a local password keeps it). Confirms before the POST |

A successful action re-reads the credential state and calls `onchanged` (the show
route refreshes the document via `invalidateAll`). The temporary password is held in
memory only between the POST response and the panel close; on close the host clears
the value, so a regenerate always needs a fresh confirm-and-generate round.

All state-changing calls send `X-Requested-With: XMLHttpRequest` (the IAM CSRF rule).
Every action is a UI hint gated on the permission manifest through `can()`; the
backend re-checks each request. A failed state read degrades to `credential: null` —
the panel stays, and credential-dependent actions hide.
