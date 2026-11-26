---
type: how-to
title: Notifications
description: Read notifications from the top-bar bell, act on them, download finished exports, and turn the bell off when you need quiet.
audience: [user]
features: [FE-09, AUT-06]
sidebar:
  order: 4
verified_at: eee55a2
---

Someone mentions you on a ticket, an export finishes, an automation flags a
record. Facet tells you in the app, on the bell in the top bar. The bell
shows how many notifications you have not read, and the panel behind it
holds the list.

![The bell in the top bar — selecting it opens the notification panel.](/assets/screens/use/notifications-1.png)

## Read your notifications

Select the bell. The panel opens below it, newest first. A notification you
have not read shows a dot and a bold title; the bell keeps the count while
any unread row remains.

Select a row. The panel closes, marks that notification read, and opens the
record it is about.

The panel shows one page of notifications. Select **Load more** at the
bottom for the next page, and **Mark all read** at the top when you want a
clean slate.

## Run an action from a notification

A notification can carry buttons — for example **Approve** or **Reopen**.
The button runs a named action on the record, under your own role: the same
checks apply as on the record page itself. Some actions ask you to confirm
first.

:::caution
The first action you run turns off every action button on that row. The row
then shows **Action taken**.
:::

An export notification carries a **Download** button instead. Select it to
save the file — on these rows, selecting the row itself downloads too,
instead of opening a record.

## Turn the bell off

1. Open **My settings** from the account menu at the bottom of the sidebar.
2. In the **Notifications** chapter, turn **In-app notifications** off.

The bell hides and the badge stops counting. Nothing is lost: notifications
sent while the bell is off appear when you turn it back on. Facet delivers
notifications in the app only — there are no notification emails.

## What sends a notification

| What happened | What you get |
|---|---|
| Someone mentions you in a comment | A notification that opens the record the comment is on. An edit that adds you notifies you too; keeping a mention through an edit stays silent |
| An export or import finishes | A notification with the file, ready to download |
| An automation sends one | Whatever the automation sends, about the record that changed |

Automations are small scripts the domain author attaches to a record type.
They run when records change or on a schedule, and one of the things they
can do is send a notification. What arrives, and when, is the author's
decision — ask them, or your administrator, when an automation is noisy.

## Troubleshooting

### No notifications arrive

Check your own switch first: **My settings** → **Notifications** →
**In-app notifications**. When it is off, the bell is hidden. Then check the source. You get a mention only when someone mentions you in
a comment, and an export notification only when you started that export.
If a colleague says they mentioned you and nothing arrived, ask your
administrator to check the automation.

### The unread count looks stale

The workspace refreshes the count about once a minute, and live updates
reach you while the page is open. If the count looks wrong, wait a minute
or reload the page.

### Every action button is off

An action already ran on that notification — the row shows **Action
taken**. One notification runs one action. If you need the action again,
open the record and run it there.

### An action fails

Your role does not allow that action on that record. Notifications are not
a way around your rights — ask your administrator for the right, or ask a
colleague who holds it to run the action.

## Related

- [Comments and attachments](/use/documents/comments-attachments/) — where
  comment mentions come from.
- [Import and export data](/use/documents/import-export/) — the exports
  that arrive as download notifications.
- [Your settings and API keys](/use/account/) — the in-app notifications
  toggle.
- [Notifications and mentions (for authors)](/build/model/automation/notifications/) —
  how the domain author sends notifications.
