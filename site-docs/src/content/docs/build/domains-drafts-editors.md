---
title: Domains, drafts and domain editors
description: Open a draft domain, build and check doctypes with co-editors, and publish the structure to a live domain.
audience: [author]
features: [DOM-01, DOM-02, DOM-13, FE-13]
sidebar:
  order: 1
verified_at: fd345fe3
---

A domain is one business area with its own doctypes and its own data. You build a domain in a **draft**: a private work area whose name starts with `_`. Inside a draft you change definitions freely. When the model is ready, you publish it under its real name. Facet then creates the live domain and drops the draft.

## When to use this

Open a draft when you design a new domain, or when you change a live domain and want to test first. The draft is also where co-editors work with you: everyone who edits the draft keeps the right to edit the published domain.

:::note
A draft holds no production data. Documents you create while you test are scratch. Publish copies the structure only — never the documents.
:::

## Before you start

- **The editor role.** It lets you open a draft. Facet records you as the first domain editor of that draft.
- **Edit rights on the live domain** to fork it into a draft. Use the **Edit existing domain** action in the Builder.
- **An administrator for co-editors.** An administrator lists co-editors on the **Editors** tab of a domain. You cannot add co-editors yourself.

## Steps

### 1. Open a draft

In the Builder, create a new draft. Facet generates the name; it always starts with `_`. Set the two name fields at once:

| Field | Rule | Purpose |
| --- | --- | --- |
| Name | Lowercase letters, digits, and dashes. Starts with a letter. | The name of the live domain you plan to publish. |
| Label | Free text, up to 64 characters. | The name people see in the interface. |

:::tip
Set the **Name** field early. Facet checks the format when you save the draft, so a typo fails at once and not at publish time.
:::

### 2. Add and change doctypes

Create the doctypes of your model (see [Designing doctypes](/build/designing-doctypes/)). Inside a draft, Facet relaxes the version rules: you can remove a field, change a type, or skip a version. All other schema checks still run, and every script must compile.

The definition cache updates a second or two after you save. Re-test a change after a short wait before you judge it.

### 3. Test in preview

Open a preview session from the draft. Facet then shows the draft in the live application: you open pages, run actions, and create documents, all inside the draft. Cross-domain references into live domains show no data during preview.

### 4. Run the checks

Open the **Check** tab. Facet lists the issues and notices for every doctype in the draft. An empty draft reports that there is nothing to publish. Fix the issues before you publish (see [Checking a domain before publish](/build/checking-before-publish/)).

### 5. Publish

Open the publish confirmation. You choose the target name and the mode:

- **Fresh publish** — the target name must be free. Facet creates the domain and copies your doctypes.
- **Overwrite publish** — the target domain exists. For every doctype you changed, the schema version must be exactly one above the live version, with a migration entry for the gap (see [Evolving a schema](/build/evolving-schema/)).

Facet copies the co-editors to the published domain, files any cross-domain grant tickets, and drops the draft. Publish re-validates the model: the composition graph must close, and the overwrite version gate must pass.

<!-- d2
open: "Open a draft" {class: external}
edit: "Add and change doctypes"
check: "Check"
publish: "Publish"
live: "Live domain" {class: ok}

open -> edit
edit -> check
check -> edit: fix
check -> publish: ready
publish -> live
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/d7c475df-light.svg" alt="Open a draft" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/d7c475df-dark.svg" alt="Open a draft" loading="lazy" />
</div>

## Example

The call below publishes a draft to a fresh domain named `orders`. Read the API key from the `FACET_API_KEY` environment variable.

```sh
curl -k -X POST "https://facet.localhost:3443/Api/core/Domain/_3fjqk2m8p1xz/publish" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"target_name": "orders", "overwrite": false}'
```

The response names the published domain and reports any grant tickets and warnings. `-k` skips the certificate check of the local development address.

## Troubleshooting

### Publish refuses the target name

The name must be lowercase letters, digits, and dashes, and it must start with a letter. A name that starts with `_` is a draft name. Fix the **Name** field or the target name and publish again.

### Overwrite publish refuses a doctype

The live version and your draft version differ by more than one, or a migration entry is missing. Raise the version one step at a time, or publish to a fresh domain instead.

### My change did not appear at once

The definition cache updates a second or two after a save. Wait briefly and test again.

### I cannot delete the live domain

Deleting a domain is an administrator action, and Facet refuses while one of its drafts is open. Discard the draft first.

## Related

- [Draft domains (engineering doc)](https://github.com/wearefacet/facet/blob/main/doc/backend/draft-domains.md) — the full draft and publish contract.
- [Draft → publish](/concepts/draft-publish/) — why drafts exist and what publish copies.
- [Designing doctypes](/build/designing-doctypes/) — declare your first doctype inside the draft.
