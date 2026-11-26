---
type: explanation
title: Cross-domain replication
description: A consumer domain can copy selected fields from another domain's doctype, one hop, behind a grant.
audience: [author, admin]
features: [DOM-25, DOM-14]
sidebar:
  order: 3
verified_at: eee55a2
---

A consumer doctype can copy a field from a source doctype that lives in
another domain. The copy is a local field on the consumer document, filled
from the source document it points at. Facet keeps the copy current through
the event bus. A domain grant controls what may cross the boundary. The
plain-language half is [Domains: where your data
lives](/discover/how-it-works/domains/).

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
names a local reference field (the `via`) and the source field to copy. One
replication edge is therefore one record:

| Record part | What it names |
| --- | --- |
| Consumer side | The consumer domain, its doctype, the `via` reference field, the replica field |
| Source side | The qualified source doctype, the source field |
| Delete policy | `on_source_delete` — `keep` or `unset` |

The engine builds that record when the doctype definition is saved, and the
registry keeps it in a process-wide map keyed by source doctype. On create,
or when the reference field changes, the write path pulls the initial value
from the source document. The pull runs before computed fields, so a
computed field that reads the replica sees the pulled value, not an empty
one. After that, every source change propagates through the handler.

The handler always reads the source's current value from PostgreSQL — never
the payload inside the event. It compares that value with each consumer's
copy and writes only the difference. The consumer update is a real write:
a normal mutation row, visible in the audit log.

**Which source event does what:**

| Source event | What the handler does |
| --- | --- |
| `deleted` | Applies the delete policy: `keep` leaves the copies, `unset` clears the replica field on every referencing consumer |
| `created`, `snapshot`, `migrated`, `rolled_back` | Full sync: re-pulls the value for every referencing consumer |
| `updated`, action | Diff sync: writes only where the stored copy differs from the source |

**Replica fields are read-only.** You cannot write a replica field yourself.
The document write gate rejects the key, and the field cannot be `required`
or `unique`.

**The copy lags the source.** Delivery rides the event bus, so the copy lags
the source: it is eventually consistent. Delivery is at-most-once. A lost
update waits for the next change to the source document.

**Deletion follows a policy.** When a source document is deleted, the replica
follows the field's `on_source_delete` policy. `keep` (the default) leaves the
copied value in place. `unset` clears it on every referencing consumer. The
policy never touches the `via` reference itself — the dangling reference id
stays, exactly as for any deleted document a reference points at.

**Copied files and text stay readable.** When the replicated value is a file
field, the handler adds the consumer domain as an owner of the artifact. The
file then reads through the consumer document. A replicated longtext field
carries its file links inside the markdown; the same owner rule applies
through the normal write path.

### One hop

A replica never feeds another replica. The doctype validator checks the
definition when you save it. It rejects a replica used as a replication
source. It also rejects a `via` field that is itself a replica. At runtime, the
write that updates a replica carries a reentrant flag. A handler that receives
a reentrant event skips it. The chain stops at one hop, always.

### What the save-time gate refuses

Saving the consumer definition answers `422` for a hard violation:

- the `via` field is itself a replica,
- the source field is a replica, or a `secret` — a replica would copy the
  secret's state marker into public content,
- the replica field does not carry every tag the source field carries (a
  missing tag would show the copied value to roles that cannot read the
  source),
- the `via` reference target is not a qualified `domain.Doctype`.

A source that cannot be resolved yet — the source doctype or field does not
exist so far — is not a hard refusal. A consumer may land before its
producer. The check report names the gap as a warning, and the runtime
leaves the replica empty until the source exists.

The tag rule has one backstop: a producer-side edit that adds a tag to an
already-replicated source field does not re-validate the consumer. The
check report is the surface that flags the drift.

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
replays the retained stream. Its consumer group starts at position `0`, so
history fills the replicas — bounded by the stream's retention.

:::caution
Deactivating a grant does not delete the copies. Values already replicated
stay in the consumer domain. Treat the copied values as data that outlives
the contract.
:::

**The registry rebuilds lazily.** A doctype or grant change only marks the
registry stale; the next read rebuilds it. A burst of changes — publishing a
whole domain, for example — folds into one rebuild. Grant coverage is
re-checked against the producer's current field tags on every rebuild, so
removing a tag cuts bindings and adding one restores them.

**The limits follow from the design.** One hop stops chains: you cannot route a
field from A to B to C, even through a computed field. Two consumers of the
same source each declare their own edge. And a revoked grant leaves the last
copied value in place, so the consumer serves frozen data.

## Related

- [How domains stay isolated](/build/deeper/domain-isolation/) — the boundary, and what a grant shares.
- [Domains: where your data lives](/discover/how-it-works/domains/) — the same story, no engine words.
- [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — the bus that carries replication updates.
- [Sharing data across domains](/build/model/relations/across-domains/) — declare the `replicate` config on a field and grant cross-domain access.
- Internals on GitHub: [replication.md](https://github.com/wearefacet/facet/blob/main/doc/backend/replication.md), [domain-grants.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md).
