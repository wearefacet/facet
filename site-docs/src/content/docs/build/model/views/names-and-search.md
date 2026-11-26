---
type: how-to
title: Display names and search text
description: Write the templates that build each document's label and its search text.
audience: [author]
features: [DOM-23]
sidebar:
  order: 0
verified_at: eee55a2
---

Every Brightwater item appears in three places: a list row, the picker when
someone links an item to a ticket, and the search palette. All three show one
short label for the document. Facet builds that label from a `display_name`
template on the doctype, and the words a search matches from a `search`
template. Both are Jinja2 templates. You need no code for this page — only
template expressions such as `{{ name }}`. Facet renders both when a document
is written.

## When to use this

- A doctype shows raw ids or an unhelpful label in lists and pickers.
- Documents of a doctype never appear in cross-doctype search.
- The search text should hold more words than the label, for example a serial
  number or an email address.

## Before you start

- **Update rights** on the doctype definition.
- **The field names.** Templates bind the names the doctype declares.

## Write the templates

Add two keys to the doctype definition:

```yaml
# equipment.Item definition
display_name: "{{ name }}"
search: "{{ name }} {{ serial_number }}"
```

- `display_name` builds the label. Keep it short: Facet cuts the result at
  255 characters.
- `search` builds the search text. Facet folds runs of spaces to one space
  and cuts the result at 256 characters. The search template may also print
  `{{ display_name }}` — the label of the same document. A `display_name`
  template cannot print it: that would read the value the same write is
  computing.

In the Builder you edit both keys on the doctype's **General** tab, under
the document templates. In files they sit in the doctype's YAML file beside
the fields.

## Variables and rendering rules

| Variable | Holds |
| --- | --- |
| `{{ field_name }}` | A declared field of the doctype, by name. |
| `{{ address.city }}` | A path into an object field. |
| `{{ content.address.city }}` | The raw content tree, for advanced paths. |
| `{{ display_name }}` | The label of this document. Search templates only. |

The engine is Jinja2. The common filters work; the one you need most is
`join`, which turns an array into readable text. The full variable and filter
list lives in the [Jinja2 context reference](/reference/jinja2-context/).

| Value kind | Renders as |
| --- | --- |
| Reference field | The referenced document's stored label. An unresolved reference shows the target doctype's name. A collection reference shows its first entry. |
| Money field | The currency and the amount: `EUR 4800.00`. |
| Absent optional field | Empty text. The render never fails on missing data. |
| Array field | Python style: `['a', 'b']`. Use a filter for readable output. |

Two limits bite in practice:

- **The document `id` is not a variable.** `{{ id }}` fails when you save.
  Brightwater solves this with a declared field: the item's human-facing code
  `EQ-2026-0001` is the generated `id`, and the serial the team searches for
  lives in `serial_number`. Declare a string field for a code and print that.
- **An empty string counts as filled.** `{% if nick %}` runs for
  `nick = ""`. Compare with `{{ nick == '' }}` when the empty value must
  count as empty.

## Example

The Brightwater `equipment.Item` doctype carries the two keys shown above. A
stored item holds:

```json
{
  "name": "Main tent 10x15",
  "serial_number": "TN-10015-A",
  "status": "out"
}
```

The stored label is:

```text
Main tent 10x15
```

The stored search text is:

```text
Main tent 10x15 TN-10015-A
```

The serial lands in the search text but not in the label, so a warehouse
search for `TN-10015` finds the item while every list still reads *Main tent
10x15*. Live check: the list filter `filters[search]=TN-10015` returns the
item.

If the template printed `{{ tags }}` on a doctype with an array field, the
same document would carry `['vip', 'fleet']` in its search text. Print
`{{ tags | join(', ') }}` instead.

## Save, then re-project old rows

Save the definition. New documents render the templates at once. Documents
written before the change keep their old label until Facet re-projects them.
Run the re-projection command to rebuild the label and search text of every
live document:

```sh
facet doctype:reproject equipment.Item
```

See [Change a live domain safely](/build/model/change-a-live-domain/) for
when a schema change needs this step.

## Without a template

A doctype may declare neither key. The check tool then reports what the
interface does:

- **No `display_name`.** Labels fall back to the first non-empty of the
  `name`, `title`, or `label` fields, then to the raw document id.
- **No `search` template.** The search text is the folded label. The bare
  `search` filter on the list route still matches it, but the cross-doctype
  search skips the doctype.
- **Neither key.** An aggregate root in this state is invisible to every
  search surface. The check raises an error, and Facet refuses to create or
  publish the doctype. An owned child is exempt — it is reached through its
  parent, and the check reports an info notice.

## Troubleshooting

**The check says a template contains no variable.**

The template has no `{{` in it. It renders the same literal for every
document — usually a lost brace pair. Fix the expression.

**A save fails with a template error.**

The template compiles but fails at render: a misspelled filter, a wrong
type, or a bad expression. The write is rejected; nothing is stored. Fix the
template and save again.

**Lists still show the old label after a template change.**

The rows were written before the change. Run
`facet doctype:reproject <domain.Doctype>`.

## Related

- [Jinja2 template context](/reference/jinja2-context/) — every variable and filter.
- [Lists, boards and calendars](/build/model/views/lists-boards-calendars/) — the surfaces the label appears on.
- [How old documents follow a new schema](/build/deeper/documents-and-projections/) — where the label and the search text live.
