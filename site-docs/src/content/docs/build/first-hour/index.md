---
type: overview
title: Your first hour
description: One guided route from an empty machine to a running Facet with a domain, an app, a team and an agent.
audience: [evaluator, author, admin, developer]
features: []
sidebar:
  order: 0
next: /build/first-hour/run-facet/
verified_at: eee55a2
---

You are new to Facet and you want to see it work — not read about it. This
route takes you there in about an hour. Each tutorial is a list of steps
that ends in a working result, written for someone who has never opened the
product. Follow them in order; each one continues from the last.

**Before you start**, you need two things:

- [Docker with Compose](https://docs.docker.com/compose/) for tutorial 1. No
  repository clone: `facet-cli setup-dev` pulls the images.
- Node.js 20+ for tutorials 1 and 4 (the CLI and the coding agent). The rest
  need nothing beyond a browser.

Every tutorial uses the same running example: **Brightwater Rentals**, a
fictional event-equipment rental company near Lyon. You model their
equipment, invite their people, and ship their check-out app. A reader who
follows two pages sees the same domains and the same people.

## The route

| # | Tutorial | Time | You end with |
|---|---|---|---|
| 1 | [Run Facet](/build/first-hour/run-facet/) | 15 min | The container stack up, the first admin signed in, the welcome tour done. |
| 2 | [Model your first domain](/build/first-hour/first-domain/) | 20 min | The Brightwater equipment domain built in a draft with the assistant, checked, published, with a kanban board of maintenance tickets. |
| 3 | [The same domain in files](/build/first-hour/first-domain-in-files/) | 15 min | The same domain as files under the dev watcher — one change seen live, one bundle exported. Developers only. |
| 4 | [Ship your first app](/build/first-hour/first-app/) | 30 min | The Brightwater check-out app, built with a coding agent and signed in through Facet. |
| 5 | [Give your team access](/build/first-hour/team-access/) | 15 min | A colleague invited; one role that hides purchase prices; one salesperson who sees only their own clients. |
| 6 | [Connect an AI agent](/build/first-hour/connect-an-agent/) | 15 min | An MCP client answering questions about Brightwater bookings under a real role, on the record. |

## If you only have ten minutes

Run tutorial 1 and open the workspace. Seeing the product in front of you
changes how every page reads.

## After the first hour

The [Build section](/build/) goes deeper on everything the route touches:
drafts and publishing, field types, actions, views, and automation. The
[Workspace pages](/use/) cover the day-to-day surfaces your team uses.

## Related

- [Why Facet](/discover/why-facet/) — the idea behind the product, if you
  want it before the practice.
- [Set up a dev environment](/build/dev-environment/) — run Facet from
  source instead of containers.
