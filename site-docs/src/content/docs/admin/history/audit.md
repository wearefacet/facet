---
type: how-to
title: Auditing activity
description: Read the mutation log through the API and the admin UI, and inspect the login-event log.
audience: [admin]
features: [AUD-02, AUD-08, IAM-13, FE-16]
sidebar:
  order: 0
verified_at: a8e1b43
---

Facet records every create, update, delete, and snapshot in one append-only
log. Each row states who made the change, what changed, when, and what caused
it. This page shows how to read the log, and how to read the sign-in event log
beside it.

## When to use this

- You must answer who changed a document, and when.
- You investigate one incident across many documents.
- You review sign-in and security events.

## Before you start

- **Document history.** It needs read rights on the target document.
- **The global log.** It needs wildcard read on `*.*`, a line that covers
  every doctype.
- **The model.** See [The mutation log](/admin/under-the-hood/change-log/) for what one
  row holds.

## Steps

### 1. Read one document's history

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/hr/Employee/01J8Z0A7G3Q5M2X9K4T6VBNR8D/history"
```

The answer lists the document's changes, newest first. Each row carries the
action, the actor, the time, and the content or the diff.

### 2. Merge the child documents into the timeline

Add `?include=children` to fold the history of composition children into the
parent timeline:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/hr/Employee/01J8Z0A7G3Q5M2X9K4T6VBNR8D/history?include=children"
```

Each child branch is filtered by the child's own row scope. A child you cannot
read does not answer `403` — its branch drops out.

### 3. Search across the organization

The global log lists every mutation. Filters ride the bracket form:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/Audit?filters[action__eq]=delete&filters[domain__eq]=hr"
```

The answer lists every delete in the `hr` domain, with a capped count and a
`more` flag for paging. A bare query key such as `?doc_type=Invoice` answers
`422` — the grammar admits only the bracket form. Scripts can send the `QUERY`
HTTP method instead, with the list parameters in a JSON body:
`{"filters": {"action__eq": "delete"}}`. On that form any query-string
parameter answers `422`.

### 4. Use the admin UI

Open **Configure → Audit**. The table lists every mutation across all domains.
Add filter chips for domain, doctype, action, actor, channel, or time. Select a
row to inspect the changed fields, the actor, the channel, and the cause. From
here an administrator can also roll a document back — see
[Rolling back changes](/admin/history/roll-back/).

### 5. Read the login-event log

Sign-in events are documents of doctype `iam.LoginEvent`. A role with read
rights on it lists them through the standard document API:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/iam/LoginEvent?items=20&sort=-created_at"
```

Each row carries the event type, the account id, and details such as the
client address.

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

- **Document history.** The target document's read gate applies. A caller with
  no read right on the doctype at all answers `403`. A caller who cannot see
  that one document answers the same `404` as a missing document.
- **Global log.** Wildcard read on `*.*` is required. `domain` and `doc_type`
  act as filters, never as gates — one call asks what changed in one domain.

### Filters

| Field | Operators |
| --- | --- |
| `domain`, `doc_type`, `doc_id` | `eq` |
| `action`, `actioner_id`, `app`, `channel`, `kind`, `trace` | `eq`, `ne` |
| `emitted_at` | `gte`, `lte` |

`kind` filters by cause kind, for example `action`, `hook_event`,
`rollback`, or `assistant`. `trace` takes a cluster root id.

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
`redacted` block names the paths. See
[Field visibility with tags](/admin/people/hidden-fields/).

### The login-event log

`iam.LoginEvent` rows record every authentication event: login, logout,
refresh reuse, lockout, MFA enrolment and changes, password reset, invites,
consent grants, API-key and session revocations, OIDC sign-ins, and denials.
Two limits matter for reviewers. Single failed password attempts are not
logged — only the lockout is. Successful token refreshes are not logged
either — they run on a clock and would flood the log. The backend log carries
every failed attempt and every successful refresh, with the account id and
the client address.

## Troubleshooting

### The API answers `422 Unknown parameter`

A bare query key is not in the grammar. Wrap the filter in the bracket form,
or send the `QUERY` body.

### The global log answers `403`

Your active role lacks wildcard read on `*.*`. Switch to a role that holds it.

### A history row shows no value

Redaction for your role — see
[Field visibility with tags](/admin/people/hidden-fields/).

### A recent change is missing

The log keeps rows inside the retention window. Older rows fold into one
snapshot per document — see [Retention](/admin/history/retention/).

## Related

- [The mutation log](/admin/under-the-hood/change-log/) — the data model behind this page.
- [Rolling back changes](/admin/history/roll-back/) — undo from the log.
- [Retention](/admin/history/retention/) — how long the log keeps rows.
- [History and undo](/use/documents/history-undo/) — the per-document surface in the app.
- Internals on GitHub: [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
