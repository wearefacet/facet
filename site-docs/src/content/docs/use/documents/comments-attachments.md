---
type: how-to
title: Comments and attachments
description: Comment on a document and attach files in the panel beside the document page.
audience: [user]
features: [DOM-06, FE-04]
sidebar:
  order: 2
verified_at: eee55a2
---

The side panel sits beside a document page. Use it to discuss the document
in comments and to keep its files as attachments. Comments take markdown,
so you can format text, mention people, and link other documents.

![A maintenance ticket page with the side panel on the right: the Comments and Attachments tabs above the thread and the composer.](/assets/screens/use/documents-2.png)

## Before you start

- **Read access.** You need read access to the document. Without it, Facet
  does not show the document or the panel.
- **Create rights.** You need the right to create on the record type to
  comment or attach. A missing right hides the controls on this page.
- **Panel lists.** A record type decides which lists the panel carries. A
  type with no lists shows one column only.

## Steps

### 1. Open the side panel

Open a document. The panel stands on the right side of the page and stays
in place while you scroll the document.

A record type can carry more than one list, for example Comments and
Attachments. Each list then shows as a tab with a count. The count updates
when you add or remove an entry.

In a window of 1100 pixels or less, the panel moves below the document.

### 2. Write a comment

Open the Comments tab. The composer sits at the bottom and stays visible
while you scroll the thread.

Type in Write mode. The editor gives you headings, tables, code, and links.
Select Preview to read the result. Select Markdown to edit the raw text.

To put a file inside a comment, drop or paste it into the editor. An image
shows in the comment. Another file shows as a file link. Facet uploads the
file when you send.

Select **Comment** to send. While Facet saves, the button shows
**Posting…**. Your comment then joins the end of the thread with your name,
your picture, and the time.

:::tip[Fast submit]
Press Enter to send a comment. Press Shift+Enter to start a new line.
:::

### 3. Mention a person or link a document

Type `@` and start to type a name. A list opens with people and documents.
You can also type `[[` to open the same list.

Pick an entry. The editor inserts a chip that shows the current name of the
person or document. The person you mention receives a notification.

The list starts with the document's domain. Use the **All domains** row to
search everywhere. Press Esc to close the list; the text you typed stays.

The list does not open when `@` sits inside a word, for example in an
address.

### 4. Reply, edit, or delete a comment

**Reply.** Select **Reply** on the comment. A chip above the input shows
*Replying to* and the name. Type your reply and select **Comment**. To stop,
select the cancel button on the chip.

Facet nests replies under the comment they answer. The nesting shows to
three levels. A deeper reply moves up and carries a *replying to* note. A
thread with replies shows **Expand replies** or **Collapse replies**, with
the number of replies.

**Edit.** Select **Edit** on your comment. Change the text and select
**Save**.

**Delete.** Select **Delete** and confirm. Facet asks you to confirm,
because it cannot undo the delete. When someone deletes a comment that has
replies, Facet keeps the replies and shows a placeholder in place of the
deleted comment.

These controls show on your own comments. Your role decides this. Facet
checks your rights again when you save.

### 5. Attach a file

Open the Attachments tab and select **Choose file**. The name field fills
with the file name. Change it if you want.

Select **Attach**. While Facet uploads, the button shows **Attaching…**.
The file then lists with its type, its size, the time, and the account that
uploaded it.

| Rule | Detail |
| --- | --- |
| Largest file | 50 megabytes by default. Your administrator sets the limit. |
| File types | Any |
| Same content | Facet stores identical content once and reuses it. |
| Storage | Facet keeps file bytes in its file store, outside the document. |

### 6. Download, rename, or remove an attachment

**Download.** Select the download control on the row. The file opens in a
new tab. Facet checks your access at each download.

**Rename.** Select the rename control, change the attachment name, and
save.

**Remove.** Select the delete control and confirm.

:::caution[Delete is final]
When you confirm the delete, the attachment disappears from the document.
Facet asks: *Delete this attachment? This cannot be undone.*
:::

## Example

At Brightwater, Lucía reports damage on a ticket and asks Tom to call the
client. In Write mode she types `@` and picks Tom from the list. In Markdown
mode the same comment looks like this:

```markdown
Generator casing cracked near the exhaust. [@Tom Aaland](urn:facet:iam:Account:06H1FKYQFRDS3FBJ6HTX6FNQAE) — please call the client before Friday.

| Check | Result |
| ----- | ------ |
| Fuel level | Half tank |
| Hours run | 412 |
```

The chip keeps working when Tom's display name changes, and Tom receives a
notification.

## Troubleshooting

### The panel does not show

The record type carries no panel lists. Ask the domain author to add
comments to the type. See
[Add comments and attachments](/build/model/relations/comments-attachments/).

In a narrow window, look below the document. The panel sits there.

### The composer is missing

Your role cannot comment on this record type. Facet shows: *"You cannot
comment on this document."* Ask your administrator for the comment right.

### Facet rejects my upload

1. Check the file size. The file may be larger than the size limit. The
   default limit is 50 megabytes. Use a smaller file, or ask your
   administrator to raise the limit.
2. Check your rights. Your role may also lack the attach right. Facet then
   shows: *"You cannot attach files to this document."*

### I do not see Edit on a comment

You can change only your own comments. A moderator role can act on any
comment. Ask your administrator if you need this right.

## Related

- [Open and edit a document](/use/documents/view-and-edit/) — open and edit
  the document that hosts the panel.
- [Notifications](/use/notifications/) — what a person receives when you
  mention them.
- [Roles: who sees and does what](/discover/how-it-works/roles/) — the
  checks behind every comment, upload, and download.
- [Security](/discover/security/) — who may read and change documents.
- [Add comments and attachments](/build/model/relations/comments-attachments/) —
  how a domain author adds a panel list to a record type.
- [Documents: records with a memory](/discover/how-it-works/documents/)
