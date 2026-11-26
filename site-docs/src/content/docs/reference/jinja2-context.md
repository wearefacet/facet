---
type: reference
title: Jinja2 template context
description: Variables and filters available inside Jinja2 templates.
audience: [author, developer]
features: [DOM-22, DOM-23]
sidebar:
  order: 13
verified_at: eee55a2
---

You write a template and need to know which variables and filters the engine
binds. Facet renders Jinja2 templates in three places: the `display_name` label
and the `search` text of a doctype, both on the server, and the calendar
chip title of a collection view, in the browser.

This page gives the variables each template binds and the filters the server
engine registers.

## Where templates run

| Template | Declared on | Rendered | Engine |
| --- | --- | --- | --- |
| `display_name` | The doctype definition | On the server, on every document write. The result is the document label, truncated to 255 characters. | Full Jinja2 subset (Crinja), filters included |
| `search` | The doctype definition | On the server, on every document write. The result is the search text: whitespace-normalised, accent-folded, truncated to 256 characters. | Full Jinja2 subset (Crinja), filters included |
| `config.calendar.title_template` | A `core.CollectionView` document | In the browser, for each calendar chip. | Minimal subset: `{{ path }}` placeholders only |

A write that renders a broken server template fails and rolls back. A
missing field never fails — it renders empty.

## Context variables — server templates

| Name | Type | Content |
| --- | --- | --- |
| `<field_name>` | The field's type | One variable per declared field, bound to the field's value after the write. Dotted paths walk into object fields: `{{ address.postal_code }}`. |
| `content` | object | The raw document content tree, for paths the declared fields do not shape: `{{ content.address.postal_code }}`. |
| `display_name` | string | The document's label. Bound in `search` templates only. A `display_name` template must not reference it — the save rejects the self-reference. |

Rules the validator enforces at save time:

- Every root variable must be a declared field or a reserved variable.
  `{{ id }}` is rejected — the document id is not a variable. Declare a
  string field for a human-facing code and print that field.
- Variables used only inside `{% if %}` or `{% for %}` arguments are not
  validated.

### How values render

| Value kind | Renders as |
| --- | --- |
| Reference field | The referenced document's stored label. An unresolved reference shows the target doctype's bare name, never the id. A collection reference shows its first entry. |
| Money field | The currency and the amount: `USD 120000`. Nested money objects format the same way. |
| Absent field | Empty text. A nested path over an absent field renders empty too. |
| Array | Python style: `['a', 'b']`. Use `join` for readable output. |
| Object printed as a leaf | Empty text. |
| HTML or quotes | Verbatim. Autoescape is off; templates produce plain text. |

Two quirks matter in practice:

- **An empty string is truthy.** `{% if nick %}` runs for `nick = ""`.
  Compare with `{{ nick == '' }}` when the empty value must fail the
  check.
- **A global function shadows a field.** A name such as `range` hides a
  field of the same name.

## Registered filters

The server engine registers these filters. Arguments are named
arguments, for example `{{ tags | join(', ') }}` or
`{{ price | round(2) }}`.

| Filter | Arguments | Effect |
| --- | --- | --- |
| `abs` | — | Absolute value of a number. |
| `append` | `string` | Appends the string after the value. |
| `attr` | `name` | Reads the attribute `name` from an object. |
| `batch` | `linecount`, `fill_with` | Slices an array into rows of `linecount` items. |
| `capitalize` | — | Upper-cases the first character, lower-cases the rest. |
| `center` | `width` | Pads the value with spaces to `width`. |
| `count` | — | Alias of `length`. |
| `d` | — | Alias of `default`. |
| `date` | `format` | Formats a time value with the given pattern. Field values are strings, so this filter rarely applies to them. |
| `default` | `default_value`, `boolean` | Falls back to `default_value` when the value is empty. With `boolean=true`, also when it is falsy. |
| `dictsort` | `case_sensitive`, `by` | Sorts a dictionary by key (`by="key"`, the default) or value. |
| `e` | — | Alias of `escape`. |
| `escape` | — | HTML-escapes the value. Autoescape is off, so use it only when HTML output is wanted. |
| `filesizeformat` | `binary` | Formats a byte count as `1.5 kB` or, with `binary=true`, `1.5 KiB`. |
| `first` | — | First item of an array. |
| `float` | `default` | Converts to a float; `default` when the value is not a number. |
| `forceescape` | — | HTML-escapes the value, even inside a marked-safe string. |
| `format` | — | `sprintf`-style formatting: `{{ "%d items" | format(3) }}`. |
| `groupby` | `attribute` | Groups an array by an attribute. |
| `indent` | `width`, `indentfirst` | Indents each line by `width` spaces. |
| `int` | `default`, `base` | Converts to an integer; `default` when the value is not a number. |
| `join` | `separator`, `attribute` | Joins an array into one string. The filter most templates need. |
| `last` | — | Last item of an array. |
| `length` | — | Item count of an array or string. |
| `list` | — | Converts the value to an array. |
| `lower` | — | Lower-cases the value. |
| `map` | `attribute`, or a filter name | Picks one attribute from each item, or applies a filter to each item. |
| `pprint` | `verbose` | Pretty-prints the value for debugging. |
| `prepend` | `string` | Puts the string before the value. |
| `random` | — | One random item of an array. |
| `reject` | — | Keeps the items a test rejects. |
| `rejectattr` | — | Keeps the items whose attribute a test rejects. |
| `replace` | `old`, `new`, `count` | Replaces occurrences of `old` with `new`. |
| `reverse` | — | Reverses an array or string. |
| `round` | `precision`, `method`, `base` | Rounds a number to `precision` digits. |
| `safe` | — | Marks the value safe from escaping. |
| `select` | — | Keeps the items a test accepts. |
| `selectattr` | — | Keeps the items whose attribute a test accepts. |
| `slice` | `slices`, `fill_with` | Slices an array into `slices` roughly even parts. |
| `sort` | `reverse`, `case_sensitive`, `attribute` | Sorts an array, optionally by an attribute. |
| `string` | — | Converts any value to its string form. Useful before `upper` or `length` on a non-string value. |
| `striptags` | — | Removes HTML tags and collapses whitespace. |
| `sum` | `attribute`, `start` | Sums the items, or their `attribute`. |
| `title` | — | Title-cases each word. |
| `tojson` | `indent` | Serialises the value as JSON. |
| `trim` | — | Strips whitespace from both ends. |
| `truncate` | `length`, `killwords`, `end`, `leeway` | Cuts the string to `length` and appends `end`. |
| `upper` | — | Upper-cases the value. |
| `urlencode` | — | URL-encodes the value. |
| `urlize` | `trim_url_limit`, `nofollow`, `target`, `rel` | Turns URLs in text into links. |
| `wordcount` | — | Counts the words. |
| `wordwrap` | `width`, `break_long_words`, `wrapstring` | Wraps text at `width` characters. |
| `xmlattr` | `autoescape` | Serialises a dictionary as HTML attributes. |

A missing or unknown filter raises an error at render time. The write
that triggered the render is rejected.

## Context variables — calendar title template

The calendar `title_template` renders in the browser against a smaller
rule set:

| Name | Content |
| --- | --- |
| `<field_name>` | A declared field of the parent doctype. |
| `content` | The raw document content tree, through the `content.` prefix. |
| `created_at`, `updated_at` | The system timestamps of the document. |

`display_name` is rejected in this template — the chip falls back to it
when no template is set. The browser renderer supports placeholders
only:

- Filters, `{% if %}` blocks, and `{# #}` comments render verbatim, not
  as an error.
- A missing field renders empty.
- A money object renders as `EUR 100`.
- An array renders with the items joined by `, `.

Save-time validation still checks the syntax and every root variable,
so a template that could never render is rejected at authoring time.

## Full example

A `hr.Person` doctype declares the fields `first_name`, `last_name`,
`email`, `tags` (array of string), `salary` (money), and `manager_id`
(reference to `hr.Person`). The definition carries:

```yaml
display_name: "{{ last_name | upper }}, {{ first_name }} — {{ salary }}"
search: "{{ first_name }} {{ last_name }} {{ email }} {{ tags | join(', ') }}"
```

A document stores:

```json
{
  "first_name": "Ada",
  "last_name": "Lovelace",
  "email": "ada@facet.local",
  "tags": ["crm", "vip"],
  "salary": { "value": "120000", "currency": "USD" },
  "manager_id": "hr.Person.01JCATPMKP4N82GVG2J7K4MHZZ"
}
```

The stored label is:

```text
LOVELACE, Ada — USD 120000
```

The stored search text is:

```text
Ada Lovelace ada@facet.local crm, vip
```

The `{{ manager_id }}` variable would print the referenced person's
stored label; the two templates above do not use it.

## Related

- [Display names and search text (Jinja2)](/build/model/views/names-and-search/) — write the two doctype templates.
- [View templates](/build/model/views/document-pages/) — the structured view templates, a separate format.
- [View template schema](/reference/dvt-schema/) — the full variable list a view template binds.
- [Computed fields](/build/model/data/computed-fields/) — Lua functions, not templates.
