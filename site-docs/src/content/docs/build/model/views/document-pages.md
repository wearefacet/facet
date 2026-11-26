---
type: how-to
title: Design document pages
description: Lay out the document page, the form, and the peek panel with view templates.
audience: [author]
features: [DOM-22, FE-04]
sidebar:
  order: 1
verified_at: eee55a2
---

Your users open one document a hundred times a day, and the default layout
shows every field in one long column. A view template is a small layout tree
stored on the doctype. Facet renders it on the show page, the form, and the
peek panel, so a warehouse team sees a status chip and grouped sections
instead of a field list. No code is needed — the template is a JSON tree you
edit in the Builder or in a YAML file.

## When to use this

- The default field list hides the structure of your documents.
- You want a header with a status chip, grouped sections, or a table of
  child rows.
- The form should place fields side by side instead of one long column.

## Before you start

- **Update rights** on the doctype definition.
- **The fields.** Know the field names and types you want to show.
- **The Views tab.** Open the doctype in **Configure** (or the draft in the
  **Builder**), then the **Views** tab. It lists the five kinds with a
  preview, and an **Edit** mode with a JSON editor.

## The five kinds

Each template has a kind. One template per kind:

| Kind | Surface |
| --- | --- |
| `view` | The document show page. |
| `form` | The new and edit forms. |
| `quickView` | The peek panel beside a list. |
| `card` | The card on a kanban board. |
| `inline` | A row inside an editable relation table. |

A new doctype starts with no templates. Every surface then uses a generic
layout that Facet builds from the field list, so a template is optional per
kind. The missing kinds show as info notices in the check report, not as
errors — the generic layout covers them.

## Build the layout from nodes

A template is a tree of nodes. Each node has a `type` and a few properties.
The nodes you use most:

| Node | Purpose |
| --- | --- |
| `section` | A labelled group of rows. |
| `header` | The page header: status chip, chips, subtitle, logo. |
| `field` | One labelled value row. Write the value as `$field_name`. |
| `markdown` | A long text field, rendered as markdown. |
| `grid`, `row`, `col` | Layout containers. A `grid` takes fractions like `3 1`. |
| `tabs` | Tabbed areas; each `tab` holds children. |
| `sidebar` | The right rail of a show page; add `record-meta` inside for provenance. |
| `relation` | A table of child or linked documents, with `columns`. |
| `input` | A form control; it picks the control from the declared field type. |

More node types exist for conditions (`if`), nested data (`object`, `array`,
`dict`), links (`link`, `email`), pictures (`image-artifact`), and forced
controls (`input-text`, `input-money`). The full node grammar with every
required property lives in the [DVT template
schema](/reference/dvt-schema/).

## Save and check

Save the template. Facet validates it against the doctype and refuses a
write that carries a blocking error:

- an `input` bound to an unknown field, to a dotted path, or to a container
  or computed field is an error — the form could never save such a value,
- an `input` bound to a `read_only` field is a warning — the node renders,
  but the value can never be saved,
- an unknown node type, an empty options list, or a duplicate relation column
  is a warning — the node renders but degrades.

Each issue names its place in the tree, for example
`template.children.2.field`. Open the Views tab, walk to that node, and fix
the binding. Run **Check** to see the full report — see [Check before you
publish](/build/model/in-app/check-before-publish/).

## Example

The Brightwater `equipment.Item` doctype carries a `form` template. Its
complete `template` value:

```json
{
  "type": "col",
  "children": [
    { "type": "section", "label": "Item", "children": [
      { "type": "row", "layout": "2fr 1fr", "children": [
        { "type": "input", "field": "name" },
        { "type": "input", "field": "category" }
      ]}
    ]},
    { "type": "section", "label": "Stock", "children": [
      { "type": "row", "layout": "repeat(3, minmax(140px, 1fr))", "children": [
        { "type": "input", "field": "status" },
        { "type": "input", "field": "serial_number" },
        { "type": "input", "field": "purchase_price" }
      ]}
    ]},
    { "type": "section", "label": "Notes", "children": [
      { "type": "input", "field": "notes" }
    ]}
  ]
}
```

The new-item form renders three labelled groups. `name` and its category sit
side by side, the three stock fields share one row, and notes take the full
width. Each `input` picks its control from the declared field type: a
reference picker for `category`, a status select for `status`, a money field
for `purchase_price`.

The same doctype carries a `card` template for the kanban board:

```json
{
  "type": "col",
  "children": [
    { "type": "field", "label": "Status", "value": "$status" },
    { "type": "field", "label": "Serial number", "value": "$serial_number" }
  ]
}
```

Every card on the maintenance board's sibling item lists shows the status
and the serial. Reference values never show as raw ids: a `$field` that
points at another document renders the referenced document's label.

In files, the two templates live at
`views/equipment.Item/document_views/form.yml` and `.../card.yml` inside the
domain folder — see [The domain file layout](/build/model/in-files/domain-files/).

## Troubleshooting

**A field row shows nothing.**

The `$field_name` in the template does not match a stored field. Check the
spelling against the doctype definition.

**A form control is missing for a field.**

The field is read-only, or its type has no control in that node. Use the
plain `input` node, which picks the control from the declared type.

**The check lists template issues with paths like `template.children.2`.**

Each issue names its place in the tree. Open the Views tab, walk to that
node, and fix the binding or the property.

## Related

- [DVT template schema](/reference/dvt-schema/) — every node type and required property.
- [Lists, boards and calendars](/build/model/views/lists-boards-calendars/) — configure the list pages beside the document pages.
- [How old documents follow a new schema](/build/deeper/documents-and-projections/) — what a document page renders from.
