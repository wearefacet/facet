---
type: how-to
title: Agent tools
description: Use the shared document tool catalogue that serves MCP clients and the assistant.
audience: [developer]
features: [AI-04, AI-06]
sidebar:
  order: 2
verified_at: a77c6171
---

One catalogue of document tools serves every agent surface. The MCP server and
the in-app assistant mount the same entries. Whichever surface calls, the
capabilities, the RBAC, the caps, and the error mapping are the same.

> **For agents:** Call tools with `tools/call` — connect per [MCP: connecting agents](/build/apps/agents/mcp/). Sequence:
> `tools/list` → `whoami` → `get_schema` before any write → `list_documents` with `field__op` filters →
> `create_document` / `update_document` (JSON merge patch; `null` removes a key) → `batch` (25 ops max). A filter
> key the doctype does not declare raises `InvalidParams` — never a silent empty result. Errors carry `data.reason`;
> caps: 200 rows, 1 MiB envelope, 25 batch ops. Files move over HTTP: `request_artifact_upload` mints a signed URL.

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

- Connect first — see [MCP: connecting agents](/build/apps/agents/mcp/). This page
  speaks MCP; the assistant mounts the same entries.
- Call `whoami` first: it returns the role, the permission lines, the scopes,
  and the visible tags. Fields whose tags fall outside `visible_tags` are
  absent from every result.

## The catalogue

`requires` is the permission line the role must hold for the tool to appear
in `tools/list`:

| Tool | `requires` | Purpose |
| --- | --- | --- |
| `ping` | none | Server identity and the mounted role. |
| `list_domains` | read | Live domains; drafts excluded. |
| `list_doctypes` | read | Doctypes of one domain. |
| `get_schema` | read | Full doctype definition: fields, actions, scopes, `member_of`, sidecars. |
| `whoami` | none | Identity, permissions, scopes, visible tags. |
| `list_documents` | read | Filtered, sorted, paginated list. |
| `aggregate_documents` | read | `count`, or `sum`/`avg`/`min`/`max` over an integer, duration, or money field. |
| `get_document` | read | One document by id; optional `expand` and `fields`. |
| `create_document` | write | Full-content create; `parent_id` creates a child. |
| `update_document` | write | JSON merge patch (RFC 7386); `null` removes a key. |
| `delete_document` | write | Soft delete — a tombstone. |
| `batch` | write | Ordered atomic ops in one transaction. |
| `call_action` | action | Named doctype action with typed args. |
| `create_sidecar` | write | Sidecar create on a host document's segment. |
| `list_sidecars` | read | One host's sidecar segment, paged. |
| `list_mutations` | read | Document history — or the whole log, for a wildcard reader. |
| `resolve_refs` | read | A batch of URNs resolved to stub rows. |
| `get_links` | read | The outbound document links of one document. |
| `get_backrefs` | read | The live documents that link to one document. |
| `search_documents` | read | Cross-doctype search; 5 matches per doctype. |
| `request_artifact_upload` | write | A one-time signed upload URL for a file. |
| `get_artifact` | read | A short-lived signed download URL. |
| `list_artifact_refs` | read | The live documents that reference one artifact. |

`read_skill` is not a catalogue entry. Each surface mounts its own loader; the
MCP mount serves short markdown references for these tools.

## Steps

### 1. List the tools and read the schema

`tools/list` returns the role-filtered listing. Visibility is a convenience
for the agent, never a boundary: enforcement runs at call time, exactly as on
REST. Read `get_schema` before any write. It carries the fields, the actions,
the scopes, the `member_of` parent link, and the host's sidecar segments.

### 2. List and read documents

`list_documents` takes `domain` and `doctype`, plus:

| Argument | Purpose |
| --- | --- |
| `filters` | `field__op` keys — `status__eq`, `salary__gte`, `name__match` |
| `sort` | field names; a `-` prefix sorts descending |
| `page`, `items` | pagination |
| `fields` | project each row's content to the named fields |
| `expand` | resolve reference fields into a `resolved` map |
| `scope` | apply a named row scope as a query-time filter |
| `parent_id` | list one parent's children; child doctypes only |

Filter keys validate against the doctype. An unknown key, or an operator the
field does not serve, raises `InvalidParams` — never a silent empty result.
`parent_id` gates through the parent's read scope, the same gate as the
nested REST route. An oversized result sets `meta.truncated: true` and
carries `next_cursor`; fetch that page next. Every row's `meta` carries
`display_name`. `aggregate_documents` runs under the same filters and caps.

### 3. Write documents

`create_document` takes the full content. A child doctype needs `parent_id`; a
child without it is refused. `update_document` takes a JSON merge patch: new
keys are set, and a `null` value removes the key. `delete_document`
tombstones the document. `batch` runs ordered `create`, `update`, `delete`,
and `action` ops in one transaction; a failure rolls the batch back and names
the op index.

### 4. Act, extend, and inspect

`call_action` runs a named action with typed args. `create_sidecar` and
`list_sidecars` work on one segment of one host document. `list_mutations`
answers a document's history; without a `doc_id`, it serves the whole log to
a wildcard reader. `resolve_refs`, `get_links`, and `get_backrefs` walk the
reference graph. `search_documents` fans a search term over every readable
doctype.

### 5. Move files over HTTP

No file bytes ride the tool channel:

1. Call `request_artifact_upload`. It returns a one-time signed upload URL.
2. POST the multipart `file` part to that URL.
3. Put the returned artifact id into a document.
4. Call `get_artifact` for a download URL, or `list_artifact_refs` to see
   where an artifact is used.

  See [Uploading and serving files](/build/apps/data/files/) for the HTTP side.

## Caps and errors

The caps come from the `mcp:` block: 200 rows, 1 MiB envelope, 25 batch ops —
see [MCP: connecting agents](/build/apps/agents/mcp/). An oversized result is cut,
not failed: it sets `meta.truncated` and `next_cursor`. Failures are JSON-RPC
errors:

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

A validation failure on a write carries the per-field errors in `data.details`.

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
      "domain": "crm",
      "doctype": "Contact",
      "filters": { "status__eq": "active" },
      "sort": ["-created_at"],
      "page": 1
    }
  }
}
```

The payload rides in `result.structuredContent`; the same payload also rides as
a JSON string in `result.content[0].text`:

```json
{
  "data": [
    {
      "data": { "name": "Ada Lovelace", "status": "active" },
      "meta": {
        "id": "01JE2W4G7Q2M8X3K5P9R2T4V6W",
        "domain": "crm",
        "doc_type": "Contact",
        "mid": "01JE2W4G7Q2M8X3K5P9R2T4V6X",
        "version": 1,
        "created_at": "2026-11-13T09:12:44Z",
        "updated_at": "2026-11-13T09:12:44Z",
        "display_name": "Ada Lovelace"
      }
    }
  ],
  "meta": { "total": 1, "page": 1, "items": 1, "truncated": false, "next_cursor": null }
}
```

`truncated: false` with `next_cursor: null` is a final page. A page cut by
the row or byte cap sets `truncated: true` and `next_cursor` to the next
page number.

A create:

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "tools/call",
  "params": {
    "name": "create_document",
    "arguments": {
      "domain": "crm",
      "doctype": "Contact",
      "content": { "name": "Grace Hopper", "email": "grace@example.com", "status": "active" }
    }
  }
}
```

The result carries the created content and the same meta shape, with a fresh
`id` and `mid`.

## Troubleshooting

**The answer is `unknown_argument`.**

A key no handler reads — check the tool's `inputSchema` from `tools/list`.

**A listed tool answers `rbac_denied`.**

Listing is visibility; the role still gates the call. Check `whoami` for the
permission lines.

**Results stop with `truncated: true`.**

Fetch the page `next_cursor` names. The cut is a cap, not a failure.

**`NotFound` for a document you can see elsewhere.**

Row scope or non-disclosure. Check `whoami`; tombstoned and invisible
documents give the same answer.

## Related

- [MCP: connecting agents](/build/apps/agents/mcp/) — the surface that serves this catalogue.
- [Use the REST API](/build/apps/data/rest-api/) — the same filters and errors over HTTP.
- [Search](/build/apps/data/search/) — the corpus `search_documents` fans out over.
- [AI under the caller's rights](/discover/how-it-works/assistant/) — the rights model.
- Internals on GitHub: [agent-tools.md](https://github.com/wearefacet/facet/blob/main/doc/backend/agent-tools.md).
