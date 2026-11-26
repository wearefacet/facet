---
type: how-to
title: Using the assistant
description: Open the chat, ask about your documents, and let the assistant make changes for you.
audience: [user]
features: [FE-22, AI-01]
sidebar:
  order: 5
verified_at: 49d7c7e5
---

The assistant is a chat window that works with your data. You ask in everyday
words. It finds documents, makes changes, computes numbers, and opens pages.
Replies arrive while it works. Everything it does runs inside your account's
rights.

## Before you start

Your role must include assistant access. Your administrator grants it. If the
top bar shows no assistant button, your role does not include assistant
access. Ask your administrator to enable it.

## Steps

### 1. Open the chat

Use any of these:

- Select the **Assistant** button in the top bar.
- Press Ctrl+I, or Cmd+I on a Mac.
- Open the command palette (Ctrl+K or Cmd+K) and select **Toggle the
  assistant**.

  The chat opens as a floating window. Move it, resize it, collapse it, or
  maximize it. Your instance may show another name than "Assistant". Your
  administrator sets that name.

:::tip
The window stays open while you move through the workspace. Keep it beside
your work and ask as you go.
:::

### 2. Ask for what you need

Type into the message box. Press Enter to send. Press Shift+Enter to add
a new line. You can also select the send button.

Examples:

- "Find the companies with status lead."
- "Show the tasks due this week as cards."
- "Sum the annual revenue of these companies."
- "Change the status of Acme Corp to active."
- "Create a task for the Acme follow-up."
- "Open the Acme Corp page."

The assistant writes in the language of your workspace. You can ask it to
write in another language.

### 3. Follow the work

The reply streams in while the assistant works. A **Thought** block shows its
reasoning. It folds away when the answer starts. Results appear as document
cards, compact rows, or number tiles. When the assistant opens a page for
you, the workspace navigates there at once.

The send button becomes **Stop** while the assistant works. Select it to
cancel the current answer. The text written so far stays, marked
"Cancelled."

### 4. Keep your conversations

The rail on the left lists your conversations. Select one to continue it.
Select **+ New** to start another one. The toggle in the rail header shows
archived conversations. A finished reply carries a copy button. It copies
the answer text.

## What the assistant may do

The assistant can:

- find and read documents, also across lists
- show documents as cards in the chat
- create, change, and delete documents. A delete sends the document to the
  trash.
- run the named actions of a list
- compute counts, sums, averages, minimums, and maximums
- open pages in the workspace
- read the history of a document

All of this runs under your account's rights:

- The assistant sees only what your account may see. A hidden field stays
  hidden. A row you cannot read stays out.
- Facet records every change under your account, in the same history as your
  hand edits.
- A denial is final. When the assistant refuses an action, asking again does
  not change the answer. You lack the right for it. Ask your administrator,
  or do the action yourself if you can.

  These rules are the same on every path into Facet. Read
  [AI under the caller's rights](/discover/how-it-works/assistant/) for the
  model behind them.

## Usage limits

When your account has a budget, a bar above the message box shows your use:
"12% of the 30-day budget used". Without a budget, you see no bar.

When the budget is spent, Facet stops new messages:

> You have used your full assistant token budget for this 30-day window.
> Ask an administrator to raise the budget, or wait for older usage to
> leave the window.

The window rolls. Usage older than 30 days stops counting.

## Troubleshooting

### The assistant button is missing

Your role does not include assistant access. Ask your administrator to enable
it. The chat is also absent on the Configure screens. That is normal.

### The assistant refuses an action

The refusal is final. Your account lacks the right. Ask your administrator for
it, or do the action yourself if you can.

### The message says you used your full budget

For example: "You have used your full assistant token budget for this 30-day
window."

Wait for old usage to leave the window, or ask your administrator to raise
the budget.

### The answer stopped halfway

The connection may have broken. The work continues on the server.

1. Reopen the chat. Facet catches up and shows the finished answer.
2. Wait for the current answer to finish. You cannot send the next message
   until it does.

### An error line appears

For example: "The turn failed."

Read the error. Send the request again. If it fails every time, ask your
administrator.

## Related

- [AI under the caller's rights](/discover/how-it-works/assistant/) — the
  model that keeps the assistant inside your rights.
- [Search and the command palette](/use/finding/search/) —
  the palette also opens the assistant.
- [History and undo](/use/documents/history-undo/) — where the assistant's
  changes appear.
- [Keyboard shortcuts](/use/finding/keyboard-shortcuts/) — the assistant
  shortcut and all others.
- [Roles, levels and the authority guard](/admin/people/who-can-change-roles/) —
  what a role controls.
