# Table view renders array fields as raw JSON text

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H080QE8833XMJG1CV9W45HAE` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | frontend (table cells, shared value renderer) |
| Verdict | Confirmed. Fix is small and localized |

## Summary

In table views, an array-typed field (for example `quality-assurance.Issue`
`tags`) renders as a JSON-ish dump — `["iam","grants","ui"]` — instead of a
list of capsules. The gap sits in the shared typed-value renderer, so every
surface without an explicit template node shows the same dump.

## Evidence

- `frontend/src/lib/components/primitives/data/cellKind.ts` L46-50 — the
  type→kind map sends arrays to text:
  ```ts
  object: 'text',
  array: 'text',
  dictionary: 'text',
  ```
  The only special case (L76) is arrays of references → `reference`.
- `cellKind.ts` L116-120 — `plainTextValue` stringifies arrays:
  `return JSON.stringify(value);` (L118). This produces the reported dump.
- `FieldValue.svelte` L145, L172-177 — the `text` branch renders
  `plainTextValue(value)`. The table passes no fallback (`Table.svelte`
  L654-660), and `defaultCell` (L651-710) has no array snippet.
- The chip language exists elsewhere, so the report's expectation matches the
  design system: reference-item arrays already render as capsule lists in
  tables (`cellKind` L76 → `FieldValue` L183-186 → `Table.svelte` L661-668);
  record pages render primitive arrays as chips through template `array` nodes
  (`DvtArray.svelte`; seed example `data/seeds/core.DocumentView/documents.yml`
  L256-264). `QuickViewHost.svelte` L512-516 documents the fallback:
  "Objects and arrays fall back to JSON text."
- In-repo instance of the same field shape: `data/fixtures/hr.facet-domain/
  doctypes/hr.Candidate.yml` L7-12 (`tags`: array of string).

## Root cause

`cellKind` maps `array` → `text`, and `plainTextValue` JSON-stringifies
arrays. No array kind exists in the shared renderer.

## Fix direction

1. `cellKind.ts` — map arrays with primitive `items` (`string` / `integer` /
   `enum`) to a new `'array'` kind. Keep object-item and definition-less
   arrays on `'text'` to avoid regressions.
2. `FieldValue.svelte` — add an `array` branch: one chip per item with a `+N`
   overflow chip. `Tag.svelte` and `Chip.svelte` exist as building blocks
   (currently story-only). Blank `[]` already renders the dash
   (`isBlankValue` L100-106).
3. `DvtValue.svelte` forwards to `FieldValue` (L78-85), so record pages inherit
   the fix. No backend change and no data change.
