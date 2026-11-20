# Document view — header and relation table

The document-view template renderer turns a `core.DocumentView` template tree into the body of a document show page. `DocumentViewTemplate.svelte` dispatches each node to its component. This doc covers the header surface, the relation table surface, and the fallback form's field list, plus the two rules the view surfaces share: reference-label rendering and malformed-column normalization.

## Source files

| File | Purpose |
|---|---|
| `frontend/src/lib/components/features/document-view/DvtHeader.svelte` | Show-page header: title, status chip, chips, subtitle, logo avatar |
| `frontend/src/lib/components/features/document-view/DvtHeader.stories.svelte` | Stories; the play functions are the component tests |
| `frontend/src/lib/components/features/document-view/DvtRelationTable.svelte` | `view: 'table'` relation renderer: column boundary, hydration pass, cells |
| `frontend/src/lib/components/features/document-view/DvtRelationTable.stories.svelte` | Stories; the play functions are the component tests |
| `frontend/src/lib/components/features/document-view/DvtField.svelte` | The canonical field row (label + value) on every template display surface |
| `frontend/src/lib/components/features/document-view/DvtField.stories.svelte` | Stories; the play functions are the component tests |
| `frontend/src/lib/components/features/document-view/DvtValue.stories.svelte` | Stories for the typed-value fallback: scalar and collection reference capsules, driver-less plain text |
| `frontend/src/lib/components/features/document-view/DocumentForm.svelte` | Document create/edit form; owns the fallback field list |
| `frontend/src/lib/table/Table.svelte` + `Table.stories.svelte` | The schema-aware table's `referenceCell` — one capsule per collection-reference element |
| `frontend/src/lib/template-resolve.ts` | Resolution helpers: `splitInterpolation`, `normalizeRelationColumns`, `leafReferenceColumn` |
| `frontend/src/lib/referenceLabel.ts` | Shared reference-label resolver over the driver |
| `frontend/src/lib/components/primitives/surfaces/documentIdentity.ts` | Pure identity derivations; `displayLabel` is the canonical label rule |

## Reference-label rendering rule

A stored `reference` value is a URN (`crm.Supplier.01HXYZ…`) or a bare id. Surfaces render the target document's label. They never show the raw URN as a final state.

- **Relation table, leaf reference column.** A column whose key is a single field declared as `reference` (`leafReferenceColumn`) renders a `Capsule` in the cell. The Capsule receives the `driver`, the stored value, and the field's declared target doctype. It hydrates its own label — the same component and states as a `$field` reference in `DvtField` and the schema-aware table. A click fires `onreferenceclick` with `{ domain, doctype, id }`. A blank value renders the em-dash blank. Without a `driver`, the cell falls back to the typed-cell path and shows the raw id.
- **Header subtitle, pure reference token.** `subtitle: "$supplier"` with a `reference`-typed field renders one hydrated `Capsule` inline. Click-through uses the header's `onreferenceclick` prop.
- **Header subtitle, mixed string.** `subtitle: "Supplied by $supplier"` resolves each `reference`-typed token to its label inline. Non-reference tokens interpolate as before. The labels come from the shared resolver; while a label loads, the id portion shows (Capsule's provisional behavior).
- **Header chips.** A chip bound to a `reference` field (scalar or collection) renders one neutral chip per stored token. The label comes from the shared resolver over the header's driver; while a label loads, the id portion shows; without a driver the stored token shows. Other non-string values route through the shared typed-text pipeline (`resolveInterpolated`): money renders `<currency> <value>`, a secret marker drops the chip, and any other object or array renders as JSON.
- **Typed-value fallback rows.** The show page and the peek drawer render one row per stored field when the doctype has no view template. Those rows go through `DvtValue`; with a `driver`, a `reference` field renders hydrated `Capsule`s (click-through wired to the surface's reference handler) instead of raw `domain.Type.id` tokens (B-132). A single value renders one capsule. A collection reference (a JSON array value) renders one capsule per token — `DvtValue` passes the same `referenceCell` snippet to `FieldValue` that the table passes (F10-F). Driver-less callers keep the plain-text rendering — the tokens joined with `', '`.
- **Schema-aware table cells.** The table's default cell renderer shares `FieldValue` and passes a `referenceCell` snippet, so a collection reference renders one `Capsule` per array element — each hydrates its own label through the shared show cache. A cell that joined the array into one comma-joined id fetched `/Api/<domain>/<Doctype>/<token,token>` and 404'd (the capsule's failed state) on every element; `FieldValue` now splits array values into tokens (`referenceTokens` in `cellKind.ts`) and renders one cell per token. An empty array renders the blank dash. The document-view surfaces hydrate collections the same way — `DvtValue` owns the same reference-cell snippet.
- **Degradation.** The declared types come from the doctype definition (`def` prop). Without a definition or a driver, the subtitle interpolates plainly — the stored value shows. A dotted token (`$contact.name`) never hydrates as a reference; it interpolates.

### The shared resolver (`referenceLabel.ts`)

| Export | Contract |
|---|---|
| `referenceParts(value, qualifiedDoctype?)` | Splits a reference value into `{ domain, doctype, id }`. A qualified value parses on its own; a bare id pairs with the declared doctype. Returns `null` when neither source names a doctype. |
| `referenceLabel(driver, refId, qualifiedDoctype?)` | Resolves the display label of one referenced document. The promise never rejects. |

The label rule mirrors `Capsule`: the backend-computed `meta.display_name` first, then the conventional content fields, then the id. The rule lives in `displayLabel` (`documentIdentity.ts`), and the resolver reuses it. A `410` tombstone resolves to the surviving label from the error body. A failed fetch resolves to the stored value and drops the cache entry, so the next render retries.

The cache is a `WeakMap` keyed by driver. One driver instance exists per page load, so the cache is per-page: one fetch per distinct referenced document per page. Concurrent callers share one in-flight promise. The REST driver's `show()` also dedupes and TTL-caches by URL (`documentShowCache`), so repeated capsules for the same document cost one network fetch.

## Malformed relation columns

The write doors refuse malformed relation columns at authoring time: `Document::Create` and `Document::Update` run the `Document::ViewTemplateGate` on every `core.DocumentView` write — the same `ViewTemplateValidator` pass the assistant tools run. Bare-string columns, keyless columns, and duplicate keys are the shapes the gate names. `:error` issues answer 422 with the issue list; `:warning` issues stay non-blocking (the assistant door reports them, `Doctype::Check` names them post-hoc, and duplicate keys are warnings). Rows stored before the gate existed can still carry malformed columns. `DvtRelationTable` normalizes the column list once at the render boundary with `normalizeRelationColumns`:

- A bare string column coerces to `{ key, label: humanized(key) }`.
- A column without a non-empty string `key` is dropped.
- Duplicate keys collapse to the first occurrence, so the each-block keys stay unique.

Every reader consumes the normalized list — headers, cells, hydration targets, and the toggle check. A malformed template then degrades to a working table instead of a render crash.

## Field visibility (B-176)

The backend read mask omits a tag-invisible field's key from `content` — there is no placeholder on the wire. Both display surfaces align on the client-side `fieldVisible` check (`permissions.svelte.ts`, the `visible_tags` rule):

- **Fallback form.** `DocumentForm.svelte` filters the field list — a masked field renders no input and no affordance (the write guard would refuse it with 403).
- **Template display path.** `DvtField.svelte` applies the same check: a field row bound to a masked field renders nothing at all — no label, no muted dash. Kanban card bodies ride the same component through `DocumentViewTemplate`. Without a definition on the props (or for interpolated values), the row renders as before; the check needs the field's declared tags.

No value leaks on either surface — the mask strips the value server-side; the client filter only removes the empty affordance.

## Fallback form field list

When the resolved `kind: form` view carries no template, `DocumentForm.svelte` renders the fallback form: one input per declared field that is editable. Four filters build the list — the form skips computed fields (`type: 'data'`), `read_only` fields, `replicate` fields, and tag-invisible fields (B-176: the RBAC `visible_tags` mask). The rule has no per-field opt-out; a `kind: form` view with a template is the way to control the list.

## Testing

The stories run as tests in the Storybook vitest project (`pnpm vitest run --project storybook <file>`).

- `DvtRelationTable.stories.svelte` covers a stored string-column template (humanized headers, rendered rows) and a reference column (hydrated Capsule label, click-through, em-dash blank, a dotted column beside it).
- `DvtHeader.stories.svelte` covers the pure-reference subtitle (Capsule + click-through), the mixed string (inline label), the no-driver fallback (plain interpolation), and the chips: a scalar reference chip and a collection reference chip (hydrated labels, no URN tokens), plus a money chip (`EUR 12.50`, no `[object Object]`).
- `DvtValue.stories.svelte` covers the scalar reference capsule (B-132), the no-driver fallbacks (scalar and collection keep plain text), and the collection-reference capsules (one hydrated capsule per stored token).
- `DvtField.stories.svelte` covers the tag-mask alignment (F10-05): with `visible_tags` narrowed, the masked field renders no row (no label, no dash) while the visible field beside it renders as usual; with the field's tag held, the tagged field renders as usual.
- `Table.stories.svelte` covers the schema-aware collection-reference cell: one Capsule per element (the pre-fix comma-joined id fetched `/Api/<domain>/<Doctype>/<token,token>` and 404'd), plus the empty-array blank dash.
