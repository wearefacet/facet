---
title: History and undo (rollback)
description: Read a document's change history, put it back to an earlier version, and restore a deleted document.
audience: [user]
features: [FE-06, AUD-02, AUD-04]
sidebar:
  order: 6
verified_at: 49d7c7e5
---

Facet records every change to every document. The history page shows who
changed what, and when. You can put a document back to an earlier version.
You can also bring back a document that someone deleted.

## Steps

### 1. Open the history page

Open the document. The details block lists the created and updated times.
Select the History link in it. The link shows the current version, for
example v42.

The history page opens. Its heading shows the document name and the number of
recorded changes. Select Back to document to return.

### 2. Read a change entry

The timeline lists every change, newest first. Each row shows:

| Part | What it shows |
| --- | --- |
| Action | Create, update, delete, or snapshot |
| Document | The changed document. A change to a child document carries its own badge. |
| Summary | Short text that describes the change. |
| Actor | The account or system that made the change. |
| When | The time, relative to now. |

Select a row. The detail pane shows four lines:

- **What** — the action, the document, and its version at that change, for
  example v3.
- **Who** — the actor, with a chip that names the cause. Examples: via
  Assistant, via Rollback. A plain edit shows the channel; a browser session
  shows as facet.
- **When** — the full date and time in your timezone, plus the relative time.
- **Ref** — the change id with a copy button, and the number of field
  changes.

  Below the header, Facet lists the fields that changed. Most rows show the new
  value. A removed field shows a removed note. A value your role cannot see
  shows a Value hidden chip.

### 3. Put the document back to an earlier version

1. Select the change that holds the content you want.
2. Select Revert to this version. The dialog names the document and the
   change.
3. Select Roll back.

Facet sets the document back to the content and details of that change. A
new snapshot entry appears at the top of the timeline.

:::caution[Rollback overwrites content]
The document takes the full content of the selected change. Changes made
after it are gone from the document. They stay in the history. Select a later
change and revert again to return to them.
:::

:::note[How far back you can go]
Facet keeps each document's history for a set window. The default is 180
days. Your administrator sets the window. A revert to an older change fails,
and the error names the window.
:::

### 4. Restore a deleted document

If you have a link to the history page of the deleted document, open it.

1. Select the delete entry. The hint Revert restores the document. shows.
2. Select Revert to this version, then Roll back.

On the global audit log, an administrator selects the delete row and selects
Restore document.

Facet puts the document back with the content it had before the delete. Facet
also brings back the child documents that the delete removed.

:::note[Restore works at any age]
Facet always keeps the delete entry and the state before it. The retention
window does not block a restore.
:::

### 5. Undo a whole action (administrators)

Open the global audit log in the Configure area. It lists every change in
every domain. Each row shows the action, the document, the actor, the
channel, and the time.

Select a row. When one action changed several documents, the panel shows One
action — N changes across M documents, with a Roll back the whole action
control.

Select it, then confirm with Roll back action. Every document in the action
returns to its state before the action. Documents that the action created are
deleted.

:::caution[The undo covers every document in the action]
The undo overwrites later changes to every document in the action. The
history keeps those changes.
:::

The global audit log needs permission to read every domain. The undo also
needs update rights on each document in the action. If one document fails the
check, Facet changes nothing.

## Example

Select a change, and the page address updates. Send the address to a colleague. The colleague opens the same change:

```
/crm/Company/01JCATPMKP4N82GVG2J7K4MHZZ/history?mutation=01HRR7X9QK3V5T2W8Y4Z6A0BCD
```

## Troubleshooting

### The revert control is missing

The selected change is the newest one. A revert would change nothing. Select
an earlier change.

Your role may lack update permission on the doctype. Facet shows the reason
under the control.

### Facet refuses the rollback

The selected change is older than the retention window. The error names the
window. Ask your administrator to widen the window, or work with the current
content.

### An entry shows Value hidden

Your role cannot see that field. The log still lists the change, but not the
value. See [How Facet checks permissions](/concepts/authorization-enforcement/).

### A shared link does not open the change

The page loads older pages by itself. If it cannot find the change, it says
so. The change may be older than the retention window, or the link is wrong.

## Related

- [The mutation log](/concepts/mutation-log/) — what Facet records for every change.
- [Viewing and editing a document](/workspace/viewing-editing-document/) — where you open a document.
- [Roles, levels, and authority](/concepts/roles-levels-authority/) — the rights behind the revert control.
- [How Facet checks permissions](/concepts/authorization-enforcement/) — why some values show as hidden.
- [Govern access](/govern/) — set roles and retention windows as an administrator.
