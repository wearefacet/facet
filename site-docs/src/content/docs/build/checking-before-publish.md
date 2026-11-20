---
title: Checking a domain before publish
description: Run the check tool on a draft domain and clear its issues before publish.
audience: [author]
features: [DOM-16]
sidebar:
  order: 18
verified_at: fd345fe3
---

A draft domain carries a check tool. It reads every doctype of the domain and reports what would not work after publish. Run it as often as you edit. Publish then re-checks the rules that involve live domains, and the publish dialog shows the result before anything lands.

## When to use this

- Before you publish a draft.
- After you add a reference, a replication field, or a view template.
- When the Builder landing page shows an issue count on a draft card.

## Before you start

- **A draft domain** that you hold the right to update.
- **Nothing to lose.** The check is read-only. It writes nothing.

## Steps

### 1. Run the check

Open the draft in the Builder and open the **Check** tab. The landing page also shows an issue count on every draft card. From a terminal, the check is one read on the domain:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/core/Domain/_a1b2c3/check"
```

### 2. Read issues and notices

The report splits into two kinds of entries:

| Kind | Meaning |
| --- | --- |
| Issue (warning or error) | A real defect. The publish confirmation counts these. |
| Notice (info) | A deliberate fallback, not a fault. For example, a missing view kind, or no `display_name` template. |

One defect blocks writes, not only the report: a reference field declared with a bare name such as `Client` (no `domain.` prefix) rejects every value of that field. The check marks it as an error.

### 3. Fix and re-run

Each issue names a category and often a field:

| Category | Points at |
| --- | --- |
| `reference` | A target doctype that is not registered, or a bare target name. |
| `children` | A child doctype that is not registered in the domain. |
| `composition` | A one-sided parent/child link, a missing `aggregate_root`, or a child modelled as a reference. |
| `replication` | A replicate field whose source, type, or grant does not hold. |
| `view` | A broken view template, or a template bound to an unknown field. |
| `template` | A label or search template with no variable in it. |
| `actions` | Named actions with no script. |
| `hooks` | A domain hook that does not compile. |

Fix the definition in the editor and run the check again. Repeat until the count is zero. Notices may stay; they describe behaviour, not faults.

:::note
A save lands on the server about one to two seconds after you confirm it. If a fix seems to have no effect, wait a moment and check again.
:::

### 4. Read the publish confirmation

The publish dialog runs its own checks and shows them before you confirm:

- **Composition closure.** Every parent/child link must be mutual.
- **Version gate** (publish over an existing domain). Every changed doctype needs the next schema version and a migration for the step.
- **Grant tickets.** Cross-domain edges in your definitions file tickets with the producing domains. The dialog reports each ticket and whether it lands active.
- **Warnings.** Publishing over a live domain does not carry the draft's domain hooks. The dialog names the hooks the publish leaves out.

## Example

The check of a draft with one doctype returns this report:

```json
{
  "data": {
    "domain": "_a1b2c3",
    "issue_count": 1,
    "domain_issues": [],
    "doctypes": [
      {
        "doctype_id": "_a1b2c3.Order",
        "issue_count": 1,
        "issues": [
          {
            "severity": "error",
            "category": "reference",
            "field": "customer",
            "message": "Reference field 'customer' declares a bare doctype name 'Client' — declare the qualified '_a1b2c3.Client' form; bare names match no registered doctype and every value of this field is rejected"
          }
        ],
        "notices": []
      }
    ]
  }
}
```

The fix: open the `Order` doctype, change the field target to `_a1b2c3.Client`, save, and run the check again. The count drops to zero and the publish confirmation stays clear.

## Troubleshooting

**The issue count does not go down.**

The report reads the stored definitions. Confirm the save landed, wait a moment, and run the check again.

**An issue names a doctype outside the draft.**

Replication and reference checks reach into live domains. The defect is still on your side: the draft points at something the other domain does not carry.

**Publish reports a version gate failure.**

The draft changes a doctype that exists on the target. Raise its `schema_version` by one and add the migration for the step. See [Evolving a schema](/build/evolving-schema/).

## Related

- [Draft domains concern doc](https://github.com/wearefacet/facet/blob/main/doc/backend/draft-domains.md) — the check and publish services in full.
- [Draft and publish](/concepts/draft-publish/) — how a draft becomes a domain.
- [Domains, drafts and domain editors](/build/domains-drafts-editors/) — create the draft and run the publish.
