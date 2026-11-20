# Domain grants

Cross-domain data sharing consent. A `core.DomainGrant` document is one
data-sharing contract: it lives under the **producer** domain — the domain
that gives the data and owns the consent — and names one **consumer**
domain plus the resources (producer doctypes and field tags) the consumer
may read. Grants confer read access only, and a grant must be **activated**
before any gate honours it.

## Source files

| File                            | Role                                                            |
| ------------------------------- | --------------------------------------------------------------- |
| `src/grants.cr`                 | Namespace root; `Grants::DEFAULT_TAG` (`default`)               |
| `src/grants/validator.cr`       | Authoring-time validation attached to grant create/update       |
| `src/grants/registry.cr`        | `Grants::Registry` — process-wide coverage cache                |
| `src/grants/routes.cr`          | Activate / deactivate HTTP routes                               |
| `src/grants/publish_tickets.cr` | Ticket filing at publish                                        |
| `data/seeds/core.DomainGrant/`  | Doctype seed (fields, display name, actions)                    |

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Grants are documents under the **producer** domain. | Consent belongs to the consenting party. Every contract over the producer's egress lives in the producer's own tree; the consumer's data holds none of it. Cost: publish files tickets with one bounded foreign write. |
| D2 | Read-only always. No write access exists to grant; the door stays shut by design. | Keeps the model small; future verbs would be a new, explicit feature. |
| D3 | Tag grain, not field grain. | Producers control blast radius by tagging; grants stay stable across field additions. |
| D4 | Untagged = `default`. | Fields are shareable until the producer tags them. The grant boundary stays fail-closed: no active grant, no flow. Trade-off: a new untagged field flows through grants that already name `default`, with no grant edit. |
| D5 | Acceptance is the producer's right, all-or-nothing per grant. | The `resources` list is one bundle — no per-doctype or per-tag acceptance. Mechanically the right stays a doctype-global named action; the audit log records every transition. |
| D6 | Publish merges resources but never widens silently. A merge that widens an **active** grant drops it to `active: false` — unless the publisher holds the acceptance right (D11). | A changed contract needs re-acceptance; silent widening would bypass the producer's consent. A re-publish with no resource change touches nothing. A deactivated grant stays deactivated. |
| D7 | Same-domain edges need no grant, everywhere (replication, hooks, Lua reads). | A domain reading itself is not a sharing decision. |
| D8 | No retrospective sweep on deactivate or tag narrowing; no backfill on activate. | Simple; documented. Deactivation and tag narrowing leave already-copied values in place. Activation does not fill the other direction either: rows written while the grant was inactive keep `replica: null`, and no job fills them. Recovery is event-driven. The grant fanout marks the replication registry stale; the rebuilt binding survives the coverage re-check. The next event from a referenced source document pushes the source's current value into the null replica (the push compares stored values, not changed fields); a `via`-field change re-pulls at write time (G2). A first binding for a consumer domain also creates its replication stream group, and that group starts at `0` — the replay of the retained stream fills the replicas from history, bounded by stream retention. Delivery is at-most-once, so a dropped event delays the fill to the next source event. The miss is not silent: the write-time pull logs a WARN when the grant gate refuses (`SyncPull`), and the replication registry build logs its own WARN when it drops the binding. The `on_source_delete: unset` machinery is the template if a sweep is ever wanted. |
| D9 | Cross-domain reference reads through the document API stay RBAC-only. | Unchanged scope; UI reads of referenced foreign documents are governed by role permissions, not grants. |
| D10 | Tags are free-form strings, not a closed enum. | Producers invent labels as their model grows; no code change per new label. A diagnostic flags grant tags that no producer field carries. |
| D11 | Publish files tickets active when the publisher holds `activate` on `core.DomainGrant`; otherwise inactive. | Admin publishers self-serve — no follow-up activation to forget. The right is doctype-global, so a holder could file and then activate anyway; collapsing the steps changes nothing RBAC-wise. The audit log attributes the active filing to the publisher. |

## The document

One grant per (consumer, producer) pair, stored as a child of the
producer's `core.Domain` document (`meta.parent_id` is the producer's bare
domain id — the domain name IS the document id).

| Field             | Type                 | Rules                                                                                                                             |
| ----------------- | -------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `consumer_domain` | `reference` → `core.Domain` | Required. The admitted consumer. Equality filter on, so consumer-side held-access lists are cheap.                          |
| `resources`       | `array(object)`      | Required. One `{doctype, tags}` entry per producer doctype the consumer may read. The list is the field mask, at tag grain.        |
| `active`          | `boolean`            | Defaults `false`. **`read_only`** — document callers can never write it; only the activate/deactivate routes and the publish filing set it. |

**Coverage rule** — a source field is readable through a grant when the
grant is `active`, the source doctype has a resource entry, and the
field's tags share at least one name with that entry's `tags`. Untagged
producer fields resolve to `["default"]` (`Grants::DEFAULT_TAG`), so an
entry naming `default` reaches every untagged field. Tags are free-form
strings (D10); a field may carry several.

**States** — `active: false` is a filed ticket awaiting acceptance (or
paused after deactivation / a widening merge, D6). `active: true` is the
accepted contract. Acceptance is the producer's right, all-or-nothing per
grant, held doctype-global as the `activate` / `deactivate` named actions
(D5).

## `Grants::Validator`

Runs on every `core.DomainGrant` create/update (attached in
`Document::Create` / `Document::Update`'s core-doctype dispatch) and on
demand from the `/check` report. The typed field schema covers shape; the
validator adds what it cannot express: the consumer must differ from the
parent domain (a self-grant is invalid — same-domain edges need no grant,
D7), resource `doctype` values are CamelCase, and tags carry no empty
strings.

## `Grants::Registry`

Process-wide cache, stale-flag / lazy-rebuild — the `Hooks::Registry`
pattern. Built from non-deleted `core.DomainGrant` projections; both sides
must be live domains (drafts on either side exclude the grant) and the
producer must pass `domain_enabled?`. An inactive grant builds no entry.

| Method | Returns |
|---|---|
| `covers?(db, consumer, producer, doctype, field_tags)` | True when an active grant's entry for the doctype shares at least one tag with `field_tags`. |
| `active?(db, consumer, producer, doctype)` | True when an active grant names the doctype (any tags) — admits hook fires. |
| `project(db, consumer, producer, doctype, content)` | Copy of `content` reduced to fields whose tags the granted tags cover. |

Invalidation: the `DoctypeCache` subscriber marks the registry stale on
`fanout:core.DomainGrant:*` (create, update, delete); the next read
rebuilds replace-all. Field tags resolve through `Doctype::DefinitionStore`
(invalidated by the `core.DocType` fanout), so a producer tag change
re-asserts coverage on the next rebuild — removing a tag cuts bindings,
adding one restores them; already-copied values stay (D8). A lost fanout
is bounded by `cache.staleness_ttl_s`.

## The four gates

| Gate | File | Behaviour |
|---|---|---|
| G1 Registry build | `src/replication/registry.cr` | A cross-domain binding survives only when `Grants::Registry.covers?` holds for the source field's tags. |
| G2 Write-time pull | `src/replication/sync_pull.cr` | Before pulling an initial value across domains, re-check `covers?`; no coverage → the replica stays null. |
| G3 Hook delivery | `src/hooks/handler.cr`, `src/hooks/executor.cr` | A hook whose source domain is foreign fires only when `active?` holds; `ctx.event.content` passes through `project` first. Same-domain events keep full content. |
| G4 Lua cross-domain reads | `src/document/lua_document_helpers.cr` | `document.get` / `document.list` with a qualified `domain.Doctype`: no active grant → Lua error (catchable with `pcall`; uncaught, the hook/action surfaces 422 with the denial message); active grant → content projected through `project`. |

Same-domain edges skip every gate (D7).

**Producer note (audit consideration):** a G4 read is projected by the
**grant's** tag coverage, not by the calling role's `visible_tags`. A
domain grant on a tag (e.g. `pay`) admits the consumer's scripts to those
fields through `document.get` / `document.list`, even when the human
caller who triggered the action cannot read the field over REST. Producers
grant a tag to a domain, not to a role — review grant scope with that in
mind.

## Create route

A grant is a child of its producer's `core.Domain` document. Create it
through the nested-children route, using the relation name `grants` from
`core.Domain`'s `children` map — not the doctype name `DomainGrant`:

```text
POST /Api/core/Domain/:producer/grants
```

The flat route (`POST /Api/:domain/DomainGrant`) and the wrong nested
form (`POST /Api/core/Domain/:producer/DomainGrant`) answer 404. The
`Unknown child` error names the valid relations (`doctypes`, `grants`).

## Activate / deactivate routes

`POST /Api/core/DomainGrant/:id/activate` and `.../deactivate`
(`Grants::Routes`). These are **not** document actions — the route performs
the internal mutation directly and runs no Lua; the routes register before
the REST catch-all so the paths never reach the nested-children matcher.
The gate is the named action on `core.DomainGrant`
(`RBAC::WriteEnforcer.authorize_action`), doctype-global by design (D5);
every transition is audit-attributed to the caller. A same-value write
persists nothing (the update pipeline's empty-diff path).

## Publish flow

After the publish's structure lands, `Grants::PublishTickets.file` scans
the published definitions and hooks for outbound cross-domain edges:
replicate fields whose `via` targets a foreign doctype, and event hooks
whose `source.domain` is foreign (a domain-wide hook expands over every
producer doctype). Per foreign producer, edges group by doctype; the
producer's current definition supplies each referenced field's tags
(untagged → `default`; hook edges claim `default`).

Per producer with a live domain — a domain is live when its `core.Domain`
projection exists, is not tombstoned, and carries `draft != true`; an
**absent `draft` key counts as live** (domains created through the direct
`POST /Api/core/Domain` path carry no `draft` key). Draft producers surface
as `/check` diagnostics instead:

- **No existing grant** — file one inside the publish transaction, into
  the producer's subtree. `active` follows D11: `true` when the publisher
  holds the `activate` named action (the publish route resolves the
  verdict), `false` otherwise. System-attributed publishes file inactive.
- **Existing grant, union widens** — the merged resources land; an active
  grant drops to `active: false` (D6) unless the publisher holds the
  acceptance right (D11); an inactive grant stays inactive.
- **Union unchanged** — touch nothing.

This is the one bounded foreign write the publish performs, attributed in
the audit log through `actioner_id`. `Publish::Result` carries the per-
producer ticket report (`producer`, `filed`, `active`, `dropped`, `edges`);
the publish HTTP route serializes it as `grant_tickets`, and the publish
dialog renders it — including the D6 re-acceptance warning (`dropped`) and
the untagged-fields warning (an edge naming `default`).

## Import flow

The portable-domain import runs the same `Grants::PublishTickets.file`
scan after its doctypes land (fresh and `--merge` both). The bundled
definitions — rewritten to the target identity — and the target domain
document's hooks are the edge sources; the rules above apply unchanged,
except that the import is a system actor: tickets always file **inactive**
(the producer's acceptance stays an explicit act). A re-import whose edges
the target already carries widens nothing and touches no grant.

`Import::Result.grant_tickets` carries the per-producer report; the CLI
prints one line per ticket with its state. An imported edge stays inert
until the producer activates the ticket — the same state a publish without
the acceptance right leaves.

## Diagnostics

`Replication::Validator` verifies grant coverage per replicate edge, with
distinct messages per failure shape: no grant, grant inactive, doctype not
granted, tag not covered. `Doctype::Check` surfaces them under the
`:replication` category; the draft check endpoint aggregates them, and the
publish dialog shows the count before publishing.

## Frontend

The domain editor's grants tab renders both sides — issued grants
(editable resources + activate/deactivate) and held access (read-only) —
and the publish dialog renders the ticket report. See
[`../frontend/configure-editors.md`](../frontend/configure-editors.md) →
Grants tab.
