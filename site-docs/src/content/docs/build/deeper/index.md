---
type: overview
title: How it works (deeper)
description: The four pages that explain the engine behind building — domains, storage, schema changes, and cross-domain copies.
audience: [author, developer]
features: []
sidebar:
  order: 0
verified_at: eee55a2
---

The pages in this group explain the machinery under the Builder. They use
the engine's own words — projection, mutation, lazy migration — and define
each one. Read them when a how-to page says "see the deeper page", or when
a behaviour surprises you and you want the reason.

Each topic also has a plain-language half in [How Facet
works](/discover/how-it-works/) — same facts, no engine words.

## The four pages

- [How domains stay isolated](/build/deeper/domain-isolation/) — what a
  domain owns, what crosses a boundary, and what gates it.
- [How a document is stored](/build/deeper/documents-and-projections/) —
  doctype, document, projection: the three parts of every record, and the
  ETag.
- [How old documents follow a new schema](/build/deeper/schema-evolution/)
  — lazy migration: why there is no backfill job, and what it costs.
- [How copied fields stay in sync](/build/deeper/cross-domain-replication/)
  — the one-hop copy behind a `replicate` field, and the grant that gates
  it.

## Related

- [Build domains](/build/) — the how-to half of this tab.
- [Choose how you build](/build/model/index/) — the two build modes these pages sit under.
