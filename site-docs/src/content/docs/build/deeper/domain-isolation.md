---
type: explanation
title: How domains stay isolated
description: What a domain owns, what crosses a boundary, and the two consents that keep domains isolated.
audience: [author, developer]
features: [DOM-01, DOM-14]
sidebar:
  order: 4
verified_at: eee55a2
---

A domain is the unit of ownership and the unit of isolation. It holds one
business area, and nothing inside it leaves on its own. This page is the
full mechanism: what a domain owns, what crosses a boundary, and the two
consents that open it. The plain-language half of
this story is [Domains: where your data
lives](/discover/how-it-works/domains/).

## What a domain owns

<!-- d2
direction: down
call: "A call reaches into a domain" {class: external}
same: "Same domain?" {class: decision}
free: "Runs under the caller's roles" {class: ok}
consent: "Explicit consent held?" {class: decision}
api: "Role permission for the foreign doctype" {class: ok}
grant: "Active grant covers the tags" {class: ok}
refused: "Refused" {class: danger}

call -> same
same -> free: "yes"
same -> consent: "no — foreign domain"
consent -> api: "document API"
consent -> grant: "replication, hooks, Lua"
consent -> refused: "neither"
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/7955fcf2-light.svg" alt="A call reaches into a domain" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/7955fcf2-dark.svg" alt="A call reaches into a domain" loading="lazy" />
</div>

A domain is one `core.Domain` document, and its id is the domain name. That
id is the first segment of a compound identity. A document is addressed by
its domain, its doctype, and its id; a doctype is addressed as
`equipment.Item`. The projection store keys rows by the `(domain, doctype)`
pair, so two domains can each hold an `Item` without any collision.

The domain owns:

- **its doctype definitions** — registering a doctype into a domain that
  does not exist answers `422`,
- **their view templates** — the document pages and the shared list views,
- **the hooks declared on the domain document**,
- **the grants it issues** to other domains,
- **its draft state** — a draft domain is a separate `_`-prefixed identity.

The domain is also the unit of portability: export and import move exactly
one domain.

## Two consents open the boundary

By default, data does not cross. A call from outside needs one of two
explicit consents, depending on the surface:

| Surface | Consent | What it allows |
| --- | --- | --- |
| The document API | A role permission that names the foreign doctype | Reading, and writing where the role allows, under the caller's own roles |
| The automation surfaces — replication fields, hooks with a foreign source, Lua `document.get` / `document.list` | An active domain grant | Reading the covered fields of the producer's documents |

Same-domain edges skip both consents. A domain reading itself is not a
sharing decision.

## What a grant shares

A grant is one data-sharing contract, stored as a document **under the
producer domain** — consent belongs to the party that gives the data. One
grant covers one consumer domain; the pair is unique. It names resources:
one entry per producer doctype, and each entry carries field tags.

- **Read-only.** No write grant exists. The door stays shut by design.
- **Tag grain, not field grain.** Tags are free-form labels on fields.
  Untagged fields count as the tag `default`, so an entry naming `default`
  reaches every untagged field. A new untagged field therefore flows
  through grants that already name `default`.
- **Projection, not disclosure.** When a covered value crosses — into a
  hook's content, a Lua read, or a replica — the server reduces the
  document to the covered fields first. Fields outside the contract never
  leave the producer.
- **Grant ≠ role.** A grant works at tag grain for the *domain*. A Lua
  script in the consumer domain reads the covered fields even when the
  human who triggered the script cannot read them over the API. Grant a
  tag to a domain with that in mind.

## The four gates

The grant is checked at four runtime points. All four fail closed:

| Gate | When it runs | Without coverage |
| --- | --- | --- |
| Registry build | At server start, after a grant or doctype change | The cross-domain binding is dropped; updates stop |
| Write-time pull | At consumer create, or when the reference field changes | The replica stays empty |
| Hook delivery | Before a foreign event reaches a hook | The hook never fires |
| Lua reads | On `document.get` / `document.list` with a foreign doctype | The read errors — catchable with `pcall` in Lua |

## The producer decides activation

A grant ships as a filed ticket with `active: false`. Activation is the
producer's right, all-or-nothing per grant — there is no per-doctype or
per-tag acceptance. Publish and import file these tickets. A publish files
them active only when the publisher holds the acceptance right. An import
always files them inactive, because the import is a system actor.

A merge that widens an active grant's resources drops the grant back to
inactive. A changed contract needs re-acceptance — silent widening would
bypass the producer's consent. A re-publish with no resource change touches
nothing.

## Drafts stay inside the sandbox

Grants never involve drafts. Both sides of every contract must be live
domains; a draft producer surfaces as a check diagnostic instead of a
ticket. The replication engine excludes drafts on both sides too — a draft
domain is never a replication source or a consumer. Inside the draft
everything is rehearsal: publish copies the structure, relinks the
same-domain reference targets to the live name, and drops the draft. See
[How drafts work](/build/model/in-app/how-drafts-work/).

## Dropping a domain

Dropping a domain is one transaction. The definitions, the domain document,
its data, and its view and index rows go together. The audit log keeps
a `delete` record of who dropped it. Two refusals guard the operation. The
system domains — `core`, `iam`, `app` — cannot be dropped. A live domain
with an open draft cannot be dropped until the draft is discarded. The
generic document delete route answers `422` for a domain; the drop route is
the only door.

References from other domains that pointed at the dropped domain's
documents dangle. That is the same accepted behaviour as deleting any
referenced document.

## The trade-offs

**Grants couple domains.** The consumer reads live data, so it depends on
the producer's contract. Deactivate the grant, and the copies stop
updating. Narrow the tags, and the values already copied stay where they
are — no job sweeps them out. Activate again, and the next source event
re-pushes the value.

**Hard isolation costs duplication.** When the coupling costs more than
the copy, duplicate the field and keep the domains fully independent. Both
options are first-class.

## Related

- [Domains: where your data lives](/discover/how-it-works/domains/) — the same story, no engine words.
- [How copied fields stay in sync](/build/deeper/cross-domain-replication/) — the copy mechanism the grant gates.
- [How access is enforced](/admin/under-the-hood/how-access-is-enforced/) — the role checks behind the document API.
- [Drafts, editors and publishing](/build/model/in-app/drafts-and-publishing/) — the draft lifecycle the sandbox protects.
- Internals on GitHub: [domain-grants.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md), [draft-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/draft-domains.md).
