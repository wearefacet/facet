---
title: Use the REST API
description: Call the document API directly — shapes, filters, aggregates, ETags, and errors.
audience: [developer]
features: [DOC-01, DOC-02, DOC-03, DOC-04, PLT-13]
sidebar:
  order: 10
verified_at: a77c6171
---

The document API is plain HTTP and JSON. One envelope serves every read and
write, and one filter grammar serves every list. This page teaches the shapes: create and update
bodies, list filters, aggregates, entity tags (ETags), and errors. The machine-readable contract
lives in the [REST API reference](/reference/rest-api/).

> **For agents:** Auth: `Authorization: Bearer fct_…` (static key) or `Authorization: DPoP <token>` plus
> a `DPoP` proof header (app token). Sequence: `POST /Api/crm/Company` with fields at the top level of the
> JSON body (`201`, envelope `{data, meta}`) → `GET /Api/crm/Company/<id>` (store the `ETag`) → re-send it
> as `If-None-Match: "<etag>"` for a `304` → `GET /Api/crm/Company?items=50&filters[status__eq]=active&sort=-updated_at`
> → `PATCH` (merge patch; `null` removes a key) → `DELETE` (`204`). Validation failures are `422` with
> `{error, details:[{field, message, code, params?}]}`. A hidden or missing document is `404`; a deleted one is `410`.

## When to use this

Use the raw API when:

- You call Facet from a language without an SDK.
- You need direct control over filters, paging, or cache validators.
- You debug an integration and must see the raw shapes.

For TypeScript apps, prefer [the TypeScript SDK](/apps/typescript-sdk/): types, paging, typed errors.

## Before you start

- A running Facet instance and a credential with a read grant on the target
  doctype. Creates and updates need `write`; delete needs `delete`.
- Three credentials work on every route:
  - `Authorization: Bearer fct_…` — a static API key
    ([service accounts and API keys](/apps/service-accounts/)).
  - `Authorization: DPoP <token>` with a fresh proof in the `DPoP` header —
    an app token ([DPoP token binding](/apps/dpop/)).
  - A browser session cookie.
- A write with a cookie session must carry `X-Requested-With: XMLHttpRequest`.
  A Bearer or DPoP request without a session cookie is exempt.
- Paths carry a lowercase domain first: `/Api/crm/Company`. An uppercase first
  segment (`/OAuth`, `/Ws`) names an infrastructure route, never a domain.

  The examples use `https://facet.example.com` and the `crm.Company` doctype.
  Replace both with your values.

## Steps

### 1. Read one document

```sh
curl "https://facet.example.com/Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

The answer is one `{ data, meta }` envelope. `data` holds the fields the doctype declares. `meta`
holds system metadata and is never writable:

```json
{
  "data": { "name": "Acme", "status": "active" },
  "meta": {
    "id": "crm.Company.01JD8W2G7Q5M2X9K4T6VBNR8D",
    "uri": "urn:facet:crm:Company:01JD8W2G7Q5M2X9K4T6VBNR8D",
    "mid": "01JD8W2G7Q5M2X9K4T6VBNR8E",
    "domain": "crm", "doc_type": "Company",
    "version": 1, "schema_version": 1,
    "display_name": "Acme",
    "created_at": "2026-01-01T12:00:00Z", "updated_at": "2026-01-01T12:00:00Z"
  }
}
```

| Field | Meaning |
| --- | --- |
| `id`, `uri` | Document id in the dotted `{domain}.{Doctype}.{id}` form; canonical URN. |
| `mid` | ULID of the last mutation applied to the document. |
| `domain`, `doc_type` | The domain id and the doctype name. |
| `version`, `schema_version` | The document version and the doctype schema version. |
| `display_name` | Human label from the doctype template; `null` when the doctype declares none. |
| `created_at`, `updated_at` | Timestamps in UTC. |

### 2. Create a document

Fields ride at the top level of the JSON body. There is no `content` wrapper:

```sh
curl -X POST "https://facet.example.com/Api/crm/Company" \
  -H "Authorization: Bearer $FACET_API_KEY" -H "Content-Type: application/json" \
  -d '{ "name": "Acme", "status": "active" }'
```

The answer is `201` with the envelope from step 1. A wrapped body names no
doctype field, so it fails with `422`:

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
curl -X POST "https://facet.example.com/Api/crm/Company" \
  -H "Authorization: Bearer $FACET_API_KEY" -H "Content-Type: application/json" \
  -d '{ "$content": { "name": "Acme", "status": "active" },
    "$children": { "memberships": [
      { "role": "primary", "contact": "crm.Contact.01JD9K2G7Q5M2X9K4T6VBNR8E" } ] } }'
```

The answer carries an extra `children` key, grouped by relationship name. Each entry carries the
same `{ data, meta }` shape as the parent:

```json
{ "children": { "memberships": [
  { "data": { "role": "primary" }, "meta": { "id": "crm.CompanyMembership.01JD9K2G7Q5M2X9K4T6VBNR8F" } } ] } }
```

### 3. Update and delete

`PATCH` sends a JSON merge patch (RFC 7386). A `null` value removes a key from the document; the
mutation log records the removal as an `unset` entry:

```sh
curl -X PATCH "https://facet.example.com/Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D" \
  -H "Authorization: Bearer $FACET_API_KEY" -H "Content-Type: application/json" \
  -d '{ "status": "churned", "website": null }'
```

The answer is `200` with the updated envelope. Document routes are PATCH-only: a `PUT` answers
`405` with an `Allow` header, because `PUT` is reserved for definition authoring on `core.DocType`.

`DELETE` soft-deletes the document and answers `204` with no body. The document becomes a
tombstone; a restore call brings it back (see `410` under [Errors](#errors)).

### 4. List and filter

```sh
curl "https://facet.example.com/Api/crm/Company?items=50&filters[status__eq]=active&sort=-updated_at" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

The collection envelope holds an array of `{ data, meta }` rows. The list `meta` carries `count`
and `more`:

```json
{
  "data": [
    { "data": { "name": "Acme", "status": "active" },
      "meta": { "id": "crm.Company.01JD8W2G7Q5M2X9K4T6VBNR8D", "created_at": "2026-01-01T12:00:00Z", "updated_at": "2026-01-02T09:30:00Z" } },
    { "data": { "name": "Globex", "status": "active" },
      "meta": { "id": "crm.Company.01JD9K2G7Q5M2X9K4T6VBNR8E", "created_at": "2026-01-03T08:00:00Z", "updated_at": "2026-01-03T15:11:42Z" } }
  ],
  "meta": { "count": 2, "more": false }
}
```

Paging: `page` starts at 1; `items` clamps to 1..1000; the defaults are page 1, 100 items, sort
`id`. `count` caps at 1000 and includes one probe row when a further page exists — a one-item
page against a larger set reports `count: 2`. `more` is `true` when a further page exists.

Filter keys are `field__operator` pairs:

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

Every doctype also accepts the system targets `id`, `created_at`, `updated_at`, and `deleted_at`.
Array values on the query string ride JSON-encoded:
`filters[value__between]=%5B%22USD%202500%22%2C%22USD%201000%22%5D`. Sort entries take a `-` prefix
for descending. Numeric types (integer, money, duration) sort numerically, not as text. Unknown
filter fields answer `422` with `unknown_filter_field`; unknown parameters answer
`422 Unknown parameter '<key>'`. A typo never degrades to an unfiltered result.

### 5. Aggregate

`aggregate=count` counts the full filtered set. It ignores `page` and `items` and caps the count
at 1000. It answers `{ "data": [], "meta": { "count": 87, "more": false } }`:

```sh
curl "https://facet.example.com/Api/crm/Company?aggregate=count&filters[status__eq]=active" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

`aggregate=sum|avg|min|max` needs `field=`. The field must be a top-level `integer`, `duration`,
or `money` field. A field aggregate runs over the full filtered set with no cap. A money field
returns a bag with one entry per currency present, never a single cross-currency total; amounts
are decimal strings:

```sh
curl "https://facet.example.com/Api/crm/Deal?aggregate=sum&field=value" \
  -H "Authorization: Bearer $FACET_API_KEY"
```

```json
{ "data": { "value": { "USD": "123456.78" } }, "meta": { "count": 87, "more": false } }
```

An empty set answers `value: 0` for `sum`, `value: null` for `avg`, `min`, and `max`, and
`value: {}` for a money field. `meta.count` counts matching rows; rows that omit the field still
count.

### 6. Cache reads with ETags

Every read emits a strong `ETag`. On a single document the tag is the ULID of its last mutation.
On a collection the tag combines the role, the request, and the doctype version. Send the tag
back in `If-None-Match`, and the server answers `304 Not Modified` when nothing changed:

```http
GET /Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D
→ 200
ETag: "01JD8W2G7Q5M2X9K4T6VBNR8E"

GET /Api/crm/Company/01JD8W2G7Q5M2X9K4T6VBNR8D
If-None-Match: "01JD8W2G7Q5M2X9K4T6VBNR8E"
→ 304
```

A `304` carries `Cache-Control: no-cache`, so the client revalidates on the next read. A write
gives the document a new tag, so a stale client never receives a false `304`.

### 7. Send list parameters in a QUERY body

The `QUERY` method (RFC 10008) carries list parameters in a JSON body only. New clients should
prefer it; `GET` keeps the body plus query-string merge for backward compatibility, and the
query string wins on a collision:

```sh
curl -X QUERY "https://facet.example.com/Api/crm/Company" \
  -H "Authorization: Bearer $FACET_API_KEY" -H "Content-Type: application/json" \
  -d '{ "items": 50, "filters": { "status__eq": "active" }, "sort": ["-updated_at"] }'
```

Any query-string parameter on a `QUERY` request answers `422`. A body with a non-JSON
`Content-Type` answers `415`. An empty body means the defaults: page 1, 100 items, sort `id`.
Responses carry `Accept-Query: application/json`, so a client can discover the format from any
list response.

## Errors

| Status | Meaning |
| --- | --- |
| `422` | Validation failed, or a filter, sort, select, or parameter name is wrong. |
| `403` | Class denial: the credential holds no permission on the doctype at all. |
| `404` | Non-disclosing: a missing document and a hidden one are indistinguishable. |
| `405` | Method not allowed; the `Allow` header names the accepted methods. |
| `409` | Concurrent write on the document. Re-issue the same request. |
| `410` | Tombstone: the document is deleted. |
| `415` | A non-JSON `Content-Type` on a body-consuming request. |

A `422` body carries one entry per failed field. Each entry holds `field`, `message`, and `code`;
a `params` map holds the interpolations behind a templated `code` when present (step 2 shows a
full example). A concurrent write answers
`{ "error": "Concurrent write on this document — retry the request" }`. The losing write never
landed, so a fresh write takes the next free slot.

A read of a tombstone answers `410` with the surviving label:

```json
{ "error": "Document 01JD8W2G7Q5M2X9K4T6VBNR8D was deleted", "display_name": "Acme", "deleted_at": "2026-01-01T12:00:00Z" }
```

Restore the document with `POST /Api/crm/Company/<id>/restore` and an empty JSON body. Every
error response sets `Cache-Control: no-store`, so no cache keeps a stale failure.

## Example

One sequence covers the full create, read, update, and delete (CRUD) cycle:

```sh
BASE="https://facet.example.com"
AUTH="Authorization: Bearer $FACET_API_KEY"
ID="01JD8W2G7Q5M2X9K4T6VBNR8D"

curl -s -X POST "$BASE/Api/crm/Company" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{ "name": "Initech", "status": "lead" }'          # → 201: meta.id, fresh ETag
curl -s -D - -o /dev/null "$BASE/Api/crm/Company/$ID" -H "$AUTH"          # → 200: copy the ETag
curl -s -D - -o /dev/null "$BASE/Api/crm/Company/$ID" -H "$AUTH" \
  -H 'If-None-Match: "01JD8W2G7Q5M2X9K4T6VBNR8E"'       # → 304 when unchanged
curl -s "$BASE/Api/crm/Company?filters[status__eq]=active&sort=-updated_at&items=10" -H "$AUTH"  # → 200
curl -s -X PATCH "$BASE/Api/crm/Company/$ID" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{ "status": "active" }'                           # → 200: updated envelope
curl -s -X DELETE "$BASE/Api/crm/Company/$ID" -H "$AUTH" -o /dev/null -w '%{http_code}\n'  # → 204
```

## Troubleshooting

**A document you just created answers `404`.**

Row scopes on the role, or a missing grant, hide the row. A `404` never discloses existence.
Check what the credential may attempt — see
[Gate your UI with the manifest](/apps/permission-manifest/).

**A list call answers `422 Unknown parameter` or `unknown_filter_field`.**

A typo sits in the parameter grammar. Check the key and the operator against
the table in step 4.

**A conditional read returns `200` every time.**

The `If-None-Match` value must match the `ETag` verbatim, quotes included.

**A write answers `409`.**

Two writers raced on one document. The losing write never landed. Re-issue
the same request.

**A create answers `422` with `unknown_field` on `content`.**

The body is wrapped in a `content` key. Send the fields at the top level of
the JSON body.

## Related

- [The TypeScript SDK (`@facetapp/sdk`)](/apps/typescript-sdk/) — the typed wrapper over this surface.
- [Search](/apps/search/) — cross-doctype label search in one call.
- [Realtime with WebSockets](/apps/websockets/) — push updates instead of polling.
- [Gate your UI with the manifest](/apps/permission-manifest/) — what the credential may attempt.
- [REST API reference](/reference/rest-api/) — the machine-readable contract.
- Internals on GitHub: [http-layer.md](https://github.com/wearefacet/facet/blob/main/doc/backend/http-layer.md).
