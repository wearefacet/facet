---
type: how-to
title: Use the domain-builder assistant
description: Draft a whole domain by chatting with the builder assistant.
audience: [author]
features: [AI-02, AI-06]
sidebar:
  order: 2
verified_at: fd345fe3
---

The domain-builder assistant is a chat that edits a draft domain for you. Ask for a doctype, a page layout, or sample data, and the assistant writes the definitions and runs the checks itself. You review each step and keep control of the publish.

## When to use this

- You start a domain from a short description instead of empty forms.
- You want view templates drafted for an existing doctype.
- You want a loop of build, check, and fix that does not need you to click through editors.

## Before you start

- **Create rights.** You hold the rights to create domains and doctypes. The assistant acts under your name: every change it makes is attributed to you in the history.
- **A draft domain.** Work happens in a draft. Nothing reaches live data until you publish.

## Steps

### 1. Open the assistant

1. Open **Builder** in the sidebar.
2. Create a draft with **New domain**, or open an existing draft.
3. Select the assistant control in the top bar to open the chat window.

The chat is bound to that draft. Ask directly: "Model a customer and a contact, with companies holding many contacts."

### 2. Ask for the model

The assistant creates and edits doctypes in the draft. It picks field types, sets labels and colors, and wires parent/child relations. It also writes view templates and list views when you ask for pages.

:::tip
Describe the work, not the schema. "Track helpdesk tickets with a state and an engineer" gives better results than a field list.
:::

### 3. Watch the trace

Each assistant action shows in the chat as a tool call, so you see every create and update as it happens. The assistant works in a loop: it writes a definition, runs the check, reads the issues, and fixes them. You can interrupt at any point and take over in the editors.

### 4. Review with previews

Two actions render in the chat itself: a preview of a page layout with sample data, and a jump to a page of the builder. Ask "show me the ticket page" and judge the layout before you keep it.

### 5. Smoke-test with sample documents

Ask the assistant to create a few documents. It writes them into the draft, so you can open real pages and forms, then delete the samples before publish.

### 6. Publish yourself

The assistant cannot publish, edit consent grants, or touch live domains. Finish in the builder: run the check, read the report, and publish. See [Checking a domain before publish](/build/model/in-app/check-before-publish/).

## Example

A short session for an inventory domain:

> **You:** Model a warehouse domain. Stock items with a name, a unit, and a
> quantity. Deliveries hold many lines, each pointing at a stock item.
>
> **Assistant:** Creates `StockItem` and `Delivery` with a `DeliveryLine` child, sets `display_name` templates, and runs the check. Two issues come back: a one-sided parent link and a missing child back-reference. The assistant fixes both and re-checks until the report is clean.
>
> **You:** Show the delivery page.
>
> **Assistant:** Renders a preview card of the delivery page with three sample lines.

The draft now holds a checked model. You open the check tab, read the clean report, and publish to `warehouse`.

## How the assistant knows Facet

The assistant carries a set of authoring guides built in: doctype anatomy, field types, scope rules, view layout patterns, and the check workflow. When it meets an unfamiliar rule, it reads the matching guide first. This is why its output follows the same conventions a careful author would use.

## Troubleshooting

**The assistant cannot create anything.**

Your role lacks the domain or doctype create right. Ask an administrator.

**The chat edits a different domain.**

The chat binds to the draft you opened it from. Reopen the chat inside the right draft.

**A change is wrong.**

Say so in the chat, or undo in the editors. The history shows every assistant write under your name, so a rollback works like any other.

**The preview looks broken.**

The template may bind a field that does not exist yet. Ask the assistant to run the check; the binding errors name the field.

## Related

- [Agent tools reference](/reference/agent-tools/) — every tool the assistant can call.
- [AI under the caller's rights](/discover/how-it-works/assistant/) — why its changes carry your name.
- [Checking a domain before publish](/build/model/in-app/check-before-publish/) — read the report the assistant worked through.
