---
title: Designing doctypes
description: Declare a doctype with fields, identifier, label, icon, actions, children, and templates.
audience: [author]
features: [DOM-03]
sidebar:
  order: 2
verified_at: fd345fe3
---

A doctype is one record type inside a domain, such as `crm.Company` or `hr.Employee`. You declare it once, and Facet validates every write against it. The definition holds the fields, the actions users can run, the owned children, and the rules that name and search each document.

## When to use this

You add a doctype to a draft domain, or you rework an existing one. Work in a draft domain while you design; publish when the model holds (see [Domains, drafts and domain editors](/build/domains-drafts-editors/)).

## Before you start

- **Edit rights.** You need the right to edit doctypes in the target domain. The editor role holds it for the domains the account edits.
- **A domain to live in.** The domain must exist before Facet accepts a doctype in it.
- **A free action name.** Reserved action names (`validate`, `create`, `update`) are not available; they name lifecycle hooks.

## Steps

### 1. Declare the fields

Give each field a name and a type, then add the constraints the data needs. Field names use lower_snake_case or camelCase. See [Field types (guide)](/build/field-types/) for the common types, and [Field types (reference)](/reference/field-types/) for the full table.

### 2. Set the label, icon, and templates

| Part | Purpose |
| --- | --- |
| `label` | The name the interface shows, for example `Company`. Falls back to the doctype name. |
| `icon` | A Lucide icon name in kebab-case, for example `building-2`. |
| `display_name` | A Jinja2 template that names each document, for example `{{ name }}`. |
| `search` | A Jinja2 template for the search text. A doctype without one stays out of cross-doctype search. |

### 3. Choose root or child

A doctype is exactly one of two things:

| Kind | Declaration | Meaning |
| --- | --- | --- |
| Aggregate root | `aggregate_root: true` | The record users create and delete. It is the unit of locking and of access control. |
| Owned child | `aggregate_root: false` plus `member_of` | A part of a parent document. See [Parent/child composition](/build/parent-child-composition/). |

### 4. Add actions, children, and an identifier

Add `actions` when users need typed operations beyond edits (see [Named actions](/build/named-actions/)). Add `children` for owned parts. Add an `identifier` block when documents need readable numbers (see [Identifiers and unique constraints](/build/identifiers-unique-constraints/)).

### 5. Register the doctype and iterate

Submit the definition while your draft domain is open. Facet validates the schema, compiles the script, and returns the issues. On a live domain, every later change to the data shape needs a version bump (see [Evolving a schema](/build/evolving-schema/)).

Every write then follows the same path: Facet validates the document, appends one log row, updates one projection, and publishes one event.

<!-- d2
writer: "App or user" {class: external}
mutations: "mutations log" {class: store}
projections: "projections row" {class: store}
bus: "Redis event bus"
consumers: "Hooks, webhooks, live updates"

writer -> mutations: validated write
mutations -> projections
mutations -> bus
bus -> consumers
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/d2a28d26-light.svg" alt="App or user" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/d2a28d26-dark.svg" alt="App or user" loading="lazy" />
</div>

## Example

The definition below declares a `crm.Company` root with four fields. Send it to the doctype endpoint of your instance.

```json
{
  "domain": "crm",
  "doctype": "Company",
  "label": "Company",
  "icon": "building-2",
  "aggregate_root": true,
  "schema_version": 1,
  "display_name": "{{ name }}",
  "search": "{{ name }} {{ industry }}",
  "fields": {
    "name": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "industry": { "type": "string", "filters": ["equality"] },
    "status": {
      "type": "enum",
      "default": "lead",
      "filters": ["equality"],
      "values": [
        { "key": "lead", "label": "Lead" },
        { "key": "active", "label": "Active" }
      ]
    },
    "website": { "type": "url" }
  }
}
```

```sh
curl -k -X POST "https://facet.localhost:3443/Api/core/DocType" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d @company.json
```

`-k` skips the certificate check of the local development address. A second submit of the same definition answers `409`; updates go through the doctype editor instead.

## Troubleshooting

### The create answers `422 Domain 'crm' does not exist`

Create the domain first. A doctype needs a live or draft domain to live in.

### The create answers `422` with a key name

A definition accepts only known keys, and every field entry checks its own keys. The message names the key and its location. Most often a constraint is misspelled, for example `reqired` instead of `required`.

### The icon does not show

The icon value must match a Lucide icon name in kebab-case. Facet falls back to a plain mark when the name is unknown.

## Related

- [Doctype schema (reference)](/reference/doctype-schema/) — every definition key and its shape.
- [Documents, doctypes and projections](/concepts/documents-doctypes-projections/) — how a definition shapes stored documents.
- [Field types (guide)](/build/field-types/) — choose the type for each field.
