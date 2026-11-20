---
title: Named scopes
description: Declare reusable row filters on a doctype and attach them to role permissions.
audience: [author, admin]
features: [DOM-12]
sidebar:
  order: 16
verified_at: f1409cdc
---

A named scope is a saved filter over the fields of one doctype. An administrator attaches it to a permission line, and the permission then reaches only the rows the filter matches. Scopes keep row rules in one place: the doctype owns the filter, roles only name it.

:::note[This page is one half of a pair]
This page covers the **author** side: declare the scope, and the context set it reads. The **admin** side — attaching the alias to a role and how Facet applies it — lives in [Row scopes](/govern/row-scopes/). The [worked example](#worked-example-own-projects-via-teams) below shows both halves together.
:::

## When to use this

- A role may see or change only its own rows.
- Several roles share one row rule, and you do not want to repeat it.
- A reader needs a saved subset through the API, for example "active projects".

## Before you start

- **Author side:** you edit the doctype definition to declare scopes.
- **Admin side:** an administrator edits the role to attach them. The full permission model lives under the access pages — this page stays with the author's part.

## Steps

### 1. Declare the scopes on the doctype

Add a `scopes` map to the doctype definition. Each entry has a description and a `where` filter:

```yaml
scopes:
  mine:
    description: "Projects owned by the actioner"
    where:
      owner_id: "$self"
  active:
    description: "Projects in the active status"
    where:
      status: "active"
  open:
    description: "Projects with no owner yet"
    where:
      owner_id: "$null"
```

The `where` values follow one grammar:

| Value | Matches |
| --- | --- |
| `"active"` | The literal stored value. |
| `"$self"` | The acting account's id. Works on a reference field and on a plain string field that stores an account id. |
| `"$null"` | Rows where the field is absent. |
| `"$my_teams"` | Rows whose field value is in the set a context set resolves to. The set is a query that the domain declares; Facet runs it per request for the acting account and matches the rows' values against the result. An empty or failed set matches no rows. |
| `"$organizational_unit"` | The acting account's organizational unit path. |

A field name can carry an operator, like the list filters do: `priority__gte`, `title__match`, `price__between`. A bare name means equals.

The `$<name>` form is generic: any name that is not `$self`, `$null`, or `$organizational_unit` is a context set. `$my_teams` is only the usual name for "the teams the acting account belongs to". To use one, declare the context set on the domain document — not on the doctype — under **Configure → Domains → (the domain) → Grants → Context sets**:

```yaml
# production domain document, under content
context_sets:
  my_teams:
    from: TeamMember   # a doctype of the same domain
    where:
      account: "$self"
    select: "$parent_id"  # the field to collect; $parent_id reads the parent team
```

`from` names the doctype to query, `where` filters its rows, and `select` names the field to collect into the set. Both `where` and `select` accept `$self`, `$parent_id`, `$doc_id`, and other context sets, so one set can build on another.

### 2. Attach the scopes to a role

An administrator opens the role in **Configure → Access**, finds the doctype, and sets the scope on an action. The select lists **All** plus every scope declared on the doctype. Several scopes on one line combine with OR: the permission reaches rows that match any of them.

The stored permission line looks like this:

```json
{
  "action": "read",
  "on": "production.Project",
  "scope": ["$mine", "$open"]
}
```

That line grants read on projects the reader owns **or** projects nobody owns. A line without a scope reaches every row.

### 3. Use a scope as a saved filter

Any reader can pass a declared scope as a filter on the list route. It only narrows what the caller may already see:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/production/Project?scope=active"
```

## Example

The full round trip on a `production.Project` doctype, with an `owner_id` reference field and a `status` enum field:

1. The author declares the `mine` and `active` scopes from step 1.
2. An administrator sets the **Read** action of the field-editor role to `["$mine", "$active"]` in the roles editor.
3. A reader with that role lists projects. Facet returns the projects the reader owns plus every active project, and nothing else. A project owned by someone else with status `planned` stays hidden.
4. The same reader calls the list route with `?scope=active` and gets only the active subset.

## Troubleshooting

**The scope select on the role shows only All.**

The doctype declares no scopes yet, or the definition failed to save. Add the `scopes` map and check the doctype again.

**A scoped list returns nothing.**

The filter matches no rows. Check the stored value shape: a reference field stores a qualified id, but `"$self"` matches it anyway; a literal must equal the stored value exactly. For a context-set value, check that the set resolves for this account: an empty set, or a set whose `where` matches no row, matches no rows of the list either.

**The API answers Unknown scope.**

The scope name is not declared on that doctype. Copy the name from the definition.

**A role change has no effect.**

Permissions apply on the next request. Reload the list and check that the role was saved on the right doctype path, for example `production.Project`.

## Worked example: own projects via teams

A project manager reads only the projects of their own team. Projects belong to a team, a team has members, and each member names an account. One context set and one named scope express this, and the role references the scope by alias.

### The document model

Two relationships carry the rule:

- **Team → TeamMember** is composition. `Team` is the aggregate root and `TeamMember` is its child (`member_of: Team`). Each member row holds an `account` reference to `iam.Account`.
- **Project → Team** is a reference. `Project` holds a `team` reference to `projects.Team`.

<!-- d2
Account: iam.Account {class: external}
Team: projects.Team {class: node}
Member: projects.TeamMember {class: node}
Project: projects.Project {class: node}
Set: my_teams context set {class: info}
Scope: team_projects scope {class: info}

Team -> Member: children / member_of
Member -> Account: account
Project -> Team: team
Set -> Member: reads membership
Set -> Scope: resolves for
Scope -> Project: where team
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/b8c9ce6e-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/b8c9ce6e-dark.svg" alt="Diagram" loading="lazy" />
</div>

The diagram shows the two data relationships and the two declarations that
read them.

A separate `TeamMember` doctype is the right shape here: membership is a row with its own life (join date, role in the team), and one account can sit in several teams. A single `members` reference field on `Team` would also work for a flat list, but a child doctype gives each membership its own fields and audit trail.

```json
// projects.Team — the aggregate root
{
  "domain": "projects",
  "doctype": "Team",
  "aggregate_root": true,
  "fields": {
    "name": { "type": "string", "required": true }
  },
  "children": {
    "members": { "doctype": "TeamMember", "collection": true }
  }
}
```

```json
// projects.TeamMember — the child; the parent link is implicit
{
  "domain": "projects",
  "doctype": "TeamMember",
  "member_of": "Team",
  "fields": {
    "account": { "type": "reference", "doctype": "iam.Account", "required": true }
  }
}
```

```json
// projects.Project — points at its team
{
  "domain": "projects",
  "doctype": "Project",
  "aggregate_root": true,
  "fields": {
    "name": { "type": "string", "required": true },
    "team": { "type": "reference", "doctype": "projects.Team", "filters": ["equality"] }
  }
}
```

See [Parent/child composition](/build/parent-child-composition/) for the `children`/`member_of` pair and [References, links and backlinks](/build/references-links-backlinks/) for the reference fields.

### Step 1 — the context set resolves the caller's teams

Declare `my_teams` on the `projects` domain document. It queries the caller's `TeamMember` rows and collects each row's parent team id:

```yaml
# projects domain document, under content
context_sets:
  my_teams:
    from: TeamMember        # a doctype of the same domain
    where:
      account: "$self"      # the caller's own membership rows
    select: "$parent_id"    # the parent team id of each row
```

`$parent_id` reads the child's parent linkage, so the set holds the ids of the teams the caller belongs to — resolved per request.

### Step 2 — the named scope turns teams into a row filter

Declare a scope on `projects.Project` that matches rows whose `team` is in that set:

```yaml
# projects.Project definition
scopes:
  team_projects:
    description: "Projects of the caller's teams"
    where:
      team: "$my_teams"
```

`$my_teams` is not built in — it is the context set declared in step 1. Any `$<name>` that is not `$self`, `$null`, or `$organizational_unit` resolves as a context set, so the two declarations are linked by that name.

### Step 3 — the role names the scope

An administrator sets the **Read** action of the `project_manager` role to `team_projects`. The stored line is:

```json
{
  "action": "read",
  "on": "projects.Project",
  "scope": ["$team_projects"]
}
```

A manager who belongs to two teams lists `projects.Project` and sees the projects of both teams, and nothing else. A project of a team they do not belong to answers `404` on a direct read, exactly like a missing document. See [Row scopes](/govern/row-scopes/) for how the enforcer applies the alias at list, read, and write time.

## Related

- [Row scopes](/govern/row-scopes/) — attach a scope to a role and see how Facet applies it.
- [Permission syntax reference](/reference/permission-syntax/) — the full permission grammar.
- [Roles, levels and authority](/concepts/roles-levels-authority/) — how roles and permissions relate.
- [Lifecycle scripts and guards](/build/lifecycle-scripts-guards/) — guard writes the same way you filter reads.
