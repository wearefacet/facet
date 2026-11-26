---
type: explanation
title: Documents, doctypes and projections
description: Learn how a doctype shapes a document, how writes maintain the projection, and what the ETag means.
audience: [author, developer]
features: [DOC-01, DOM-03, DOM-23]
sidebar:
  order: 1
verified_at: 7a6cb462
---

Facet splits a record into three parts. The doctype declares the shape. The
document holds the data. The projection keeps the state that reads use. Read
this page to see how the three parts connect, and what the design costs.

## Explanation

<!-- d2
definition: "Doctype: the schema"
document: "Document: one JSON instance"
log: "Mutation log: append-only" {class: store}
projection: "Projection: current readable state"
content: "content: the stored JSON"
display: "display_name: label from a template"
search: "search: corpus from a template"
links: "links: reference edges"

definition -> document: shapes
document -> log: write
log -> projection: trigger
projection -> content
projection -> display
projection -> search
projection -> links
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/45bce05b-light.svg" alt="Doctype: the schema" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/45bce05b-dark.svg" alt="Doctype: the schema" loading="lazy" />
</div>

**The doctype is the schema.** A doctype is a typed record type inside a
domain, such as `hr.Employee`. Its definition declares the fields and their
types, the named actions, the row scopes, and the child relationships. The
definition is itself a document — `core.DocType` — so you register and
version it through the same pipeline as any other record.

**The document is the data.** A document is one JSON instance of its
doctype. PostgreSQL stores it as JSONB. The document routes give the full
cycle: `POST` creates, `GET` reads, `PATCH` deep-merges a patch, `DELETE`
soft-deletes, and a restore route brings a deleted document back. An update
stores only the computed diff, never the full body.

**The projection is the readable state.** Every write appends one row to the
mutation log. A PostgreSQL trigger applies that row to the projection in the
same transaction. The projection holds the content, the display name, the
search text, and the backlinks. Reads never parse the log. They read the
projection, with the caller's row scopes applied as SQL.

**The last mutation id is the ETag.** Each projection row stores the id of
its last mutation in its `state` column. A single-document read returns that
value as the `ETag` response header — a version tag for the response. Send it
back with `If-None-Match`, and an unchanged document answers `304 Not
Modified`. A different ETag on a later read means another write landed in
between. Concurrent writers to one document are serialized by row locks; the
remaining race answers `409`, and the client retries the same request.

### Derived columns

Two of the projection's columns come from Jinja2 templates on the doctype.
Jinja2 is a template language from the Python ecosystem; Facet renders it in
Crystal, at mutation time.

| Column | Example template | What it holds |
| --- | --- | --- |
| `display_name` | `"{{ first_name }} {{ last_name }}"` | The document's label, truncated to 255 characters |
| `search` | `"{{ first_name }} {{ last_name }} {{ email }}"` | The search corpus, folded and truncated to 256 characters |

In a `display_name` template, a reference field resolves to the target
document's stored label, and a money field renders as `USD 120000`. The third
derived column, `links`, has no template. The write path walks the reference
fields and records the edges; the show page lists them as backlinks.

**Templates render on every write.** A document written before a template
change keeps its old values until the next write lands on it.

:::caution
Changing a `display_name` or `search` template does not re-project the
documents that already exist. Run `facet doctype:reproject <domain.Doctype>`
to back-fill every live document of the doctype.
:::

**The trade-off.** The projection copies content for read speed: one indexed
row lookup per document. Every write pays for it — the log append, the
projection update, and the derived columns.

**Two places for one shape.** The derived logic lives in templates, away from
the field definitions, so a doctype author maintains two places for one shape.

**Tombstones keep their payload for a while.** A soft delete keeps the
content, the links and the search text on the tombstone. The trash listing can
still show the row. A cron job clears that payload after the configured
retention window; only the label survives.

## Related

- [Designing doctypes](/build/model/data/design-doctypes/) — how to declare fields, actions and templates.
- [Build](/build/) — the how-to pages for authoring domains.
- [Schema evolution](/build/deeper/schema-evolution/) — what happens to stored documents when a definition changes.
- [The mutation log](/admin/under-the-hood/change-log/) — the append-only history behind every projection.
- Internals on GitHub: [document.md](https://github.com/wearefacet/facet/blob/main/doc/backend/document.md), [doctype-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/doctype-system.md), [templating.md](https://github.com/wearefacet/facet/blob/main/doc/backend/templating.md).
