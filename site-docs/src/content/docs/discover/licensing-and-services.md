---
title: Licensing and services
description: What the BSL 1.1 licence lets you do, when releases turn Apache 2.0, and where to get help.
type: explanation
audience: [evaluator, developer, operator]
features: []
verified_at: eee55a2
sidebar:
  order: 7
---

Before you build on a product, read its licence. Facet's is short and loose
by intent: it blocks one business move and allows nearly everything else.
This page translates it into plain words. The licence files in the repository
are the binding text — this page is the summary.

## The licence in one paragraph

Facet is source-available under the Business Source License 1.1 (BSL 1.1),
published by Amplitude Solutions Ltd. The BSL is not an open-source licence;
it says so itself. You may use, change, fork and redistribute Facet, and run
it in production. Each release becomes Apache 2.0 four years after it is
published, and stays that way.

## What you may do

| You may | Because |
| --- | --- |
| Run Facet in production for your own organization | Production use by the user is permitted. |
| Change it, fork it, redistribute copies | The licence grants copy, modify and redistribute rights to everyone. |
| Build apps and domains on Facet and sell them, including public-facing apps | Your application is your product; the licence does not restrict it. |
| Sell services around Facet: consulting, development, migration, support, training | The Additional Use Grant permits services to third parties. |
| Host and operate Facet for a client under a services agreement | The grant covers managed hosting within a contract. |
| Sell domain templates, doctype packs or extensions you wrote | Your original work is yours; the licence covers Facet's code, not yours. |

## What it blocks

Two moves need a commercial licence from the publisher:

- **A self-service Facet offering**: a service where third parties sign up
  and provision Facet instances or tenants on their own. That covers SaaS
  sign-up, automated provisioning through a portal, API or marketplace, and
  published standard plans anyone can buy without negotiation.
- **Public one-click deployments** — offering Facet to the public as
  pre-packaged container or VM images, installers, or cloud marketplace
  listings.

The test from the licence's own question-and-answer page: is Facet itself the
product, sold on self-service terms? Then it needs a commercial licence. Is
Facet the tool you use to serve a specific customer under an agreement? Then
it is allowed.

Some cases have no clean answer: a product that embeds Facet, a free public
demo service, a partnership program. Write to the publisher before you
launch: [contact@amplitude-solutions.com](mailto:contact@amplitude-solutions.com),
the contact named in the licence. Alternative licensing arrangements go to the
same address.

## Your data and your work

The licence covers Facet's code only. Your domains, record types, apps,
templates and data are yours. Facet stores your documents; the licence claims
none of them.

## The four-year conversion

Every release is published under BSL 1.1. Four years after publication, that
release converts to the Apache License, Version 2.0. Older releases stay on
Apache 2.0; newer ones carry their own four-year clock. The conversion is in
the licence text itself, not a promise on a website.

## Contributing

Contributions need a signed Contributor License Agreement (CLA). It exists
for one purpose: it lets the publisher keep one licence for the whole
codebase, so every release can convert to Apache 2.0 on schedule. You keep
ownership of what you contribute; you grant a licence, not your copyright.
Signing runs through the CLA Assistant app on your first pull request, and
one signature covers your later contributions. See
[CLA.md](https://github.com/wearefacet/facet/blob/main/CLA.md).

## Trademarks

The name Facet, the logo, and the names of official distributions and
services belong to Amplitude Solutions Ltd. The licence grants no trademark
rights, so a separate page states what you may do:

- **Truthful references are fine**: "built on Facet", "runs on Facet", "works
  with Facet", "Facet consulting", "Facet domain templates".
- **Do not name a distribution, image, installer or hosted offering "Facet"**,
  or anything confusingly similar. If you distribute a fork, rename it.
- **Do not present your offering as official or certified**, and do not use
  the logo without written permission.
- **Three words stay with the publisher**: "official", "certified", and
  "Facet Cloud".

See [TRADEMARKS.md](https://github.com/wearefacet/facet/blob/main/TRADEMARKS.md).

## Where to get help

Facet's support surface is its repository:
[github.com/wearefacet/facet](https://github.com/wearefacet/facet). Read the
source, open an issue, and read the licence files —
[LICENSE](https://github.com/wearefacet/facet/blob/main/LICENSE),
[LICENSING.md](https://github.com/wearefacet/facet/blob/main/LICENSING.md),
[TRADEMARKS.md](https://github.com/wearefacet/facet/blob/main/TRADEMARKS.md),
and
[CLA.md](https://github.com/wearefacet/facet/blob/main/CLA.md). The
documentation you are reading covers the product; the repository holds the
engineering contracts behind it.

## Related

- [Is Facet right for you?](/discover/is-it-right-for-you/) — what you need
  to run it.
- [Security and governance](/discover/security/) — the claims a review will
  check.
- [Deploy to production](/admin/install/production/) — the self-hosting
  walkthrough.
