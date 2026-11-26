---
type: how-to
title: Display names and search text (Jinja2)
description: Write the Jinja2 templates that build each document label and its search text.
audience: [author]
features: [DOM-23]
sidebar:
  order: 0
verified_at: fd345fe3
---

A list row, a picker entry, and a search result all need one short label for a document. Facet builds that label from a `display_name` template on the doctype. The same doctype can carry a `search` template that builds the words a search matches. Both are Jinja2 templates that Facet renders when a document is written.

## When to use this

- A doctype shows raw ids or an unhelpful label in lists.
- Documents of a doctype never appear in cross-doctype search.
- You want the search text to hold more words than the label, for example an email address or a code.

## Before you start

- **Update rights.** You edit the doctype definition. You need the right to update the doctype.
- **Field names.** Know the field names of the doctype. Templates bind those names.

## Steps

### 1. Write the display name template

Add a `display_name` key to the doctype definition. The value is a Jinja2 template. Keep it short: Facet cuts the result at 255 characters. A person doctype could carry `display_name: "{{ first_name }} {{ last_name }}"`.

### 2. Write the search text template

Add a `search` key. Facet folds runs of spaces to one space and cuts the result at 256 characters. The search template may also print the reserved `display_name` variable — the label of this document.

### 3. Save and re-project old rows

Save the definition. New documents render the templates at once. Documents written before the change keep their old label until Facet re-projects them.

:::caution
Changing a template does not rewrite existing rows. Run `facet doctype:reproject <domain.Doctype>` to rebuild the label and search text of every live document. See [Evolving a schema](/build/model/change-a-live-domain/).
:::

## Variables and filters

| Variable | Holds |
| --- | --- |
| `{{ field_name }}` | A declared field of the doctype, by name. |
| `{{ address.city }}` | A path into an object field. |
| `{{ content.address.city }}` | The raw content tree, for advanced paths. |
| `{{ display_name }}` | The label of this document. Search templates only. |

Templates render with a Jinja2 engine. The common filters work; the one you need most is `join`, which turns an array into readable text. See the [Jinja2 context reference](/reference/jinja2-context/).

Rendering rules:

| Value kind | Renders as |
| --- | --- |
| Reference field | The referenced document's stored label. An unresolved reference shows the target doctype's name. A collection reference shows its first entry. |
| Money field | The currency and the amount: `USD 120000`. |
| Absent optional field | Empty text. The render never fails on missing data. |
| Array field | Python style: `['a', 'b']`. Use a filter for readable output. |

Two limits bite in practice:

- **The document `id` is not a variable.** `{{ id }}` fails at save. Declare a string field for a human-facing code and print that field.
- **An empty string counts as filled.** `{% if nick %}` runs for `nick = ""`. Compare with `{{ nick == '' }}` when the empty value must count as empty.

## Example

A `hr.Person` doctype declares the fields `first_name`, `last_name`, `email`, `tags` (array of string), and `manager_id` (reference to `hr.Person`). The definition carries:

```yaml
display_name: "{{ first_name }} {{ last_name }}"
search: "{{ first_name }} {{ last_name }} {{ email }} {{ tags | join(', ') }}"
```

A document stores:

```json
{
  "first_name": "Ada",
  "last_name": "Lovelace",
  "email": "ada@facet.local",
  "tags": ["crm", "vip"],
  "manager_id": "hr.Person.01JCATPMKP4N82GVG2J7K4MHZZ"
}
```

The stored label is:

```text
Ada Lovelace
```

The stored search text is:

```text
Ada Lovelace ada@facet.local crm, vip
```

If the template printed `{{ tags }}` without the filter, the same document would carry `['crm', 'vip']` in its search text.

## What happens with no template

A doctype may declare neither key. The check tool then reports what the interface does:

- **No `display_name`.** Labels fall back to the first of the `name`, `title`, or `label` fields, then to the raw document id.
- **No `search` template.** The search text is the folded label. A search term still matches it; the cross-doctype search skips the doctype.
- **Neither key.** A search term matches only the document id, and the check raises a warning. Declare at least one key.

## Troubleshooting

**The check says a template contains no variable.**

The template has no `{{` in it. It renders the same literal for every document — usually a lost brace pair. Fix the expression.

**A save fails with a template error.**

The template compiles but fails at render: a misspelled filter, a wrong type, or a bad expression. The write is rejected; nothing is stored. Fix the template and save again.

**Lists still show the old label after a template change.**

The rows were written before the change. Run `facet doctype:reproject <domain.Doctype>`.

## Related

- [Jinja2 context reference](/reference/jinja2-context/) — every variable and filter.
- [Documents, doctypes and projections](/build/deeper/documents-and-projections/) — where the label and the search text live.
- [View templates](/build/model/views/document-pages/) — show the same fields on the document page.
