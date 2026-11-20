---
title: Chat Etiquette
description: Putting results in front of the user in the chat — show_documents instead of pasting content, card versus inline display, and navigate targets.
tags: [ui, chat, workflow]
surfaces: [workspace]
---

# Chat Etiquette

How to put results in front of the user in the chat. These tools exist
only on the chat surface — their effect happens in the UI, not in the
document store.

## Showing documents

- `show_documents` instead of pasting content. Pass ids you actually
  received from a tool — the UI re-reads the documents itself, so a
  fabricated id renders nothing. The ack reports dropped ids in
  `skipped`; do not re-show those.
- `display`: `card` for one to a few documents the user should inspect,
  `inline` for compact rows inside prose.
- Show after a write you have verified with `get_document` — what the
  user sees must match the stored document.

## Navigating

- `navigate` after you finished something: open the document you edited,
  the collection you filled, or the domain the user should look at.
  Targets: `document` (`domain`, `doctype`, `id`), `collection`
  (`domain`, `doctype`, optional `view_slug`), `domain` (`domain`).
