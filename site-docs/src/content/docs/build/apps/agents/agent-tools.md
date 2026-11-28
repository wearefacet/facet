---
title: What agents can do
description: The shared document tool catalogue that serves MCP clients and the assistant — families, rights, caps, and errors.
type: how-to
audience: [developer]
features: [AI-04, AI-06]
verified_at: eee55a2
sidebar:
  order: 2
---

One catalogue of document tools serves every agent surface. The MCP server
and the in-app assistant mount the same entries. Whichever surface calls,
the capabilities, the RBAC, the caps, and the error mapping are the same.
The full generated list — every tool with its parameters — lives in
[the agent tools reference](/reference/agent-tools/); this page explains
how the catalogue behaves.

> **For agents:** Call tools with `tools/call` — connect per
> [Connect agents over MCP](/build/apps/agents/mcp/). Sequence: `tools/list` → `whoami` →
> `get_schema` before any write → `list_documents` with `field__op` filters → `create_document` /
> `update_document` (JSON merge patch; `null` removes a key) → `batch` (25 ops max). A filter key
> the doctype does not declare raises `-32602` — never a silent empty result. Errors carry
> `data.reason`; caps: 200 rows, 1 MiB envelope, 25 batch ops. Files move over HTTP:
> `request_artifact_upload` mints a signed URL.

:::note[Document tools only]
The catalogue carries no schema authoring: no domain or doctype create or
update, no publish. `create_document` writes into an already-registered
doctype; it does not register one. Schema work belongs to REST and the
builder assistant.
:::

## When to use this

Use this page when:

- You build an agent on the MCP surface, or you extend the assistant.
- You must know which tools exist, what they need, and what they return.
- A tool call fails, and you need the error contract.

## Before you start

- Connect first — see
  [Connect agents over MCP](/build/apps/agents/mcp/). This page speaks
  MCP; the assistant mounts the same entries.
- Call `whoami` first: it returns the role, the permission lines, the
  scopes, and the visible tags. Fields whose tags fall outside
  `visible_tags` are absent from every result.

## The catalogue by family

The registry holds 23 tools; the MCP mount adds `read_skill`, for 24 on
`tools/list`. They fall into six families:

| Family | Tools | Rights class |
| --- | --- | --- |
| Surface | `ping`, `whoami` | none |
| Discovery | `list_domains`, `list_doctypes`, `get_schema`, `read_skill` | read |
| Read | `list_documents`, `aggregate_documents`, `get_document`, `resolve_refs`, `get_links`, `get_backrefs`, `search_documents`, `list_mutations`, `list_sidecars`, `list_artifact_refs` | read |
| Write | `create_document`, `update_document`, `delete_document`, `batch`, `create_sidecar` | write |
| Actions | `call_action` | action |
| Files | `request_artifact_upload`, `get_artifact` | write / read |

`read_skill` is not a catalogue entry. Each surface mounts its own loader;
the MCP mount serves short markdown references for these tools.

A tool's `requires` line gates its appearance in `tools/list`: `read`
appears for a role that reads the target, `write` for one that writes,
`action` for one that may run the doctype's non-CRUD actions. Visibility is
a convenience for the agent, never a boundary: enforcement runs at call
time, exactly as on REST.

## Steps

### 1. List the tools and read the schema

`tools/list` returns the role-filtered listing. Read `get_schema` before
any write. It carries the fields, the actions, the scopes, the `member_of`
parent link, and the host's sidecar segments. On the Brightwater instance,
`get_schema` on `clients.Company` names the filterable fields before any
call is made.

### 2. List and read documents

`list_documents` takes `domain` and `doctype`, plus:

| Argument | Purpose |
| --- | --- |
| `filters` | `field__op` keys — `status__eq`, `name__match`, `city__starts_with` |
| `sort` | field names; a `-` prefix sorts descending |
| `page`, `items` | pagination |
| `fields` | project each row's content to the named fields |
| `expand` | resolve reference fields into a `resolved` map |
| `scope` | apply a named row scope as a query-time filter |
| `parent_id` | list one parent's children; child doctypes only |

Filter keys validate against the doctype. An unknown key, or an operator
the field does not serve, raises an error — never a silent empty result.
From a live session on the Brightwater instance:

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "error": {
    "code": -32602,
    "message": "Filter operator 'bogus' is not supported for field 'name' on clients.Company (supported: eq, in, match, ne, starts_with)",
    "data": { "reason": "unsupported_operator", "field": "name", "operator": "bogus" }
  }
}
```

`parent_id` gates through the parent's read scope, the same gate as the
nested REST route. An oversized result sets `meta.truncated: true` and
carries `next_cursor`; fetch that page next. Every row's `meta` carries
`display_name`. `aggregate_documents` runs under the same filters and caps.

### 3. Write documents

`create_document` takes the full content. A child doctype needs `parent_id`;
a child without it is refused. `update_document` takes a JSON merge patch:
new keys are set, and a `null` value removes the key. `delete_document`
tombstones the document. `batch` runs ordered `create`, `update`, `delete`,
and `action` ops in one transaction; a failure rolls the batch back and
names the op index.

### 4. Act, extend, and inspect

`call_action` runs a named action with typed args — on Brightwater, the
`confirm` action on `rentals.Booking`. `create_sidecar` and `list_sidecars`
work on one segment of one host document. `list_mutations` answers a
document's history; without a `doc_id`, it serves the whole log to a
wildcard reader. `resolve_refs`, `get_links`, and `get_backrefs` walk the
reference graph. `search_documents` fans a search term over every readable
doctype.

### 5. Move files over HTTP

No file bytes ride the tool channel:

1. Call `request_artifact_upload`. It returns a one-time signed upload URL.
2. POST the multipart `file` part to that URL.
3. Put the returned artifact id into a document.
4. Call `get_artifact` for a download URL, or `list_artifact_refs` to see
   where an artifact is used.

  See [Upload and serve files](/build/apps/data/files/) for the HTTP side.

## Caps and errors

The caps come from the `mcp:` block: 200 rows, 1 MiB envelope, 25 batch ops
— see [Connect agents over MCP](/build/apps/agents/mcp/). An oversized
result is cut, not failed: it sets `meta.truncated` and `next_cursor`.
Failures are JSON-RPC errors:

| Error class | JSON-RPC code | Meaning |
| --- | --- | --- |
| `InvalidParams` | `-32602` | Bad arguments; unknown argument keys are rejected centrally |
| `RbacDenied` | `-32603` | The role lacks the permission; it never names the failed line |
| `NotFound` | `-32602` | Unknown, tombstoned, and invisible documents give one non-disclosing answer |
| `Capped` | `-32603` | The result exceeds a cap |
| `ToolError` | `-32603` | Fallback |

Every failure carries a machine-readable `data.reason`:

| `data.reason` | Class | Extra keys |
| --- | --- | --- |
| `invalid_params` | `InvalidParams` | `argument` |
| `unknown_argument` | `InvalidParams` | `argument`, `tool` |
| `unknown_field` | `InvalidParams` | `field` |
| `unsupported_operator` | `InvalidParams` | `field`, `operator` |
| `unknown_tool` | `NotFound` | `tool` |
| `not_found` | `NotFound` | `deleted: true` on a tombstone |
| `rbac_denied` | `RbacDenied` | — |
| `capped` | `Capped` | `cap` |

Live examples of three reasons:

```json
{ "code": -32602, "message": "Unknown tool: no_such_tool",
  "data": { "reason": "unknown_tool", "tool": "no_such_tool" } }
```

```json
{ "code": -32602, "message": "Unknown argument 'aggregate' for tool 'list_documents' (accepted: doctype, domain, expand, fields, filters, items, page, parent_id, scope, sort)",
  "data": { "reason": "unknown_argument", "argument": "aggregate", "tool": "list_documents" } }
```

```json
{ "code": -32603, "message": "Argument 'ops' must hold between 1 and 25 entries (got 26)",
  "data": { "reason": "capped", "cap": 25 } }
```

A validation failure on a write carries the per-field errors in
`data.details`.

## Example

The request:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "list_documents",
    "arguments": {
      "domain": "clients",
      "doctype": "Company",
      "filters": { "city__eq": "Lyon" },
      "sort": ["-created_at"],
      "page": 1
    }
  }
}
```

The payload rides in `result.structuredContent`; the same payload also rides
as a JSON string in `result.content[0].text`:

```json
{
  "data": [
    {
      "data": { "name": "Maison Lumière", "city": "Lyon" },
      "meta": {
        "id": "06H1FM1B3MXBPS0JYVM3BDD154",
        "domain": "clients",
        "doc_type": "Company",
        "mid": "06H1FM1B3MWR784V64VP6QFM94",
        "version": 1,
        "created_at": "2026-11-26T12:24:08Z",
        "updated_at": "2026-11-26T12:24:08Z",
        "display_name": "Maison Lumière"
      }
    }
  ],
  "meta": { "total": 1, "page": 1, "items": 1, "truncated": false, "next_cursor": null }
}
```

`truncated: false` with `next_cursor: null` is a final page. A page cut by
the row or byte cap sets `truncated: true` and `next_cursor` to the next
page number.

A tombstone read names the deletion without revealing anything else:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "error": {
    "code": -32602,
    "message": "Document clients.Company#06H1FRV45MM80SVH32K5JCA6BH not found (deleted)",
    "data": { "reason": "not_found", "deleted": true }
  }
}
```

The full generated list of tools, parameters, and access classes lives in
[the agent tools reference](/reference/agent-tools/).

## Troubleshooting

**The answer is `unknown_argument`.**

A key no handler reads — check the tool's `inputSchema` from `tools/list`.

**A listed tool answers `rbac_denied`.**

Listing is visibility; the role still gates the call. Check `whoami` for
the permission lines.

**Results stop with `truncated: true`.**

Fetch the page `next_cursor` names. The cut is a cap, not a failure.

**`NotFound` for a document you can see elsewhere.**

Row scope or non-disclosure. Check `whoami`; tombstoned and invisible
documents give the same answer.

## Related

- [Connect agents over MCP](/build/apps/agents/mcp/) — the surface that serves this catalogue.
- [Use the REST API](/build/apps/data/rest-api/) — the same filters and errors over HTTP.
- [Search from an app](/build/apps/data/search/) — the corpus `search_documents` fans out over.
- [Agent tools reference](/reference/agent-tools/) — the full generated list.
- [AI under the caller's rights](/discover/how-it-works/assistant/) — the rights model.
