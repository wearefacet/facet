---
title: Display Name and Identity
description: display_name and search templates (Jinja2), color, icon, identifier sequential ids (Util::Sequence) — the label and identity conventions from the fixtures.
tags: [schema, display, identity, sequence]
---

# Display Name and Identity

Four doctype-level features shape how documents are labelled, colored, searched, and identified. All four are optional, and all four appear throughout `data/fixtures/`.

## `display_name`

A Jinja2 template rendered at mutation time into the projection's `display_name` column — the label every list, reference, and audit view shows.

| Example (fixture) | Template |
|---|---|
| `hr.Employee` | `"{{ person }}"` |
| `crm.Deal` | `"{{ title }} - {{ company_id }} - {{ value }}"` |
| `crm.Contact` | `"{{ first_name }} {{ last_name }}"` |
| `identity.Person` | `"{{ full_name }}"` |
| `crm.CompanyMembership` | `"{{ role }} at {{ contact }}"` |

Rules:

- Expressions are `{{ field }}` or `{{ path.to.field }}`; plain text between expressions is kept. Full Jinja2 syntax works (filters like `{{ title | upper }}`, control flow like `{% if nickname %}`).
- Reference variables resolve to the target's stored `display_name`; an unresolved reference falls back to the target doctype's bare name (never the raw id).
- Money variables render as `"<currency> <value>"` (e.g. `"USD 120000"`).
- Missing fields render empty and never fail the render.
- Each variable's first segment must name an existing field — validated at authoring time. Variables inside tag arguments (`{% if %}`, `{% for %}`) are not validated.
- Render failures raise an error and reject the mutation.
- A doctype without `display_name` has no label; give every user-facing doctype one.
- Quirk: Crinja treats an empty string as truthy (unlike Jinja2's Python truthiness). Compare explicitly (`{{ nick == '' }}`) when an empty value must follow the false branch.

## `color`

A doctype-level hex color the UI uses to identify the doctype (e.g. `"#4CAF50"`). The schematic and the doctype list render it. Not required — the UI falls back to a deterministic hash of the qualified id — but the fixtures always set one.

## `icon`

An optional doctype-level Lucide icon name (kebab-case, e.g. `"building-2"`) the UI renders in doctype marks (headers, badges, capsules, schematic nodes, reference pickers). When absent or not a known icon, the UI falls back to the signature diamond.

```yaml
icon: building-2
```

- The value is a free-form string — no backend validation — so the frontend picker is the source of truth for valid values.
- The fixtures set one per doctype; pick an icon that matches the doctype's purpose (e.g. `crm.Company` → `building-2`, `hr.Employee` → `id-card`).
- Use the kebab-case Lucide name (e.g. `handshake`, `folder-kanban`), not the PascalCase export name.

## `search`

A Jinja2 template whose rendering becomes the projection's `search` column for trigram substring search (accent-folded, whitespace-normalised, truncated to 256 chars):

```yaml
search: "{{ full_name }} {{ email }}"
```

- Paths support nested dot notation (e.g. `{{ address.postal_code }}`).
- When `search` is absent, the corpus falls back to the document id and the computed `display_name` — so any doctype with a `display_name` is searchable by label without declaring `search`.
- Declare `search` when a listing must match on content fields beyond the label (e.g. `crm.Company` searches `{{ name }} {{ domain_name }}`).

## `identifier` — sequential ids

A doctype may declare an `identifier` block to generate sequential, human-readable document ids instead of ULIDs:

```yaml
identifier:
  template: "INV-{year}-####"
  genonly: false
```

| Key | Required | Description |
|---|---|---|
| `template` | yes | `#` digit groups (zero-padded, rightmost starts at 1) and `{year}` / `{month}` / `{day}` time variables. |
| `genonly` | no | When `true`, the id is always system-generated; callers cannot supply a custom `doc_id`. |

The fixtures use `{year}` + `####` (e.g. `crm.Deal`: `"DEAL-{year}-####"`, `crm.Prospect`: `"PROS-{year}-####"`). Generation serializes per doctype, and on digit-group overflow the system falls back to a ULID — a document is never rejected for counter exhaustion.

## Combined example

```yaml
# crm.Deal (abridged)
doctype: Deal
domain: crm
aggregate_root: true
display_name: "{{ title }} - {{ company_id }} - {{ value }}"
color: "#FF9800"
icon: handshake
identifier:
  template: "DEAL-{year}-####"
  genonly: false
```
