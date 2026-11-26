---
title: See who did what
description: "Read the audit trail: one document history, every change from one place, and the sign-in log."
type: how-to
audience: [admin]
features: [AUD-02, AUD-08, IAM-13, FE-16]
verified_at: eee55a2
sidebar:
  order: 0
---

A client phones Brightwater: "someone moved our booking to Tuesday". Ravi
needs an answer, with proof, in one minute. Facet records every create,
update, delete, and snapshot in one append-only log. Each row states who made
the change, what changed, when, and what caused it. It answers for one
document, or for the whole organization at once. A second log records the
sign-in events.

## When to use this

- You must answer who changed a document, and when.
- You investigate one incident across many documents.
- You review sign-in and security events.

## Before you start

- **Document history.** It needs read rights on the target document.
- **The global log.** It needs wildcard read on `*.*` — a permission line that
  covers every doctype.
- **The model.** [The change log, in detail](/admin/under-the-hood/change-log/)
  explains what one row holds.

## Steps

### 1. Read one document's history

Every document answers for its own past on the history route:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/equipment/Item/EQ-2026-0004/history"
```

The answer lists the document's changes, newest first. The Pagoda tent at
Brightwater shows two rows — its create, and the update the check-out app
wrote when Lucía returned it:

```json
{
  "id": "06H1GDBJBWDP6SE85NVRFJ9A15",
  "domain": "equipment",
  "doc_type": "Item",
  "doc_id": "EQ-2026-0004",
  "idx": 3,
  "action": "update",
  "actioner_id": "06H1FKZGAC2CA2JYPC97DKXD3Z",
  "arguments": {
    "diff": {
      "set": [{"path": ["status"], "value": "available"}],
      "unset": []
    },
    "meta_diff": {"set": [], "unset": []}
  },
  "redacted": [],
  "channel": "oauth_app",
  "app": "06H1GCMXX4HX02S6ZVDGJ3SQ3P",
  "api_key": null,
  "acting_role": "iam.Roles.warehouse",
  "cause_kind": "request",
  "cause_name": null,
  "cause_event": null,
  "cause_source": null,
  "cause_parent": null,
  "cause_trace": "06H1GDBJBWDP6SE85NVRFJ9A15",
  "emitted_at": "2026-11-26T14:14:45Z",
  "display_name": null
}
```

Read the row as a sentence: Lucía's account, acting as *Warehouse*, through
the check-out app, set `status` to `available` at 14:14. A create or a delete
carries the full content in `arguments`; an update carries the difference.

### 2. Merge the child documents into the timeline

Add `?include=children` to fold the history of composition children into the
parent timeline:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/equipment/Item/EQ-2026-0004/history?include=children"
```

Each child branch is filtered by the child's own row scope. A child you
cannot read does not answer `403` — its branch drops out of the timeline.

### 3. Search across the organization

The global log lists every change. Filters ride the bracket form:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/Audit?filters[action__eq]=delete&filters[domain__eq]=iam"
```

The answer lists every delete in the `iam` domain, with a capped count and a
`more` flag for paging. The count stops at 1,000; `more` is `true` when the
real total was higher. A bare query key such as `?doc_type=Company` answers
`422` — the grammar admits only the bracket form:

```json
{"error": "Unknown parameter 'doc_type' (accepted: page, items, sort, filters)"}
```

Scripts can send the `QUERY` method instead, with the list parameters in a
JSON body: `{"filters": {"action__eq": "delete"}}`. On that form, any
query-string parameter answers `422`.

### 4. Use the admin UI

Open **Configure → Audit log**. The table lists every change across all
domains. Add filter chips for domain, doctype, action, actor, channel, or
time. Select a row to inspect the changed fields, the actor, the channel, and
the cause. From here an administrator can also revert a change — see
[Roll back a change](/admin/history/roll-back/).

### 5. Read the login-event log

Sign-in events are documents of doctype `iam.LoginEvent`. A role with read
rights on it lists them through the standard document API:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/iam/LoginEvent?items=20&sort=-created_at"
```

Each row carries the event type, the account id, and details such as the
elected role:

```json
{"event": "login", "details": "Role: iam.Roles.admin", "account_id": "06H1FKW9RRQX860BKXRBY3YT8V"}
```

## Explanation

### What each row records

| Question | Fields |
| --- | --- |
| Who | `actioner_id`, `channel`, `app`, `api_key`, `acting_role` |
| What | the content (create, snapshot, delete) or the diff (update) |
| When | `emitted_at` |
| Why | `cause_kind`, `cause_name`, `cause_event`, `cause_parent`, `cause_trace` |

The cause fields form a chain. Each row names its parent row in
`cause_parent`, so one walk reconstructs the whole story. All rows of one
cluster share the root id in `cause_trace`, so one query returns the cluster.

### The two read modes

- **Document history.** The target document's read gate applies. A caller
  with no read right on the doctype at all answers `403`. A caller who cannot
  see that one document answers the same `404` as a missing document.
- **Global log.** Wildcard read on `*.*` is required. `domain` and `doc_type`
  act as filters, never as gates — one call asks what changed in one domain.
  A caller signed in through an app token or an app-owned key is refused
  here, whatever its role holds. A grant names one domain, so no grant can
  cover a view across every domain.

### Filters

| Field | Operators |
| --- | --- |
| `domain`, `doc_type`, `doc_id` | `eq` |
| `action`, `actioner_id`, `app`, `channel`, `kind`, `trace` | `eq`, `ne` |
| `emitted_at` | `gte`, `lte` |

`kind` filters by cause kind, for example `request`, `action`, `assistant`,
`rollback`, or `compaction`. `trace` takes a cluster root id, so one query
returns one incident.

### Channels

| Channel | Meaning |
| --- | --- |
| `session` | A signed-in browser session |
| `oauth_app` | An app token from an OAuth sign-in |
| `app_api_key` | An app-owned API key |
| `api_key` | A static API key |
| `mcp` | An MCP agent session |
| `internal` | System work: cron passes, compaction, triggers |

### Redaction

Values your role cannot see are removed from the log response, and the
`redacted` block names the removed paths. The stored log keeps the values —
the removal happens at read time, per caller. See
[Hide a field from some roles](/admin/people/hidden-fields/).

### The login-event log

`iam.LoginEvent` rows record the authentication events: login, logout,
lockout, refresh reuse, MFA enrolment and changes, password reset, invites,
consent grants, API-key and session revocations, OIDC sign-ins, and app or
SSO denials. Two limits matter for reviewers. Single failed password attempts
are not logged — only the lockout is. Successful token refreshes are not
logged either — they run on a clock and would flood the log. The backend log
carries every failed attempt and every successful refresh, with the account
id and the client address.

## Troubleshooting

### The API answers `422 Unknown parameter`

A bare query key is not in the grammar. Wrap the filter in the bracket form,
or send the `QUERY` body.

### The global log answers `403`

Your active role lacks wildcard read on `*.*`, or you called through an app
token — apps cannot read the global log. Switch to a browser session or a
static API key with a role that holds the line.

### A history row shows no value

Redaction for your role — see
[Hide a field from some roles](/admin/people/hidden-fields/).

### A recent change is missing

The log keeps rows inside the retention window. Older rows fold into one
snapshot per document — see [Retention: what is kept](/admin/history/retention/).

## Related

- [Roll back a change](/admin/history/roll-back/) — undo from the log.
- [Retention: what is kept](/admin/history/retention/) — how long the log keeps rows.
- [The change log, in detail](/admin/under-the-hood/change-log/) — the data model behind this page.
- [History and undo](/use/documents/history-undo/) — the per-document surface in the app.
- Internals on GitHub: [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
- [Security and governance](/discover/security/)
