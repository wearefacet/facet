---
title: Reference Patterns
description: Qualified reference storage contract, owner_id convention, N-N membership pattern, reference filters, owned references.
tags: [schema, references, patterns]
---

# Reference Patterns

The fixtures encode a set of conventions for modelling relationships between documents. Follow them when designing a new domain.

## Qualified reference storage contract

Every `reference`-typed field value is stored fully qualified as `{domain}.{Doctype}.{id}`:

```yaml
# data/fixtures/crm.Deal/documents.yml
owner_id: "iam.Account.account_recruiter_kim"
stage_id: "crm.PipelineStage.3"
company_id: "crm.Company.1"
```

- The id segment may itself contain dots — split on the first two dots only, never the whole string.
- API callers may submit bare ids; normalization qualifies them before validation and persistence.
- The frontend resolves the qualified form and falls back to the bare id for seeded fixtures.
- When comparing or filtering reference values in Lua, always use the qualified form (see read_skill("lua-document-helpers") → `document.list` filters).

## Cross-domain vs same-domain references

- Cross-domain reference: qualified doctype value, e.g. `doctype: "identity.Person"` (from `hr.Employee`).
- Same-domain reference: **also qualified**, e.g. `doctype: "crm.Contact"` (from `crm.Activity.contact_id`). Always declare the target as `"domain.Doctype"`, same-domain or not.
- Never write a bare name (`doctype: "Contact"`): reference values are qualified with the declared target verbatim, so a bare target produces values that can never validate and every write through the field fails.
- In a draft domain, qualify with the draft's own id (e.g. `"_abc123.Brand"`) — publish relinks same-domain targets to the final domain name.

## The `owner_id` convention

Fields that track who owns or created a document are named `owner_id` and reference `iam.Account`:

```yaml
owner_id:
  type: reference
  doctype: "iam.Account"
  title: Owner
  description: "The sales representative who owns this deal."
  filters: [equality]
```

Every user-facing fixture doctype that carries ownership uses this shape (`crm.Deal`, `crm.Company`, `crm.Prospect`, `production.Project`, `hr.Candidate`, `crm.Activity`, ...). Named scopes then bind `where: {owner_id: $self}` and the create hook may force `owner_id` from `ctx.actor` (see read_skill("lua-actor")).

## The N-N membership pattern

Many-to-many relationships use a dedicated child doctype that stores one reference per side. `crm.CompanyMembership` links `crm.Company` ↔ `crm.Contact`:

```yaml
# data/fixtures/crm.CompanyMembership/definition.yml
doctype: CompanyMembership
domain: crm
aggregate_root: false
member_of: Company          # child of the Company side
fields:
  contact:
    type: reference
    doctype: "crm.Contact"  # the other side
    required: true
    filters: [equality]
  role:
    type: enum
    values: [primary, secondary, observer]
```

- The parent (`crm.Company`) declares `children: memberships: {doctype: CompanyMembership, collection: true}`.
- One contact can appear in many membership rows (N-N) — see `crm.CompanyMembership.4`, where `crm.Contact.1` participates at two companies.
- The same pattern powers `production.TeamMember` (Team ↔ Account) and is the input to the `my_teams` RBAC context set (`from: TeamMember, where: {account: $self}, select: $parent_id`).
- The membership's `display_name` mixes both sides: `"{{ role }} at {{ contact }}"`.
- Deleting a contact requires cleaning its membership rows in the `delete` hook (see `crm.Contact/script.lua`) — cascade delete only walks the parent→child link.

## Reference `filter`

A `reference` field may declare a `filter` — conditions the referenced document must satisfy, using the `field__op` convention:

```yaml
company:
  type: reference
  doctype: crm.Company
  filter:
    status__eq: active
```

At create/update, the referenced document is checked against the composite filter (`id__eq` merged with the declared filter); a mismatch is a 422. Null references skip the check; collection references check each element.

## `owned` references

Set `owned: true` when the referenced document's lifecycle should follow the parent (cascade delete). Without it, deleting the parent leaves the referenced document untouched. Ownership is distinct from the `children`/`member_of` composition — prefer `children` for true composition (see read_skill("children-and-composition")).

## Checklist when designing references

1. Always declare the target fully qualified: `"domain.Doctype"` — same-domain or not.
2. Owner/creator? Name it `owner_id`, target `iam.Account`, add `filters: [equality]`.
3. Many-to-many? Introduce a membership child doctype with one reference per side.
4. Constrain the target? Add a `filter`.
5. Cascade delete on parent delete? `owned: true`, or model as `children` composition.
6. Should the label resolve? Add a `display_name` on the target doctype.
7. Never reference a composition child from its parent — that is what `children` is for (`:composition` check issue).
