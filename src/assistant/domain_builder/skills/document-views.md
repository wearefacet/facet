---
title: Document Views
description: core.DocumentView children, parent_doctype, kind enum, template node vocabulary, kind-based discovery, fixture-derived patterns.
tags: [ui, views, documentview]
---

# Document Views

A `core.DocumentView` is a template document attached to a doctype. Views drive the UI surfaces (table, form, card) the frontend renders for a doctype.

## Structure

`core.DocumentView` is a child of `core.DocType`. Its `parent_doctype` field references the qualified doctype id (e.g. `hr.Employee`). Storage identity: `domain="core", doc_type="DocumentView"`.

| Field | Type | Required | Description |
|---|---|---|---|
| `parent_doctype` | string | yes | Qualified doctype id (e.g. `hr.Employee`). |
| `kind` | enum | yes | One of: `view`, `form`, `inline`, `card`, `quickView`. |
| `template` | object | no | Free-form template payload. The frontend interprets it. |

## `kind` values

| Kind | When it's used |
|---|---|---|
| `view` | The default table/list surface for a doctype. |
| `form` | The create/edit form. |
| `inline` | Compact one-line row rendered inside a parent's `relation` box — for child doctypes and any doctype shown as a relation row. Falls back to `quickView` when absent. |
| `card` | Compact card in chat and on kanban boards. Falls back to the identity body (display name + updated time) when absent. |
| `quickView` | Peek-drawer summary view. Doubles as the `inline` fallback when no dedicated `inline` view exists. |

## Creating views

Use the `create_document_view` tool: pass `parent_doctype`, `kind`, and an optional `template`. The tool enforces that the parent doctype is in the draft domain and validates the template tree — structural errors are rejected with a `details` array naming the bad node path; fix the template and retry. Warnings are returned in the success payload.

`update_document_view` takes a `doc_id` plus optional `kind`/`template` — pass only the fields you want to change.

`delete_document_view` soft-deletes the view.

Only one view per `(doctype, kind)` — the `core.DocumentView` create script rejects duplicate kinds per doctype.

After the views are in, run `check_doctype`: it validates every view template and warns when a standard view kind (`view`, `form`, `quickView`, `inline`, `card`) is not defined.

## The fixture convention: five views for every doctype

Every fixture doctype ships a baseline of five views (`data/fixtures/{domain}.facet-domain/views/{qualified}/document_views/{kind}.yml`):

- `kind: view` — the full show page: a `tabs` tree with one tab per concern (identity, employment, relations), a header grid, and the fields.
- `kind: quickView` — the narrow sidebar surface: a flat `col` with identifying fields only.
- `kind: form` — the create/edit form: a `col` of `input-*` nodes, one per editable field.
- `kind: inline` — a compact one-line row rendered by a parent's `relation` box. Use `grid` with an `auto`-heavy layout (e.g. `"auto auto 1fr auto"`) so labels and capsules line up horizontally; keep it to three or four nodes. Do NOT include `<row>`-style or `<text>`-with-`weight` props — those node types do not exist. Use `label` for plain inline text and `capsule` for pill badges.
- `kind: card` — a compact `col` for chat cards and kanban boards: two or three identifying `field` rows, no deep nesting. Falls back to the identity body when absent.

The backend assigns runtime ids (ULIDs) at create and import — you never choose the id. The frontend discovers the views through `meta.parent_id` (the children endpoint) and matches them by their `kind` field, never by id. So `meta.parent_id` and a correct `kind` are the fields that matter.

## Template node vocabulary

A template is a tree of typed nodes. The display nodes (from `doc/frontend/workflow.md` → Document View Template):

| Type | Shape | Renders |
|---|---|---|
| `label` | `{type: "label", value: string}` | Resolved text |
| `field` | `{type: "field", label, value, children?}` | Labeled row with resolved value or child content. A `longtext` value renders as raw text here — bind a longtext through the auto `input` or a `markdown` node instead. |
| `tabs` | `{type: "tabs", tabs: [{type: "tab", label, children}]}` | Tab navigation |
| `object` | `{type: "object", field, children}` | Scopes children to a nested document field |
| `if` | `{type: "if", field, value?, children, else?}` | Conditional by field truthiness or equality |
| `array` | `{type: "array", field, children, layout?}` | Iterates an array field. `layout: "inline"` (default) flows primitive items in one wrapping row — the pill-list pattern with `capsule` children; `layout: "stack"` renders one bordered block per item. Object items always render as cards. |
| `dict` | `{type: "dict", field, children}` | Iterates an object's entries |
| `grid` | `{type: "grid", layout: "1 3", children}` | CSS grid with proportional columns |
| `col` | `{type: "col", children}` | Vertical column |
| `image` | `{type: "image", src, alt?, variant?}` | `<img>` from an interpolated URL. Renders nothing when the resolved `src` is empty. `src` must be a URL-bearing value (`url` field or static URL) — never a `file` field. |
| `image-artifact` | `{type: "image-artifact", field, alt?, variant?: "avatar"\|"thumbnail", size?}` | `<img>` miniature for a `file`-typed field: resolves the stored artifact id to a grant URL on mount. Muted `—` when the field is empty; a placeholder when the grant fetch fails. The correct node for pictures. |
| `markdown` | `{type: "markdown", field}` | Readonly markdown document for a `longtext` field — renders the stored markdown as prose. Renders nothing when the field is empty. The label-less variant; the auto `input` renders the same preview labeled and boxed in display context. |
| `link` | `{type: "link", href, label}` | `<a>` from an interpolated URL. Renders nothing when the resolved `href` is empty. `href` must be a URL-bearing value (`url` field or static URL) — never a `file` field. |
| `email` | `{type: "email", href, label}` | Email capsule with copy-to-clipboard |
| `title` | `{type: "title", value, level?}` | Heading (h1–h6, default h2) |
| `capsule` | `{type: "capsule", value}` | Pill badge |
| `hr` | `{type: "hr"}` | Horizontal rule |
| `relation` | `{type: "relation", label, doctype, referenceField?, source, view?, editable?, limit?, columns?}` | Linked child/related documents. `view: "inline"` renders the child's `inline` (or `quickView` fallback) template per row; `editable: true` renders the child's `form` per row and exposes Add/Remove. Only `children` sources support `editable: true` (filter-bound relations are read-only). `view: "table"` renders one column per `columns` entry (`{key, label, width?, editable?}`); a column marked `editable: true` toggles its boolean cell in place when the viewer may update the relation doctype — single-segment keys only (dotted keys resolve their leaf on the referenced document and stay read-only). |

The form uses `input` and `input-*` nodes. **Every input node requires `field`** (the document field key it binds to); on the auto `input` node `label` is optional — it derives from the field's `title`, then the humanized key. The `create_document_view` and `update_document_view` tools validate the template tree — structurally (a malformed node such as an input without `field`, a container without `children`, or an unknown type is rejected with a `details` array naming the node path) and against the parent doctype definition (unknown field bindings, dotted paths, container/computed bindings, and read-only bindings are flagged; input/type mismatches are reported as warnings).

**Prefer `input` for every editable field.** One node — `{type: "input", field}` — renders the correct control from the field's declared type: the select options come from the enum's `values`, the reference target from the field's `doctype`, the required flag from the field's `required`, and url/phone/integer fields get their keyboards automatically. Do not hand-copy props the definition already knows.

Use a specialized `input-*` node only to **force** a control the definition cannot express — an email keyboard on a string field (`inputType: email`), a url prefix, a specific picker. Deliberate overrides still get affinity-checked: a specialized node bound to a field type outside its set is reported as a warning that names the control `input` would have rendered.

**Binding rules (validated):**

- `field` must be a **bare key in the current resolution scope** — never a dotted path. At the root of the template the scope is the doctype's fields; inside an `object` wrapper it is that object's sub-fields; inside an `array` wrapper it is the item schema's fields. To edit a nested object field, wrap an `object` node around it and bind the bare sub-field name — never `input` with `field: "config.enabled"`.
- The auto `input` node **never binds** an `array` / `object` / `dictionary` / `data` field (the payload can never validate) — that binding is rejected as an error. Use `input-list` for array-of-string fields, and `object` / `array` wrappers for nested and object-item editing. `data` fields are computed and read-only.
- A specialized input bound to a field type outside its affinity set is reported as a warning on the tool payload (see the table).

| Type | Extra properties | Renders for |
|---|---|---|
| `input` | `label?` (derives), `placeholder?`, `helper?`, `required?` (derives) | The correct control for the field's declared type — prefer this node |
| `input-text` | `inputType` (`date`, `number`, `email`, `tel`, `url`, `password`), `placeholder`, `required`, `helper`, `prefix` | Override: forces a text control (e.g. an email keyboard on a string field) |
| `input-datetime` | `required`, `helper` | Override: forces the datetime picker |
| `input-period` | `required`, `helper` | Override: forces the period pair (`period` fields: a `{start, end}` pair of UTC datetimes; start strictly before end) |
| `input-dateperiod` | `required`, `helper` | Override: forces the date-period pair (`dateperiod` fields: a `{start, end}` pair of `YYYY-MM-DD` calendar dates; inclusive both ends, start may equal end) |
| `input-date` | `required`, `helper` | Override: forces the date picker (`date` fields, `YYYY-MM-DD`; never `input-datetime`, which commits a full timestamp the backend rejects) |
| `input-select` | `options` (required, array of `{value, label}`), `placeholder`, `required` | Override: forces a dropdown with hand-picked options |
| `input-toggle` | — | Override: forces the on/off switch |
| `input-longtext` | `placeholder` | Override: forces the markdown textarea |
| `input-reference` | `doctype` (locks the target), `doctypes`, `placeholder`, `required`, `helper` | Override: forces the reference picker |
| `input-money` | `placeholder`, `required`, `helper` | Override: forces the money pair |
| `input-color` | `placeholder`, `required`, `helper` | Override: forces the color picker |
| `input-file` | `placeholder`, `required` | Override: forces the uploader |
| `input-secret` | `placeholder`, `required`, `helper` | Override: forces the stage-and-store control |
| `input-list` | `placeholder`, `required`, `helper` | The one container input: `array` fields whose items are strings |

What the auto `input` renders per declared field type: `string`/`any` → text; `integer`/`duration` → number; `url` → url; `phone` → tel; `enum` → select (options from `values`); `boolean` → toggle; `date` → date picker; `datetime` → datetime picker; `period` → period pair; `dateperiod` → date-period pair; `longtext` → markdown textarea; `money` → money pair; `color` → color picker; `file` → uploader; `secret` → stage-and-store; `reference`/`child` → reference picker (target from the def). A binding the definition cannot resolve (unknown field, dotted path) or a container/computed binding is rejected at authoring time; at render time a missing definition degrades to a text control. Array fields of objects edit through the `array` wrapper with per-item `input-*` children. A node type the frontend does not know renders nothing.

## File fields — download capsules and pictures, never URLs

A `file` field stores an **artifact id** (a ULID), not a URL. Interpolating one into `link.href` or `image.src` yields the bare id, so the link or image is broken whether the field is set or empty — the view tools warn on this. Two display paths exist:

- **Download link** (PDF, 3D model, any file): a plain `field` row with the file field as `value`. The typed renderer shows a filename capsule that downloads through the artifact gateway, and `—` when empty:

  ```yaml
  - type: "field"
    label: "Guide d'utilisation"
    value: "$user_guide"
  ```

- **Picture** (a `file` field with `accept: image/*`): an `image-artifact` child bound to the bare field key. It resolves the id to a grant URL and renders a thumbnail; empty renders `—`:

  ```yaml
  - type: "field"
    label: "Photo"
    value: "$picture"
    children:
      - type: "image-artifact"
        field: "picture"
        alt: "Photo de la machine"
  ```

`link.href` and `image.src` take URL-bearing values only: a `url` field, or a static URL with `$url_field` interpolation (e.g. `"https://example.com/docs/$slug"`).

## Scalar arrays — the pill-list pattern

An `array` node over an **array-of-strings** field binds each item through the single token `$value`. The other scope tokens (`$item`, `$this`, `$self`, `$index`) do **not** bind inside an array — a label that shows one is unbound and renders empty.

Combined with the default inline layout, this is the pill-list pattern — one capsule per item, flowing on one line:

```yaml
- type: "array"
  field: "part_numbers"
  children:
    - type: "capsule"
      value: "p. $value"
```

Rules:

- `layout: "inline"` (default) renders primitive items in one wrapping row. `layout: "stack"` renders one bordered block per item — use it when a per-item box is wanted.
- Inline flow suits `capsule` and `label` children. Block-level children (e.g. `field` rows) break the flow — use `layout: "stack"` for those.
- An `array` over **objects** keeps the card rendering in both layouts (a structured item cannot inline), and the children resolve against the item's sub-fields as bare keys (e.g. an item `{name, level}` binds `$name`, `$level`).

## Value resolution

Template values prefixed with `$` resolve against `document.data`:

- `"$field_name"` → `document.data["field_name"]`
- `"$parent.child"` → dot-path traversal of `document.data`
- `"$title - $value"` → mixed literal/token interpolation (see `crm.Deal` capsules)
- Plain text → rendered as-is
- Missing or unknown tokens → empty text: `label`, `capsule`, and `title` render nothing; typed `field` rows render the muted `—` empty mark. (So a label showing a literal `$token` means the token itself is wrong, not the data.)

## The header pattern

The fixture `view` templates share a header layout — a `grid` with layout `"1 3"` containing two columns:

```yaml
- type: "grid"
  layout: "1 3"
  children:
    - type: "col"
      children:
        - type: "title"
          value: "$full_name"
          level: 1
    - type: "col"
      children:
        - type: "capsule"
          value: "$status"
        - type: "capsule"
          value: "$job_title"
        - type: "hr"
        - type: "field"
          label: "Department"
          value: "$department"
```

## Nesting and conditionals

- `field` accepts `children` for a richer rendering of one value — e.g. the email pattern used by `hr.Candidate` and `crm.Contact`:

  ```yaml
  - type: "field"
    label: "Email"
    value: "$email"
    children:
      - type: "email"
        href: "$email"
        label: "$email"
  ```

- `object` scopes its children to a nested field — sub-field values resolve with bare names (`$street` inside an `address` object block), see `hr.Candidate` → Address tab. In a **form** template, input nodes inside the wrapper bind the bare sub-field names the same way (`enabled` inside a `config` wrapper).
- `if` renders conditionally on a field's equality (`crm.PipelineStage` → Behavior tab):

  ```yaml
  - type: "if"
    field: "status"
    value: "active"
    children:
      - type: "label"
        value: "✅ Active — in good standing"
    else:
      - type: "label"
        value: "⛔ Not active"
  ```

- `relation` embeds related documents — `crm.Company` shows its `memberships` children; `crm.Contact` shows its companies by inverse filter:

  ```yaml
  - type: "relation"
    label: "Memberships"
    doctype: "crm.CompanyMembership"
    referenceField: "contact"
    source:
      kind: "children"
      rel: "memberships"
    view: "capsule"
    limit: 25
  ```

## Composite views (parent + editable children)

A composite doctype declares `children:`. Its `view` and `form` kinds embed
`relation` nodes so the parent and its children display/edit as one object.

**Show page (`view` kind)** — one tab per child collection, each holding a
`relation` with `view: "inline"`:

```yaml
- type: "tab"
  label: "Experience"
  children:
    - type: "relation"
      label: "Work Experience"
      doctype: "hr.CandidateExperience"
      source: { kind: "children", rel: "experiences" }
      view: "inline"
      limit: 25
```

**Edit form (`form` kind)** — same `relation`, but with `editable: true`. The
parent form renders an inline editor per child row and exposes Add/Remove.
On save, `DocumentForm` strips the synthetic `__relation_drafts__` key from
the parent patch, saves the parent first, then issues per-child create /
update / delete calls against `doc(parentId).children(rel)`.

```yaml
- type: "relation"
  label: "Work Experience"
  doctype: "hr.CandidateExperience"
  source: { kind: "children", rel: "experiences" }
  editable: true
  limit: 25
```

Rules:

- The relation's `rel` MUST match a `children:` key on the parent's doctype definition.
- The child doctype MUST ship an `inline` view kind (otherwise the read-side falls back to `quickView`).
- The child doctype MUST ship a `form` view kind (otherwise the editable rows render a fallback code dump).
- Child persistence is **non-transactional**: each child mutation is a separate HTTP call. Partial failures surface as per-relation errors on the parent form.
- `editable: true` implies `view: "inline"` (capsule rows are read-only). Do not set both.

## How views attach to doctypes

The `parent_id` meta field on the DocumentView projection points at the parent doctype's id (not the parent document id). Cascade delete applies: deleting a doctype also deletes its DocumentView children. On publish, views are copied with the doctype and their `parent_doctype`/`parent_id` are rewritten to the target domain.
