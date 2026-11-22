# Domain Editors

**Files:** `src/domain/editors.cr`, `data/seeds/core.DomainEditor/`, `data/seeds/core.Domain/definition.yml` (scopes), `data/seeds/core.Domain/documents.yml` (context sets), `data/seeds/core.DocType/definition.yml`, `data/seeds/core.DocumentView/definition.yml` + `script.lua`, `data/seeds/iam.Roles/documents.yml`, `src/domain/draft.cr`, `src/domain/publish.cr`, `src/domain/scratch.cr`, `src/document/create.cr`, `src/doctype/create.cr`, `src/domain/routes.cr`

Scoped domain administration for the `editor` role. The `core.DomainEditor`
doctype holds one document per (account, domain) pair. The `editor` role
keeps full rights on business documents in every domain, but its rights over
the **definition surfaces** (`core.Domain`, `core.DocType`,
`core.DocumentView`) apply only to domains the account is listed on. Any
editor can create a draft domain; the creator automatically becomes a domain
editor of that draft. Two RBAC grammar extensions make this expressible —
the `except` carve-out on a permission line and the `$doc_id` reserved field
token (see [`rbac.md`](rbac.md)).

## The `core.DomainEditor` doctype

Seeded at `data/seeds/core.DomainEditor/definition.yml`. Two fields:

| Field | Type | Rules |
|---|---|---|
| `account` | `reference` → `iam.Account` | Required. Stored qualified (`iam.Account.<id>`), so a `$self` predicate matches it. |
| `domain` | `string` | Required. The `core.Domain` document id — the live slug (`crm`) or the draft id (`_abc123`). Pattern-validated. |

`aggregate_root: true`, no `member_of`. One document per (account, domain)
pair; duplicates are harmless (context resolution is `DISTINCT`). A dangling
`domain` value never matches a scope — fail closed by construction.

A Lua `create`/`update` hook on the doctype guards the list itself:

- rejects system domains (`core`, `iam`, `app`) as targets — 422;
- rejects targets with no live `core.Domain` row — 422 (a typo'd slug must
  fail loud, not silently grant nothing).

Managing the list is **admin-only** (the `except` carve-outs on the editor
role's blanket lines). A domain editor cannot add co-editors; the grant
chain stays rooted at the wildcard role.

## Context sets (on the `core` domain document)

Context sets are domain-owned. These live on the `core` domain document, so
they resolve for enforcement on every `core.*` row — including drafts, whose
`core.Domain` rows also sit in domain `core`.

```yaml
context_sets:
  editor_domains:        # slugs of the domains the actioner edits
    from: DomainEditor
    select: domain
    where: { account: "$self" }
  editor_doctypes:       # qualified ids of the doctypes of those domains
    from: DocType
    select: "$doc_id"
    where: { domain: "$editor_domains" }
  editor_draft_domains:  # the subset that are drafts (drop rights)
    from: Domain
    select: "$doc_id"
    where: { "$doc_id": "$editor_domains", draft: "true" }
```

- `editor_domains` is the root set; the other two hang off it (acyclic DAG).
- `draft: "true"` is safe only inside a context set: context sets resolve
  through SQL, where `content->>'draft' = 'true'` compares text. The
  in-process matcher compares raw JSON (a `Bool` never equals the string
  `"true"`), which is why the draft filter lives here and never in a named
  scope.
- `editor_doctypes`/`editor_draft_domains` select `$doc_id` — the row id.
  For `core.DocType` rows that id is the qualified `{domain}.{Doctype}`,
  which is the same shape `core.DocumentView.parent_doctype` stores — exact
  join, no slug-prefix hazard (`crm` vs `crm2`).

## Named scopes (on the three definition doctypes)

```yaml
# core.Domain/definition.yml
scopes:
  domain_editor:       { where: { "$doc_id": "$editor_domains" } }
  domain_editor_draft: { where: { "$doc_id": "$editor_draft_domains" } }

# core.DocType/definition.yml
scopes:
  domain_editor: { where: { domain: "$editor_domains" } }

# core.DocumentView/definition.yml
scopes:
  domain_editor: { where: { parent_doctype: "$editor_doctypes" } }
```

## The `editor` role

The seeded role splits into two planes:

- **Content plane** — blanket `create`/`update`/`delete` on `*.*` with the
  definition surfaces carved out via `except`, plus blanket `read`.
- **Domain plane** — scoped lines: `update core.Domain` (`$domain_editor`),
  `delete core.Domain` (`$domain_editor_draft` — drafts only; an editor can
  discard a draft they edit but never drop a live domain), and
  `create`/`update`/`delete` on `core.DocType` and `core.DocumentView`
  (`$domain_editor`).

`create core.Domain` stays blanket — it is the draft door. Read stays
blanket — the live app renders forms and nav from definitions everywhere.
`admin` keeps `*` on `*.*` with no `except` and is unaffected.

The role's `connectivity` list is `[api, assistant]`. It holds no
`webhook` and no `mcp` channel: only `admin` holds those by seed. See
Caveats → Webhooks.

## Membership helpers (`Domain::Editors`)

| Method | Purpose |
|---|---|
| `member?(db, domain_id, account_id) : Bool` | Direct `EXISTS` on `core.DomainEditor` — the same membership the `$domain_editor` scope resolves, without synthetic-row evaluation. |
| `grant(db, domain_id, account_id, actioner_id) : Nil` | Writes one `core.DomainEditor` row through the full create pipeline (guard hook, links, display name, event), audit-attributed to the real creator. Skips non-account actioners (`system`, `system:*`, spec fixtures — they hold no `iam.Account` row) and runs only against a seeded database. Raises on failure so the surrounding domain creation rolls back. |
| `transfer(db, from_domain, to_domain, actioner_id) : Nil` | Copies live editor rows from one domain to the other, skipping existing (account, target) pairs. Used by publish. |
| `authorize_doctype_create?(db, target_domain, auth_context) : Bool` | The create-time gate: `All` (wildcard) and system pass; a `Scoped` caller must be a member of the target domain; anything else fails closed. |
| `authorize_draft_from?(db, source_domain, auth_context) : Bool` | The draft-from gate (`Draft.create_from`): the system bypass passes; a preview principal and a caller without `create core.Domain` fail closed; every other caller must be a member of the source domain. The create verdict does not relax the membership check — a blanket `create core.Domain` (the seeded `editor` role) still forks only a domain the account edits. |

## Where the auto-grant fires

Every domain-creation path records the creator as the domain's first editor,
inside the creation transaction:

| Path | Call |
|---|---|
| `Domain::Draft.create` / `.create_from` | `Editors.grant(txn, draft_id, actioner_id, actioner_id)` |
| `Document::Create.create_domain_instance` (generic `POST /Api/core/Domain`) | same |

The generic domain-create path also runs
`WriteEnforcer.authorize_create(db, "core", "Domain", auth_context)` — it
previously skipped RBAC entirely, so any authenticated principal (including
the anonymous principal) could mint a live domain.

## Publish, drop, cleanup

- **Overwrite guard.** Overwrite publish replaces a live target's
  definition, so `Domain::Publish` enforces
  `WriteEnforcer.authorize_update` on the target's `core.Domain` row before
  the version gate — an editor must edit the target domain too, not just
  the draft. `Publish.call` takes the `auth_context` (the HTTP route has
  it); internal callers default to the system bypass.
- **Editor carry-over.** After the structure copy (fresh and overwrite
  both), `Editors.transfer` copies the draft's editor rows onto the target,
  so co-editors of a draft keep their rights on the published domain.
- **Teardown cleanup.** `Domain::Scratch.dispose_definitions!` soft-deletes
  `core.DomainEditor` rows with `content->>'domain' = <domain>`. This
  covers publish-drop, draft discard, and `Domain::Drop` of a live domain
  (all funnel through `dispose!` → `dispose_definitions!`), so no editor
  row ever points at a dead domain.

## Create-time gates the scopes cannot express

Scopes are presence-only at create time (the row does not exist). Two gaps,
closed with the mechanism each surface supports:

| Surface | Gate |
|---|---|
| `Doctype::Create` (any domain) | Crystal check in `create_doctype_definition`, after `domain_exists?`: when the caller's `create core.DocType` result is `Scoped`, require `Editors.member?` on the target domain. `All` and system pass; `Denied` already failed the enforcer. |
| Draft from a live domain (`Draft.create_from`, `POST /Api/core/Domain/:id/draft`) | Crystal check at the top of `create_from`: the caller must be a member of the source domain. The create verdict does not relax this — `All` (a blanket `create core.Domain`, the seeded `editor` role) and `Scoped` callers alike must hold a `core.DomainEditor` row on the source. The system bypass passes; a preview principal and a `Denied` caller fail closed. Internal callers default to the system bypass, the same convention `Publish.call` uses. Closes B-240 and F04-01 — drafting forks the source's definition surface, so a role may only fork a domain it edits. The fresh-draft route (`Draft.create`, no source) stays create-then-own: any caller with `create core.Domain` may open a draft, and the creator becomes its editor in the same transaction. |
| `core.DocumentView` create | Lua `create` hook: when `ctx.actor.scopes` contains `domain_editor`, require `ctx.root.parent_doctype ∈ ctx.actor.context_sets.editor_doctypes`; unrestricted callers (scopes absent) and system writers pass. A scoped caller whose context sets did not resolve is denied (fail closed). The nested sidecar route passes its action gate (the scoped `create core.DocType` line prefix-matches the host path), so the hook is the enforcement point for both flat and nested creates. |

The `preview-session` route gates on
`WriteEnforcer.authorize_update(db, "core", "Domain", draft_id, auth_ctx)`
(the row-level gate, where the `$domain_editor` scope bites) instead of the
create-presence check on `core.DocType` it used before — a token only
reaches callers who may edit that draft's definition.

## HTTP surface

No new routes. The list is managed through the generic document API
(`POST`/`PATCH`/`DELETE /Api/core/DomainEditor[/:id]`) — admin-only by the
editor role's `except` carve-outs, open to any role that holds the grants
(`admin` by seed).

The admin UI surface is the **Editors tab** of the domain editor, reached
from both `/Configure/domains/{slug}/editors` and the Builder draft's
editors tab. Add and remove write through the same generic API; every other
role gets a read-only list. See
[`../frontend/configure-editors.md`](../frontend/configure-editors.md) →
Editors tab.

## Enforcement matrix

| Surface | Admin | Editor, member of domain | Editor, not a member |
|---|---|---|---|
| `PATCH /Api/core/Domain/:id` | yes | yes | 403 |
| Draft create (fresh, no source) | yes | yes | yes (any editor) |
| Draft from live domain | yes | yes | 403 (service gate, whatever the create verdict) |
| Publish (fresh) own draft | yes | yes | n/a |
| Publish (overwrite) target | yes | yes — must edit target too | 403 |
| Discard draft (`/drop` on draft) | yes | yes | 403 |
| Drop live domain | yes | **no** (`$domain_editor_draft`) | no |
| `/check` domain or doctype | yes | yes | 403 |
| `POST /Api/core/DocType` | yes | yes (in their domains) | 403 (service gate) |
| `PUT`/`DELETE /Api/core/DocType/:id` | yes | yes (in their domains) | 403 |
| DocumentView create | yes | yes (in their domains) | 422 (hook) |
| DocumentView update/delete | yes | yes (in their domains) | 403 (scope) |
| Manage `core.DomainEditor` rows | yes | **no** (carved out) | no |
| Business documents, all doctypes | yes | yes | yes (unchanged) |
| `iam.*`, `app.*` writes | yes | yes (unchanged) | yes (unchanged) |

## Caveats

- **Revocation latency.** A removed editor loses rights on their next
  request (context sets resolve per request). A preview token already
  issued stays valid to its short expiry — accepted, consistent with the
  preview model.
- **Custom roles.** Any customer role holding blanket `update *.*` keeps
  full domain-editing rights unless it adopts the same `except` carve-out.
  Only the seeded `editor` role carries the carve-out.
- **A grant row is inert under the wrong elected role.** Every gate consults
  only the caller's one elected (active) role — roles never merge
  (`AuthContext#can?` reads `active_role.matching_permissions`). So a
  `core.DomainEditor` row has an effect only when the elected role carries
  the scoped `$domain_editor` permission lines. The seeded `editor` role
  carries them; `admin` and blanket custom roles pass without the row. A
  grant row under any other elected role is inert, and domain writes answer
  `403`.
- **Webhooks stay blanket in permission shape, not in channel.** The
  editor role's blanket `create *.*` still covers `core.Webhook` as a
  permission, but the role's `connectivity` list excludes the `webhook`
  channel, so the `core.Webhook` create hook refuses an editor with 422.
  Only `admin` holds the channel by seed. See
  [`webhook.md`](webhook.md) → connectivity.
- **Dev databases need `db_reset`.** Seeds are idempotent per doctype;
  changed definitions and the new context sets do not re-apply to existing
  rows.
