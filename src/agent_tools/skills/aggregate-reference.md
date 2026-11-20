---
title: Aggregate Reference
description: The aggregate_documents kinds — count, sum, avg, min, max — the money per-currency bag, empty sets, caps, and field-visibility refusals.
tags: [aggregates, list]
surfaces: [workspace, mcp]
---

# Aggregate Reference

`aggregate_documents` computes one aggregate per call. It uses the same
filter grammar as `list_documents` (see `filter-grammar`), and the
result respects the user's access — rows outside the caller's scope do
not contribute.

## Kinds

| `aggregate` | `field` | Returns |
|---|---|---|
| `count` | omit it | `data` is an empty array; `meta.total` is the matching row count |
| `sum` | required | scalar total over a numeric or money field |
| `avg` | required | scalar mean over a numeric or money field |
| `min` | required | smallest value |
| `max` | required | largest value |

- `field` must be one top-level `integer`, `duration`, or `money` field.
  A non-numeric field is rejected with an error.
- The payload for sum/avg/min/max is `{aggregate, field, value, count}`:
  `value` is the aggregate, `count` is the number of contributing rows.

## Money

A money aggregate returns a per-currency bag as `value`, for example
`{"USD": "110.50", "EUR": "99.95"}` — one entry per currency that
contributed. Currencies are never converted or merged. Read the bag to
the user as separate per-currency totals.

## Empty sets and caps

- No matching rows: `value` is `null` (or `count` of 0 for `count`).
- `count` reports the matching row count in `meta.total`, capped like a
  list page — check `meta.more`-style caps before telling the user an
  exact large number.

## Visibility

- Aggregating a field the user's role must not see (a view-hidden
  field) is refused outright — the field stays hidden even though an
  aggregate returns no rows. Do not retry on another numeric field
  "instead"; ask the user what they want to learn.
- The refusal and an unknown-field error are different errors; an
  unknown field names the field, a hidden field does not.
