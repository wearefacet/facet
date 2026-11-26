---
type: explanation
title: The assistant: AI with your rights
description: See how the assistant answers under your own rights, where it appears, and what an administrator controls.
audience: [evaluator, admin]
features: [AI-01, AI-02, AI-03, AI-05, AI-07, AI-08]
verified_at: eee55a2
sidebar:
  order: 5
---

Nadia asks, "Which tents are free on 14 June?" The assistant reads the stock and answers — exactly the tents Nadia may see, no more. That is the rule the whole page hangs on: **the assistant has no rights of its own.**

*It works as you, under your role. Its changes are yours, in the history, marked as assistant work.*

```d2
direction: down
nadia: "Nadia asks a question" {class: external}
assistant: "The assistant"
check: "Every step runs as Nadia, under her role" {class: accent}
records: "Records" {class: store}
history: "History: the change is hers, marked as assistant work" {class: store}
nadia -> assistant
assistant -> check
check -> records
check -> history
```

## It acts as you

The assistant sees and changes only what your role allows. What you cannot read, it cannot read; what you may not change, it cannot change. When it does change something — a date, a status, a note — the history records it under your name. A mark says the assistant did the typing. You can open **History** on any record and see every such change, like any other.

## Where you meet it

The assistant appears in three places:

- **The workspace.** A chat panel rides along on every page. Ask about your data, and it can open the record it found.
- **The Builder.** A second assistant helps you shape the record kinds themselves: describe a *MaintenanceTicket*, and it drafts the fields and screens in your working copy.
- **Inside apps.** An app can include the same chat, so the check-out screen answers questions too — still under the signed-in person's rights.

## Agents connect too

Your AI coding agent, or Claude Desktop, can connect to Facet directly — through a standard connector called MCP. An agent always connects under one fixed role you choose for it, and the same checks apply to every call it makes. Its toolkit holds document tools only — read, change, act, search. It has no tools to reshape your record kinds.

## Your model, your rules

Facet brings no AI service of its own. An administrator connects the language model — any service that speaks the common OpenAI format — with an endpoint, a key, and a model name. The model never touches your database. It reads what the assistant's tools fetch for it, under your rights, and nothing more.

## You stay in control

A running answer stops with **Stop**. An administrator can turn the assistant off for a role, and can cap what each account may spend. The cap is a token budget over a rolling 30 days; the panel shows the meter. When the budget is spent, the panel says so, and the cap lifts as old usage ages out of the window.

## What this means for you

- Ask questions in your own words; the answers respect the same rules as your own screen.
- The audit trail stays complete: assistant work is visible, attributable, and undoable.
- Adopting AI does not mean opening the doors — it means issuing one more badge.

## For the technical detail

- [AI and permissions, in detail](/admin/under-the-hood/ai-and-permissions/) — how a tool call is checked and recorded.
- [Connect agents over MCP](/build/apps/agents/mcp/) — set up an agent connection.
- [Connect a language model](/admin/assistant/connect-a-model/) — the administrator's setup.
- [Ask the assistant](/use/assistant/) — the day-to-day how-to.

## Related

- [The big picture](/discover/how-it-works/) — where the assistant sits among the five ideas.
- [Roles: who sees and does what](/discover/how-it-works/roles/) — the rights it borrows.
- [Embed the assistant in your app](/build/apps/host/embed-assistant/) — the chat inside your own app.
