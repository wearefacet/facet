# FilterSet

`Facet::Util::FilterSet` composes SQL WHERE-clause fragments from a hash of filter keys with operator suffixes (e.g. `"age__gte"`, `"name__match"`). It is designed to be composable: multiple `FilterSet` instances can be combined with `+` to produce an AND-joined SQL fragment.

This is a **query-level utility** — it translates user-facing filter expressions into PostgreSQL `content->>'field'` comparisons. It has no knowledge of doctype schemas or field types.

## Source Files

- `src/util/filter_set.cr` — the schema-agnostic text-operator builder
- `src/util/filter_clauses.cr` — the type-aware clause builders (`Util::FilterClauses`), shared with the RBAC scope SQL surface
- `src/util/like_escape.cr` — the shared LIKE/ILIKE pattern escaper (`Util::LikeEscape`)

## Public API

### Constructor

```crystal
FilterSet.new(filters : Hash(String, JSON::Any))
```

Each key in the hash is a field name optionally followed by `__<operator>` (e.g. `"salary__gte"`). Values are escaped as PG literals and compared as text.

### Instance Methods

| Method | Returns | Description |
|---|---|---|
| `#empty?` | `Bool` | `true` when no filters were provided |
| `#to_sql` | `String` | Combined SQL fragment (AND-joined), or `""` when empty |
| `#clauses` | `Array(String)` | Individual clause strings |
| `#+(other : FilterSet)` | `FilterSet` | Returns a new set with clauses of both sets AND-joined |

### Class Methods

| Method | Returns | Description |
|---|---|---|
| `.build_clause(key, value)` | `String` | Builds a single SQL WHERE clause from a key-value pair |
| `.escape_literal(value)` | `String` | Escapes a `JSON::Any` value as a PostgreSQL literal |
| `.parse_filter_key(key)` | `{String, String}` | Splits `"field__op"` into `{"field", "op"}` (defaults to `"eq"`) |

### Supported Operators

| Suffix | SQL Output | Example |
|---|---|---|
| *(none)* / `__eq` | `content->>'field' = 'val'` | `name=Alice` |
| `__ne` | `content->>'field' IS DISTINCT FROM 'val'` | `status__ne=archived` |
| `__gt` | (see Typed comparison operators) | `age__gt=25` |
| `__gte` | (see Typed comparison operators) | `age__gte=18` |
| `__lt` | (see Typed comparison operators) | `age__lt=65` |
| `__lte` | (see Typed comparison operators) | `age__lte=100` |
| `__match` | `content->>'field' ILIKE '%' || $n || '%' ESCAPE '\\'` | `name__match=smith` |
| `__starts_with` | `content->>'field' ILIKE $n || '%' ESCAPE '\\'` | `name__starts_with=Al` |
| `__between` | (see Typed comparison operators) | `age__between=[18,65]` |
| `__in` | `content->>'field' = ANY(ARRAY[$n, $n+1, …])` | `status__in=[open,won]` |

The text-based operators (`__eq`, `__ne`) are correct as text comparison for text-typed fields — stored JSON values extract to text via `->>`, and string/boolean/enum/date equality survives the round-trip. On `integer` / `duration` fields they route through the typed builder when the field declares `equality` / `comparison` (see below), so the `btree_numeric` index stays usable.

### Membership operator (`__in`)

`__in` filters by a set: the value is a JSON array, and the clause is `content->>'field' = ANY(ARRAY[$n, $n+1, …])` — one bind parameter per entry. On `integer` / `duration` fields the typed builder intercepts it with the same cast helper as the comparison operators (`jsonb_as_numeric(content->'field') = ANY(ARRAY[$n::numeric, …])`). `__in` serves the system `id`, scalar, and typed fields only — money, container (array), range, and reference fields reject it in the tool-layer validation sets (fail loud rather than serve a half-right form). On `enum` fields the entries are the stored enum keys, matched as exact text.

`Util::FilterSet::MAX_IN_VALUES` (100) bounds the array: a longer array degrades to `FALSE` at compile time (the REST backstop), while the agent surfaces raise `InvalidParams` naming the bound before any SQL runs. An empty array degrades to `FALSE` — no value in an empty set matches.

### Pattern operators (`__match`, `__starts_with`) and LIKE escaping

`__match` is a **contains-substring** match (`%term%`) and `__starts_with` is a **prefix** match (`term%`); both are case-insensitive. The bound value passes through `Util::LikeEscape.escape`, which escapes the PostgreSQL LIKE/ILIKE special characters (`\`, `%`, `_`), and the SQL fragment carries an explicit `ESCAPE '\'` clause. A `%` or `_` in the caller's value is therefore matched **literally**, never as a wildcard:

```crystal
set = FilterSet.new({"name__match" => JSON::Any.new("50%off")})
# SQL: content->>'name' ILIKE '%' || $1 || '%' ESCAPE '\'
# Bound value: "50\%off"
```

The same escape contract applies to every ILIKE surface in the codebase: `Document::List`'s search filter (the `search` operator — it folds the term through `Util::DiacriticFold` **before** escaping, since folding never creates a metacharacter), `Document::List`'s `id__match` system-column branch, and `Assistant::Conversation`'s text-column `__match`.

### Typed comparison operators (`__eq`, `__ne`, `__gt`, `__gte`, `__lt`, `__lte`, `__between`, `__in`)

For `integer` / `duration` fields, `__gt`, `__gte`, `__lt`, `__lte`, `__between`, and `__in` are **not** handled by `FilterSet`; `__eq` / `__ne` join them when the field declares an `equality` / `comparison` capability (the `btree_numeric` index exists). Without that declaration they stay on the text path, so a unique integer field keeps its text `unique_btree`. For `boolean` fields, the ordering operators (`__gt`, `__gte`, `__lt`, `__lte`, `__between`, `__in`) are typed; `__eq` / `__ne` stay on the text path because the boolean index is a plain btree on `content->>'field'`. `Util::FilterClauses.typed_clauses` intercepts the typed operators and reads the JSONB value directly via IMMUTABLE cast helpers selected from the doctype field's declared type:

| Field type | LHS expression |
|---|---|
| `integer`, `duration` | `jsonb_as_numeric(content->'field')` |
| `boolean` | `jsonb_as_boolean(content->'field')` |

The bound value is coerced to the matching SQL type on the parameter side (`$n::numeric` / `$n::boolean`), so a query-string string value (`age__gt=20`, parsed as `JSON::Any(String)`) and a JSON-body numeric value (`age__gt: 20`, parsed as `JSON::Any(Int64)`) compile to the same numeric comparison. On the list path a non-array `__between` value raises before the builder runs (`Document::FilterCompiler` shape validation, reason `malformed_filter_value`); inside the builder — and for direct `Util::FilterClauses` callers — a non-array or wrong-arity `__between` still degrades to `FALSE` rather than raising.

For text-typed fields (`string`, `date`, `datetime`, `enum`, …) these operators remain in `FilterSet` — text comparison is correct for them (datetime is stored as tz-normalized RFC-3339, which is lexicographically sortable).

The per-type operator ceilings (`Doctype.supported_operators` in `src/doctype/filter_capability.cr`) are the single source both the clause routing and the derived `operators` metadata intersect with: `FieldDefinition#operators` and `Doctype::DerivedOperators` never stamp an operator outside the field type's ceiling, so the frontend filter bar cannot offer an operator this compiler would answer `unsupported_filter_operator` (`comparison` fans out to `ne` on a money field, but the money builder does not serve it — the metadata drops it).

`FilterSet` is deliberately schema-agnostic (per its documented contract) — it has no knowledge of doctype field types, only of field names + URL suffixes. Type-aware intercept happens at the query layer (`Document::List`) where the definition is available.

### Money operators (`__eq`, `__gt`, `__gte`, `__lt`, `__lte`, `__between`, `__currency`)

`money` fields are also **not** handled by `FilterSet` — `Util::FilterClauses.money_clauses` intercepts every money operator and routes through the IMMUTABLE `facet_money_value_as_numeric(content->'field')` helper for value comparisons, plus `content#>>'{field,currency}'` for the `__currency` operator.

| Operator | Value form | SQL output |
|---|---|---|
| `__eq` / `__gt` / `__gte` / `__lt` / `__lte` | `"<amount>"` or `"<CCY> <amount>"` | `facet_money_value_as_numeric(content->'field') OP $n::numeric` (+ optional `AND content#>>'{field,currency}' = $n+1` when `CCY` prefix is present) |
| `__between` | `["<CCY> <a>", "<CCY> <b>"]` (shared CCY) | `facet_money_value_as_numeric(content->'field') BETWEEN $n::numeric AND $n+1::numeric` (+ optional currency predicate) |
| `__currency` | `"<CCY>"` | `content#>>'{field,currency}' = $n` |

The filter value grammar accepts a currency-prefixed `"<CCY> <amount>"` form (parsed by `Util::MoneyFilterValue`) that adds a same-row currency predicate, or a bare `"<amount>"` form that compares numerically across all currencies. Unknown currency tickers or malformed amounts raise `Util::FilterClauses::MoneyFilterError` which `List.call` surfaces as a 422. Mixed-currency `__between` bounds are also rejected with 422 (cross-currency ranges are ambiguous as a filter).

`FilterSet` is deliberately schema-agnostic (per its documented contract) — money operator expansion lives at the query layer (`Document::List`) where the definition is in scope. See [`util-money.md`](util-money.md) for the money data shape and [`index-management.md`](index-management.md#money-indexes-money) for the supporting composite indexes.

### Range operators (`__contains`, `__overlaps`, `__within`)

These operators apply **only** to `period` and `dateperiod` fields and are **not** handled by `FilterSet` itself. Their clauses are built by `Util::FilterClauses.range_clauses`, which takes the doctype definition, identifies range-type fields, and expands the LHS into the matching `facet_tstzrange(content#>>'{field,start}', content#>>'{field,end}')` / `facet_daterange(...)` expression so the GiST range index is used.

`FilterSet` is deliberately schema-agnostic (per its documented contract) — it has no knowledge of doctype field types, only of field names + URL suffixes. Range operator expansion happens at the query layer (`Document::List`) where the definition is available.

| Suffix | SQL Output | Index |
|---|---|---|
| `__contains` (single point) | `facet_tstzrange(content#>>'{f,start}', content#>>'{f,end}') @> $n::timestamptz` | GiST range (`gist_tstzrange` / `gist_daterange`) |
| `__contains` (interval) | `... @> tstzrange($n, $n+1, '[)')` | GiST range |
| `__overlaps` | `... && tstzrange($n, $n+1, '[)')` | GiST range |
| `__within` | `... <@ tstzrange($n, $n+1, '[)')` | GiST range |
| `__eq` (on a range field) | `... = tstzrange($n, $n+1, '[)')` | GiST range |

The LHS uses the IMMUTABLE wrapper functions (`facet_tstzrange` / `facet_daterange`) so the WHERE expression matches the GiST index expression byte-for-byte — PostgreSQL's planner matches on the parsed expression tree, so using the raw `tstzrange(...)` constructor in the WHERE clause would NOT use the index.

## Composition

Two `FilterSet` instances can be AND-combined:

```crystal
user_filters = FilterSet.new({"status__eq" => "active"})
scope_filters = FilterSet.new({"org_id__eq" => "acme_corp"})
combined = user_filters + scope_filters
combined.to_sql # => "content->>'status' = 'active' AND content->>'org_id' = 'acme_corp'"
```

This is the pattern for combining user-supplied filters with RBAC scope restrictions.

## Usage in Document::List

`Document::List` partitions the incoming filter hash (see `partition_filters`) by routing:
- range operators on `period` / `dateperiod` fields to `Util::FilterClauses.range_clauses`,
- typed comparison operators on `integer` / `duration` fields (`__eq` / `__ne` only when the field declares `equality` / `comparison`) and the ordering operators on `boolean` fields to `Util::FilterClauses.typed_clauses`,
- every money operator on `money` fields (including the money-specific `__currency`) to `Util::FilterClauses.money_clauses`,
- system-column filters (`id`, `created_at`, `updated_at`) to `build_system_clauses`,
- everything else (text-based `__eq` / `__ne` / `__match` / `__starts_with`, and comparison ops on text-typed fields) to `FilterSet`.

```crystal
filter_set = Util::FilterSet.new(scalar_filters, offset: all_params.size)
where_clauses << filter_set.to_sql unless filter_set.empty?
```
