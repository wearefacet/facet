---
title: Documents Workflow
description: The discover → inspect → query → act loop for document work, with the label, refusal, and delete discipline that comes with it.
tags: [workflow, documents]
surfaces: [workspace, mcp]
---

# Documents Workflow

The dependable loop for document work: discover → inspect → query →
act → verify.

## The loop

1. **Discover.** `list_domains`, then `list_doctypes(domain)` to find
   the doctype the user means. Never guess a doctype name from context
   alone.
2. **Inspect.** `get_schema(domain, doctype)`. Read the fields, their
   required-ness, the named actions with their typed arguments, and the
   named scopes. Do this before the first filter, create, update, or
   action of a conversation.
3. **Query.** When you do not know where something lives,
   `search_documents(query)` first — it searches every readable doctype
   at once and returns stub rows with domain and doctype. Then
   `list_documents` with `{"filters": {"search": ...}}` for free text,
   or `field__op` keys for precision (see `filter-grammar`).
   `get_document` for one known id. Trim output with `fields` (project
   each document to the fields you need) and `expand` (resolve reference
   targets in the same call).
4. **Act.** `create_document` sends the full content.
   `update_document` sends a patch — only the fields that change.
   `call_action` runs a named action from the schema, with its typed
   `args`. `delete_document` only on an explicit user request (see
   below). A `file` field takes an artifact id: mint one with
   `request_artifact_upload`, transfer the bytes over the signed URL it
   returns, then put the id in the field (the `artifacts` skill has the
   full loop — your surface serves it when it serves the tools).
5. **Verify.** `get_document` to confirm the write. Offer
   `list_mutations` when the user asks what changed.

The system rejects invalid content with a field-by-field details array —
fix the named fields, not the whole payload.

## Labels

- Name documents by their label. Every tool result carries the label in
  `meta.display_name` — the doctype's computed display name. `null` means
  the doctype declares no template: fall back to the first non-empty of
  the `name`, `title`, or `label` content fields, then to the id. Use
  the label in prose; pass ids inside tool arguments.

## Refusals

- A read that answers "not found" means the document does not exist or
  the user cannot read it. Say that, and stop.
- A write that answers "refused" (or `Forbidden`) means the user's role
  cannot perform it. Do not retry with other tools, and do not try to
  smuggle the change through another path — there is none.
- Both denials are terminal. The correct move is a plain report and a
  question about what the user wants instead.

## Deleting

- Delete only when the user asked for deletion, not for any other goal.
- Name the exact document (`domain.doctype.id`) in your confirmation.
- A deleted document is a tombstone: recoverable, but gone for users.
  If the user asked to "empty a field", that is `update_document` with a
  null or cleared value, never a delete.
