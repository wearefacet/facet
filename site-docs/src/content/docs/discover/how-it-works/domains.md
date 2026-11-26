---
type: explanation
title: "Domains: where your data lives"
description: See how Facet keeps each business area separate, and how data crosses between areas only by agreement.
audience: [evaluator, author]
features: [DOM-01, DOM-02, DOM-14]
verified_at: eee55a2
sidebar:
  order: 1
---

Brightwater rents out tents, stages, and sound systems. The company tracks three different things: its stock, its clients, and its bookings. In Facet, each of those lives in its own **domain** — one business area, kept separate from the others.

*A domain keeps its records inside. Crossing to a neighbour is a door someone opens on purpose.*

<!-- d2
direction: down
clients: "clients — companies and contacts" {class: store}
rentals: "rentals — bookings" {class: store}
equipment: "equipment — items and repairs" {class: store}
clients -> rentals: "a granted door: the client's name rides onto the booking"
rentals -> equipment: "a granted door: bookings drive stock"
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/c40113be-light.svg" alt="clients — companies and contacts" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/c40113be-dark.svg" alt="clients — companies and contacts" loading="lazy" />
</div>

## What a domain holds

Each domain says which kinds of records exist, and what each kind holds. A kind of record is a **doctype**; the things a record holds are its **fields**.

Brightwater's *equipment* domain holds the *Item* doctype: name, category, status, serial number, purchase price. It also holds *MaintenanceTicket*, so a broken generator becomes a tracked job, not a sticky note. The *clients* domain holds *Company* and their *Contact* people. The *rentals* domain holds *Booking* and its lines.

Fields carry types — a date, a price, a choice from a list — so a booking's dates stay dates, and a price stays a number. One domain, one tidy model of one part of the business.

## Kept apart, crossed on purpose

Nothing leaves a domain on its own. That is the point: your client list cannot quietly leak into another area, and a mistake in one model cannot corrupt another.

Records still reach each other when it makes sense. A booking names its client: the *Booking* record points at a *Company* record in the *clients* domain. Your role decides whether you may follow that pointer.

Copying is a different story. The booking keeps its own copy of the client's name, so it stays readable even years later. That copy flows through a **grant**: a written agreement between the two domains, naming which records and which fields may cross. The domain that owns the data signs the agreement; the other side only reads. Brightwater runs two: the client's name rides onto bookings, and bookings drive the stock board in *equipment*.

## Start in a draft

You never edit a live domain's structure while people work in it. You work in a private copy, try the fields, break them, fix them. When it behaves, one step moves it into a real domain — that step is **publish**. Publishing copies the structure; the practice records you typed while experimenting stay behind unless you choose to bring them along.

## What this means for you

- Give each part of the business its own domain, and each domain stays simple enough to explain on one page.
- A security question has a short answer: data crosses only where someone signed a grant.
- New kinds of records arrive in a draft, so a mistake never reaches your team.

## For the technical detail

- [How domains stay isolated](/build/deeper/domain-isolation/) — the boundary rules, in full.
- [How drafts work](/build/model/in-app/how-drafts-work/) — the draft state and the publish gate.
- [Share data across domains](/build/model/relations/across-domains/) — how to set up a grant.
- [How copied fields stay in sync](/build/deeper/cross-domain-replication/) — the mechanics behind a copy.

## Related

- [The big picture](/discover/how-it-works/) — where domains sit among the five ideas.
- [Documents: records with a memory](/discover/how-it-works/documents/) — the records a domain holds.
- [Domains, drafts and domain editors](/build/model/in-app/drafts-and-publishing/) — create and publish a domain, step by step.
