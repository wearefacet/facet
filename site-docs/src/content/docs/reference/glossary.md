---
type: reference
title: Glossary
description: One short definition per term used across the Facet documentation, in alphabet order.
audience: [evaluator, user, author, admin, developer, operator]
features: []
sidebar:
  order: 1
verified_at: 7a6cb462
---

## Terms

**Auth context** — the identity and rights bundle for one request: who calls,
the one elected role, and the app grant when an app calls.
→ [Architecture at a glance](/discover/how-it-works/)

**Backlink** — the record of another document that references this one. The
show page lists them under "Referenced by".
→ [backlinks doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/links.md)

**Domain** — a namespace for one business area, such as `hr` or `sales`. It
groups doctypes and bounds rights and portability.
→ [Domains, drafts and domain editors](/build/model/in-app/drafts-and-publishing/)

**Doctype** — a typed record type inside a domain, such as `hr.Employee`. Its
definition declares the fields, the actions, and the row scopes.
→ [Designing doctypes](/build/model/data/design-doctypes/)

**Document** — one record: a JSON document with a unique id, a current state,
and a full history of changes.
→ [Designing doctypes](/build/model/data/design-doctypes/)

**Draft** — a throwaway draft domain, with an id that starts with `_`, where
you iterate on doctypes before you publish them to the live domain.
→ [Domains, drafts and domain editors](/build/model/in-app/drafts-and-publishing/)

**Elected role** — the one role a caller acts under for a request. Roles never
merge.
→ [Security & governance overview](/discover/security/)

**Grant** — explicit consent. An app grant says what an external app may do. A
domain grant lets one domain read named resources of another domain.
→ [Security & governance overview](/discover/security/)

**Mutation** — one appended row in the log: who changed which document, how,
when, and why. Create, update, delete, and snapshot are mutations.
→ [Architecture at a glance](/discover/how-it-works/)

**Permission line** — one rule inside a role: an action, a doctype path, and
optional row scopes and exceptions.
→ [Security & governance overview](/discover/security/)

**Projection** — the current state of a document: content, display name,
search text, and backlinks. Reads use projections; the log stores history.
→ [Architecture at a glance](/discover/how-it-works/)

**Scope** — a named row predicate on a doctype, such as `$mine` or `$global`.
A permission line references scopes to limit the rows it covers.
→ [Security & governance overview](/discover/security/)

**Sidecar** — a doctype that attaches to any document through a reference
field, like a comment. It is not a composition child of the host.
→ [sidecar doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/sidecar.md)

**Tag** — a label on a field. A role must hold the tag to see the field, and a
domain grant flows a field when the tag matches.
→ [Security & governance overview](/discover/security/)

**View template** — a saved template that defines how the show page of a
doctype renders: the header, the tabs, the fields, and the relation tables.
→ [document-view doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/frontend/document-view.md)

**Webhook** — an outbound registration that delivers a signed event envelope
to your URL on every mutation of a doctype.
→ [webhook doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/webhook.md)

## Related

- [What is Facet](/discover/why-facet/)
- [Architecture at a glance](/discover/how-it-works/)
- [Security & governance overview](/discover/security/)
