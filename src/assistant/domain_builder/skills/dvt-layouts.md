---
title: Document View Template Layouts
description: How to craft a document view template that looks good — the layout patterns for view, form, quickView, inline, and card surfaces, plus the cross-cutting layout rules.
tags: [ui, views, layout, documentview]
---

# DVT Layouts

This skill teaches how to **structure** a document view template so it looks good. It does not list the node types (that is `read_skill("document-views")`). It teaches which node to use where and how to arrange them for a clean, intentional layout.

You are authoring inside a **draft domain** — you do not know any fixture doctypes by name. Design from the doctype definition you are given (field types, enum values, `children`, references) and apply the layout rules below. Do not assume fixture names. Illustrative doctype/field names here are placeholders to show shape, not fixtures to copy.

## Golden rule: sections declare, tabs derive

- **Use `section` nodes for field groups.** A small doctype does not inherit the navigation cost of `tabs`.
- **Use `tabs` only when the page is crowded** — many sections, or `relation` lists that would dominate the page.
- A `relation` always gets its own tab region (a list of other records, not a field of this record).

## The five surfaces

| Surface | When it is used |
|---|---|
| `view` | Full show page. Header, then sections or tabs. Relations live here. |
| `form` | Edit/create. `section` + `row` grouping of `input-*` nodes, one per editable field. |
| `quickView` | Narrow peek drawer. Flat `col` of the identifying fields only. Never deep-nest. |
| `inline` | One-line row for a parent's `relation` box — child doctypes and any doctype shown as a relation row; three or four nodes on an `auto`-heavy row. |
| `card` | Compact card in chat and on kanban boards; a short `col` of identifying fields. |

## The `view` (show) page pattern

Structure, top to bottom:

1. `header` — the identity chrome.
2. A `grid` `layout: "3 1"` with a main `col` of `section`s and a `sidebar` (owner, `record-meta`).
3. A `tabs` block — one `tab` per child/relation.

```yaml
template:
  type: col
  children:
  - type: header
    chips: [category_a, category_b]  # neutral categorical, plural, non-color
    subtitle: $domain_note
    statusField: status              # the ONLY colored chip (an enum state machine)
    logo: logo                       # file-typed field -> avatar
  - type: grid
    layout: 3 1
    children:
    - type: col
      children:
      - type: section
        label: Classification
        children:
          # labeled rows — the value resolves via $path
        - type: field
          label: Domain
          value: $domain_note
        - type: field
          label: Revenue
          value: $annual_revenue
      - type: section
        label: Contact
        children: { ... }            # more labeled rows, one per field
      - type: section
        label: Location
        children:
        - type: object             # nested object -> scope a new tree of fields
          field: address
          children:
          - type: field
            label: Street
            value: $street        # bare names resolve inside the object scope
          - type: field
            label: City
            value: $city
          - type: field
            label: Country
            value: $country
    - type: sidebar
      children:
      - type: section
        label: Owner
        children:
        - type: field
          value: $owner_id       # no label: the section already labels it
      - type: record-meta
        history: true            # sets the provenance block
  - tabs:                          # relation list -> its own tab
    - type: tab
      label: Members
      children:
      - type: relation
        view: table
        label: Members
        doctype: Member          # the child doctype
        referenceField: contact
        source: { rel: members, kind: children }
        limit: 25
        columns:                 # table view: one column per entry
        - key: contact.full_name # dotted path crossing a reference
          label: Name
        - key: role
          label: Role
          width: 130px
  type: col                       # outer col (the template root)
```

### Rules embedded above

- **Objects get a section.** A nested `object` field gets its own `section`; wrap the sub-fields as `field` rows with bare `$path` names.
- **Reference fields render as labeled rows.** `$owner_id` resolves the reference target's label. Reference objects are NOT `relation` nodes.
- **Files and pictures use the typed display paths.** A `file` field renders as a plain `field` row — the typed renderer draws a filename download capsule, `—` when empty. A picture (`accept: image/*`) renders through an `image-artifact` child. Never interpolate a `$file` field into `link.href` or `image.src` — a file field stores an artifact id, not a URL, so the node is broken in both states (the view tools warn on this).
- **Longtext is markdown.** Bind a `longtext` field through the auto `input` node — read-only display renders the stored markdown as a document, never as raw source. The `markdown` node is the label-less variant: the section label carries the name, and an empty field renders nothing.
- **`grid` uses integer fractions.** `"3 1"`. A 2-column grid shares a vertical divider. For widths that track content, use `row`, not `grid`.
- **`record-meta` closes the sidebar.** It reads `document.meta`, renders Created/Updated (relative), and the History link when `history: true`.

## The `form` pattern

Each editable field maps to an auto `input` node — the control follows the field's declared type (enum → select, date → date picker, money → money pair, reference → picker), so the template carries only the binding, the label override, and chrome (`placeholder`/`helper`). Use a specialized `input-*` node only to force a control the definition cannot express. Group with `section`; align with `row`. A `row` layout is a compact `grid-template-columns` value so inputs keep content-true widths. Far columns take a heavier fraction.

```yaml
template:
  type: col
  children:
  - type: section
    label: Identity
    children:
    - type: row
      layout: 1fr 240px         # name stretches, fixed-width secondary
      children:
      - type: input
        field: name             # required flag derives from the definition
      - type: input
        field: slug
    - type: input
      field: logo
      placeholder: Drop the logo or click to attach
  - type: section
    label: Classification
    children:
    - type: row
      layout: repeat(3, minmax(160px, 1fr))
      children:
      - type: input             # enum -> select, options derive from values
        field: category_a
      - type: input
        field: category_b
      - type: input
        field: status
  - type: section
    label: Contact
    children:
    - type: row
      layout: minmax(200px, 1fr) minmax(280px, 2fr)
      children:
      - type: input             # phone -> tel keyboard
        field: phone
      - type: input             # url -> url keyboard
        field: website
  - type: section
    label: Account
    children:
    - type: row
      layout: minmax(220px, 1fr) minmax(280px, 2fr)
      children:
      - type: input             # money -> money pair
        field: annual_revenue
      - type: input             # reference -> picker, target derives
        field: owner_id
  - type: relation            # children are edited inline on the parent form
    label: Members
    source: { rel: members, kind: children }
    doctype: Member
    referenceField: contact
    editable: true
    limit: 25
```

Form rules:

- One `input` per editable field; `required: true` is only set to force a marker the definition does not carry.
- **Force with `input-*` overrides**: `input-text` with `inputType: email` forces an email keyboard on a string field; `prefix: https://` adds url chrome. Everything else derives.
- Do not spell out enum `options` — the select derives them from the definition's `values`.
- Nested objects nest inside a `row` using the same `object` shape with `input` children — the sub-fields dispatch from their own declared types.
- A composite doctype ends its form with `relation ... editable: true` for each child collection — the rows edit via the child's `form`, and Add/Remove are exposed. `editable: true` is children-only and implies `view: inline` (do not set both).

## The `quickView` pattern

The peek drawer is **narrow**. Show only the identifying fields: a couple of capsules, separators, and a few `section`s. Then `record-meta`.

```yaml
template:
  type: col
  children:
  - type: row
    layout: "auto auto 1fr"         # capsules seat content width, trailing space
    children:
    - type: capsule
      value: $category_a
    - type: capsule
      value: $category_b
  - type: hr
  - type: section
    label: Classification
    children:
    - type: field
      label: Domain
      value: $domain_entry
    - type: field
      label: Annual Revenue
      value: $annual_revenue
  - type: section
    label: Contact
    children:
    - type: field
      label: Phone
      value: $phone
    - type: field
      label: Website
      value: $website
  - type: section
    label: Ownership
    children:
    - type: field
      label: Owner
      value: $owner_id
  - type: record-meta
```

quickView rules:

- `row ... "auto auto 1fr"` seats capsules on one line; the trailing `1fr` absorbs overflow so they do not wrap oddly.
- Add an `hr` between the capsule header strip and the body sections.
- The same `$path` token resolution applies (bare `$street` inside an `object` `field: address` block).
- `record-meta` at the bottom for provenance.
- Do NOT decode deep structures in a quickView — keep it a summary.

## The `inline` pattern (relation row)

A doctype shown inside a parent `relation ... view: "inline"` ships a compact `inline` kind: a single `row` (or `grid` with an `auto`-heavy layout) of three or four nodes, with `label` for plain text and `capsule` for badges. No `text`/`weight` props exist — use `label`. When no `inline` kind exists, the surface falls back to `quickView`.

```yaml
template:
  type: row
  layout: "auto auto 1fr auto"   # content-width labels, flexible middle, trailing action
  children:
  - type: label
    value: $name
  - type: capsule
    value: $role
  - type: label
    value: $since
```

## The `card` pattern

Cards render in bounded containers (chat document cards, kanban boards). A short `col` of two or three identifying `field` rows — the same fields a quickView leads with, minus the chrome. Blank values render as `—`; never deep-nest. When no `card` kind exists, the surface falls back to the identity body (display name + updated time).

```yaml
template:
  type: col
  children:
  - type: field
    label: Status
    value: $status
  - type: field
    label: Industry
    value: $industry
```

## Promotion & exclusion — do not repeat

Whatever you put in `header.title`, `header.statusField`, or `header.chips` is **excluded from the body** by convention. The renderer does NOT deduplicate. `header.subtitle` is chrome, so its field may still appear as a labeled row.

## Color policy

- `header.statusField` is the **only** chip that receives rgba tint; it is a state machine (enum) and takes the enum's own `values[].color`.
- `header.chips` are always **neutral** (categorical — category, size, never colored).
- A non-status enum field shown as a `field` row in a section may still tint via its enum color (e.g. a task `priority`).
- A `capsule` renders neutral by default; use it for badges, not for status.
- Blank values render as an explicit `—` (em dash), not an empty row.

## Column/sizing rules

- Use a `row` node when columns must size to their content (`"auto 1fr auto"`, `"auto auto auto 1fr"`).
- Use a `grid` node for a true page layout — integer fractions such as `"3 1"` (main + sidebar) or `"1 3"`. A 2-column grid shares a vertical divider.
- Inside a `section`, a `row` lays `input-*` children horizontally. Give the most data-heavy field the larger fraction (`minmax(280px, 2fr)` + `minmax(200px, 1fr)`).

## Checklist

1. Pick the surface: `view` (page), `form` (edit), `quickView` (peek), `inline` (relation row), `card` (compact card).
2. Prefer `section`; use `tabs` only when crowded or for relation lists.
3. Put the identity chrome in `header`; exclude those fields from the body.
4. Objects get their own `section` with a scoped `object` node.
5. References render as `field` rows ($ resolves the label), not children.
6. Composite parents: `view` gets a `relation` tab; `form` gets `relation ... editable: true`.
7. Forms: one `input` per field (the type drives the control), `section` + `row` widths, `input-*` only to force a control.
8. quickView: capsules + `hr` + a few sections + `record-meta`. No deep work.
9. Relation rows: ship an `inline` `row` of a few labels/capsules; cards: a `col` of two or three fields.
10. Files: plain `field` rows (download capsule); pictures: `image-artifact` child. Never `$file` in `link.href` / `image.src`.
11. Longtext: the auto `input` node (read-only markdown in display context); the `markdown` node when the prose should stand label-less under its section.
12. Keep colors neutral except the status field; let blank show `—`.