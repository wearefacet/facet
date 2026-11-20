---
title: Relations
description: How documents relate — child documents listed through parent_id, qualified reference values, and the membership recipe for many-to-many links such as company and contact.
tags: [relations, children, references, filters]
surfaces: [workspace, mcp]
---

# Relations

Documents relate in two ways:

- A **child** doctype hangs off one parent document. The link is the
  system `parent_id` in the child's meta.
- A **reference** field points at another document. The stored value is
  a qualified id: `domain.Doctype.id`, for example `crm.Contact.01J...`.

## Read the relation from the schema

`get_schema` shows both sides:

- The parent side lists `children` — each entry maps a relation name to
  the child doctype.
- The child side shows `member_of` — the doctype of the parent. A schema
  without `member_of` has no parent.

## List the children of one document

Pass `parent_id` with the parent document id. It is a top-level
argument, not a filter:

    list_documents(domain, CompanyMembership, {"parent_id": "<company id>"})

`aggregate_documents` accepts `parent_id` the same way. Filters, sort,
and paging combine with it. The parent must be readable by the user —
otherwise the call answers not-found, the same as any denied read.

## Follow a reference

The bare id is the part after the second dot of the qualified value.
Read the target document with `get_document` — it takes the bare id
plus the target domain and doctype.

To resolve several references at once, pass the reference field names
in `expand` on `list_documents` or `get_document`. Rows keep their ids;
a `resolved` map rides next to `data`, keyed by URN:

    list_documents(domain, CompanyMembership, {"parent_id": "<company id>", "expand": ["contact"]})

Each entry carries `{id, domain, doc_type, display_name, data}` of the
target document, masked to the caller's field visibility. Denied or
deleted targets are absent — the same non-disclosure as a direct read.
For reference values gathered elsewhere (inline links from longtext
fields, `links` entries), `resolve_refs` takes any list of URNs.

## Ask the inverse question

`get_backrefs(domain, doctype, doc_id)` answers "which live documents
point at this one?" — across every doctype the user can read, in one
call. Use it before proposing a delete: the rows it returns are what
would dangle. `get_links` answers the outbound direction (what this
document points to); `get_backrefs` answers the inbound one.

## The membership recipe (many-to-many)

Two aggregate roots link N-N through a join child, one row per pair
(`CompanyMembership` between `Company` and `Contact`). The join row has
one parent and one reference.

Contacts of one company:

1. `list_documents(domain, CompanyMembership, {"parent_id": "<company id>"})`
2. Read each row's `contact` reference as in "Follow a reference".

Companies of one contact:

1. `list_documents(domain, CompanyMembership, {"filters": {"contact__eq": "crm.Contact.<contact id>"}})`
2. Each row's meta carries `parent_id` — the id of the company document.

Tool meta exposes `parent_id` on every child document, so a join row
always answers "who is my parent".
