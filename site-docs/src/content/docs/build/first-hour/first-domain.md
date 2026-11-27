---
type: tutorial
title: Model your first domain
description: Build the Brightwater equipment domain in a draft — doctypes, fields, and a kanban board — check it, then publish it to a live domain.
audience: [author]
features: [DOM-01, DOM-02, DOM-03, DOM-04, DOM-16, DOM-21, FE-10, FE-03, AI-02]
sidebar:
  order: 2
verified_at: c34885a
---

You model the Brightwater equipment domain: the categories of gear, the
items themselves, and the maintenance tickets that keep them working. You
build it in a draft, try it on a kanban board, and publish it as a live
domain. The draft keeps every experiment away from real data until you
publish.

**You will build:** the Brightwater `equipment` domain — three doctypes,
typed fields, and a kanban board of maintenance tickets.
**Time:** about 20 minutes.
**You need:** [Facet running and the admin signed
in](/build/first-hour/run-facet/) — tutorial 1 ends there. Creating domains
needs an administrator account, and the seeded `admin` role holds it. On a
`setup-dev` instance that is `admin@example.tld` / `admin`.

*The path your domain takes from a private draft to the live workspace.*

<!-- d2
direction: down
draft: "Open a draft"
model: "Add doctypes and fields"
preview: "Try it in Preview"
check: "Check"
publish: "Publish"
live: "Live domain" {class: ok}
draft -> model
model -> preview
preview -> check
check -> model: fix
check -> publish: clean
publish -> live
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/f5f3c4f4-light.svg" alt="Open a draft" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/f5f3c4f4-dark.svg" alt="Open a draft" loading="lazy" />
</div>

## 1. Open the Builder and create a draft

Open **Builder** in the sidebar. The landing lists your drafts in progress;
the Builder sidebar holds the actions. Click **New domain** and fill the

![The New domain dialog in the Builder: a Label field, a Domain id field with the rule that the id is permanent once the domain is published, and Cancel and Create draft buttons.](/screens/build/first-domain-4.png)

dialog:

- **Label**: `Equipment` — the name people see in the interface.
- **Domain id**: `equipment` — the permanent name the domain receives at
  publish. Lowercase letters, digits, and dashes.

Click **Create draft**.

The draft opens on its Overview. The header shows **Equipment**, a
temporary id that starts with `_` (for example `_06h1gc0yjgkj`), and a
**DRAFT** badge. The tab strip reads Overview / Doctypes / Editors /
Grants / Check. Everything you build now stays in this private work area.

:::note
**Do you have a model connected?** The domain-builder assistant can
propose this whole draft from a plain-language description — "a warehouse
domain with categories, items, and maintenance tickets". You review its
proposal in the same editors this tutorial uses. Without a model, follow
the manual steps below; they need nothing extra. See [Build with the
assistant](/build/model/in-app/build-with-assistant/).
:::

## 2. Add the Category doctype

Click **Add doctype** in the sidebar, type `Category`, and click **Create
doctype**. The doctype editor opens on the Fields tab.

Click **Add field**. A field named `new_field` appears. Set it up in the
right pane:

- **Key**: `name`
- **Type**: String
- **Title**: `Name`
- **Required**: on

Click **Save** in the header. The flash message **Saved** confirms the
write. Edits stay local until that save — a reload drops them.

A document needs a display label. Open the **General** tab, scroll to
**Document templates**, set the **Label template** to `{{ name }}`, and
save. Each category then displays by its name in every list and link.

You should see one field, `name`, marked required with an asterisk.

## 3. Add the Item doctype

Click **Add doctype** again, type `Item`, and click **Create doctype**.
Add five fields, saving after each:

| Key | Type | Settings |
| --- | --- | --- |
| `name` | String | Title `Name`, **Required** on |
| `category` | Reference | Title `Category`; Target doctype `Category` |
| `status` | Enum | Title `Status`; values `available`, `out`, `in_repair` |
| `purchase_price` | Money | Title `Purchase price` |
| `serial_number` | String | Title `Serial number`; **Unique** on |

![Adding the category field on the Item doctype: the field editor with Key and Title, the Type list open on String, and the Filter capabilities chips below.](/screens/build/first-domain-5.png)

Four of these deserve a word:

- **Enum** holds a fixed value set. Type each value key into the `+ value`
  box and press Enter — the interface shows a human label, so `available`
  displays as Available. Only enum and boolean fields can group a kanban
  board, which is why the statuses use this type.
- **Reference** points at another doctype. On commit the editor qualifies
  the bare target to the draft id — `_06h1gc0yjgkj.Category` in this run.
  Publish rewrites it to `equipment.Category`, so the qualified form is
  correct as it is.
- **Money** stores an amount with a currency. The editor asks where the
  currency comes from; the defaults are fine for now.
- **Unique** refuses a second document with the same value — no two items
  share a serial number.

Set the **Label template** to `{{ name }}` on the General tab and save.
You should see five fields; the list shows a type chip on each — string,
reference, enum, money, string.

## 4. Add the MaintenanceTicket doctype

Create the doctype the same way. Its fields:

| Key | Type | Settings |
| --- | --- | --- |
| `item` | Reference | Title `Item`; Target doctype `Item`; **Required** on |
| `problem` | Long Text | Title `Problem`; **Required** on |
| `status` | Enum | Title `State`; values `reported`, `diagnosing`, `waiting_parts`, `fixed` |

Two notes:

- The **Default ★ marks the default** select under the value chips picks
  the value a new document starts with. Pick `reported`.
- The key `status` with the title `State` is deliberate. `state` is a
  reserved name, and the save refuses it with *"is a reserved field name
  and cannot be used"*. The reserved names include `state`, `id`,
  `version`, and `links`.

Set the **Label template** to `{{ item }}` — a ticket displays the item it
is about — and save. You should see three fields, `item` and `problem`
marked required.

## 5. Try the model in Preview

Click **Preview** in the top bar. The workspace opens with a banner —
"Previewing draft … — schema edits are not available here" — and your
draft's doctypes in the sidebar. Nothing here touches live data.

Open the **MaintenanceTicket** list. A new doctype has no views, so the
page shows the starter screen: one card per layout. Pick **Kanban** —
"Cards grouped into lanes".

The New view dialog asks for:

![The New view dialog for a kanban view: Name, the Scope choice between Personal and General, Board mode with By field values and Custom lanes, Group by, Allow card moves, and Card sort.](/screens/build/first-domain-6.png)

- **Name**: `Board`
- **Scope**: **General** — every reader of the doctype sees this view.
  The choice is fixed after you save.
- **Board mode**: **By field values** — one lane per value of the chosen
  field.
- **Group by**: `State`. Each value of the field becomes a lane.

Click **Create view**. Four lanes open — Reported, Diagnosing, Waiting for
parts, Fixed — all empty.

Now feed the board. The ticket form requires an item, and the item form
requires a category, so create them in that order through each list's
**New** button:

| List | Documents |
| --- | --- |
| Category | `Tents` |
| Item | `Main tent 10x15` (Tents), `Folding chair white` (Tents) |
| MaintenanceTicket | three tickets, one per state: `reported` with the problem "Zip seam splits under load", `diagnosing` with "Frame pin sheared", `fixed` with "Loose guy-line clip replaced" |

Each ticket card shows its item name — the label template at work. The
board now groups three tickets over the four lanes. These documents are
scratch: publish leaves them behind unless you tick **Import existing
documents** in step 7.

## 6. Check the draft

Click **Exit preview** to return to the Builder, then open the **Check**
tab. The report runs over every doctype in the draft and groups the result
**By doctype**. A clean doctype shows `0 issues`. The **Notices** list
below collects informational defaults — a missing search template, the
standard view kinds. None of them needs action.

One error a fresh domain often carries: a doctype with no label template
and no search template. The report says *"No display_name and no search
template: the cross-doctype search endpoint skips the doctype…"*. If it
names one of yours, open that doctype's **General** tab, set the **Label
template**, save, and click **Refresh** on the Check tab. When nothing is
left, the publish dialog confirms: "No problems detected. Ready to
publish."

## 7. Publish

Click **Publish** in the top bar. The **Publish draft domain** dialog
prefills the **Target domain name** with `equipment`.

![The Publish draft domain dialog over the Check tab: the target domain name prefilled with equipment, the Import existing documents box unticked, and Cancel and Publish buttons.](/screens/build/first-domain-7.png)

Leave the **Import
existing documents** box unticked — the scratch documents stay behind and
the draft drops. Click **Publish**.

Facet copies the doctype definitions, the document templates, and your
saved views into a fresh live domain named `equipment`, then removes the
draft. The report names the published domain; the Builder landing shows no
drafts.

## 8. See it in the workspace

Open the workspace and pick **Equipment** in the domain picker. The three
doctypes are there. Open **MaintenanceTicket**: the **Board** tab you
created in Preview carried over, with its four lanes — empty, because the
scratch tickets stayed behind.

On the loaded Brightwater example the board is at work. One lane per
state, cards showing the item and the assignee:

![The MaintenanceTicket board of the equipment domain on the finished Brightwater example: one lane per state — Reported, Diagnosing, Waiting for parts, Fixed — with ticket cards showing the item, the state chip, and the assignee.](/screens/build/first-domain-1.png)

The equipment domain is the base of the whole Brightwater story. The
`clients` domain holds the companies, and the `rentals` domain holds their
bookings — each booking line references one of your items. The surfaces
your team works on every day look like this:

![The Booking list of the finished Brightwater example: the All bookings table view with search, filters, Export and Import, beside a Calendar view tab.](/screens/build/first-domain-2.png)

![A Booking document of the finished example: its fields, the Lines children as chips, and the comments pane.](/screens/build/first-domain-3.png)

You built and shipped a domain. The live `equipment` domain carries three
doctypes and typed fields: a reference, an enum, money, a unique
constraint. A kanban board groups the tickets by state. Label templates
give every document its name. To change the model later, open the Builder
and use **Edit existing** — Facet drafts the live domain for you.

## What you learned

- A draft is a private work area; publish copies the structure and drops
  the draft — read more in [Drafts, editors and
  publishing](/build/model/in-app/drafts-and-publishing/).
- Every field type and its settings — [Field
  types](/build/model/data/field-types/).
- The check report, and what it means for a publish — [Check before you
  publish](/build/model/in-app/check-before-publish/).
- Tables, boards, and calendars as saved views — [Collection
  views](/build/model/views/lists-boards-calendars/).
- The assistant can propose the model with you — [Build with the
  assistant](/build/model/in-app/build-with-assistant/).
- Prefer files and diffs? The same domain can live as a folder of files —
  [The same domain in files](/build/first-hour/first-domain-in-files/).

## Troubleshooting

### The save refuses a field name

The error *"is a reserved field name and cannot be used"* names a key Facet
uses internally (`state`, `id`, `version`, `links`, and the system
timestamps). Pick another key and keep the visible name in the **Title** —
that is what the example does with `status` / `State`.

### The Group by list has no field

The picker offers only enum and boolean fields that carry an equality
filter. Open the field in the Builder and check its **Filter
capabilities**.

### Publish refuses the target name

The name must be lowercase letters, digits, and dashes, and start with a
letter. A name that starts with `_` is a draft name. Fix the **Domain id**
on the draft's Overview tab and publish again.

### Publish says the domain name is already in use

A live domain already carries the name — demo data, or an earlier run of
this tutorial. Facet refuses the first publish over an existing name, and
the dialog then offers **Publish over {name}**. Confirm it only when you
mean to replace that domain's structure: every doctype you changed must
raise its schema version by one and carry a migration — see
[Change a live domain safely](/build/model/change-a-live-domain/). To keep
the existing domain, type another name in the dialog's target field and
publish again.

### My change did not appear at once

The definition cache updates a second or two after a save. Wait briefly
and test again.

### A field edit did not stick

Field edits are local until the header **Save**. The flash message
**Saved** is the confirmation — re-check the field and save again.

## Related

- [Drafts, editors and publishing](/build/model/in-app/drafts-and-publishing/)
  — the full draft lifecycle, co-editors, and publishing over a live
  domain.
- [Check before you publish](/build/model/in-app/check-before-publish/) —
  every category the report can name.
- [Field types](/build/model/data/field-types/) — the type system in full.
- [Collection views](/build/model/views/lists-boards-calendars/) — table,
  kanban, and calendar views beyond the starter.
- [How drafts work](/build/model/in-app/how-drafts-work/)
- [Field types](/reference/field-types/)
## Next

Your domain is live. In [Ship your first app](/build/first-hour/first-app/)
you build the Brightwater check-out app on top of it, and the warehouse
team signs in through Facet.
