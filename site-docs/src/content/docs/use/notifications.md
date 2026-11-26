---
type: how-to
title: Notifications
description: Read notifications from the top-bar bell, act on them, and set your in-app preference.
audience: [user]
features: [FE-09, AUT-06]
sidebar:
  order: 4
verified_at: 49d7c7e5
---

Facet delivers notifications inside the workspace. A bell in the top bar
shows how many notifications you have not read. Notifications tell you about
comment mentions, finished exports, and events that automations send.

## Steps

### 1. Open the notification panel

Select the bell in the top bar. The panel opens below the bell. It lists your
notifications, newest first. An unread row shows a dot and a bold title. The
bell shows the unread count while you have unread notifications.

### 2. Open a notification

Select the row. The panel closes, marks the notification read, and opens the
record the notification is about.

### 3. Run an action

A notification can carry action buttons, for example Approve or Reopen. An
action runs on the record, under your own role. The same checks apply as on
the record page. Some actions ask you to confirm first.

:::caution
The first action you run turns off every action button on the row. The row
then shows **Action taken**.
:::

### 4. Download an export

An export notification carries a **Download** button. Select it to save the
file. On these rows, selecting the row itself also downloads the file,
instead of opening a record.

### 5. Mark everything read

Select **Mark all read** at the top of the panel. The button appears when you
have unread notifications. Opening a row marks that one row read.

### 6. See older notifications

The panel shows one page of notifications. Select **Load more** at the bottom
for the next page.

### 7. Turn notifications on or off

1. Open **My settings**, and select the **Notifications** chapter.
2. Turn **In-app notifications** on or off.

When it is off, the bell hides, and the workspace stops showing
notifications. When you turn it on again, the notifications sent in the
meantime appear.

:::note
Notifications are in-app only. Facet does not send notification emails.
:::

## What sends a notification

| Source | What you get |
| --- | --- |
| A comment mention | A notification that opens the record the comment is on |
| A finished export | A notification with the file, ready to download |
| An automation on a doctype | Whatever the automation sends, about the record that changed |

Automations are scripts that run when a record changes. The doctype author
decides when an automation sends a notification.

## Troubleshooting

### No notifications arrive

1. Check the preference first: **My settings** → **Notifications** → **In-app
  notifications**. When it is off, the bell is hidden.
2. Check the source. You get a mention only when someone mentions you in a
  comment.

### The unread count looks stale

The workspace refreshes the count itself. If it looks wrong, wait up to one
minute, or reload the page.

### Every action button is off

An action already ran on that notification. The row shows **Action taken**.

### An action fails

Your role may not allow the action on that record. Notifications are not a
way around rights.

## Related

- [Comments and attachments](/use/documents/comments-attachments/) — where comment mentions come from.
- [Import and export data](/use/documents/import-export/) — the exports that arrive as download notifications.
- [Your settings, sessions and API keys](/use/account/) — the in-app notifications toggle.
- [Event hooks and scheduled hooks](/build/model/automation/event-hooks/) — where the automations that send notifications live.
- [Events and delivery](/admin/under-the-hood/events-and-delivery/) — how the workspace receives live updates.
