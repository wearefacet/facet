---
title: Roles and permissions
description: Write a role as permission lines, set its level, tags and channels, and know the guard that bounds every role write.
type: how-to
audience: [admin, author]
features: [RBC-01, RBC-07]
verified_at: eee55a2
sidebar:
  order: 2
---

Tom joins Brightwater as a salesperson. What may he read, change, and
create? The answer sits in one document: a **role**. A role bundles permission
lines, a level, field-visibility tags, and the connectivity channels. You
write roles here, and every check in Facet reads them — on screens, in the
API, in apps, and in the assistant.

A role is a document of doctype `iam.Roles`. Its id is the qualified form
`iam.Roles.<name>`, for example `iam.Roles.editor`.

## When to use this

- You write or edit a role and must state its reach exactly.
- You must know why a role write answered `403`.
- You audit which roles hold the sensitive operator actions.

## Before you start

- **The right page.** Open **Configure → Access → Roles**. The list page hosts
  the grants editor; each role also has a detail page with the Details, Members,
  and Grants tabs.

<!-- screenshot: configure-roles-detail -->
- **The model.** Read
  [Who can change roles](/admin/people/who-can-change-roles/) for
  the concept, and
  [How Facet checks permissions](/admin/under-the-hood/how-access-is-enforced/) for where
  enforcement runs.

## The role document

| Field | Holds |
| --- | --- |
| `name` | The unique role name. It forms the document id and is immutable. |
| `level` | Required integer from 0 to 100. It orders roles by authority. |
| `permissions` | The permission lines. |
| `visible_tags` | The field tags the role may see. Default `["default"]`; `["*"]` sees all. |
| `connectivity` | The programmatic channels, see below. |
| `description` | Free text for people. |

## The permission line

One line has four parts. Every part is optional except `action` and `on`:

| Part | Holds |
| --- | --- |
| `action` | `read`, `create`, `update`, `delete`, `*`, or a named action. |
| `on` | A doctype path, for example `crm.Deal`, or the wildcard `*.*`. |
| `scope` | An array of named row scopes. They combine with OR. |
| `except` | An array of concrete paths subtracted from the reach. |

### `on` and prefix matching

A line on a parent path also covers nested children. A line on `crm.Project`
also matches `crm.Project.Comment`. The wildcard `*.*` matches every doctype in
every domain. Seeded admin roles hold it.

### `scope`

The array form is required on every write path. Each entry names a scope
declared on the target doctype. The aliases combine with OR: the line reaches
rows that match any entry. Omitting `scope` reaches every row. See
[Show each role only its rows](/admin/people/row-scopes/) for the declaration and the aliases.

### `except`

`except` shrinks one line. The entries are concrete `domain.Doctype` paths; no
wildcards. An entry prefix-matches like `on`: an entry on `core.DocType` also
excludes `core.DocType.Comment`. It is path arithmetic, not a deny system: it
never grants anything, and it only affects the line it sits on.

### Examples

Every example is a full line, with the effect stated.

```json
{"action": "read", "on": "production.Project", "scope": ["$mine", "$global"]}
```

This line lets a member read the projects they own and the projects
with no owner.

```json
{"action": "create", "on": "crm.Deal"}
```

This line lets a member create a deal anywhere in `crm.Deal`.

```json
{"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"]}
```

This line lets a member update every document except the two definition
surfaces, so the domain and doctype shapes stay read-only for them.

```json
{"action": "read", "on": "fin.Invoice", "scope": ["$mine"]}
```

This line lets a member read only the invoices they own.

```json
{"action": "read", "on": "hr"}
```

A path with one segment and a lowercase domain name covers the whole domain.
This line lets a member read every doctype in `hr`.

## The connectivity channels

`connectivity` is an array from one closed vocabulary: `mcp`, `webhook`, `api`,
and `assistant`. It decides which programmatic doors the role may open at all.
An empty list is a browser-only role. Browser sessions and app tokens are
never gated by the field.

- `api` — the role may hold API keys. See
  [API keys](/admin/apps-access/api-keys/).
- `mcp` — agents may sign in through the Model Context Protocol (MCP) surface
  with this role.
- `webhook` — the role may author and receive webhooks. See
  [Outbound webhooks](/build/model/automation/webhooks/).
- `assistant` — the role may open the AI (artificial intelligence) assistant.
  See [Govern the assistant](/admin/assistant/govern/).

Every channel gate reads the role live. A channel you remove applies on the
next request.

## Named actions

Besides the four CRUD actions, a line may grant one named action. The action
names that gate fixed routes are worth knowing:

| Action | On | Gates |
| --- | --- | --- |
| `provision_credentials` | `iam.Account` | Temporary passwords, invite links, credential-state reads. |
| `mfa_disable` | `iam.Account` | `POST /Api/iam/mfa/disable`, the administrator recovery. |
| `publish_artifact` | the target doctype | Minting permanent file links on that doctype. |
| `revoke` | `*.*` | Revoking any file link. |
| `download` | `*.*` | Downloading any file as an operator. |
| `purge` | `*.*` | Force-deleting any file, the audited deletion. |

:::caution
A role that an external app can elect must not hold `provision_credentials`,
`mfa_disable`, `revoke`, `download`, or `purge`. Keep these five on human
operator roles only. See [Control what apps can reach](/admin/apps-access/app-grants/).
:::

## The role authority guard

Every caller-controlled write on `iam.Account` and `iam.Roles` passes one
guard. It covers create, update, delete, named actions, and rollback
transitions. A refusal answers `403`. The caller's level comes from the one
elected role of the request, never from the highest role they hold.

| Check | Rule |
| --- | --- |
| Assignment | Every role in the final `roles` array must exist, be live, and sit at or below the caller's level. `default_role` must be a member. |
| Same level | A caller may assign a role at their own level, even when that role holds powers the caller lacks. |
| Target protection | No write to an account or role whose current level is above the caller's level, not even to lower it. |
| Role authoring | The resulting level must not exceed the caller's level. Every new line must be implied by the previous role or the caller's role. New visible tags must sit inside the union of both. The connectivity channels and the assistant budget follow the same containment. |

The containment rule bounds a role editor: a level-30 editor cannot widen a
level-20 role past what the previous content or their own role implies. See
[Assign roles](/admin/people/assign-roles/) for the
assignment flow.

## The seeded roles

| Role id | Level | Reach |
| --- | --- | --- |
| `iam.Roles.admin` | 100 | `*` on `*.*`, all channels, all tags. |
| `iam.Roles.editor` | 30 | Reads and edits content everywhere; definition surfaces and `core.SystemSettings` are carved out with `except`. |
| `iam.Roles.viewer` | 20 | Read everywhere, with the same carve-outs. |
| `iam.Roles.comment_author` | 20 | Author-scoped read, update, and delete on `core.Comment` through `$mine`. |
| `iam.Roles.attachment_owner` | 20 | Uploader-scoped read, update, and delete on `core.Attachment` through `$mine`. |
| `iam.Roles.anonymous` | 0 | Serves requests with no credential. Its read grants are the public API surface. Delete it, and such requests answer `401`. |

The `core.SystemSettings` carve-out is the model to copy: the `editor` and
`viewer` seeds subtract the path from their blanket lines with
`except: ["core.SystemSettings"]`, so runtime settings stay administrator-only.
A bespoke role can still be granted the path explicitly.

Brightwater adds three roles on top of the seeds: `manager` (level 60, sees
the `finance` tag), `sales` (level 40, a row scope narrows it to its own
clients), and `warehouse` (level 40, no `finance` tag). You meet all three on
the next pages.

## The role name is immutable

The document id is `iam.Roles.<name>`, and account documents reference that
id. A rename would desync the id from the name, so the update hook refuses any
write that carries `name`:

```json
{"error": "Script validation failed", "details": [{"message": "'name' is immutable after creation — the role id is iam.Roles.wp18a_renamed; recreate the role under the new name", "code": "script"}]}
```

To rename, create a new role under the new name, move the assignments, and
delete the old one. The delete hook refuses while any account still holds the
role.

## Example

Create a regional read role for the `fin` domain:

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "regional_reader",
    "level": 10,
    "visible_tags": ["default"],
    "permissions": [
      {"action": "read", "on": "fin.Invoice"},
      {"action": "read", "on": "hr.Employee", "scope": ["$mine"]}
    ]
  }' \
  "https://facet.localhost:3443/Api/iam/Roles"
```

The new role reads every invoice and lets each member read their own employee
record. It holds no channels and no operator actions.

## Troubleshooting

### The role write answers `403`

Check the four guard rows above. The most common cause is a new permission
line that the caller's own role does not imply, or a target whose level is
above the caller's.

### A write with a string scope answers `422 must be an array`

The write paths require the array form. Change `"scope": "$mine"` to
`"scope": ["$mine"]`.

### The PATCH that renames a role answers `422`

The name is immutable. Create the role again under the new name.

### A member sees a field you expected to hide

Check `visible_tags` on their role — see
[Hide a field from some roles](/admin/people/hidden-fields/).

## Related

- [Assign roles](/admin/people/assign-roles/) — put roles on accounts.
- [Show each role only its rows](/admin/people/row-scopes/) — narrow a line to specific rows.
- [Hide a field from some roles](/admin/people/hidden-fields/) — narrow what a role sees inside a document.
- [Who can change roles](/admin/people/who-can-change-roles/) — the concept page for the guard.
- [Control what apps can reach](/admin/apps-access/app-grants/) — the app-side bound.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md).
- [Permission line syntax](/reference/permission-syntax/)
