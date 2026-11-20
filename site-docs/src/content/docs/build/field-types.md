---
title: Field types (guide)
description: Pick the right type for each field, set defaults, and know how Facet normalizes values.
audience: [author]
features: [DOM-04, DOC-13]
sidebar:
  order: 3
verified_at: fd345fe3
---

Every field in a doctype has one type. The type decides three things: what users can enter, how Facet stores the value, and which filters the list pages offer. This guide covers the types you use most. The full table of all types, with every constraint, sits in the reference.

## When to use this

You declare fields and ask yourself: text or long text? number or money? link or file? The example at the end shows a complete `fields` block you can copy.

## Before you start

- **Edit in a draft.** You edit the doctype in a draft domain. See [Designing doctypes](/build/designing-doctypes/).
- **Choose types with care before you publish.** A type change on a live domain needs a version bump, because stored values must stay readable.

## Steps

### 1. Pick the type

| Type | Holds | Example value | Notes |
| --- | --- | --- | --- |
| `string` | Short text | `"Acme Corp"` | `min`/`max` bound the length. |
| `longtext` | Long text with markdown | `"See the notes.\n\nSecond line."` | Line breaks are normalized to `\n`. |
| `integer` | Whole number | `42` | `min`/`max` bound the value. |
| `boolean` | True or false | `true` | |
| `money` | Amount with currency | `{"value": "1200.50", "currency": "USD"}` | Declare `currency: USD` to fill the currency by default. |
| `date` | Calendar date | `"2026-03-01"` | No time, no zone. |
| `datetime` | Point in time | `"2026-03-01T14:30:00Z"` | Any zone offset is accepted; Facet stores UTC. |
| `enum` | One value from a fixed list | `"active"` | Declare the `values` list; each entry has a key, a label, and a color. |
| `url` | Web address | `"www.acme.tld"` | Facet stores `https://www.acme.tld`. |
| `reference` | Link to another document | `"hr.Employee.01HQ2F5WX8K4M3PZC6NRB9TJVA"` | See [References, links and backlinks](/build/references-links-backlinks/). |
| `file` | A file in the artifact store | `"01HQ2F5WX8K4M3PZC6NRB9TJVA"` (artifact id) | See [Files and artifacts in fields](/build/files-artifacts/). |

Container types hold more than one value: `object` with named `properties`, `array` with one `items` schema, and `dictionary` with one `values` schema for all entries. Two types are special: a `data` field holds a value Facet computes (see [Computed fields](/build/computed-fields/)), and a `secret` field holds a credential (see [Secret and write-only fields](/build/secret-write-only-fields/)).

The remaining types cover time ranges (`period`, `dateperiod`), a length of time (`duration`), a color (`color`), a phone number (`phone`), and inline sub-documents (`child`). The reference table lists them all.

### 2. Add constraints

Common field keys:

| Key | Effect |
| --- | --- |
| `required: true` | The write fails when the field is missing. |
| `unique: true` | No two documents of the doctype carry the same value. |
| `default` | Facet fills the value when the writer omits the field. |
| `pattern` | The value must match this regular expression. |
| `write_only: true` | The value is accepted, read by scripts, and never stored. |
| `read_only: true` | Only scripts may set the value; user input is rejected. |

### 3. Declare the filters

Add `filters` to a field so list pages can filter on it. The common capabilities are `equality`, `comparison`, and `text_search`. A field without `filters` still shows in forms and tables; it only stays out of the filter bar.

## Example

```json
{
  "fields": {
    "job_title": { "type": "string", "required": true, "max": 120 },
    "department": { "type": "string", "filters": ["equality", "text_search"] },
    "status": {
      "type": "enum",
      "default": "active",
      "filters": ["equality"],
      "values": [
        { "key": "active", "label": "Active" },
        { "key": "on_leave", "label": "On Leave" },
        { "key": "terminated", "label": "Terminated" }
      ]
    },
    "hire_date": { "type": "date", "required": true, "filters": ["comparison"] },
    "salary": { "type": "money", "currency": "USD", "filters": ["comparison"] },
    "remote": { "type": "boolean", "default": false }
  }
}
```

With the `salary` currency declared, a write of `{"value": "54000"}` stores `{"value": "54000", "currency": "USD"}`.

## Troubleshooting

### A write answers `422` on a money field

The amount must be a decimal string, and the currency must be a registered ticker. Send `{"value": "54000", "currency": "USD"}`, not a bare number.

### A datetime stores a different form than I sent

Facet normalizes every datetime to UTC and stores it ending in `Z`. `2026-03-01T15:30:00+01:00` is stored as `2026-03-01T14:30:00Z`. The value is the same moment.

### A URL shows a scheme I did not type

Facet completes a bare dotted address such as `www.acme.tld` to `https://www.acme.tld`. A value without a dotted host stays rejected.

### My color changes shape

Facet normalizes colors to the `#RRGGBBAA` form. `#1565C0` is stored as `#1565C0FF`.

## Related

- [Field types (reference)](/reference/field-types/) — the full table of all types.
- [Documents, doctypes and projections](/concepts/documents-doctypes-projections/) — how field values are stored and re-read.
- [Identifiers and unique constraints](/build/identifiers-unique-constraints/) — add readable reference numbers and uniqueness rules.
