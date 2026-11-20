---
title: Error responses
description: "Error response shapes: validation 422s, auth failures, and non-disclosing 404s."
audience: [developer, operator]
features: [PLT-13]
sidebar:
  order: 8
verified_at: f1409cdc
---

Use this page to read an error the API returned, or to build the error handling your client needs.

Every error the API returns is one JSON object with an `error` key.
Validation failures add a `details` array. All error responses are
`application/json` and carry `Cache-Control: no-store`.

This page gives the status codes, the body shapes, and what each denial lets a
caller conclude.

## Body shape

```json
{ "error": "<message>", "details": [ ... ], "<extra>": "<value>" }
```

| Part | Present | Content |
| --- | --- | --- |
| `error` | always | The human-readable message. English, never localised. |
| `details` | validation failures only | One object per rejected value. Omitted when empty. |
| extra keys | a few statuses only | Flat string values a route adds, for example the tombstone fields on a `410`. |

## Status codes

| Status | Returned when | Body notes |
| --- | --- | --- |
| `400` | A malformed JSON body on a create route, or a QUERY request whose body declares no `Content-Type`. | Names the parse error. |
| `401` | A presented credential is invalid or unparseable. | `{"error": "Authentication required"}`. |
| `403` | The caller holds no permission for the operation at all, or fails the cross-site request check. | `{"error": "Forbidden"}` for permission denials. |
| `404` | The document is missing, or the caller holds a grant but cannot see the row. Also for an unknown route, an unknown doctype, or a disabled domain. | Non-disclosing — see below. |
| `405` | The path routes for other methods. | Carries the `Allow` header; the message names the same set. |
| `409` | A concurrent write lost the ordering race, a duplicate doctype registration, or a state conflict such as restoring a live document. | `{"error": "Concurrent write on this document — retry the request"}` for the write race. Re-issue the same request. |
| `410` | The document exists as a tombstone. | Carries `X-Document-Deleted: true`, plus `display_name` and `deleted_at` when known. |
| `415` | The request declares a non-JSON media type where the route needs JSON. | |
| `422` | Validation failed, the body has the wrong shape, or a query parameter is unknown. | Carries `details` when field validation failed. |
| `500` | An unexpected failure. | Always `{"error": "Internal server error"}` — never exception text. The details go to the server log. |
| `503` | A list aggregate exceeded the statement timeout. | Retry with a narrower filter. |

## The 422 validation shape

Each entry in `details` describes one rejected value:

| Field | Present | Content |
| --- | --- | --- |
| `field` | when the error names one field | Dot-separated path. Array indices are bare numeric segments: `items.3.name`. |
| `message` | always | The English fallback text. |
| `code` | when the producer stamps one | A stable machine tag to branch on. |
| `params` | when the code is templated | Flat `{name: value}` map with the interpolations. |

The stable codes:

| Code | Means |
| --- | --- |
| `required` | A required field is missing or null. |
| `invalid_type` | The value does not match the field's declared type. |
| `unknown_field` | The input carries a key the doctype does not declare. |
| `read_only` | The caller set a read-only or replicated field. |
| `reserved` | The input uses a system-reserved field name. |
| `unique` | A unique constraint was violated. |
| `invalid_format` | The value is malformed for its format, for example a pattern or an enum key. |
| `inactive_currency` | A money value names a registered but inactive currency. |
| `out_of_range` | A numeric or length bound was violated. |
| `compute` | A compute function called `error(msg)`. |
| `compute_runtime` | A compute function raised an unexpected exception. |
| `script` | A lifecycle hook or action called `ctx.error(msg)`. |
| `rbac` | An RBAC permission definition failed authoring-time validation. |
| `context_set` | A domain context set definition is malformed. |
| `named_scope` | A named scope references an undeclared context set. |
| `schema` | A doctype-definition-level check failed. |
| `template` | A view template failed structural validation. |
| `argument` | A named-action argument is missing or invalid. |

Branch on `code`, never on the text of `message`.

### Example

A create that sends an enum value the doctype does not declare:

```sh
curl -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"title": "Fix login", "status": "archived"}' \
  "https://facet.example.com/Api/helpdesk/Ticket"
```

The answer is:

```json
{
  "error": "Document validation failed",
  "details": [
    {
      "field": "status",
      "message": "has invalid enum value 'archived' (allowed: active, inactive)",
      "code": "invalid_format",
      "params": {
        "value": "archived",
        "allowed": "active, inactive",
        "format": "one of: active, inactive"
      }
    }
  ]
}
```

A client that renders `params` can show the rejection in the user's
language; a client that does not shows `message`.

## Non-disclosing 404

A document read or write answers one of three ways:

| Situation | Answer |
| --- | --- |
| The caller holds no grant for the action on the doctype at all | `403` |
| The caller holds a grant, but the row misses the grant's row scope — or the row does not exist | `404` |
| The row is a tombstone and the caller could otherwise read it | `410` |

The `404` is deliberately non-disclosing: an inaccessible document is
indistinguishable from a missing one. A caller may conclude that the id
names no readable document. A caller may not conclude anything about:

- whether the document exists,
- who may see it,
- why the scope missed.

This contract protects documents with enumerable ids. Keep it intact in
your own error handling:

- Report the same body for both causes.
- Do not probe ids to map a role's reach — every denial is logged server-side.

Lists behave differently by design: a scoped list narrows silently and
answers `200` with the visible rows, possibly an empty set.

## Authentication and authorization errors

| Situation | Answer |
| --- | --- |
| No credential at all | The request runs under the seeded `anonymous` role. Its read grants are the public surface; anything beyond them answers `403`. |
| A credential is presented but invalid — expired, wrong signature, unparseable `Authorization` header, unknown scheme | `401` `{"error": "Authentication required"}`. A broken credential never downgrades to anonymous access. |
| A permission denial on a document or feature route | `403` `{"error": "Forbidden"}`. |
| A state-changing request from a cookie session without the `X-Requested-With` header | `403` `{"error": "CSRF: Missing X-Requested-With header"}`. |

A request that carries `Authorization: Bearer` is exempt from the header check — an API key, an app token, or an agent token. A cross-site browser request cannot carry that header.

## Related

- [REST API](/reference/rest-api/) — the endpoint surface these statuses belong to.
