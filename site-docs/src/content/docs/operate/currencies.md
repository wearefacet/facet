---
title: Currencies and money
description: Manage the currency list and learn how money values are stored, validated, and filtered.
audience: [operator, author]
features: [PLT-14, FE-15]
sidebar:
  order: 14
verified_at: 008dd880
---

A currency is a document. Facet seeds the registry, and you curate it in
the Configure area like any other list. A money field always carries a
value and a ticker together. The backend stores both and checks the
ticker on every write.

## When to use this

Work on currencies when:

- You add or retire a currency in the picker.
- You define a money field on a doctype.
- You filter documents by money amounts.

## Before you start

- The `core` domain is hidden from the workspace sidebar. The Configure
  area is the way in.
- `facet seed:core` seeds the currency rows. The command is idempotent,
  so a re-run changes nothing.

## Steps

### 1. Open the currency list

Open **Configure → Currency**. The list is a standard table with the
usual create and edit routes, `/core/Currency/new` and
`/core/Currency/{id}/edit`. Peek and show render through the seeded view
templates.

### 2. Add or edit a currency

The seed ships the ISO-4217 circulating currencies. Six rows start
active — `CHF`, `CNY`, `EUR`, `GBP`, `JPY`, and `USD` — and every other
row ships inactive. One row holds these fields:

| Field | Meaning | Example |
| --- | --- | --- |
| `ticker` | The registry key. Uppercase, starts with a letter, 3 to 10 characters. Unique. | `EUR` |
| `symbol` | The display glyph. Optional — an empty symbol renders the bare ticker. | `€` |
| `name` | The English currency name. | `Euro` |
| `digits` | Sub-unit digits, 0 to 4. Default `2`. | `2` |
| `active` | Puts the ticker in create flows when `true`. | `true` |
| `favorite` | Pins the row to the top of the currency picker. | `false` |
| `grouping` | Display grouping: `standard` (thousands) or `lakhs` (12,34,567). | `standard` |

Set `active` to `false` to retire a currency without deleting it. An
inactive ticker stays known: documents that hold it keep working.

### 3. Know how the registry propagates

Every currency save fans out and marks the in-memory registry stale on
every running process. The next write on each process rebuilds the
registry from the documents. A restart starts stale and hydrates on the
first write. If a fanout is lost, a staleness bound of
`cache.staleness_ttl_s`, 300 seconds by default, forces a rebuild at the
next read.

### 4. Follow the write rules

A gate checks money values on every write path:

| Path | Rule |
| --- | --- |
| Create | Every money path must name a registered **and active** currency. Nested paths count too. |
| Update | Only changed tickers are checked. Re-saving a path with its existing ticker passes even when the row went inactive. A switch to another ticker needs an active row. |
| Bulk import | The check is skipped. A registered-but-inactive ticker imports. A deleted ticker fails with `UnknownCurrencyError`. |

A violation answers `422` with the code `inactive_currency` on the
`<path>.currency` field. An unknown ticker keeps failing as a schema
error.

### 5. Store and filter money values

One money value is one JSON object:

```json
{ "value": "123.42", "currency": "USD" }
```

`value` is a string. The backend parses it as an exact decimal and never
as a float, so precision survives.

A money filter accepts two forms: `USD 1000` compares that currency
only, and a bare `1000` compares any currency.

## Example

Create a currency with the API, then declare a money field that uses it:

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"ticker":"CRD","symbol":"Cr","name":"House credit","digits":2,"active":true,"favorite":false,"grouping":"standard"}' \
  "https://facet.localhost:3443/Api/core/Currency"
```

The `ticker` field is unique across the doctype, so a ticker that a live
row already holds answers `422` with a `unique` validation error.

The doctype field declaration:

```json
{
  "salary": { "type": "money", "currency": "USD" }
}
```

The field-level `currency` is a display hint and a default: a write that
omits the currency member is backfilled with it. The stored value still
carries its own ticker. Filter the doctype by amount:

```sh
curl -s -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/hr/Employee?filters[salary__gte]=USD%201000"
```

## Troubleshooting

**A save answers `422` with `inactive_currency`.**

The ticker is known but inactive. Activate the currency row, or keep the
document on its existing ticker — a same-ticker re-save passes.

**The picker misses a currency.**

The row is inactive, or the registry has not rebuilt yet. Activate the
row and save a document; the next write rebuilds the registry.

**An import fails on a currency.**

The ticker was deleted, not just deactivated. Re-add the currency row
with the same ticker, then run the import again.

**The config file holds no currency list.**

Currencies do not come from config. They are `core.Currency` documents,
and the registry reads them from the database.

## Related

- [Field types](/build/field-types/) — the `money` field type on a doctype.
- [Bulk import and export](/apps/bulk-import-export/) — the import path that skips the active check.
- [System settings](/operate/system-settings/) — the runtime tier above the config file.
- Internals on GitHub: [util-money.md](https://github.com/wearefacet/facet/blob/main/doc/backend/util-money.md).
