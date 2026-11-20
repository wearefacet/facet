---
title: Notifications and mentions
description: Notify people from scripts and mention them in comments.
audience: [author, user]
features: [AUT-06]
sidebar:
  order: 24
verified_at: fd345fe3
---

A notification is a short message in a person's bell menu, pointing at a document. Two paths create them: you type `@` in a comment, or a script sends one. This page covers both, plus the switch that silences them.

## When to use this

- A review step should tell its reviewer without an email loop.
- A colleague should know someone mentioned them in a comment.
- You read notifications but want the badge and the panel to stay quiet.

## Before you start

- **For @mentions:** write a comment on any document. See [Comments and attachments](/workspace/comments-attachments/).
- **For scripted notifications:** you write Lua in a doctype script or a hook.

## Steps

### 1. Mention a person

Type `@` in a comment and pick a name. The person receives a notification that links back to the document. Mentioning yourself does nothing, and an edit only notifies people who are new to the text.

### 2. Turn the panel on or off

1. Open **Settings** and select the **Notifications** section.
2. Switch **In-app notifications** on or off.

Off stops the bell, the badge, and the live panel. Nothing is lost: Facet still records the notifications, and switching on again shows what arrived while you were muted.

### 3. Send from a script

Scripts send notifications with `notification.send`. It takes a recipient, a document to point at, and the message. A complete call in a create hook:

```lua
local export = {}

function export.create(ctx)
  local ok, sent = pcall(
    notification.send,
    ctx.root.owner_id,
    nil,
    "leave_approved",
    "Your leave request was approved",
    {
      icon = "check",
      body = "Approved by a manager",
      actions = {
        { key = "reopen", label = "Reopen", variant = "primary" }
      }
    }
  )
  if not ok then
    ctx.error("Failed to notify: " .. tostring(sent))
  end
end

return export
```

| Argument | Meaning |
| --- | --- |
| Recipient | An account id. Use a field of the document, as above. |
| Document | The id of the document to open. `nil` means the current one. |
| Kind | A short tag, for example `leave_approved`. |
| Title | The one-line text in the bell menu. |
| Options | An icon, a longer body, and buttons. |

The buttons run actions on the pointed document, under the reader's own rights. A notification can never hand out a right the reader does not have.

:::note
A send is recorded only after the change that caused it is saved. A failed change sends nothing.
:::

## Example

The comment mention flow, end to end. Marie comments on the contract `accountancy.Contract.01HQABC3N7P2K5R8WVBN6P3A1YCD`:

```markdown
@Ada Lovelace can you check the totals before Friday?
```

Facet creates one notification for Ada with the title `Marie Dubois mentioned you on Contract 47`, pointing at the contract. Ada opens the bell, selects the entry, and lands on the contract. The entry stays unread until she reads or dismisses it.

## Troubleshooting

**A mention produced no notification.**

You mentioned yourself, or the name was not picked from the list. Only a chip mention sends; plain text does not.

**The bell shows nothing new.**

The preference may be off, or the notification was already read. Check Settings → Notifications.

**My script send fails with a validation error.**

A required argument is missing or too long. The title has a length limit, and buttons must name actions that exist on the pointed document.

**Buttons on a notification do nothing for me.**

The action needs a right your role does not carry. Ask an administrator.

## Related

- [Notifications concern doc](https://github.com/wearefacet/facet/blob/main/doc/backend/notifications.md) — the store and the producer API.
- [Event delivery](/concepts/events-delivery/) — how notifications reach the bell.
- [Event and schedule hooks](/build/event-hooks/) — send notifications on any change, not only comments.
