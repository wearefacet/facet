---
title: Concepts
description: How Facet thinks. Short explanation pages for the model behind the product.
audience: [evaluator]
features: []
sidebar:
  order: 0
verified_at: 7a6cb462
---

These pages explain how Facet works and why. Each one is short, leads with a
diagram or a table, and names the trade-offs. Read them when a how-to guide
assumes the model.

## In this section

- [Domains and isolation](/concepts/domains-and-isolation/) — what a domain bounds, and what a grant may cross.
- [Documents, doctypes and projections](/concepts/documents-doctypes-projections/) — the three parts of every record.
- [The mutation log](/concepts/mutation-log/) — why every write appends a row, and why this is not domain event sourcing.
- [Draft → publish](/concepts/draft-publish/) — edit a draft, then publish it in one transaction.
- [Auth contexts](/concepts/auth-contexts/) — one elected role on every channel.
- [Authorization enforcement](/concepts/authorization-enforcement/) — row scopes, field tags, and non-disclosing denials.
- [Roles, levels and the authority guard](/concepts/roles-levels-authority/) — who may edit roles, and who may not.
- [Apps: grants ∩ roles](/concepts/apps-grants-roles/) — the intersection that caps every app call.
- [Events and delivery guarantees](/concepts/events-delivery/) — at-most-once delivery, and the crons that repair it.
- [Schema evolution and lazy migration](/concepts/schema-evolution/) — documents migrate on their next read.
- [Cross-domain replication](/concepts/cross-domain-replication/) — one-hop, grant-gated field copies.
- [AI under the caller's rights](/concepts/ai-under-callers-rights/) — the assistant holds no permissions of its own.
