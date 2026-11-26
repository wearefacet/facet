---
type: how-to
title: History and undo
description: Read a document's change history, put it back to an earlier version, and restore a deleted document.
audience: [user]
features: [FE-06, AUD-02, AUD-04]
sidebar:
  order: 3
verified_at: eee55a2
---

Facet records every change to every document. The history page shows who
changed what, and when. You can put a document back to an earlier version.
You can also bring back a document that someone deleted.

## Before you start

- [Open and edit a document](/use/documents/view-and-edit/) — how to open the document whose history you will read.

![The history page of a booking: the Audit trail timeline on the left and the detail pane for the selected change on the right.](/assets/screens/use/documents-3.png)

## Steps

### 1. Open the history page

Open the document and select **History** in the page header. The history
page opens. Its heading shows the record name and the number of recorded
changes, for example *15 mutations*. Select **Back to document** to return.

You can also send the page address to a colleague — it opens the same
history page.

### 2. Read a change entry

The timeline lists every change, newest first. Each row shows:

| Part | What it shows |
| --- | --- |
| Action | Create, update, delete, or snapshot. |
| Document | The changed document. A change to a child document carries its own badge. |
| Summary | Short text that describes the change. |
| Actor | The account or system that made the change. |
| When | The time, relative to now. |

Select a row. The detail pane shows four lines:

- **What** — the action, the document, and its version at that change, for
  example v3.
- **Who** — the actor, with a chip that names the cause. Examples: *via
  Assistant*, *via Rollback*. A plain edit shows the channel; a browser
  session shows as *facet*.
- **When** — the full date and time in your timezone, plus the relative
  time.
- **Ref** — the change id with a copy button, and the number of field
  changes.

Below the header, Facet lists the fields that changed. Most rows show the
new value. A removed field shows a *removed* note. A value your role cannot
see shows a **Value hidden** chip.

### 3. Put the document back to an earlier version

1. Select the change that holds the content you want.
2. Select **Revert to this version**. The dialog names the document and the
   change.
3. Select **Roll back**.

Facet sets the document back to the content and details of that change. A
new snapshot entry appears at the top of the timeline.

:::caution[Rollback overwrites content]
The document takes the full content of the selected change. Changes made
after it are gone from the document. They stay in the history. Select a
later change and revert again to return to them.
:::

:::note[How far back you can go]
Facet keeps each document's history for a set window. The default is 180
days. Your administrator sets the window. A revert to an older change
fails, and the error names the window.
:::

### 4. Restore a deleted document

If you have a link to the history page of the deleted document, open it.

1. Select the delete entry. The hint *Revert restores the document.* shows.
2. Select **Revert to this version**, then **Roll back**.

Facet puts the document back with the content it had before the delete.
Facet also brings back the child documents that the delete removed.

:::note[Restore works at any age]
Facet always keeps the delete entry and the state before it. The retention
window does not block a restore.
:::

### 5. Undo a whole action (administrators)

An administrator can undo one action that touched several documents — an
import, an assistant run, an automation. Open the global audit log in the
**Configure** area, select the action's row, and select **Roll back the
whole action**. Every document in the action returns to its state before
the action; documents the action created are deleted. The undo is
all-or-nothing: if one document fails the check, nothing changes.

The details and the rights this needs sit on the administrator pages:
[Auditing activity](/admin/history/audit/) and
[Rolling back changes](/admin/history/roll-back/).

## Example

Tom changes a booking date by mistake: he moves BK-2026-0002 a week too
far. The client calls. Tom opens the booking's **History**, selects his
wrong change, selects **Revert to this version**, and confirms. The booking
takes the content it had before his mistake, and the timeline shows a new
snapshot entry under Tom's name. No administrator needed.

Select a change, and the page address updates. Send the address to a
colleague. The colleague opens the same change:

```
/rentals/Booking/BK-2026-0002/history?mutation=01HRR7X9QK3V5T2W8Y4Z6A0BCD
```

## Troubleshooting

### The revert control is missing

The selected change is the newest one. A revert would change nothing.
Select an earlier change.

Your role may lack update permission on the record type. Facet shows the
reason under the control.

### Facet refuses the rollback

The selected change is older than the retention window. The error names the
window. Ask your administrator to widen the window, or work with the
current content.

### An entry shows Value hidden

Your role cannot see that field. The log still lists the change, but not
the value. See [Roles: who sees and does what](/discover/how-it-works/roles/).

### A shared link does not open the change

The page loads older pages by itself. If it cannot find the change, it says
so. The change may be older than the retention window, or the link is
wrong.

## Related

- [Open and edit a document](/use/documents/view-and-edit/) — where you open
  a document.
- [The mutation log](/admin/under-the-hood/change-log/) — what Facet records
  for every change, one layer down.
- [Auditing activity](/admin/history/audit/) — the administrator's view of
  every change.
- [Rolling back changes](/admin/history/roll-back/) — rollback in depth,
  including its limits.
- [Documents: records with a memory](/discover/how-it-works/documents/)
