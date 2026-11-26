---
title: Cross-domain replication
description: A consumer domain can copy selected fields from another domain's doctype, one hop, behind a grant.
audience: [author, admin]
features: [DOM-25, DOM-14]
sidebar:
  order: 11
verified_at: 7a6cb462
---

A consumer doctype can copy a field from a source doctype that lives in
another domain. The copy is a local field on the consumer document, filled
from the source document it points at. Facet keeps the copy current through
the event bus. A domain grant controls what may cross the boundary.

## Explanation

<!-- d2
direction: down
change: "Source document changes"
bus: "Event bus"
handler: "Replication handler"
find: "Find consumer documents through the reference field"
read: "Read the current source value in PostgreSQL"
write: "Write the replica field on each consumer"
reentrant: "Consumer update emits a reentrant event"
skip: "The next handler skips it" {class: ok}

change -> bus
bus -> handler
handler -> find
find -> read
read -> write
write -> reentrant
reentrant -> skip
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/f1eb9af1-light.svg" alt="Source document changes" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/f1eb9af1-dark.svg" alt="Source document changes" loading="lazy" />
</div>

### How the copy works

The replica field on the consumer doctype carries a `replicate` config. It
names a local reference field (the `via`) and the source field to copy. On
create, or when the reference field changes, Facet pulls the initial value
from the source document. After that, every source change propagates. The
handler reads the source's current value from PostgreSQL. It compares that
value with each consumer's copy and writes only the difference.

**Replica fields are read-only.** You cannot write a replica field yourself.
The document write gate rejects the key, and the field cannot be `required` or
`unique`.

**The copy lags the source.** Delivery rides the event bus, so the copy lags
the source: it is eventually consistent. Delivery is at-most-once. A lost
update waits for the next change to the source document.

**Deletion follows a policy.** When a source document is deleted, the replica
follows the field's `on_source_delete` policy. `keep` (the default) leaves the
copied value in place. `unset` clears it on every referencing consumer.

### One hop

A replica never feeds another replica. The doctype validator checks the
definition when you save it. It rejects a replica used as a replication
source. It also rejects a `via` field that is itself a replica. At runtime, the
write that updates a replica carries a reentrant flag. A handler that receives
a reentrant event skips it. The chain stops at one hop, always.

### Grants gate the boundary

A cross-domain edge needs an active domain grant, stored under the producer
domain. The grant names the consumer domain and the producer resources it may
read, at tag grain. Facet re-checks coverage at two points:

| Check | When it runs | Without grant coverage |
| --- | --- | --- |
| Registry build | at server start, and after any doctype or grant change | the binding is dropped, so updates stop |
| Write-time pull | at consumer create, or when the reference field changes | the replica stays null |

Same-domain edges need no grant. A domain reading itself is not a sharing
decision.

**Revoking a grant stops the updates.** When the grant is revoked, the
registry drops the binding on its next rebuild. Updates stop. The values
already copied stay in place — no sweep deletes them. Reactivation does not
backfill. The next change to a referenced source document pushes its current
value into the copy. A consumer domain that gains its first binding late
replays the retained stream. History then fills the replicas within the
stream's retention.

:::caution
Deactivating a grant does not delete the copies. Values already replicated
stay in the consumer domain. Treat the copied values as data that outlives
the contract.
:::

**The limits follow from the design.** One hop stops chains: you cannot route a
field from A to B to C, even through a computed field. Two consumers of the
same source each declare their own edge. And a revoked grant leaves the last
copied value in place, so the consumer serves frozen data.

## Related

- [Domains and isolation](/discover/how-it-works/domains/) — why domains stay separate, and what crosses.
- [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — the bus that carries replication updates.
- [Sharing data across domains](/build/model/relations/across-domains/) — declare the `replicate` config on a field and grant cross-domain access.
- Internals on GitHub: [replication.md](https://github.com/wearefacet/facet/blob/main/doc/backend/replication.md), [domain-grants.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md).
