---
type: explanation
title: Domains and isolation
description: A domain groups doctypes and bounds their data; no data crosses a domain boundary without explicit consent.
audience: [evaluator, author]
features: [DOM-01, DOM-14]
sidebar:
  order: 1
verified_at: 7a6cb462
---

A domain holds one business area, such as `hr` or `sales`. Doctypes, hooks,
and grants all live inside it. Nothing crosses the boundary on its own.
Every cross-domain flow needs an explicit consent.

## Explanation

<!-- d2
domain: Domain {class: external}
boundary: "Read crosses a\ndomain boundary?" {class: decision}
free: No grant needed {class: ok}
grant: "Active domain grant?" {class: decision}
flow: Granted fields flow {class: ok}
refused: Read refused {class: danger}

domain -> boundary
boundary -> free: "no — same domain"
boundary -> grant: "yes — foreign domain"
grant -> flow: "field tags covered"
grant -> refused: "missing or inactive"
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/57f6d8f8-light.svg" alt="Read crosses a domain boundary?" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/57f6d8f8-dark.svg" alt="Read crosses a domain boundary?" loading="lazy" />
</div>

**What a domain holds.** A domain is a `core.Domain` document, and its id
is the domain name. Every doctype id is therefore qualified, like
`hr.Employee`. The domain must exist before you register doctypes inside
it; registration answers `422` when it does not.

The domain owns its doctypes and their view templates. It owns the hooks
declared on the domain document, and the grants it issues to other domains.
It also owns its draft state: a draft domain has an id that starts with
`_`. You publish a draft into a fresh, live domain. Grants never involve
drafts — both sides must be live domains.

**A domain moves as one unit.** A domain is also the unit of portability.
Export and import move one domain with its definitions and its data.

**Isolation is the default.** Data does not leave a domain on its own. A
cross-domain read needs one of two explicit consents:

- **The document API.** Reads follow role permissions. The role must hold
  a permission line that names the foreign doctype.
- **The automation surfaces.** Replication fields, hooks with a foreign
  source, and Lua reads of a foreign doctype need an active domain grant.
  Without coverage, the read is refused.

  Same-domain edges skip every gate. A domain reading itself is not a sharing
  decision.

  **What a grant shares.** A grant is a document under the producer domain,
  and one grant covers one consumer domain. It carries a resources list: one
  entry per producer doctype, and each entry names field tags. Grants give
  read access only — no write access exists.

  **A field is shared when its tags match.** Untagged fields count as
  `default`, so an entry that names `default` reaches every untagged field.
  The consumer receives the covered fields only; the server removes the rest
  before delivery.

  **The producer decides activation.** Activation is the producer's right, and
  it is all-or-nothing per grant. A publish that widens the shared resources
  drops an active grant back to inactive. The producer must accept it again.

  **One hop only.** Replication is one hop. A replica field may not feed
  another replica; the authoring gate rejects the chain with `422`.

:::caution
A grant works at tag grain, not at role grain. A consumer domain that
holds a grant on a tag can read those fields from Lua scripts. The human
caller who triggers the script may not read the same field through the
document API. Grant a tag to a domain, never to a role.
:::

### The trade-off

**Grants couple domains.** The consumer reads live data, so it depends on the
producer's contract. Deactivate the grant, and the copies stop updating.
Narrow the tags, and the values already copied stay where they are. No job
sweeps them out. Activate the grant again, and the next source event
re-pushes the value.

**Hard isolation costs duplication.** Both options are first-class. When the
coupling costs more than the copy, duplicate the field and keep the domains
fully independent.

## Related

- [Architecture at a glance](/discover/how-it-works/) — where domains sit in the request path.
- [Domains, drafts and domain editors](/build/model/in-app/drafts-and-publishing/) — create a domain and register doctypes in it.
- [Cross-domain replication](/build/deeper/cross-domain-replication/) — the copy mechanism a grant gates.
- [Authorization enforcement](/admin/under-the-hood/how-access-is-enforced/) — the role checks behind the document API.
- Internals on GitHub: [doctype-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/doctype-system.md), [domain-grants.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md), [replication.md](https://github.com/wearefacet/facet/blob/main/doc/backend/replication.md).
