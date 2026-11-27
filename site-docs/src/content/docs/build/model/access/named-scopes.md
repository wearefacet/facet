---
type: how-to
title: Write row rules for roles
description: Declare named scopes on a doctype so roles can reach only the rows that match.
audience: [author, admin]
features: [DOM-12]
sidebar:
  order: 0
verified_at: eee55a2
---

At Brightwater, each salesperson should see only the clients they manage.
Tom sells to five of the ten companies; his colleague sells to the others.
Both hold the same *Sales* role, so the role cannot name companies — the
rule must say "your own clients". As the domain author, you write that rule
once on the Company doctype as a **named scope**: a saved filter over the
doctype's own fields. An administrator then gives it to the role, and every
surface follows — lists, search, the API, apps.

:::note[This page is one half of a pair]
This page covers the **author** side: declare the scope, and the context
set it reads. The **admin** side — attaching the alias to a role and how
Facet applies it — lives in [Show each role only its
rows](/admin/people/row-scopes/). The [worked
example](#worked-example-own-projects-via-teams) below shows both halves
together.
:::

## When to use this

- A role may see or change only its own rows.
- Several roles share one row rule, and you do not want to repeat it.
- A reader needs a saved subset through the API, for example "active
  projects".

## Before you start

- **Author side:** you edit the doctype definition to declare scopes.
- **Admin side:** an administrator edits the role to attach them. This page
  stays with the author's part; the application rules sit on [the admin page](/admin/people/row-scopes/).

## Declare the scopes

Add a `scopes` map to the doctype definition. Each entry has a description
and a `where` filter. The Brightwater Company doctype declares one:

```yaml
# clients.Company definition
scopes:
  my_clients:
    description: "Companies whose account manager is the caller."
    where:
      account_manager: "$self"
```

The `where` values follow one grammar:

| Value | Matches |
| --- | --- |
| `"active"` | The literal stored value. |
| `"$self"` | The acting account's id. Works on a reference field and on a plain string field that stores an account id. |
| `"$null"` | Rows where the field is absent or null. Equals matches only. |
| `"$my_teams"` | The values of a context set the domain declares, resolved per request. An empty or unresolvable set matches no rows. |
| `"$organizational_unit"` | The acting account's organizational unit path. |

A field name can carry an operator, like the list filters do:
`priority__gte`, `title__match`, `price__between`. A bare name means
equals. A field accepts exactly the operators its declared `filters`
capabilities allow. Two reserved keys read the system columns: `$parent_id`
(the parent linkage) and `$doc_id` (the row id), both with equals or
not-equals only.

Facet validates the declaration when you save the doctype: every field must
exist, and every `$name` that is not `$self`, `$null`, or
`$organizational_unit` must name a context set the domain declares.

## Context sets

Some rules read other doctypes: "projects of my teams" needs the team
memberships first. A **context set** is a saved query the domain declares —
on the domain document, not on the doctype — that resolves to a list of
values per request:

```yaml
# the domain document, under content
context_sets:
  my_teams:
    from: TeamMember       # a doctype of the same domain
    where:
      account: "$self"     # the caller's own membership rows
    select: "$parent_id"   # the field to collect; $parent_id reads the parent team
```

`from` names the doctype to query, `where` filters its rows, and `select`
names the field to collect into the set. Both accept `$self`, `$parent_id`,
`$doc_id`, and other context sets, so one set can build on another. A scope
then uses the set by name:

```yaml
# projects.Project definition
scopes:
  team_projects:
    description: "Projects of the caller's teams"
    where:
      team: "$my_teams"
```

`$my_teams` is not a built-in token — any `$name` that is not one of the
three reserved values resolves as a context set. The two declarations are
linked by that name.

## Attach the scopes to a role

An administrator opens the role, finds the doctype, and sets the scope on
an action. The select lists **All** plus every scope declared on the
doctype. Several scopes on one line combine with OR: the permission reaches
rows that match any of them. The stored permission line looks like this:

```json
{ "action": "read", "on": "clients.Company", "scope": ["$my_clients"] }
```

A line without a scope reaches every row. How the enforcer applies the
alias at list, read, and write time is the admin page's subject — see
[Show each role only its rows](/admin/people/row-scopes/).

## Narrow a list on request

Any reader can pass a declared scope as a parameter on the list route. It
only narrows what the caller may already see:

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/clients/Company?scope=my_clients"
```

An unknown name answers `422` with `Unknown scope`.

## Example

The Brightwater round trip, live on the example instance:

1. The author declares `my_clients` on `clients.Company`, as above.
2. The *Sales* role carries the read line shown above.
3. Tom signs in and lists companies. He sees his five: Maison Lumière,
   Festival des Collines, Cabinet Moreau, Château de Vireloup, Mairie de
   Saint-Clair — and nobody else's.
4. The same list with `?scope=my_clients` returns the same five, narrowed
   from what he may already see. A direct read of another salesperson's
   company answers `404`, exactly like a missing document.

## Troubleshooting

**The scope select on the role shows only All.**

The doctype declares no scopes yet, or the definition failed to save. Add
the `scopes` map and check the doctype again.

**A scoped list returns nothing.**

The filter matches no rows. Check the stored value shape: a literal must
equal the stored value exactly, while `"$self"` matches both the qualified
reference form and the bare id. For a context-set value, check that the set
resolves for this account: an empty set matches no rows of the list either.

**The API answers Unknown scope.**

The scope name is not declared on that doctype. Copy the name from the
definition.

**A role change has no effect.**

Permissions apply on the next request. Reload the list and check that the
role was saved on the right doctype path, for example `clients.Company`.

## Worked example: own projects via teams

A project manager reads only the projects of their own team. Projects
belong to a team, a team has members, and each member names an account. One
context set and one named scope express this, and the role references the
scope by alias. This section holds the authoring declarations; the admin
half — the role line and what the manager sees — sits on [Show each role
only its rows](/admin/people/row-scopes/).

### The document model

Two relationships carry the rule:

- **Team → TeamMember** is composition. `Team` is the aggregate root and
  `TeamMember` is its child (`member_of: Team`). Each member row holds an
  `account` reference to `iam.Account`.
- **Project → Team** is a reference. `Project` holds a `team` reference to
  `projects.Team`.

*The two data relationships and the two declarations that read them.*

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

A separate `TeamMember` doctype is the right shape here: membership is a
row with its own life (join date, role in the team), and one account can
sit in several teams. A single `members` reference field on `Team` would
also work for a flat list, but a child doctype gives each membership its
own fields and audit trail.

```json
{ "domain": "projects", "doctype": "Team", "aggregate_root": true,
  "fields": { "name": { "type": "string", "required": true } },
  "children": { "members": { "doctype": "TeamMember", "collection": true } } }
```

```json
{ "domain": "projects", "doctype": "TeamMember", "member_of": "Team",
  "fields": { "account": { "type": "reference", "doctype": "iam.Account", "required": true } } }
```

```json
{ "domain": "projects", "doctype": "Project", "aggregate_root": true,
  "fields": {
    "name": { "type": "string", "required": true },
    "team": { "type": "reference", "doctype": "projects.Team", "filters": ["equality"] }
  } }
```

See [Parent/child
composition](/build/model/relations/parent-child/) for the
`children`/`member_of` pair and [Link documents
together](/build/model/relations/references-links/) for the reference
fields.

### The two declarations

Declare `my_teams` on the `projects` domain document, and
`team_projects` on `projects.Project` — both shown in [Context
sets](#context-sets) above. The set resolves, per request, to the ids of
the teams the caller belongs to; the scope matches projects whose `team` is
in that set.

The administrator then sets the read line on the role — the full walk
through is on the admin page.

## Related

- [Show each role only its rows](/admin/people/row-scopes/) — attach a scope to a role and see how Facet applies it.
- [Permission syntax](/reference/permission-syntax/) — the full permission grammar.
- [Roles, levels and authority](/admin/people/who-can-change-roles/) — how roles and permissions relate.
- [Scripts and guards](/build/model/behaviour/scripts-and-guards/) — guard writes the same way you filter reads.
