---
type: how-to
title: Notifications and mentions
description: Notify people from scripts and mention them in comments.
audience: [author, user]
features: [AUT-06]
sidebar:
  order: 2
verified_at: eee55a2
---

A maintenance ticket sits unassigned for two days because nobody knew. A
notification is a short message in a person's bell menu, pointing at a
document. Two paths create them: you type `@` in a comment, or a script
sends one. Both paths are on this page, with the switch that silences them.
The script path needs one Lua call; the mention path needs no code at all.

## When to use this

- A review step should tell its reviewer without an email loop.
- A colleague should know someone mentioned them in a comment.
- You read notifications but want the badge and the panel to stay quiet.

## Before you start

- **For @mentions:** you write a comment on any document — see [Comments
  and attachments](/use/documents/comments-attachments/).
- **For scripted notifications:** you write Lua in a doctype script or a
  hook.

## Mention a person

Type `@` in a comment and pick a name from the list. The person receives a
notification that links back to the document. Three rules keep it quiet:

- Mentioning yourself sends nothing.
- Only a picked mention sends; plain text with an `@` does not.
- An edit notifies only the people who are new to the text — a mention kept
  through an edit stays silent.

## Turn the panel on or off

1. Open **Settings** and select the **Notifications** section.
2. Switch **In-app notifications** on or off.

Off stops the bell, the badge, and the live panel. Nothing is lost: Facet
still records the notifications, and switching on again shows what arrived
while you were muted.

## Send from a script

Scripts send notifications with `notification.send`. It takes a recipient,
a document to point at, and the message. A complete call in a create hook
on a Brightwater maintenance ticket:

```lua
local export = {}

function export.create(ctx)
  if ctx.actor == nil then return end
  if not ctx.root.assignee then return end
  local ok, sent = pcall(
    notification.send,
    ctx.root.assignee,
    nil,
    "ticket_assigned",
    "A ticket was assigned to you",
    {
      icon = "wrench",
      body = "Reported by " .. tostring(ctx.actor_id)
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
| Document | The qualified id of the document to open. `nil` means the current one. |
| Kind | A short tag, for example `ticket_assigned`. |
| Title | The one-line text in the bell menu. |
| Options | An icon, a longer body, structured data, and buttons. |

A button is an action descriptor — `{ key = "confirm", label = "Confirm",
variant = "primary" }` — and it must name an action that exists on the
pointed document. Three rules bound the send:

- **The send waits for the write.** Facet records the notification only
  after the change that caused it is saved. A failed change sends nothing.
- **The buttons run under the reader's rights.** A button names an action
  on the pointed document; running it dispatches through the same check as
  the document menu. A notification can never hand out a right the reader
  does not have.
- **A button fires once.** The first successful action closes every button
  on that notification; a second press answers `409`.

Wrap the call in `pcall` when a failure is acceptable; a malformed send
raises a Lua error at send time.

## Example

The comment mention flow, end to end, on the Brightwater example. Lucía
comments on maintenance ticket `MT-2026-0004`:

```markdown
@Tom Aaland can you order the contact cleaner today?
```

Facet creates one notification for Tom, pointing at the ticket. The title
reads *Lucía Ferrer mentioned you* — the ticket has no `name`, `title`, or
`label` field, so the host label is dropped rather than guessed. On a
doctype that has one, the title carries it: *Lucía Ferrer mentioned you on
Main tent 10x15*. Tom opens the bell, selects the entry, and lands on the
ticket. The entry stays unread until he reads or dismisses it.

## Troubleshooting

**A mention produced no notification.**

You mentioned yourself, or the name was typed as plain text instead of
picked from the list. Only a chip mention sends.

**The bell shows nothing new.**

The preference may be off, or the notification was already read. Check
**Settings → Notifications**.

**My script send fails with a validation error.**

A required argument is missing or too long: the title takes at most 256
characters, and buttons must name actions that exist on the pointed
document.

**Buttons on a notification do nothing for me.**

The action needs a right your role does not carry, or the notification
already fired its one action. Ask an administrator for the first, and
expect `409` for the second.

## Related

- [Comments and attachments](/use/documents/comments-attachments/) — where mentions live.
- [React to events and schedules](/build/model/automation/event-hooks/) — send notifications on any change, not only comments.
- [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — how notifications reach the bell.
- Internals on GitHub: [notifications.md](https://github.com/wearefacet/facet/blob/main/doc/backend/notifications.md).
