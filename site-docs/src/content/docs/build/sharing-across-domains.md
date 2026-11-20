---
title: Share data across domains
description: Let one domain read another's fields through grants and replicated copies.
audience: [author, admin]
features: [DOM-14, DOM-25]
sidebar:
  order: 20
verified_at: fd345fe3
---

Domains keep their data apart. Two tools open a controlled door between them. A **domain grant** is a consent contract: the producing domain names a consumer and the resources it may read. A **replicated field** copies one value from a source document into the consumer's document, so the consumer shows it without a lookup.

## When to use this

- A doctype references documents in another domain and its scripts must read them.
- A list in domain `hr` should show a value that lives in domain `identity`, such as a person's full name.
- You want the copy to follow the source automatically.

## Before you start

- **Two sides.** Decide which side holds the contract: the **producer** gives data, the **consumer** receives it.
- **Tags.** Tag the producer fields you share. A field without tags carries the implicit tag `default`.
- **Read only.** Grants give read access only. No grant ever allows a write.

## Steps

### 1. File the grant on the producer

Create a grant document under the **producer** domain, as a child of its domain document. One grant per consumer:

```json
{
  "consumer_domain": "core.Domain.bill",
  "resources": [
    { "doctype": "identity.Person", "tags": ["default"] }
  ]
}
```

`resources` is one entry per producer doctype the consumer may read. The tags are the field mask at tag grain: a field is covered when it shares at least one tag with the entry.

### 2. Activate the grant

A new grant starts inactive. A holder of the `activate` action on grants in the producer domain turns it on; the same right turns it off. Facet refuses a self-grant: a domain needs no contract to read itself.

:::note
An inactive grant admits nothing. Deactivating does not erase values that were already copied.
:::

### 3. Declare the replicated field on the consumer

On the consumer doctype, add two fields: a reference to the source doctype, and a field that holds the copy:

```yaml
fields:
  person:
    type: reference
    doctype: "identity.Person"
  person_full_name:
    type: string
    replicate:
      via: person
      field: full_name
    on_source_delete: unset
```

Rules for the pair:

- `via` names the reference field on the same doctype.
- The source field must not be a secret, and a copy cannot feed another copy.
- `on_source_delete` is `keep` (default) or `unset`. `keep` leaves the copied value; `unset` clears it when the source is deleted.
- Users cannot write a copied field. It cannot be required or unique.

### 4. Watch the copies behave

Facet pulls the initial value when a consumer document is created or its reference changes. Later changes on the source push to every consumer that references it. Each push is a real, audited update on the consumer document.

:::caution
A cross-domain edge without an active grant stays inert. The check reports the missing grant, and the copy stays empty until the producer activates the contract.
:::

## Example

Domain `bill` invoices people stored in domain `identity`. The producer files and activates a grant on `identity.Person` with tag `default`. The `bill.Invoice` doctype carries:

```yaml
fields:
  person:
    type: reference
    doctype: "identity.Person"
  person_full_name:
    type: string
    replicate:
      via: person
      field: full_name
```

An invoice references `identity.Person.01HXYZ7Q2K4N82GVG2J7K4MHZZ`, whose `full_name` is `Ada Lovelace`. On create, `person_full_name` fills with `Ada Lovelace`. The person later renames to `Ada King`. The copy on the invoice updates to `Ada King` without anyone touching the invoice. The history shows the update as an automated change on the invoice.

## Troubleshooting

**The copy stays empty.**

Walk the chain: the grant must be active, it must name the source doctype, and its tags must cover the source field. The doctype check names the missing piece.

**The copy did not follow a source change.**

The reference must point at the source document. An empty or dangling reference has no source to pull from.

**The grant disappeared from the consumer's view.**

A widened grant returns to inactive until the producer accepts it again. The publish dialog reports this when it happens.

## Related

- [Domain grants concern doc](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md) — the grant contract and its gates.
- [Cross-domain replication](/concepts/cross-domain-replication/) — how copies flow between domains.
- [Event hooks](/build/event-hooks/) — react to another domain's events the granted way.
