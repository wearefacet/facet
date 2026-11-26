---
type: reference
title: Permission line syntax
description: The grammar of permission lines with examples and their effects.
audience: [admin, developer]
features: [RBC-01, RBC-03, RBC-06]
sidebar:
  order: 15
verified_at: eee55a2
---

You author a role and need to know exactly what each permission line grants.
A permission line is one JSON object in the `permissions` array of an
`iam.Roles` document. The line grants one action on one doctype path,
with an optional row scope and an optional path subtraction.

This page gives the exact grammar the parser accepts and the effect of each
form.

## Line structure

A line carries four parts. `action` and `on` are required; `scope` and
`except` are optional.

```json
{ "action": "<action>", "on": "<domain>.<path>", "scope": ["$<alias>"], "except": ["<domain>.<Doctype>"] }
```

| Part | Required | Form |
| --- | --- | --- |
| `action` | yes | `read`, `create`, `update`, `delete`, `*` (all actions), or a named action such as `activate` or `publish_artifact`. Matching is exact; only `*` is a wildcard. `write` is a grant-only alias — an app grant expands it to `create` + `update`, and the role validator refuses it on a permission line as "not a role action". |
| `on` | yes | A dot-separated path: domain, then doctype segments. Domain names are lowercase with dashes; doctype segments are CamelCase. |
| `scope` | no | An array of `$<alias>` strings. Each alias names a scope declared on the leaf doctype. Aliases combine with OR. |
| `except` | no | An array of concrete `domain.Doctype` paths. Each entry removes its subtree from the line. |

The parser normalizes every line to this shape. Three rules apply to all
forms:

- A missing `scope` means every row.
- `$all` in a `scope` array collapses the line to unrestricted.
- An `except` entry never grants anything. It only shrinks the line it
  sits on.

## The `on` path

| Form | Matches |
| --- | --- |
| `crm.Deal` | The `crm.Deal` doctype. |
| `crm.Deal.Comment` | The nested child doctype only. |
| `crm` | Every doctype in the `crm` domain. |
| `crm.Project` | `crm.Project` **and** every nested child such as `crm.Project.Comment` — a parent path covers its subtree. |
| `*.*` | Every doctype in every domain. The only wildcard form. |

Rules the validator enforces:

- The domain segment must match `[a-z][a-z0-9-]*`. Path segments must
  match `[A-Z][a-zA-Z0-9]*` (CamelCase).
- The wildcard domain `*` is valid only with the wildcard doctype: the
  full path must be `*.*`. A mixed form such as `*.Deal` is an error.
- A `*.*` line is a wildcard line. The role-authority guard lets only a
  caller whose own role reaches `*.*` write one.
- Every line a caller writes must be implied by its own role's lines or by
  the previous state of the role it edits. The role-authority guard refuses
  a role write that grants powers the caller does not hold (a widening).

## The `scope` field

The array form is the form the validator accepts on every write path. The
single-string form (`"scope": "$mine"`) is a legacy shape that stored roles
may still carry; the parser accepts it on read, but a role write that sends
a string scope fails with `must be an array` — always send the array form.

| Form | Rows the line reaches |
| --- | --- |
| absent | Every row. |
| `"$all"` | Every row. Same as absent. |
| `["$mine"]` | Rows that match the `mine` scope declared on the leaf doctype. |
| `["$mine", "$global"]` | Rows that match `mine` **or** `global` — the aliases OR together. |
| `["$all", "$mine"]` | Every row. Any `$all` entry collapses the whole array. |

Each alias must be declared in the `scopes:` block of the leaf doctype.
The validator rejects an unknown alias at authoring time; enforcement
expands it against the live definition at request time. A role never
writes its own query predicate. A line that pairs `create` with a scope
stays legal — the validator warns, because the scope cannot gate a create
(no row exists to check). The scope is an intent channel that a Lua create
hook reads through `ctx.actor.scope`. See
[Row scopes](/admin/people/row-scopes/)
for the declaration grammar.

## The `except` field

| Rule | Detail |
| --- | --- |
| Entry form | A concrete `domain.Doctype` path. At least two segments; no `*` anywhere. |
| Matching | An entry prefix-matches like `on`: an entry on `core.DocType` also excludes `core.DocType.Comment`. |
| Effect | A target that matches any entry never matches the line, even when it matches `on`. |
| Validation | Entries are checked at parse time. A malformed entry fails the role write. |

`except` is path arithmetic, not a deny system. It lets a scoped
re-grant on the same paths apply next to a blanket line.

## Examples and effects

| Permission line | Effect |
| --- | --- |
| `{"action": "read", "on": "production.Project"}` | Read every row of `production.Project`, and of its nested child doctypes. |
| `{"action": "read", "on": "production.Project", "scope": ["$mine"]}` | Read only rows that match the `mine` scope. A list shows only those rows. A read of another row answers `404`. |
| `{"action": "read", "on": "production.Project", "scope": ["$mine", "$global"]}` | Read rows the actioner owns, plus rows with no owner. |
| `{"action": "read", "on": "production.Project", "scope": "$all"}` | Read every row — the explicit form of an omitted scope. Legacy string form; use the array form in writes. |
| `{"action": "read", "on": "hr"}` | Read every doctype in the `hr` domain. |
| `{"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"]}` | Update every document except the two definition surfaces and their nested children. |
| `{"action": "*", "on": "*.*"}` | Every action on every doctype. The seeded `admin` role holds this line. |
| `{"action": "activate", "on": "core.DomainGrant"}` | Run the named action `activate` on `core.DomainGrant`. Reads, creates, updates, and deletes stay ungranted. |
| `{"action": "create", "on": "crm.Deal", "scope": ["$mine"]}` | Create a deal. The scope is **not** enforced at create time — no row exists to check. It is an intent channel that a Lua create hook reads through `ctx.actor.scope`. The domain check reports a warning for such lines. |

Enforcement answers differ by denial class:

- No line matches the action and doctype at all → `403` on the gated
  surface.
- A line matches, but the row misses its scope (single-document
  operations) → the non-disclosing `404`.
- A list query → the scope compiles into the query. The list stays
  scope-narrowed, possibly empty. A scoped list never turns into a
  `403`.

## Complete example

A role for a helpdesk team. The `helpdesk.Ticket` doctype declares the
named scope `unresolved`; `helpdesk.Ticket.Comment` declares `mine`.

```json
{
  "name": "support_agent",
  "level": 20,
  "visible_tags": ["default"],
  "permissions": [
    { "action": "read",   "on": "helpdesk.Ticket" },
    { "action": "create", "on": "helpdesk.Ticket" },
    { "action": "update", "on": "helpdesk.Ticket", "scope": ["$unresolved"] },
    { "action": "delete", "on": "helpdesk.Ticket.Comment", "scope": ["$mine"] }
  ]
}
```

A holder of this role can:

- Read every ticket, including every ticket's comments — the `read`
  line covers the child doctype through prefix matching.
- Create tickets. The create is unrestricted.
- Update a ticket while the row matches the `unresolved` scope, for
  example a ticket whose `status` is not `closed`. An update to a closed
  ticket answers `404`.
- Delete their own comments — rows where the comment's `mine` scope
  matches, for example rows the holder authored.

  The same holder cannot:

- Delete tickets — no `delete` line reaches `helpdesk.Ticket`, and a
  delete never rides the `update` line.
- Delete another agent's comment — the `mine` scope misses, so the
  answer is `404`.
- Update a closed ticket — the `unresolved` scope misses.
- Read or write anything outside `helpdesk.Ticket` and its children —
  any other doctype answers `403`.
- See fields tagged beyond `default` — `visible_tags` is
  `["default"]`.

## Field visibility

Field visibility is not part of a permission line. The role carries one
`visible_tags` array; each field carries `tags`. A field is visible
when all of its tags sit in the role's tags. The default role tags are
`["default"]`; the wildcard tag `["*"]` sees every field. A write into
an invisible field answers `403`. See
[Field visibility with tags](/admin/people/hidden-fields/).

## Related

- [Roles and permission lines](/admin/people/roles-and-permissions/) — edit role documents.
- [Row scopes](/admin/people/row-scopes/) — declare and reference the scopes.
- [Field visibility with tags](/admin/people/hidden-fields/) — the per-field mask.
