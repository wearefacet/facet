---
title: Doctype Anatomy
description: DoctypeDefinition structure, required vs optional fields, identity rules, aggregate_root vs member_of.
tags: [schema, structure]
---

# Doctype Anatomy

A `DoctypeDefinition` is a single JSON object stored as a `core.DocType` document, it is identified by `<domain>.<Doctype>`. See the reference pattern `data/fixtures/hr.Employee/definition.yml` for a complete example.

## Example (abridged)

```yaml
# data/fixtures/hr.Employee/definition.yml

doctype: Employee
 domain: hr
 schema_version: 1
 aggregate_root: true
 display_name: "{{ person }}"
 color: "#4CAF50"
 fields:
   status:
     type: enum
     values:
       - {key: active, label: Active, color: "#b16147"}
     default: active
     filters: [equality]
   salary:
     type: money
     filters: [comparison]
   person:
     type: reference
     doctype: "identity.Person"
     required: true
     unique: true
   tenure_days:
     type: data
     compute: employee_tenure_days
     compute_when: [hire_date, termination_date]
 children:
   career_events:
     doctype: CareerEvent
     collection: true
 actions:
   promote:
     args:
       new_title:
         type: string
         required: true
```

## Top-level fields

| Field | Type | Required | Description |
|---|---|---|---|
| `doctype` | string | yes | CamelCase identifier (e.g. `Employee`). Cannot start with a digit. |
| `domain` | string | yes | Lower-case domain this doctype belongs to (e.g. `hr`). Must match the document's draft or live domain. |
| `schema_version` | integer | yes | ≥ 1. In draft mode, version/migration discipline is lifted — you can freely rewrite the doctype. |
| `aggregate_root` | boolean | yes | `true` when this doctype owns its transaction boundary and lock target. Most top-level doctypes are roots. |
| `member_of` | string | no | Parent doctype name (e.g. `WorkOrder`). Set this instead of `aggregate_root: true` for a child doctype. |
| `nav_visible` | boolean | no | `true` puts a `member_of` child in the app sidebar with its own listing (default `false`: children open through the parent's relations surface). Needs a `read` RBAC grant on the child. Ignored for aggregate roots. |
| `description` | string | no | Human-readable summary. |
| `display_name` | string | no | Jinja2 template that resolves into the display label (e.g. `"{{ person }}"`, `"{{ title }} - {{ company_id }} - {{ value }}"`). See read_skill("display-and-identity"). |
| `color` | string | no | Hex color used in the UI (e.g. `"#4CAF50"`). |
| `icon` | string | no | Optional Lucide icon name (kebab-case, e.g. `"building-2"`) shown in doctype marks. Falls back to the diamond when absent or unknown. See read_skill("display-and-identity"). |
| `identifier` | object | no | Sequential identifier config `{template: "INV-{year}-####", genonly: false}`. See read_skill("display-and-identity"). |
| `fields` | object | yes | Map of field name → field definition. See read_skill("field-types"). |
| `actions` | object | no | Map of action name → action definition. Reserved names: `validate`, `create`, `update`, `delete`, `migrate`, `snapshot`, `history`, `rollback`. |
| `children` | object | no | Child relationship declarations (parent→child composition). See read_skill("children-and-composition"). |
| `migrations` | object | no | Map of source version → Lua function name (e.g. `"1": "migrate_from_1"`). |
| `script` | string | no | Lua module source. See read_skill("lifecycle-scripts"). |
| `scopes` | object | no | Named predicates over this doctype's own fields. See read_skill("named-scopes"). |
| `search` | string | no | Jinja2 template rendered into the search column (trigram search over the accent-folded corpus). |

## Identity

- `domain.doctype` is the qualified id (e.g. `hr.Employee`).
- `member_of` references the parent's doctype (not qualified).
- A doctype with `member_of` is a child; `aggregate_root` must be `false`.
- A child doctype must NOT declare a reference field back to its parent. The link is the system-managed `meta.parent_id`.

## Display name and search

- `display_name` is a Jinja2 template, rendered at mutation time into the `display_name` column on the projection.
- Reference variables are resolved to the target's stored `display_name`. An unresolved reference falls back to the bare doctype name.
- `search` is a Jinja2 template rendered into the search column (trigram search over the accent-folded corpus — unaccented terms match accented text). When `search` is absent, the corpus falls back to the document id and the display_name label — every doctype with a `display_name` is searchable by label without a `search` declaration.

## Draft mode conventions (from fixtures)

- Child doctypes: `aggregate_root: false` + `member_of: <Parent>` (e.g. `production.Task` declares `member_of: Project`).
- Children are hidden in the sidebar until the definition sets `nav_visible: true`. Set it when the child needs its own listing entry (see read_skill("children-and-composition")).
- Enum fields: use the object form `{key, label, color}` so the UI shows readable labels and stable colors (e.g. `crm.Deal.status`).
- Reference fields always carry the full qualified target (`"domain.Doctype"`), same-domain or not — e.g. `crm.Activity.contact_id` targets `crm.Contact`, `crm.Activity.owner_id` targets `iam.Account`. Never write a bare name.
- Name the owner/creator reference field `owner_id` and target it at `iam.Account` (see `crm.Deal.owner_id`, `production.Project.owner_id`).
- Use `title` and `description` on fields — the UI renders them as labels and help text.
- Doctype-wide search: add a `search` template when the listing needs substring search.
- `display_name` templates may mix plain text and variables: `"{{ title }} - {{ company_id }} - {{ value }}"` (see `crm.Deal`).

## YAML gotcha

Crystal's YAML parser follows YAML 1.1: bare `on`, `off`, `yes`, `no` become booleans. When used as hash keys they silently collide. Quote such keys: `"on": value`.

## In draft mode

- Version may decrease, skip ahead, or carry destructive same-version edits.
- Replicate declarations are valid schema but remain inert until published.
- Use `update_doctype` freely — no `$force` flag is needed in draft.
