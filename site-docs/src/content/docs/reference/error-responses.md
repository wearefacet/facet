---
type: reference
title: Error responses
description: "Error response shapes: validation 422s, auth failures, and non-disclosing 404s."
audience: [developer, operator]
features: [PLT-13]
sidebar:
  order: 18
verified_at: eee55a2
---

Your client calls the API and gets an error back. This page shows the body
shape, every status the API answers with, and the validation codes you can
branch on. You also learn what each denial lets you conclude — and what it
never tells you.

## Body shape

Every error is one JSON object with an `error` key. All error responses are
`application/json` and carry `Cache-Control: no-store` — browsers may store
`404` and `410` by default, and a cached tombstone would keep reporting a
document as deleted after a restore.

```json
{ "error": "<message>", "details": [ ... ], "<extra>": "<value>" }
```

| Part | Present | Content |
| --- | --- | --- |
| `error` | always | The human-readable message. English, never localised. |
| `details` | validation failures only | One object per rejected value. Omitted when empty. |
| extra keys | a few statuses only | Flat string values a route adds, for example the tombstone fields on a `410` or the `dependency` key on a `503`. |

## Status codes

| Status | Returned when | Body notes |
| --- | --- | --- |
| `400` | A malformed JSON body on a create route, or a QUERY request whose body declares no `Content-Type`. | Names the parse error. |
| `401` | A presented credential is invalid or unparseable. | `{"error": "Authentication required"}`. |
| `403` | The caller holds no permission for the operation at all, fails the cross-site request check, or writes into an invisible field. | `{"error": "Forbidden"}` for permission denials; the write-plane refusals carry their own messages — see the table below. |
| `404` | The document is missing, or the caller holds a grant but cannot see the row. Also for an unknown route, an unknown doctype, or a disabled domain. | Non-disclosing — see below. |
| `405` | The path routes for other methods. | Carries the `Allow` header; the message names the same set. |
| `409` | A concurrent write lost the ordering race, a duplicate doctype registration or domain name, or a state conflict such as restoring a live document. | `{"error": "Concurrent write on this document — retry the request"}` for the write race. Re-issue the same request. |
| `410` | The document exists as a tombstone — a read of a deleted document, or a delete of an already-deleted one. | Carries `X-Document-Deleted: true`, plus `display_name` and `deleted_at` when known. |
| `413` | An upload — file artifact, document import, or domain import — exceeds the size cap. | `{"error": "Upload exceeds the maximum allowed size (N bytes)"}` with the cap value. |
| `415` | The request declares a non-JSON media type where the route needs JSON: a QUERY body, a nested document write, or the `export_view` body. | The message names the route that refused it. |
| `422` | Validation failed, the body has the wrong shape, or a query parameter is unknown. | Carries `details` when field validation failed. |
| `429` | A rate limit or budget fired: the OAuth refresh floor (`slow_down`), an IAM throttle (login lockout, MFA verify, change password), or the assistant token budget. | The message says which gate fired. The OAuth token endpoint also sets `Retry-After`. |
| `500` | An unexpected failure. | Always `{"error": "Internal server error"}` — never exception text. The details go to the server log. |
| `502` | The mail test route reached a transport that refused or failed the request. | The message carries the adapter's own error. |
| `503` | Either a list or export exceeded the statement timeout, or a backing service (Redis, PostgreSQL) could not be reached. | Two shapes — see below. |

### The 403 write-plane refusals

A `403` on a write can name its reason:

| Message | Means | Source |
| --- | --- | --- |
| `Forbidden` | The caller holds no permission for the action on the doctype at all (role denial or app-grant ceiling). | `src/document/read.cr:174-182`, `src/document/action.cr:239-251` |
| `Write refused: invisible field` | The write reaches a field the caller's role cannot see — an explicit `null` counts as a write. `details` names the content paths. | `src/rbac/write_enforcer.cr:75` |
| `Role authority refused this write` | The write would move an IAM account or role above the caller's level, or into a protected target. | `src/rbac/role_authority.cr:390-393` |

### The two 503 shapes

| Shape | Cause | What to do |
| --- | --- | --- |
| `{"error": "The request exceeded the server's statement timeout — narrow the filters and retry"}` | A list, export, or aggregate query ran past `database.statement_timeout_ms`. | Narrow the filters and retry. |
| `{"error": "Service unavailable", "dependency": "redis" \| "postgresql"}` | A connection-level failure of a backing service. | An operator signal, not a client bug — check the health probe. |

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
| `unique` | A unique constraint was violated. The lost unique-index race carries this code too. |
| `invalid_format` | The value is malformed for its format — a pattern, an enum key, a URL shape, a reference token. |
| `invalid_reference_format` | A reference value does not use the `domain.Doctype.id` form. |
| `reference_target_not_found` | The referenced target does not exist as a live row. |
| `reference_doctype_mismatch` | A reference value names a doctype the field does not declare. |
| `reference_filter_mismatch` | A referenced row exists but misses the field's `filter`, or the caller cannot read it. |
| `duplicate_reference_target` | A collection reference names the same target twice. |
| `inactive_currency` | A money value names a registered but inactive currency. |
| `out_of_range` | A numeric or length bound was violated. |
| `too_long` | A value exceeds a fixed ceiling, for example an enum key length. |
| `empty_value` | A value that must be non-empty carries empty text. |
| `duplicate_value` | A definition-level list carries the same key twice, for example an enum. |
| `invalid_value` | A value is outside the set a rule allows, for example a kanban lane colour. |
| `invalid_mime` | An uploaded file's bytes do not match the field's allowed MIME types. |
| `immutable` | A write tries to change a field that cannot change after creation, for example an account email. |
| `unsupported_field` | A view configuration names a field the surface does not serve. |
| `wildcard_target` | An app grant names the `domain.*` wildcard instead of a concrete target. |
| `unsupported_filter_operator` | The field does not serve the operator the filter uses. |
| `malformed_filter_value` | The filter value has the wrong shape, for example a non-array `__between`. |
| `compute` | A compute function called `error(msg)`. |
| `compute_runtime` | A compute function raised an unexpected exception. |
| `script` | A lifecycle hook or action called `ctx.error(msg)`. |
| `rbac` | An RBAC permission definition failed authoring-time validation. |
| `context_set` | A domain context set definition is malformed. |
| `named_scope` | A named scope references an undeclared context set. |
| `schema` | A doctype-definition-level check failed. |
| `template` | A view template failed structural validation. |
| `argument` | A named-action argument is missing or invalid. |
| `forbidden` | The write-plane refusal `Write refused: invisible field` — the details carry the invisible paths. |

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
