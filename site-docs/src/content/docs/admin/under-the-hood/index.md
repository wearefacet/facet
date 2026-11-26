---
title: Under the hood
description: The five deep pages — the mutation log, auth contexts, enforcement, events, and the assistant's rights.
type: overview
audience: [admin, developer]
features: []
verified_at: eee55a2
sidebar:
  order: 0
---

The admin pages tell you what to click. These pages tell you what Facet
actually does when you click it. Each one takes one mechanism apart: the
change log, the auth context, the enforcement checks, the event bus, and the
assistant's rules.

Read one when a how-to page links it. Or read one when you must answer a
"why" question with precision: an audit, a security review, a design
discussion.

## The five pages

| Page | The question it answers |
| --- | --- |
| [The change log, in detail](/admin/under-the-hood/change-log/) | Where does every change go, and what does one row record? |
| [Why you act as one role at a time](/admin/under-the-hood/one-role-at-a-time/) | How does every channel resolve to one identity and one role? |
| [How access is enforced](/admin/under-the-hood/how-access-is-enforced/) | Which checks sit between a request and the data? |
| [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) | What happens when a reaction is lost, and why is that safe? |
| [AI and permissions, in detail](/admin/under-the-hood/ai-and-permissions/) | Whose rights does an assistant tool call run under? |

## How to read them

Each page stands alone, but they share one spine. A request arrives with one
[auth context](/admin/under-the-hood/one-role-at-a-time/). The
[enforcers](/admin/under-the-hood/how-access-is-enforced/) decide what it may
touch. An accepted write appends one row to the
[change log](/admin/under-the-hood/change-log/) and publishes an
[event](/admin/under-the-hood/events-and-delivery/) that other parts of the
system react to. When the caller is the assistant, the same enforcers apply —
see [AI and permissions, in detail](/admin/under-the-hood/ai-and-permissions/).

## Related

- [Administer](/admin/) — the full admin section, one layer up.
- [The big picture](/discover/how-it-works/) — the plain-words version of the same story.
- [Health, metrics and logs](/admin/keep-running/monitoring/) — watch these mechanisms run.
