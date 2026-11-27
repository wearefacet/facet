---
title: Use the REST API
description: Use the REST API to create, read, update, list, and delete documents over plain HTTP — one envelope, one filter grammar.
type: how-to
audience: [developer]
features: [DOC-01, DOC-02, DOC-03, DOC-04, DOC-14, PLT-12, PLT-13]
verified_at: c34885a
sidebar:
  order: 0
---

The document API is plain HTTP and JSON. One envelope serves every read and
write. One filter grammar serves every list. Nadia's calendar, Tom's client
table, and Lucía's warehouse board all read this surface — and so does your
app.

> **For agents:** Login: `POST /Api/iam/login` (cookie) or `Authorization: Bearer fct_…`
> (an API key from `POST /Api/iam/keys`, pinned to one role, or an app API key) or
> `Authorization: DPoP <token>` + `DPoP` proof header (app token). Sequence:
> `POST /Api/clients/Company` with fields at the top level of the JSON body (`201`, envelope
> `{data, meta}`) → `GET /Api/clients/Company/<id>` (store the `ETag` — the `mid`) → send it back as
> `If-None-Match` for a `304` → `GET /Api/clients/Company?items=50&filters[status__eq]=confirmed&sort=-updated_at`
> → `PATCH` (merge patch; `null` removes a key) → `DELETE` (`204`) → `POST …/<id>/restore` revives a
> tombstone. Validation failures are `422` with `{error, details:[{field, message, code}]}`. A hidden
> or missing document is `404`; a deleted one is `410`.

## When to use this

Call the API directly when:

- Your code runs in a language without an SDK.
- You need direct control over filters, paging, or cache validators.
- You debug an integration and want to see the raw shapes.

For TypeScript, prefer [the TypeScript SDK](/build/apps/data/sdk/) — it wraps
this surface with typed handles and errors.

## Before you start

- A running Facet instance and a credential that can read the target doctype.
  Writes need the `write` action; delete needs `delete`.
- Three credentials work on every route:
  - `Authorization: Bearer fct_…` — an app API key
    ([service accounts for backend apps](/build/apps/connect/backend-apps/)).
  - `Authorization: DPoP <token>` with a fresh proof in the `DPoP` header —
    an app token ([DPoP token binding](/build/apps/connect/dpop/)).
  - A browser session cookie from `POST /Api/iam/login`.
- A cookie-authenticated write must carry `X-Requested-With: XMLHttpRequest`.
  The cross-site request forgery (CSRF) check rejects the write with `403`
  without it, because a cross-site form POST can set no custom header. Bearer
  and DPoP requests carry no cookie, so they are exempt.
- The path is `/Api/<domain>/<doctype>`. The first segment is lowercase — an
  uppercase first segment (`/OAuth`, `/Ws`) names an infrastructure route,
  never a domain.

The examples run against a dev instance at `https://facet.localhost:3443`
with the Brightwater Rentals data loaded
([the running example](/build/apps/how-apps-work/)). The self-signed dev
certificate is why every `curl` carries `-k`.

## Steps

### 1. Read one document

Sign in once and store an API key pinned to the `manager` role. Every API
call presents its own credential; a bearer call carries no cookie, so it
needs no `X-Requested-With` header:

```sh
pnpx @facetapp/cli connect --role manager   # sign in, elect manager, store the key
NADIA_KEY=$(pnpx @facetapp/cli apikey)
```

One booking in the rentals domain is `BK-2026-0001` — the Maison Lumière
wedding, 11 to 13 December:

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  https://facet.localhost:3443/Api/rentals/Booking/BK-2026-0001
```

```json
{
  "data": {
    "dates": { "end": "2026-12-13", "start": "2026-12-11" },
    "notes": "Wedding — main lawn. Site contact: Claire.",
    "total": 1970,
    "client": "clients.Company.06H1FM1B3MXBPS0JYVM3BDD154",
    "status": "confirmed",
    "client_name": "Maison Lumière"
  },
  "meta": {
    "id": "BK-2026-0001",
    "uri": "urn:facet:rentals:Booking:BK-2026-0001",
    "mid": "06H1FM1DPGYWFD4D8RR2BXM2S9",
    "domain": "rentals",
    "doc_type": "Booking",
    "version": 1,
    "schema_version": 1,
    "display_name": "Maison Lumière",
    "created_at": "2026-11-26T12:24:08Z",
    "updated_at": "2026-11-26T12:24:08Z"
  }
}
```

The answer is one `{ data, meta }` envelope. `data` holds the fields the
doctype declares. `meta` holds system metadata and is never writable:

| Field | Meaning |
| --- | --- |
| `id`, `uri` | Document id; canonical URN `urn:facet:<domain>:<Doctype>:<id>`. |
| `mid` | ULID of the last mutation applied to the document. Also the document's `ETag`. |
| `domain`, `doc_type` | The domain id and the doctype name. |
| `version`, `schema_version` | The document version and the doctype schema version. |
| `display_name` | Human label from the doctype template; `null` when the doctype declares none. |
| `created_at`, `updated_at` | Timestamps in UTC. |

### 2. Create a document

Fields ride at the top level of the JSON body. There is no `content` wrapper:

```sh
curl -sk -X POST https://facet.localhost:3443/Api/clients/Company \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "name": "Atelier Vermeil", "city": "Lyon" }'
```

The answer is `201`:

```json
{
  "data": { "city": "Lyon", "name": "Atelier Vermeil" },
  "meta": {
    "id": "06H1FRV45MM80SVH32K5JCA6BH",
    "uri": "urn:facet:clients:Company:06H1FRV45MM80SVH32K5JCA6BH",
    "mid": "06H1FRV45MKNZD49WQA7A843TW",
    "domain": "clients",
    "doc_type": "Company",
    "version": 1,
    "schema_version": 1,
    "display_name": "Atelier Vermeil",
    "created_at": "2026-11-26T12:45:08Z",
    "updated_at": "2026-11-26T12:45:08Z"
  }
}
```

A body that wraps the fields in a `content` key names no doctype field, so it
fails with `422`:

```json
{
  "error": "Document validation failed",
  "details": [{ "field": "content", "code": "unknown_field",
    "message": "is not a defined field — this looks like a wrapped body: send the fields at the top level; there is no content wrapper" }]
}
```

To create a parent with its children in one call, send `$content` and
`$children`. The call is one transaction: a child failure rolls the whole call
back. The `$children` keys are relationship names on the doctype:

```sh
curl -sk -X POST https://facet.localhost:3443/Api/clients/Company \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "$content": { "name": "Café des Sports", "city": "Vienne" },
    "$children": { "contacts": [ { "name": "Léa Martin", "email": "lea@cafedesports.example" } ] } }'
```

The answer carries an extra `children` key, grouped by relationship name.
Each entry carries the same `{ data, meta }` shape as the parent:

```json
{ "children": { "contacts": [
  { "data": { "name": "Léa Martin", "email": "lea@cafedesports.example" },
    "meta": { "id": "06H1G0A2B3C4D5E6F7G8H9J0K1L", "parent_id": "06H1G0Z9Y8X7W6V5U4T3S2R1Q0P" } } ] } }
```

### 3. Update and delete

`PATCH` sends a JSON merge patch (RFC 7386). A `null` value removes a key
from the document:

```sh
curl -sk -X PATCH https://facet.localhost:3443/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "city": "Annecy", "name": null }'
```

The answer is `200` with the updated envelope. Document routes accept
`GET`, `HEAD`, `PATCH`, and `DELETE` — a `PUT` answers `405` with
`allow: GET, HEAD, PATCH, DELETE`.

`DELETE` soft-deletes the document and answers `204` with no body:

```sh
curl -sk -X DELETE -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $NADIA_KEY" \
  https://facet.localhost:3443/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH
# 204
```

The document becomes a tombstone. A read of it now answers `410` and keeps
the label, so an audit view can still name it:

```json
{
  "error": "Document 06H1FRV45MM80SVH32K5JCA6BH was deleted",
  "deleted_at": "2026-11-26T12:45:27Z",
  "display_name": "Atelier Vermeil"
}
```

`POST /Api/clients/Company/<id>/restore` with an empty JSON body brings the
document back. The answer carries the restored envelope and a
`cascade_restored` list for any children the delete had taken down.

### 4. List and filter

```sh
curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/rentals/Booking?filters[status__eq]=confirmed&select=client_name,status,dates&items=2'
```

The `curl -g` flag matters: it stops `curl` from mangling the brackets in the
filter key. The answer is `200`:

```json
{
  "data": [
    { "data": { "client_name": "Maison Lumière", "status": "confirmed", "dates": { "end": "2026-12-13", "start": "2026-12-11" } },
      "meta": { "id": "BK-2026-0001", "display_name": "Maison Lumière", "created_at": "2026-11-26T12:24:08Z", "updated_at": "2026-11-26T12:24:08Z" } },
    { "data": { "client_name": "Harbour Events Ltd", "status": "confirmed", "dates": { "end": "2026-12-20", "start": "2026-12-19" } },
      "meta": { "id": "BK-2026-0003", "display_name": "Harbour Events Ltd", "created_at": "2026-11-26T12:24:08Z", "updated_at": "2026-11-26T12:24:08Z" } }
  ],
  "meta": { "count": 6, "more": false }
}
```

Paging: `page` starts at 1, `items` clamps to 1..1000, and the defaults are
page 1, 100 items, sort `id`. `count` caps at 1000. `more` is `true` when a
further page exists.

Filter keys are one bracket level deep, `filters[field__operator]=value`:

| Operator | Matches |
| --- | --- |
| `__eq`, `__ne` | Equal, not equal. |
| `__gt`, `__gte`, `__lt`, `__lte` | Comparison. |
| `__match` | Contains the substring, case-insensitive. |
| `__starts_with` | Starts with the value, case-insensitive. |
| `__between` | Inclusive range; the value is a two-element array. |
| `__in` | Membership; the value is an array of at most 100 entries. |
| `__currency` | Money amount in one currency. |
| `__contains`, `__overlaps`, `__within` | Range tests on `period` and `dateperiod` fields. |
| `search` (bare key, no suffix) | Substring match on the document's search corpus. |

Every doctype also accepts the system targets `id`, `created_at`,
`updated_at`, and `deleted_at`. The server names what it accepts when a key
or operator is wrong — a typo never degrades to an unfiltered result:

```json
{ "error": "Unknown filter field 'nope' (filterable: account_manager, city, created_at, deleted_at, id, name, search, updated_at)" }
```

```json
{ "error": "Filter operator 'regex' is not served for field 'name' (allowed: eq, in, match, ne, starts_with)" }
```

Array values on the query string ride JSON-encoded, for example
`filters[dates__between]=%5B%222026-12-11%22%2C%222026-12-20%22%5D`. Sort
entries take a `-` prefix for descending: `sort=-updated_at,id`.

**Relative dates.** Any datetime or date bound accepts a relative date
instead of an absolute one: `filters[created_at__gte]=-7d`. The grammar is
`[+|-]<n><unit>…` with units `y`, `mo` (month), `w`, `d`, `h`, `m`
(minute), `s`; a leading `-` is in the past, `+` or no sign in the future,
and the sign applies to every component (`-1mo6d` is one month and six
days back). **`m` is a minute and `mo` is a month.** Months and years are
calendar steps — `-1mo` from March 31 is February 28 — and weeks, days,
hours, minutes and seconds are fixed-length. On a `datetime` field or
`created_at`/`updated_at` the bound is the exact instant; on a `date`
field it truncates to the calendar day. `__lte` covers the whole day the
bound lands on and `__gt` starts at it, so `created_at__lte=-7d` means "up
to seven days ago, the whole day". A relative bound with `h`, `m` or `s`
on a `date` field answers `422`.

A second form exists for long filters: the `QUERY` method (step 6) carries
the same parameters as a JSON body.

### List a parent's children

The nested route `GET /Api/<domain>/<Doctype>/<id>/<relationship>` lists
one parent's children — for example `/Api/clients/Company/<id>/contacts`.
It forwards the full list grammar: `filters`, `sort`, `page`, `items`,
`select`, `aggregate`, `scope`, and `deleted`, with the flat route's
defaults (page 1, 100 items) and the same validation — a malformed filter
answers `422`, never an unfiltered result. The response ETag digests the
whole request, so two different pages or orders never share a validator.
Sidecar lists — comments and attachments — are the exception: they stay
unpaginated.

### 5. Aggregate

`aggregate=count` counts the full filtered set. It ignores `page` and
`items`:

```sh
curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/rentals/Booking?aggregate=count&filters[status__eq]=confirmed'
```

```json
{ "data": [], "meta": { "count": 6, "more": false } }
```

`aggregate=sum|avg|min|max` needs `field=`. The field must be a top-level
`integer`, `duration`, or `money` field. A money field returns a bag with one
entry per currency present, never a cross-currency total; amounts are decimal
strings. Brightwater's 44 booking lines hold 387 rented pieces in total:

```sh
curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/rentals/BookingLine?aggregate=sum&field=price'
```

```json
{ "data": { "value": { "EUR": "8128.00" } }, "meta": { "count": 44, "more": false } }
```

```sh
curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/rentals/BookingLine?aggregate=sum&field=quantity'
```

```json
{ "data": { "value": 387 }, "meta": { "count": 44, "more": false } }
```

An empty set answers `value: 0` for `sum`, `value: null` for `avg`, `min`,
and `max`, and `value: {}` for a money field. A field the doctype does not
declare, or one that is not numeric, answers `422`:

```json
{ "error": "field 'total' is not a numeric field (type: data)" }
```

### 6. Cache reads with ETags

Every read emits a strong `ETag`. On a single document the tag is the ULID of
its last mutation — the `mid`. On a collection the tag combines the account,
the role, the request, and the doctype version. Send the tag back in
`If-None-Match`, and the server answers `304 Not Modified` when nothing
changed:

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" -D - -o /dev/null \
  https://facet.localhost:3443/Api/rentals/Booking/BK-2026-0001 | grep -i etag
# etag: "06H1FM1DPGYWFD4D8RR2BXM2S9"

curl -sk -H "Authorization: Bearer $NADIA_KEY" -o /dev/null -w '%{http_code}\n' \
  -H 'If-None-Match: "06H1FM1DPGYWFD4D8RR2BXM2S9"' \
  https://facet.localhost:3443/Api/rentals/Booking/BK-2026-0001
# 304
```

A `304` carries `Cache-Control: no-cache`, so the client revalidates on the
next read. A write gives the document a new `mid`, so a stale client never
receives a false `304`.

### 7. Send list parameters in a QUERY body

The `QUERY` method carries list parameters in a JSON body only. It keeps long
filters readable and out of the shell's quoting rules:

```sh
curl -sk -X QUERY https://facet.localhost:3443/Api/clients/Company \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "items": 10, "filters": { "city__eq": "Lyon" }, "sort": ["-updated_at"] }'
```

Any query-string parameter on a `QUERY` request answers `422`:

```json
{ "error": "QUERY does not accept query parameters; put them in the request body" }
```

A body with a non-JSON `Content-Type` answers `415`. A malformed body answers
`422` with `{"error": "Invalid JSON body"}`. An empty body means the
defaults: page 1, 100 items, sort `id`. Responses carry
`Accept-Query: application/json`, so a client can discover the format from
any list response.

## The machine-readable spec

This surface has a machine-readable description: an OpenAPI file. The
instance serves it at `GET /Api/openapi.json` to a signed-in caller —
without a credential it answers `401`. The file covers a subset of the
REST surface by decision; the reference page embeds it — see
[REST API](/reference/rest-api/).

## Errors

| Status | Meaning |
| --- | --- |
| `401` | No credential, or a credential the surface refuses (an MCP token on REST, for example). |
| `403` | The credential holds no permission on the doctype at all; or the CSRF header is missing on a cookie write. |
| `404` | Non-disclosing: a missing document and a hidden one are indistinguishable. Also an unknown domain or doctype. |
| `405` | Method not allowed; the `Allow` header names the accepted methods. |
| `410` | Tombstone: the document is deleted. |
| `415` | A non-JSON `Content-Type` on a body-consuming request. |
| `422` | Validation failed, or a filter, sort, select, or parameter name is wrong. |

A `422` body carries one entry per failed field. Each entry holds `field`,
`message`, and `code`:

```json
{
  "error": "Document validation failed",
  "details": [{ "field": "name", "message": "is missing", "code": "required" }]
}
```

The server names the accepted keys for parameter mistakes:

```json
{ "error": "Unknown parameter 'bogus' (accepted: page, items, sort, select, aggregate, field, scope, deleted)" }
```

```json
{ "error": "Unknown select key 'bogus' (accepted: client, client_name, dates, notes, status, total)" }
```

Every error response sets `Cache-Control: no-store`, so no cache keeps a
stale failure. The full catalogue lives in the
[error responses reference](/reference/error-responses/).

## Example

One full cycle against the dev instance — create, read, update, cache-check,
delete, restore, delete again:

```sh
BASE=https://facet.localhost:3443
AUTH="Authorization: Bearer $NADIA_KEY"
CT='Content-Type: application/json'

# Create — remember meta.id from the 201 answer.
curl -sk -H "$AUTH" -H "$CT" -X POST "$BASE/Api/clients/Company" \
  -d '{ "name": "Atelier Vermeil", "city": "Lyon" }'

# Read — copy the ETag (the mid) from the headers.
curl -sk -H "$AUTH" -D - -o /dev/null "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH"

# Conditional read — 304 when nothing changed.
curl -sk -H "$AUTH" -o /dev/null -w '%{http_code}\n' \
  -H 'If-None-Match: "06H1FRV45MKNZD49WQA7A843TW"' \
  "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH"

# Update — 200 with the fresh envelope.
curl -sk -H "$AUTH" -H "$CT" -X PATCH "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH" \
  -d '{ "city": "Annecy" }'

# List — one filtered page.
curl -skg -H "$AUTH" \
  "$BASE/Api/clients/Company?filters[name__match]=Vermeil&select=name,city"

# Delete — 204. Read answers 410 afterwards.
curl -sk -H "$AUTH" -X DELETE -o /dev/null -w '%{http_code}\n' \
  "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH"

# Restore — 200 with the restored envelope.
curl -sk -H "$AUTH" -H "$CT" -X POST "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH/restore" -d '{}'

# Delete again — the record is a throwaway probe.
curl -sk -H "$AUTH" -X DELETE -o /dev/null -w '%{http_code}\n' \
  "$BASE/Api/clients/Company/06H1FRV45MM80SVH32K5JCA6BH"
```

## Troubleshooting

**A create or delete answers `403` with `{"error":"CSRF: Missing X-Requested-With header"}`.**

The call carries a session cookie, so the CSRF check applies. Add
`X-Requested-With: XMLHttpRequest`, or send an API key in
`Authorization: Bearer`. A bearer or DPoP call without a cookie needs no
header.

**A list answers `422 Unknown filter field 'name][match'`.**

Rack-style nesting (`filters[name][match]`) is not the grammar. One bracket
level holds the whole key: `filters[name__match]=value` — with `curl -g` so
the brackets survive.

**A document you created moments ago answers `404`.**

Row scopes on the role, or a missing grant, hide the row. A `404` never
discloses existence. Check what the credential may attempt — see
[Gate your UI with the manifest](/build/apps/connect/permission-manifest/).

**A conditional read returns `200` every time.**

The `If-None-Match` value must match the `ETag` verbatim, quotes included.
The document's `mid` changes on every write — copy the tag after the write.

**A read answers `410`.**

The document is a tombstone. `POST /Api/<domain>/<doctype>/<id>/restore`
brings it back. A `410` carries `display_name`, so the UI can label the row.

**A create answers `422` with `unknown_field` on `content`.**

The body is wrapped in a `content` key. Send the fields at the top level of
the JSON body.

**An aggregate answers `422 field 'x' is not a numeric field`.**

`sum`, `avg`, `min`, and `max` take a top-level `integer`, `duration`, or
`money` field. `aggregate=count` needs no field.

## Related

- [The TypeScript SDK](/build/apps/data/sdk/) — the typed wrapper over this surface.
- [Search from an app](/build/apps/data/search/) — cross-doctype label search in one call.
- [Live updates](/build/apps/data/realtime/) — push updates instead of polling.
- [Gate your UI with the manifest](/build/apps/connect/permission-manifest/) — what the credential may attempt.
- [REST API reference](/reference/rest-api/) — the full route and parameter reference.
- [Documents: records with a memory](/discover/how-it-works/documents/)
