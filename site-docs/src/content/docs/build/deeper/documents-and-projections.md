---
type: explanation
title: Documents, doctypes and projections
description: Learn how a doctype shapes a document, how writes maintain the projection, and what the ETag means.
audience: [author, developer]
features: [DOC-01, DOM-03, DOM-23]
sidebar:
  order: 1
verified_at: eee55a2
---

Facet splits a record into three parts. The doctype declares the shape. The
document holds the data. The projection keeps the state that reads use. Read
this page to see how the three parts connect, and what the design costs. The
plain-language half is [Documents: records with a
memory](/discover/how-it-works/documents/).

## The three parts

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
cycle: `POST` creates, `GET` reads, `PATCH` merges, `DELETE`
soft-deletes, and a restore route brings a deleted document back. An update
stores only the computed diff, never the full body.

**Identity is three-part.** A document row is unique per domain, doctype,
and id: `equipment.Item` in two domains are two different record types, and
the same id under both is two different documents. That is why a bundle can
rename its whole domain on import (`--into`) without colliding.

**The projection is the readable state.** Every write appends one row to the
mutation log. A PostgreSQL trigger applies that row to the projection in the
same transaction. The projection holds the content, the display name, the
search text, and the backlinks. Reads never parse the log. They read the
projection, with the caller's row scopes applied as SQL.

**The last mutation id is the ETag.** Each projection row stores the id of
its last mutation in its `state` column — an id, not a status string. A
single-document read returns that value as the `ETag` response header — a
version tag for the response. Send it back with `If-None-Match`, and an
unchanged document answers `304 Not Modified`. A different ETag on a later
read means another write landed in between. Concurrent writers to one
document are serialized by row locks; the remaining race answers `409`, and
the client retries the same request.

## Derived columns

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

**How the trigger gets the values.** The write path renders the templates
and hands the results to the trigger through transaction-local settings. The
display name, the search corpus, and the link edges ride with the mutation
row; the trigger only writes what was staged. A row written with
nothing staged stores empty derived columns, which is why every raw write
path must stage them first.

**Templates render on every write.** A document written before a template
change keeps its old values until the next write lands on it.

:::caution
Changing a `display_name` or `search` template does not re-project the
documents that already exist. Run `facet doctype:reproject <domain.Doctype>`
to back-fill every live document of the doctype.
:::

## What a delete leaves behind

A soft delete keeps the content, the links and the search text on the
tombstone — the deleted document's row survives with its payload. The trash
listing can still show the row. A delete event that reaches a live
subscription is still checked against the reader's rules. The label
(`display_name`) survives even longer: audit views use it
to name a deleted row.

A cron job clears the retained payload after a configured window —
`tombstone.content_retention_days`. That is storage cleanup only. The
append-only history is the replay source, so a rollback to a delete
mutation restores the document even after the payload is gone.

## The trade-offs

**The projection copies content for read speed.** One indexed row lookup per
document. Every write pays for it — the log append, the projection update,
and the derived columns.

**Two places for one shape.** The derived logic lives in templates, away from
the field definitions, so a doctype author maintains two places for one shape.

**Recent edits can fold into one history row.** Writes from the same person
and channel inside a short window are stored as one change. A burst of form
saves therefore does not bury the history. The projection's ETag changes
nevertheless — every write is a new version. The change-log page has the
detail: [The change log](/admin/under-the-hood/change-log/).

## Related

- [Designing doctypes](/build/model/data/design-doctypes/) — how to declare fields, actions and templates.
- [Documents: records with a memory](/discover/how-it-works/documents/) — the same story, no engine words.
- [How old documents follow a new schema](/build/deeper/schema-evolution/) — what happens to stored documents when a definition changes.
- [The change log](/admin/under-the-hood/change-log/) — the append-only history behind every projection.
- Internals on GitHub: [document.md](https://github.com/wearefacet/facet/blob/main/doc/backend/document.md), [doctype-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/doctype-system.md), [templating.md](https://github.com/wearefacet/facet/blob/main/doc/backend/templating.md).
