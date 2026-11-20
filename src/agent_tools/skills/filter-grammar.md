---
title: Filter Grammar
description: The field__op filter grammar for list_documents and aggregate_documents — operators per field type, special keys, sorting, paging, caps.
tags: [filters, list]
surfaces: [workspace, mcp]
---

# Filter Grammar

`list_documents` and `aggregate_documents` share one filter grammar. A
filter key is `{field}` (equality) or `{field}__{op}`. Values are plain
JSON values. Unknown filter fields are rejected with an error; a filter
that names no rows simply returns an empty result.

## Operators

| Suffix | Meaning | Notes |
|---|---|---|
| (none) or `__eq` | equal | every field |
| `__ne` | not equal | every field |
| `__match` | contains the substring | case-insensitive; `%` and `_` in the value never act as wildcards |
| `__starts_with` | starts with the prefix | case-insensitive |
| `__gt` `__gte` `__lt` `__lte` | ordered comparison | number, money, date, datetime, duration fields |
| `__between` | inclusive range | value is a two-element array `[lo, hi]` |
| `__currency` | currency equals | money fields only; the value is a ticker like `"USD"` |
| `__contains` `__overlaps` `__within` | range predicates | `period` and `dateperiod` fields only; `between` is rejected on these fields |

- Comparison values bind by their JSON type: numbers compare as
  numbers, strings as text. Send datetime bounds as UTC RFC-3339
  (for example `2025-06-01T00:00:00Z`) — offsets are accepted and
  converted to UTC before the comparison.
- Money comparisons accept `"USD 1200"` (currency-bound) or `"1200"`
  (any currency). Combine `__currency` to pin the ticker.

## Special keys

| Key | Use |
|---|---|
| `search` | Substring search over the doctype's accent-folded label corpus (case-folded, NFKD, diacritics stripped), so unaccented terms match accented text. Bare key only — `search` is an operator, not a column; `search__match` or any other suffixed form matches nothing. `{"search": "annual report"}` |
| `id` | Equality on the document id |
| `created_at` `updated_at` | System timestamps; comparison operators apply |

## Sorting and paging

- `sort` is an array of field names; a `-` prefix makes one descending,
  for example `["-updated_at", "name"]`. System timestamps may sort.
- `page` starts at 1; `items` is the page size. The service clamps
  `items` to the platform's result cap, so a page never grows past it.
- The list payload is `{data, meta}`; `meta.total` is the matching row
  count and `meta.truncated` with `meta.next_cursor` marks a payload cut
  by the response-size cap — page on instead of retrying.

## Scope

The results already respect the user's access. You never add a row
filter for permission reasons — if the count looks small, it is the
user's scope, not a bug.
