---
title: Longtext
description: "Writing longtext fields — markdown that renders live content. Document capsules, file links, images, and mermaid diagrams, the traps that break a capsule, and the verify step."
tags: [longtext, markdown, links, urn, images, mermaid]
surfaces: [workspace, mcp]
---

# Longtext

A `longtext` field holds markdown: headings, lists, tables,
blockquotes, fenced code, mermaid diagrams. Some markdown renders as
live content, and that live content rides on `urn:facet:` URNs. A
longtext field is the only place where you write a URN yourself —
every other field takes a plain value (a reference field takes a
qualified id `domain.Doctype.id`, never a URN; see the `relations`
skill).

## What renders as live content

| Markdown | Renders as |
| --- | --- |
| `[label](urn:facet:domain:Doctype:id)` | document capsule — opens the document |
| `[filename](urn:facet:artifact:id)` | file capsule — downloads the file |
| `![](urn:facet:artifact:id)` | image, served by the download gateway |
| ` ```mermaid ` fenced block | the diagram, rendered for every reader |
| everything else | static text — headings, lists, tables, code fences |

## Link a document

1. Resolve the target: `search_documents`, `list_documents`, or
   `get_document`.
2. Write the link. Build the URN from the row you resolved —
   `urn:facet:` + domain + doctype + bare id. Use an id from a tool
   result. Never invent one.

       [Acme Ltd](urn:facet:crm:Company:01J5X...)

The capsule shows the target's live display name. The stored label is
a fallback — it shows only when the target is deleted or
unresolvable. So a short label is fine.

## Link a file or image

First get an artifact id: mint one with `request_artifact_upload` and
upload the bytes over the signed URL it returns (the `artifacts` skill
has the full loop — your surface serves it when it serves the tools).
Then link the id inside the longtext:

    [report.pdf](urn:facet:artifact:01J5X...)

An image goes in as an image link:

    ![](urn:facet:artifact:01J5X...)

The link keeps the artifact alive. An upload that no document links is
swept by prune after the retention window.

## Draw a diagram

A fenced block with the `mermaid` language renders as a diagram:

    ```mermaid
    graph TD
      A[Order received] --> B{In stock?}
      B -- yes --> C[Ship]
      B -- no --> D[Backorder]
    ```

Write the whole diagram in one fence. A broken diagram shows an error
card; the source stays in the document, so a fix is a normal edit.
Keep diagrams small — a reader scrolls past them in the field body.

## Three traps

- **A bare URN is a dead capsule.** A `urn:facet:` token written as
  plain text still counts as a link on the server, but the editor
  renders it as plain text. Always wrap it: `[label](urn:facet:...)`.
- **No state pin.** A URN with `?state=` names a historical version,
  not the live document. It renders as a plain link, not a capsule.
  Link to the live document.
- **A mention is not a notification.** An `iam.Account` URN renders as
  a mention chip. In a comment sidecar a mention notifies the account;
  in a plain longtext field it does not.

## Verify

After a write that adds links, confirm they landed:

- `resolve_refs` with the URNs you wrote — every URN must resolve. A
  URN that does not resolve names a document that does not exist. Fix
  the id.
- `get_links` on the document — your URNs must appear in `data`.
- `list_artifact_refs` on the artifact — the document must appear.
