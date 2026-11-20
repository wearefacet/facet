# Frontend Templating

A minimal Jinja2-subset renderer for client-side templates. It renders the calendar view's `config.calendar.title_template` against a document's content, with the same conventions as the backend `Templating` engine (Crinja, `src/templating.cr`) that renders the `display_name` / `search` templates.

## Source files

- `frontend/src/lib/templating.ts` — the `renderTemplate` renderer.
- `frontend/src/lib/templating.spec.ts` — Vitest `server` project tests.
- `frontend/src/lib/calendar/discriminator.ts` — the consumer: `renderCalendarTitle` (see [`calendar.md`](calendar.md)).

## Template rules

| Input | Output |
| ----- | ------ |
| `{{ path }}` | The value at `path`; dotted paths walk nested objects. |
| `{{ content.path }}` | Same walk, expressed against the raw document tree (mirrors the backend's reserved `content` variable). |
| Missing field / nested miss | Empty string — an absent optional field is a normal state, never an error. |
| Money object (`{value, currency}`, both strings) | `"<currency> <value>"` — the same shape-based formatting the backend applies. |
| Plain object (not money) | Empty string — a walkable node printed as a leaf renders empty. |
| Array | Elements joined with `", "`. |
| Plain text | Verbatim. |
| Unsupported Jinja (filters, `{% %}`, `{# #}`) | Verbatim — unmatched syntax surfaces in the output instead of failing silently. |

## Example

```ts
renderTemplate('{{ name }} — {{ amount }}', {
	name: 'Floor resurfacing',
	amount: { value: '9.5', currency: 'USD' }
});
// → "Floor resurfacing — USD 9.5"
```

The view editor's helper copy points authors at the `{{ field }}` form (`list_editor_title_template_helper`); when a calendar view stores no template, its chips default to the document's `display_name`.

The backend validates an authored template at view-save time against the parent doctype — compile check plus root-variable allow-list (`Doctype::CollectionView::TitleTemplate`, see [`../backend/collection-view.md`](../backend/collection-view.md) → Title template validation). The renderer stays tolerant at render time: unknown fields render empty, never an error.
