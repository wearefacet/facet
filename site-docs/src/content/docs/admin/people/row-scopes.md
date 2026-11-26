---
title: Show each role only its rows
description: Attach a declared row scope to a permission line so a role reaches only the rows that match — on every surface.
type: how-to
audience: [admin, author]
features: [RBC-05, DOM-12]
verified_at: eee55a2
sidebar:
  order: 4
---

Tom sells to five of Brightwater's ten clients. His colleague sells to the
others. Both use the same *Sales* role, so the role cannot name companies —
the rule must say "your own clients". A **row scope** does that: a saved
filter, declared once on the doctype, that a role attaches to a permission
line. Everywhere Tom's role reaches the Company doctype — lists, search, the
API, apps — he sees his five companies and nobody else's.

:::note[This page is one half of a pair]
This page covers the **admin** side: attach an alias to a role and see how
Facet applies it. The **author** side — declaring the scope and the context
set it reads — lives in [Named scopes](/build/model/access/named-scopes/). The
[worked example](#worked-example-own-projects-via-teams) below shows both
halves together.
:::

## When to use this

- A role may see or change only its own rows.
- A role may see rows that match a shared rule, for example every active
  project.
- Several roles share one row rule, and you want it declared once.

## Before you start

- **The grammar.** You know the permission-line grammar — see
  [Roles and permissions](/admin/people/roles-and-permissions/).
- **The declaration.** The scopes must exist on the doctype definition before
  a role can reference them. The authoring steps live in
  [Named scopes](/build/model/access/named-scopes/).

## The Brightwater setup

The `clients` domain declares one scope on its Company doctype:

```yaml
# clients.Company definition
scopes:
  my_clients:
    description: "Companies where I am the account manager"
    where:
      account_manager: "$self"
```

The *Sales* role references it by alias:

```json
{"action": "read", "on": "clients.Company", "scope": ["$my_clients"]}
```

Tom signs in and lists companies:

```json
["Maison Lumière", "Festival des Collines", "Cabinet Moreau", "Château de Vireloup", "Mairie de Saint-Clair"]
```

Five companies — the five where Tom is the account manager. Nadia, whose
*Manager* role has no scope on the line, lists the same doctype and sees all
ten.

## Explanation

### Where scopes live

The doctype definition carries the scopes under `scopes`. Each entry is a
`where` filter over the doctype's own fields. Roles pick from this catalogue.
They cannot add a predicate of their own on a permission line. The `where`
grammar:

| Value | Matches |
| --- | --- |
| `"active"` | The literal stored value. |
| `"$self"` | The acting account's id. It matches both the reference form `iam.Account.<id>` and a bare id, so one scope works on reference and on string owner fields. |
| `"$my_teams"` | The values of a context set that the domain declares, resolved per request. An empty or unresolvable set matches no rows, also with `ne`. |
| `"$null"` | Rows where the field is absent or JSON null. Works with `eq` only. |
| `"$organizational_unit"` | The acting account's folder-like path, for example `/engineering/backend/`. |

A `where` key can carry an operator suffix, as list filters do:
`priority__gte`, `title__starts_with`, `price__between`. A bare key means
equals. A field accepts exactly the operators that its declared `filters`
capabilities allow. Two reserved keys exist: `$parent_id` reads the parent
linkage, and `$doc_id` reads the row id. Both take `eq` or `ne` only.

### What a permission line says

Read each line together with its effect:

```json
{"action": "read", "on": "production.Project", "scope": ["$mine", "$global"]}
```

This line lets a member read the projects they own and the projects
with no owner.

```json
{"action": "update", "on": "crm.Deal", "scope": ["$mine"]}
```

This line lets a member update the deals they own, and no other deals.

```json
{"action": "read", "on": "production.Project", "scope": "$all"}
```

This line lets a member read every project. `$all` is the explicit
unrestricted form; an omitted `scope` means the same. Inside an array, `$all`
collapses the whole line to unrestricted.

### How Facet applies a scope

- **Lists.** The scope compiles to an SQL `WHERE` fragment. A scoped list
  answers `200` with the matching rows, possibly none. Row scoping never turns
  into `403`.
- **Single reads, updates, deletes, and actions.** The enforcer checks the row
  against the scope. A row that fails answers the same `404` as a missing
  document, so the answer never reveals that the document exists.
- **Create.** No row exists yet, so the scope does not run at create. The
  scope rides to the Lua create hook as an intent channel that can set field
  values, for example the owner. The domain check reports one warning per
  scoped create line on the `iam` domain.
- **Redefinition.** Edit a scope on the doctype, and every role that
  references the alias uses the new predicate from the next request. No role
  edit is needed.
- **Query-time narrowing.** List and aggregate routes and the agent tools
  accept `scope=<name>`. It only narrows what the caller can already see. An
  unknown name answers `422`.
- **Credential-less requests.** They run under the `anonymous` role. `$self`
  resolves to the literal value `anonymous`, which matches no account, so
  `$self` scopes stay inert. `$organizational_unit` resolves to the root path
  `/`.

:::caution[An alias must exist on the target doctype]
A scope alias resolves against the doctype that the line targets. A line that
names an alias the doctype does not declare fails validation when you save the
role.
:::

## Worked example: own projects via teams

A `project_manager` role reads only the projects of the manager's own team.
Projects belong to a team, and a team has member rows that name an account.
The rule needs two declarations — one on the domain, one on the doctype — and
then a role line names the scope.

### The document model

- **Team → TeamMember** is composition: `Team` is the aggregate root,
  `TeamMember` its child (`member_of: Team`), and each member row holds an
  `account` reference to `iam.Account`. A dedicated `TeamMember` doctype suits
  this because membership is a row with its own life and one account can sit in
  several teams.
- **Project → Team** is a reference: `Project.team` points at `projects.Team`.

<!-- d2
direction: down
Account: iam.Account {class: external}
Team: projects.Team {class: node}
Member: projects.TeamMember {class: node}
Project: projects.Project {class: node}
Set: my_teams context set {class: info}
Scope: team_projects scope {class: info}
Role: project_manager role {class: accent}

Team -> Member: children / member_of
Member -> Account: account
Project -> Team: team
Set -> Member: reads membership
Set -> Scope: resolves for
Scope -> Project: where team
Role -> Scope: references alias
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/e527fc23-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/e527fc23-dark.svg" alt="Diagram" loading="lazy" />
</div>

The diagram shows the two data relationships, the two declarations that read
them, and the role that names the scope. The authoring declarations (the
`children`/`member_of` pair, the reference field, the `my_teams` context set,
and the `team_projects` scope) are on
[Named scopes](/build/model/access/named-scopes/#worked-example-own-projects-via-teams).
The admin part follows.

### The role line

The `project_manager` role carries one read line on `projects.Project`:

```json
{
  "action": "read",
  "on": "projects.Project",
  "scope": ["$team_projects"]
}
```

`team_projects` is a scope the doctype declares, with
`where: { team: "$my_teams" }`. The `$my_teams` context set resolves, per
request, to the ids of the teams the caller belongs to.

### What the manager sees

1. The manager belongs to two teams. A list of `projects.Project` returns the
   projects of both teams, and nothing else.
2. A direct read of a project in another team answers `404`, although the
   project exists — the non-disclosing answer from
   [How Facet checks permissions](/admin/under-the-hood/how-access-is-enforced/).
3. The manager moves to a new team. The next request resolves the new
   `my_teams` set and returns the new team's projects. No role edit is needed.

## Troubleshooting

### A scoped list returns rows you did not expect

Aliases in an array combine with OR. Check whether one line carries more
aliases than you intended, or whether `$all` sits in the array.

### A member gets `404` on a document that exists

The row failed the scope check. This is the non-disclosing answer by design —
see [How Facet checks permissions](/admin/under-the-hood/how-access-is-enforced/).

### The API answers `Unknown scope`

The scope name is not declared on the doctype in the line. Copy the name from
the definition.

### A scoped create line saves with a warning

Create ignores scopes by design. Move the row rule into a create hook — see
[Lifecycle scripts and guards](/build/model/behaviour/scripts-and-guards/).

## Related

- [Named scopes](/build/model/access/named-scopes/) — declare scopes and their context
  sets on the doctype and domain.
- [Roles and permissions](/admin/people/roles-and-permissions/) — the line grammar around `scope`.
- [Hide a field from some roles](/admin/people/hidden-fields/) — narrow at the field level the same way.
- [How Facet checks permissions](/admin/under-the-hood/how-access-is-enforced/) — where the enforcers sit.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md).
- [Roles: who sees and does what](/discover/how-it-works/roles/)
