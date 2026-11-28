---
type: how-to
title: Build with the assistant
description: Draft a whole domain by chatting with the builder assistant — it writes definitions, runs the checks, and shows previews.
audience: [author]
features: [AI-02, AI-06]
sidebar:
  order: 2
verified_at: eee55a2
---

The domain-builder assistant is a chat that edits a draft domain for you.
Ask for a doctype, a page layout, or sample data, and the assistant writes
the definitions and runs the checks itself. You review each step and keep
control of the publish.

## When to use this

- You start a domain from a short description instead of empty forms.
- You want view templates drafted for an existing doctype.
- You want a loop of build, check, and fix that does not need you to click
  through editors.

## Before you start

- **Create rights.** You hold the rights to create domains and doctypes. The
  conversation checks both before it opens.
- **A configured assistant.** An administrator [connects a language
  model](/admin/assistant/connect-a-model/) in the system settings, or
  through the server's environment. Without one, the chat tells you.
- **A draft domain.** Work happens in a draft. Nothing reaches live data
  until you publish.

## Steps

### 1. Open the assistant

1. Open **Builder** in the sidebar.
2. Create a draft with **New domain**, or open an existing draft.
3. Select the assistant control in the top bar to open the chat window.

The chat is bound to that draft. Ask directly: "Model a customer and a
contact, with companies holding many contacts."

### 2. Ask for the model

The assistant creates and edits doctypes in the draft. It picks field types,
sets labels and colours, and wires parent/child relations. It also writes
view templates and list views when you ask for pages.

:::tip
Describe the work, not the schema. "Track helpdesk tickets with a state and
an engineer" gives better results than a field list.
:::

### 3. Watch the trace

Each assistant action shows in the chat as a tool call, so you see every
create and update as it happens. The assistant works in a loop: it writes a
definition, runs the check, reads the issues, and fixes them. You can
interrupt at any point and take over in the editors.

<!-- screenshot: assistant-chat-trace -->

### 4. Review with previews

Two actions render in the chat itself: a preview of a page layout with
sample data, and a jump to a page of the builder. Ask "show me the ticket
page" and judge the layout before you keep it.

### 5. Smoke-test with sample documents

Ask the assistant to create a few documents. It writes them into the draft,
so you can open real pages and forms, then delete the samples before
publish.

### 6. Publish yourself

The assistant cannot publish, edit consent grants, or touch live domains.
Finish in the builder: run the check, read the report, and publish. See
[Check before you publish](/build/model/in-app/check-before-publish/).

## Prompts that work

Start small, and ask for the check before the extras. This prompt produced
the trace below on the running instance:

```text
Create one doctype named Crate with a single string field name (required).
Give it a display_name template. Run the check and stop when it is clean.
Do not create views or documents.
```

What you see in the chat: three tool calls that read the assistant's built-in
authoring guides, then the create, then the check. The result of the create
arrives as a small JSON answer:

```json
{"ok":true,"data":{"doctype_id":"_06h1fr93h499.Crate","schema_version":1}}
```

The id carries the draft's `_`-prefix — the doctype exists in the draft, not
in a live domain. The check comes back clean, with info notices about the
views you asked the assistant to skip.

Mistakes in the loop are normal and visible. In the same session, a first
`create_doctype` came back with
`{"ok":false,"error":"Invalid doctype definition: Missing required field 'doctype'"}`
— the assistant corrected its own definition and called the tool again.
That is the loop working: create, check, fix, re-check.

For the Brightwater Rentals example, a second session builds the story used
across the docs:

```text
Add a MaintenanceTicket doctype linked to Item: a problem text, a status
(open / in_progress / done), and a reference to the item it is about.
Run the check until it is clean.
```

## How the assistant knows Facet

The assistant carries a set of authoring guides built in: doctype anatomy,
field types, scope rules, view layout patterns, and the check workflow. When
it meets an unfamiliar rule, it reads the matching guide first. This is why
its output follows the same conventions a careful author would use.

## What it cannot do

The limits are enforced in each write tool, not by the prompt alone:

- **No publish.** No tool publishes the draft; you press **Publish**.
- **No grants or context sets.** The tools that edit them are not mounted;
  the assistant sends you to the **Grants** tab.
- **Nothing outside the draft.** Every write tool verifies the target
  domain equals the draft's.
- **No core doctypes.** Editing a `core` doctype (such as `core.Comment`)
  is refused unless you explicitly ask for it and confirm the risk.

Every change the assistant makes is attributed to you: the history shows
your account with an *Assistant · domain-builder* cause, not "system". A
wrong change rolls back like any other.

## Troubleshooting

**The assistant cannot create anything.**

Your role lacks the domain or doctype create right. Ask an administrator.

**The chat edits a different domain.**

The chat binds to the draft you opened it from. Reopen the chat inside the
right draft.

**A change is wrong.**

Say so in the chat, or undo in the editors. The history shows every
assistant write under your name, so a rollback works like any other.

**The preview looks broken.**

The template may bind a field that does not exist yet. Ask the assistant to
run the check; the binding errors name the field.

## Related

- [Agent tools reference](/reference/agent-tools/) — every tool the assistant can call.
- [The assistant: AI with your rights](/discover/how-it-works/assistant/) — why its changes carry your name.
- [Check before you publish](/build/model/in-app/check-before-publish/) — read the report the assistant worked through.
