---
type: how-to
title: View templates
description: Lay out the document page, the form, and the peek panel with view templates.
audience: [author]
features: [DOM-22, FE-04]
sidebar:
  order: 1
verified_at: fd345fe3
---

A doctype decides how its document pages look. A view template is a small layout tree stored on the doctype. Facet renders it on the show page, the form, and the peek panel. Without a template, every surface falls back to a generic layout: one row per field.

## When to use this

- The default field list hides the structure of your documents.
- You want a header with a status chip, grouped sections, or a table of child rows.
- The form should place fields side by side instead of one long column.

## Before you start

- **Update rights** on the doctype definition.
- **The fields.** Know the field names and types you want to show.
- **The Views tab.** Open the doctype in **Configure**, then the **Views** tab. The tab lists the templates of the doctype and shows a preview.

## Steps

### 1. Pick the kind

Each template has a kind. One template per kind:

| Kind | Surface |
| --- | --- |
| `view` | The document show page. |
| `form` | The new and edit forms. |
| `quickView` | The peek panel beside a list. |
| `card` | The card on a kanban board. |
| `inline` | A row inside an editable relation table. |

A new doctype starts with no templates. Every surface then uses the generic layout, so a template is optional per kind.

### 2. Build the layout from nodes

A template is a tree of nodes. Each node has a `type` and a few properties. The nodes you use most:

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

More nodes exist for conditions (`if`), nested data (`object`, `array`, `dict`), links (`link`, `email`), pictures (`image-artifact`), and forced controls (`input-text`, `input-money`).

### 3. Save and check

Save the template. Facet validates it against the doctype: an input bound to an unknown field or a read-only field is an error; a missing `view`, `form`, or `quickView` kind is only a notice, because the generic layout covers it. Run the check to see the report. See [Checking a domain before publish](/build/model/in-app/check-before-publish/).

## Example

A `helpdesk.Ticket` doctype carries fields `title` (string), `status` (enum: open, closed), `priority` (enum), `due_date` (date), `description` (longtext), and `owner_id` (reference). This complete template is the `view` kind of the doctype:

```yaml
content:
  kind: view
  parent_doctype: helpdesk.Ticket
  template:
    type: col
    children:
      - type: header
        statusField: status
        chips:
          - priority
        subtitle: "Owned by $owner_id"
      - type: grid
        layout: 3 1
        children:
          - type: col
            children:
              - type: section
                label: Details
                children:
                  - type: markdown
                    field: description
                  - type: field
                    label: Due date
                    value: $due_date
          - type: sidebar
            children:
              - type: section
                label: Owner
                children:
                  - type: field
                    value: $owner_id
              - type: record-meta
                history: true
meta:
  parent_id: helpdesk.Ticket
```

A document stores:

```json
{
  "title": "Printer stops mid job",
  "status": "open",
  "priority": "high",
  "due_date": "2026-12-01",
  "description": "The queue stops after page two.",
  "owner_id": "iam.Account.01JCATPMKP4N82GVG2J7K4MHZZ"
}
```

The show page then renders: a header with the status chip in the enum's color, the priority beside it, and the subtitle **Owned by** with the referenced account's label; the description as rendered markdown under **Details**, with **Due date** beside it; and an **Owner** rail with the account label and a history link. Reference values never show as raw ids.

## Troubleshooting

**A field row shows nothing.**

The `$field_name` in the template does not match a stored field. Check the spelling against the doctype definition.

**A form control is missing for a field.**

The field type has no editable control in that node, or the field is read-only. Use the plain `input` node, which picks the control from the declared type.

**The check lists template issues with paths like `template.children.2`.**

Each issue names its place in the tree. Open the Views tab, walk to that node, and fix the binding or the property.

## Related

- [Doctype schema reference](/reference/doctype-schema/) — the fields a template binds.
- [Documents, doctypes and projections](/build/deeper/documents-and-projections/) — what a document page renders from.
- [Collection views](/build/model/views/lists-boards-calendars/) — configure the list pages beside the document pages.
