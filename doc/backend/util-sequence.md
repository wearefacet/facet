# Util::Sequence — Sequential identifier generation

`Facet::Util::Sequence` generates sequential, human-readable identifiers from a template string with auto-incrementing digit groups and time-based variables.

**Source files:**
- `src/util/sequence.cr`
- `spec/util/sequence_spec.cr`

The sequence is persisted per-doctype in the `sequence_identifiers` table and consumed by `Document::Create` when a doctype declares an `identifier` block. See [`doc/backend/doctype-system.md`](doctype-system.md#sequential-identifiers) for the integration point.

---

## Public API

```crystal
result = Facet::Util::Sequence.next(template, current_value)
# => NextResult(value: "INV-2026-0001", overflow: false)

result = Facet::Util::Sequence.next("INV-#", "INV-9")
# => NextResult(value: nil, overflow: true)
```

### `Sequence.next(template : String, current_value : String?) : NextResult`

Generates the next sequential identifier.

- **`template`** — A pattern string with `#` digit groups and `{year}`/`{month}`/`{day}` variables.
- **`current_value`** — The last generated identifier, or `nil` for the first creation.
- **Returns** a `NextResult` struct with `value : String?` (the generated identifier, or `nil` on overflow) and `overflow? : Bool`.

Raises `ArgumentError` if the template is invalid or `current_value` does not match the template pattern.

---

## Template grammar

| Token | Meaning | Example |
|---|---|---|
| `#` | Auto-incrementing digit group (zero-padded to its width) | `####` → `0001`, `0002`, ... `9999` |
| `{year}` | Current year (4 digits, always reflects `Time.utc`) | `2026` |
| `{month}` | Current month (2 digits, always reflects `Time.utc`) | `06` |
| `{day}` | Current day (2 digits, always reflects `Time.utc`) | `15` |
| Literal text | Any character not `#` or `{` (passed through verbatim) | `INV-`, `-`, `TKT-` |

Rules:
- At least one `#` group is required — a template with only `{year}` and literals raises `ArgumentError`.
- Digit group width is capped at 18 (fits `Int64` during increment).
- Unknown variables (`{foo}`) raise `ArgumentError` at compile time.
- Unclosed `{` raises `ArgumentError` at compile time.

---

## Behaviour

### First creation (`current_value = nil`)

Variables are filled from `Time.utc`. The rightmost digit group starts at **1** (not 0), all others are zero-filled:

```
Sequence.next("INV-{year}-####", nil)
# => NextResult("INV-2026-0001", overflow: false)
```

### Subsequent creation (same period)

When no time variable has changed, the rightmost digit group increments. When a group exceeds its width, it resets to zero and the carry moves left into the next **digit group** — time variables never increment:

```
Sequence.next("INV-{year}-####", "INV-2026-0001")
# => NextResult("INV-2026-0002", overflow: false)

Sequence.next("INV-{year}-####-####", "INV-2026-0000-9999")
# => NextResult("INV-2026-0001-0000", overflow: false)
```

When the carry consumes every digit group (the rightmost group is at its maximum and no group to the left can absorb the carry), the result is overflow — `value` is `nil` and `overflow?` is `true`:

```
Sequence.next("INV-{year}-####", "INV-2026-9999")
# => NextResult(nil, overflow: true)
```

The caller (`Document::Create` — see Integration below) falls back to a ULID on overflow, so document creation never fails.

### Time-variable rollover

When any variable (`{year}`, `{month}`, `{day}`) differs from the stored value, all digit groups to the **right** of that variable reset to zero (rightmost resets to 1):

```
# Year changed from 2025 → current year (e.g. 2026)
Sequence.next("INV-{year}-####", "INV-2025-0099")
# => NextResult("INV-2026-0001", overflow: false)
```

```
# Month changed from 05 → current month (e.g. 06), year same
Sequence.next("DOC-{year}-{month}-{day}-####", "DOC-2026-05-15-0042")
# => NextResult("DOC-2026-06-15-0001", overflow: false)
```

If **no** variable changed, normal increment applies (the old "preserve variable from current_value" behavior is gone):

```
# Year is already current — normal increment
Sequence.next("INV-{year}-####", "INV-2026-0042")
# => NextResult("INV-2026-0043", overflow: false)
```

### Overflow

When all digit groups are at their maximum, `overflow?` returns `true` and `value` is `nil`:

```
Sequence.next("INV-#", "INV-9")
# => NextResult(nil, overflow: true)

Sequence.next("INV-{year}-####-####", "INV-2026-9999-9999")
# => NextResult(nil, overflow: true)
```

---

## Integration with Doctype system

The `Document::Create.persist_and_publish` method calls `Sequence.next` inside a transaction guarded by `pg_advisory_xact_lock`. On overflow, it falls back to `Util::ScriptHelpers.ulid` — the document creation never fails due to counter exhaustion.

The `sequence_identifiers` table stores the last generated value per `(domain, doc_type)`:

```sql
SELECT last_value FROM sequence_identifiers
WHERE domain = $1 AND doc_type = $2
```

The `DoctypeDefinition` `identifier` block declares the template:

```yaml
identifier:
  template: "INV-{year}-####"
  genonly: true
```

---

## Error types

| Error | Raised when |
|---|---|
| `ArgumentError` | Template has no `#` group |
| `ArgumentError` | Unknown variable (not `year`/`month`/`day`) |
| `ArgumentError` | Unclosed `{` in template |
| `ArgumentError` | Digit group width > 18 |
| `ArgumentError` | `current_value` does not match the template pattern |
