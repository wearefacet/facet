# Util::Money — Currency & Money types

`Facet::Util::Currency` and `Facet::Util::Money` provide a typed foundation for monetary values with currency awareness, arithmetic, and JSON serialization. A money field is always multi-currency at the storage layer — every stored row carries its own ticker.

**Source files:**
- `src/util/money.cr`
- `src/util/money_filter_value.cr`
- `src/currency.cr`
- `src/document/money_currency_check.cr`
- `spec/util/money_spec.cr`
- `spec/util/money_filter_value_spec.cr`

---

## Money

`Money` is a struct that holds a canonical decimal string and a currency ticker. The JSON shape is `{"value":"<amount>","currency":"<ccy>"}`:

```json
{"value": "123.42", "currency": "USD"}
```

`value` is stored as a JSON string (parses as `BigDecimal`, never a JSON float — preserves precision). `currency` is an ISO-4217-style ticker registered in the `Currency` registry, which `Facet::Currency::Registry` builds from the `core.Currency` documents. Validation rejects unknown tickers.

### Construction

```crystal
m = Facet::Util::Money.new("123.42", "USD")
m.value     # => "123.42"
m.currency  # => "USD"
m.amount    # => BigDecimal.new("123.42")
```

`initialize` parses `value` as `BigDecimal` eagerly and verifies the currency is registered. `amount` re-parses the value string (immutable).

### Arithmetic

| Operation | With | Behaviour |
|-----------|------|-----------|
| `+` / `-` | `Money` | Same-currency only; raises `CurrencyMismatchError` if currencies differ |
| `*` | `Number` | Scalar multiplication — returns a new `Money` |
| `/` | `Number` | Scalar division; raises `DivisionByZeroError` on zero |

```crystal
Money.new("100.00", "USD") + Money.new("0.50", "USD")  # => #<Money value="100.50" currency="USD">
```

The result's `value` string is regenerated from the `BigDecimal` arithmetic result — it is not the original input echo.

### Conversion

```crystal
Money.new("123.42", "USD").to_s  # => "123.42 USD"
Money.new("0", "JPY").to_s       # => "0 JPY"
```

### JSON

```crystal
money = Money.from_json(%({"value":"150.00","currency":"EUR"}))
money.to_json  # => "{\"value\":\"150.00\",\"currency\":\"EUR\"}"
```

`from_json` parses the `{value, currency}` object and runs the same validation as `initialize`. Missing keys raise `KeyError`. Unknown currency raises `UnknownCurrencyError`. Non-decimal `value` raises `ArgumentError`. `to_json` always echoes the original `value` string verbatim — it never re-emits `.amount.to_s`.

---

## MoneyFilterValue

Helper struct for parsing the filter value grammar of `money` field filters (`price__gte=USD%201000`). Parses either a currency-prefixed `"<CCY> <amount>"` form or a bare `"<amount>"` form.

```crystal
v = Facet::Util::MoneyFilterValue.parse("USD 1000")
v.currency  # => "USD"
v.amount    # => BigDecimal.new("1000")

v = Facet::Util::MoneyFilterValue.parse("1000")
v.currency  # => nil
v.amount    # => BigDecimal.new("1000")
```

Raises `ArgumentError` on empty input, malformed amounts, or unregistered currencies. Consumed by `Util::FilterClauses.money_clauses`, which serves `Document::List` and the RBAC scope-predicate compiler.

---

## Currency

A currency definition struct with ticker, symbol, name, sub-unit digits, and the picker / display fields (`active`, `favorite`, `grouping`).

```crystal
eur = Facet::Util::Currency.new(ticker: "EUR", symbol: "€", name: "Euro", digits: 2)
eur.ticker   # => "EUR"
eur.symbol   # => "€"
eur.digits   # => 2
eur.active   # => true
eur.favorite # => false
eur.grouping # => "standard"
```

### Registry population

The registry is populated from the database, not from config. `Facet::Currency::Registry` (`src/currency.cr`) reads every non-deleted `core.Currency` projection row and replaces the in-memory set (`reset!` + `register`), so deletes and deactivations land. A malformed currency row raises loudly — data corruption is never a silent registry gap.

| Method | Purpose |
| --- | --- |
| `stale?` | True until the first refresh. |
| `mark_stale` | Pure flag for the invalidation path — no DB access. |
| `mark_fresh` | Marks fresh without a rebuild (spec plumbing). |
| `ensure_fresh(db)` | Rebuilds only when stale. |
| `refresh(db)` | Replace-all rebuild from `core.Currency` projections. |

Hydration call sites:

| Call site | Behaviour |
| --- | --- |
| Server boot (`src/main.cr`) | Warms the registry after the cache Pub/Sub subscribers start. |
| `Migrate.db_reset` | Refreshes after core-doctype seeding. |
| `Document::Create` / `Document::Update` | `ensure_fresh` before validating a write. |
| Import / export jobs | `ensure_fresh` at each job's entry point. |

Invalidation follows the contract of the doctype-definition cache and the webhook registry: the `DoctypeCache` Pub/Sub subscriber marks the registry stale on every `fanout:core.Currency:*` fanout (create, update, delete), and the next `ensure_fresh` on the affected process rebuilds it. There is no DB access on the invalidation path itself; the consistency window between a commit and the next `ensure_fresh` is the same one those registries accept. A process restart starts stale, so the first write hydrates even without a fanout. A fanout lost during a Redis outage is bounded by `cache.staleness_ttl_s` — `ensure_fresh` past the bound rebuilds without a fanout (see `doc/backend/replication.md` → `Event::Subscriber::DoctypeCache` → staleness bound).

`Util::Currency` keeps the in-memory set APIs the registry builds on:

```crystal
Currency.register({"EUR" => Currency.new("EUR", "€", "Euro", 2)})
Currency["EUR"]            # => #<Currency ...>
Currency.registered?("XYZ") # => false
Currency.all               # => {"EUR" => #<Currency ...>, ...}
Currency.reset!            # clears the set (registry refresh and tests)
```

`Currency.[]` raises `UnknownCurrencyError` for unregistered tickers. `find` returns `nil` instead of raising. `registered?` is the non-raising predicate used by `MoneyType#validate` and the filter grammar.

### JSON

```crystal
Currency.from_json(%({"ticker":"EUR","symbol":"€","name":"Euro","digits":2,"grouping":"standard"}))
Currency.new("EUR", "€", "Euro", 2).to_json
```

### Configuration surface

Currencies are edited as ordinary documents. The application-side entry is the
Configure page (`frontend/src/routes/Configure/currencies/`) — a tab-less
`ListView` over `core.Currency` with the standard create/edit routes
(`/core/Currency/new`, `/core/Currency/{id}/edit`); peek and show render
through the seeded `core.DocumentView` templates in
`data/seeds/core.DocumentView/documents.yml`. The workspace sidebar hides the
`core` domain, so the Configure page is how these rows are reached
application-side. Every save fans out and marks the registry stale — the row
itself carries no money fields, so the save never blocks on the registry.

---

## Integration with Doctype system

Money fields in doctype definitions declare `{"type": "money"}` with an optional `currency:` declaration:

```json
{
  "salary": { "type": "money", "currency": "USD" }
}
```

The field-level `currency:` declaration is a **display hint / default backfill**. A money row always carries its own `currency` member. If a content payload omits `currency`, `MoneyType#normalize` backfills it from `field_definition.currency` before validation, so single-currency editors can still send `{"value": "100"}`. `MoneyType#validate_definition` checks the field-level `currency` (if present) is a registered ticker.

### Lifecycle rule on document writes

`Document::MoneyCurrencyCheck` gates money values on the write paths, after schema validation:

| Path | Rule |
| --- | --- |
| Create | Every money path — nested paths included (array items, object properties, dictionary values) — must point at a registered **and active** currency. |
| Update | Only money paths whose ticker changed are compared against the stored content. Re-saving a path with the same ticker passes even when the row went inactive; switching a path to another ticker requires an active row. |
| Bulk import | Skips the check — a registered-but-inactive ticker still imports; a deleted ticker fails in the decode path (`UnknownCurrencyError`). |

A violation answers `422` with a `ValidationError` on the `<path>.currency` field, code `inactive_currency`. Unknown tickers keep failing as `schema` errors in `MoneyType#validate` — the check adds only the inactive case.

---

## Error types

| Error | Raised when |
|-------|-------------|
| `CurrencyMismatchError` | Adding/subtracting Moneys with different currencies |
| `UnknownCurrencyError` | Looking up or deserializing an unregistered currency |
| `DivisionByZeroError` | Dividing Money by zero |
