---
type: overview
title: Build domains
description: Model your business data in Facet — doctypes, fields, actions, views, and automation.
audience: [author]
features: []
sidebar:
  order: 0
verified_at: fd345fe3
---

You are a domain author, and you want your business data to live in Facet.
This section shows you how. Start with a draft domain and one doctype. Then
grow the model as you learn what the product can hold.

You will work through four jobs: **model** the data, **shape the views**
people use, **publish and evolve** the domain, and **automate** what happens
next.

## Modeling

- [Domains, drafts and domain editors](/build/model/in-app/drafts-and-publishing/) — open a draft domain, invite co-editors, and publish to the live domain.
- [Designing doctypes](/build/model/data/design-doctypes/) — declare the fields, actions and templates of a record type.
- [Field types (guide)](/build/model/data/field-types/) — pick the right type for each field; defaults and normalization.
- [References, links and backlinks](/build/model/relations/references-links/) — connect documents to each other and browse the connections.
- [Identifiers and unique constraints](/build/model/data/identifiers-uniqueness/) — human-readable reference numbers and uniqueness rules.
- [Parent/child composition](/build/model/relations/parent-child/) — model owned children that live and die with their parent.
- [Sidecars (comments, attachments)](/build/model/relations/comments-attachments/) — add a discussion panel and files to a doctype.
- [Files and artifacts in fields](/build/model/data/files/) — store files in the artifact store and link them from fields.
- [Secret and write-only fields](/build/model/data/secret-fields/) — store credentials safely and accept values you can never read back.
- [Named actions](/build/model/behaviour/named-actions/) — give users typed operations beyond plain edits.
- [Lifecycle scripts and guards](/build/model/behaviour/scripts-and-guards/) — run Lua on create, update and delete, and block invalid writes.
- [Computed fields](/build/model/data/computed-fields/) — derive field values from a template.

## Views

- [Display names and search text (Jinja2)](/build/model/views/names-and-search/) — control how documents are named and how search sees them.
- [Document view templates (show/form pages)](/build/model/views/document-pages/) — design the page a user sees when they open a document.
- [Collection views](/build/model/views/lists-boards-calendars/) — configure the table, kanban or grid that lists a doctype.
- [Named scopes](/build/model/access/named-scopes/) — reusable row filters that roles can reference.
- [The schematic view](/build/model/views/schematic/) — see the whole domain as a diagram while you design it.

## Publish and evolve

- [Checking a domain before publish](/build/model/in-app/check-before-publish/) — run the publish checks and read the report.
- [Evolving a schema (migrations, reproject)](/build/model/change-a-live-domain/) — change fields safely and map old values to new ones.
- [Sharing data across domains (grants, replication)](/build/model/relations/across-domains/) — grant another domain access and copy reference data.
- [Moving domains between instances (bundles)](/build/model/bundles/) — export a domain and import it elsewhere.

## Automate

- [Event and schedule hooks](/build/model/automation/event-hooks/) — react to changes and run jobs on a schedule.
- [Outbound webhooks](/build/model/automation/webhooks/) — call external systems when documents change.
- [Notifications and mentions](/build/model/automation/notifications/) — notify people from scripts and comments.
- [Use the domain-builder assistant](/build/model/in-app/build-with-assistant/) — draft a domain by describing it in chat.
- [The dev domain watcher](/build/model/in-files/domain-watcher/) — sync domain definitions from your editor while you develop.
