---
title: Search from an app
description: Find documents across doctypes with one ranked, label-only search call.
type: how-to
audience: [developer]
features: [DOC-06]
verified_at: eee55a2
sidebar:
  order: 2
---

Search answers one term with one ranked response. It reads every searchable
doctype the credential can read, inside one domain or across the whole
application. It returns labels only, never document content. The Facet
command palette calls this endpoint; your app can call it too.

> **For agents:** `GET /Api/<domain>/search?q=<term>` (one domain) or `GET /Api/search?q=<term>`
> (whole application). One parameter `q`; a term shorter than 2 characters answers `200` with an
> empty result, never an error. Hits arrive in per-doctype groups in rank order; each hit carries
> `id`, `display_name`, `rank`, `root_doctype`, `root_id`, `root_display_name`, `child_label` —
> labels only, no content. Fetch the document by `root_id` (or `id`) to read content. QUERY form:
> `-X QUERY` with `{"q": "<term>"}` in a JSON body; any query-string parameter answers `422`.

## When to use this

Reach for search when:

- You build a command-palette-style picker or a global find box.
- You need documents of several doctypes from one term.
- You must match documents without knowing their doctype first.

To filter one known doctype, use the list filters instead — see
[Use the REST API](/build/apps/data/rest-api/).

## Before you start

- A credential with a read grant on the doctypes you expect to match. A
  doctype without a read grant contributes nothing to the response.
- A doctype joins search only when its definition declares a non-empty
  `search` template. Internal doctypes stay out by not declaring one.
- On the raw list API, a doctype with no template still matches by its label
  through the bare `search` filter — see
  [Use the REST API](/build/apps/data/rest-api/).

The examples run against a dev instance at `https://facet.localhost:3443`
with the Brightwater Rentals data loaded. Sign in first and issue an API
key — see [Use the REST API](/build/apps/data/rest-api/) for both calls —
and keep it in a variable:

## Steps

### 1. Pick the scope

Two routes exist, each with a GET and a QUERY form:

| Route | Scope |
| --- | --- |
| `GET /Api/clients/search` | One domain. |
| `GET /Api/search` | The whole application. |

The app-wide route runs one query per storage group and merges the results
by rank. An unknown domain answers `404`. A draft domain answers `200` with
an empty result and is excluded from the app-wide route:

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/clients/search?q=Lumière'

curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/search?q=Lumière'
```

### 2. Send the term

One parameter exists: `q`. A term shorter than 2 characters after strip, or
a missing term, answers `200` with an empty result — never an error. Gate
the same way in the client before you call.

The `QUERY` form carries `q` in a JSON body only:

```sh
curl -sk -X QUERY 'https://facet.localhost:3443/Api/clients/search' \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "q": "Lumière" }'
```

Any query-string parameter on a `QUERY` request answers `422`. A body with a
non-JSON `Content-Type` answers `415`.

### 3. Read the response

The app-wide search for `Lumière` over the Brightwater data answers:

```json
{
  "data": [
    {
      "domain": "clients",
      "doctype": "Company",
      "hits": [
        {
          "id": "06H1FM1B3MXBPS0JYVM3BDD154",
          "display_name": "Maison Lumière",
          "rank": 0.4444444477558136,
          "root_doctype": "Company",
          "root_id": "06H1FM1B3MXBPS0JYVM3BDD154",
          "root_display_name": "Maison Lumière",
          "child_label": null
        }
      ]
    },
    {
      "domain": "clients",
      "doctype": "Contact",
      "hits": [
        {
          "id": "06H1FM1C1MN3MMVH7KH5H8THSA",
          "display_name": "Marc Dubois",
          "rank": 0.24242424964904785,
          "root_doctype": "Company",
          "root_id": "06H1FM1B3MXBPS0JYVM3BDD154",
          "root_display_name": "Maison Lumière",
          "child_label": "Marc Dubois"
        },
        {
          "id": "06H1FM1BZW99TG47BEJ2H1D73T",
          "display_name": "Claire Fontaine",
          "rank": 0.24242424964904785,
          "root_doctype": "Company",
          "root_id": "06H1FM1B3MXBPS0JYVM3BDD154",
          "root_display_name": "Maison Lumière",
          "child_label": "Claire Fontaine"
        }
      ]
    },
    {
      "domain": "rentals",
      "doctype": "Booking",
      "hits": [
        {
          "id": "BK-2026-0001",
          "display_name": "Maison Lumière",
          "rank": 0.190476194024086,
          "root_doctype": "Booking",
          "root_id": "BK-2026-0001",
          "root_display_name": "Maison Lumière",
          "child_label": null
        }
      ]
    }
  ],
  "meta": { "q": "Maison", "count": 5, "domain": null }
}
```

| Field | Meaning |
| --- | --- |
| `id`, `display_name` | The matched row: its id and its label. |
| `rank` | Match score; the server sorts by it, descending. |
| `root_doctype`, `root_id`, `root_display_name` | The root document the hit anchors to. |
| `child_label` | The matched child's own label on a child hit; `null` on a root hit. |
| `meta.q` | The term as received. |
| `meta.count` | The number of hits in the response. |
| `meta.scope` | `domain` or `app`. |

Every hit anchors to a root document. A hit on a root doctype anchors to
itself. A hit on a composition child anchors to the aggregate root, so the
app can always open the page behind the hit. The two Contact hits above both
anchor to Maison Lumière — collapse them in the client, with the top-ranked
child as the subtitle.

Only doctypes with a read grant contribute. A child hit drops when its root
is unreadable, deleted, or the chain breaks. Nothing reaches the client that
the credential cannot open. Tom sees only his five companies; a search that
would match another company answers without it.

Caps are server constants, not request parameters:

| Constant | Value | Purpose |
| --- | --- | --- |
| `MIN_TERM_LENGTH` | 2 | Shorter terms answer empty. |
| `PER_DOCTYPE_CAP` | 5 | Matches per doctype group. |
| `OVERALL_CAP` | 25 | Hits in the response. |
| `MAX_COMPOSITION_DEPTH` | 8 | Child-to-root walk bound. |

### 4. Fetch the documents

Hits carry labels only, never content. Fetch the content with a document
read on `root_id`, or on `id` when the hit is the root:

```sh
curl -sk -H "Authorization: Bearer $NADIA_KEY" \
  'https://facet.localhost:3443/Api/clients/Company/06H1FM1B3MXBPS0JYVM3BDD154'
```

See [Use the REST API](/build/apps/data/rest-api/) for the document envelope.

## Example

One fetch renders the labels for a find box:

```ts
const response = await fetch('https://facet.localhost:3443/Api/search?q=Lumière', {
	headers: { Authorization: `Bearer ${process.env.FACET_API_KEY}` }
});
if (!response.ok) throw new Error(`search failed: ${response.status}`);

const { data } = await response.json();
for (const group of data) {
	for (const hit of group.hits) {
		console.log(hit.root_display_name, hit.rank);
	}
}
```

## Troubleshooting

**Empty results for a term you know exists.**

Four causes answer empty, never an error: the doctype declares no `search`
template; the term is shorter than 2 characters after strip; the rows are
deleted; or the credential holds no read grant on the doctype.

**The app-wide search misses a whole domain.**

A draft domain is excluded from the app-wide route. A domain-scoped call on
a draft domain also answers empty.

**An unknown domain answers `404`.**

The route checks the domain before it queries. The `404` is non-disclosing.

**The hits carry no content.**

By design: labels only. Fetch each document by `root_id` or `id` (step 4).

## Related

- [Use the REST API](/build/apps/data/rest-api/) — the list filters behind one doctype.
- [What agents can do](/build/apps/agents/agent-tools/) — the `search_documents` tool for agents.
- Internals on GitHub:
  [search.md](https://github.com/wearefacet/facet/blob/main/doc/backend/search.md).
