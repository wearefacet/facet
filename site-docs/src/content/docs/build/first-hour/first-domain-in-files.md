---
type: tutorial
title: The same domain in files
description: Run the Brightwater equipment domain from files under the dev watcher, change one, and export a bundle.
audience: [developer]
features: [DOM-19, DOM-15]
sidebar:
  order: 3
prev: /build/first-hour/first-domain/
next: /build/first-hour/first-app/
verified_at: eee55a2
---

Tutorial 2 built the equipment domain in the Builder, with clicks. This
tutorial shows the other path: the same domain lives as a folder of files,
and the dev server applies every save. Developers who prefer an editor, a
diff, and a code review work this way — and it is how AI coding agents
touch a domain.

You will make one change to the Brightwater equipment domain, watch the
server apply it, and export the domain as a bundle.

**You will build:** one throwaway doctype in the equipment domain, then
remove it.
**Time:** about 15 minutes.
**You need:** [a dev environment](/build/dev-environment/) with the stack
running (`./scripts/dev`). The dev configuration already watches this
repository's example folder. To point the watcher at your own folder, set
`dev.domain_watch.path` in your dev config — see
[The dev domain watcher](/build/model/in-files/domain-watcher/).

:::caution
The watcher applies every save to the running database. The tutorial's
change is reversible — you delete the file at the end and the server
removes the doctype again. Never point the watcher at a folder you cannot
afford to change.
:::

## 1. Look at the domain folder

The example domains live under `site-docs/examples/brightwater/`. The
equipment domain is one folder:

```text
equipment.facet-domain/
├── bundle.yml
├── domain.yml
├── doctypes/
│   ├── equipment.Category.yml
│   ├── equipment.Item.yml
│   ├── equipment.Item.lua
│   └── equipment.MaintenanceTicket.yml
├── hooks/
│   └── 1-booking-drives-stock.lua
└── views/
    ├── equipment.Item/
    └── equipment.MaintenanceTicket/
```

`bundle.yml` names the domain. `domain.yml` is the domain document — its
label, color, description, and its hooks. One file in `doctypes/` is one
doctype definition; the `.lua` file next to `equipment.Item.yml` is that
doctype's lifecycle script. The folder is a **bundle**: the same format
`facet domain:export` writes and `facet domain:import` reads.

Look at one small definition, `equipment.Category.yml`:

```yaml
content:
  icon: tags
  color: "#0d9488"
  domain: equipment
  fields:
    name:
      type: string
      title: Name
      required: true
      unique: true
      filters:
        - equality
        - text_search
      description: "Category name, e.g. 'Tents', 'Sound', 'Lighting'."
  doctype: Category
  description: "A family of rental equipment."
  display_name: "{{ name }}"
  search: "{{ name }}"
  aggregate_root: true
  schema_version: 1
meta:
  parent_id: equipment
```

The shape is the doctype definition you saw in the Builder in tutorial 2 —
fields with types, a display name template, the schema version.

## 2. Add a doctype and watch it sync

Create a new file in `doctypes/`, next to the others. This tutorial adds a
small throwaway doctype, `ScratchNote`:

```yaml
---
content:
  icon: sticky-note
  color: "#64748b"
  domain: equipment
  fields:
    name:
      type: string
      title: Name
      required: true
      filters:
        - equality
    note:
      type: string
      title: Note
      description: "What the note says."
  doctype: ScratchNote
  description: "A warehouse scratch note."
  display_name: "{{ name }}"
  search: "{{ name }} {{ note }}"
  aggregate_root: true
  schema_version: 1
meta:
  parent_id: equipment
```

Save the file. Within about a second — the watcher polls every 500
milliseconds — the server log shows the sync. The example was captured from
the stack started by `./scripts/dev`:

```text
[backend] … WARN  facet.dev.domain_watcher: [dev-sync] dropping managed domain 'equipment' — full rebuild
[backend] … INFO  facet.dev.domain_watcher: [dev-sync] synced 'equipment' from './site-docs/examples/brightwater/equipment.facet-domain': 4 doctype(s) created, 0 updated, 0 unchanged, 0 document(s) replayed
```

The watcher replaces the domain's definitions from the folder on every
change; `4 doctype(s) created` counts the three existing ones plus your
new `ScratchNote`.

You should see the new doctype in the API. Sign in as the dev admin and
read the definition:

```sh
curl -skg -b cookies.txt -H "X-Requested-With: XMLHttpRequest" \
  https://facet.localhost:3443/Api/core/DocType/equipment.ScratchNote
```

```json
{"data":{"doctype":"ScratchNote","domain":"equipment","schema_version":1,…}
```

Create a document in it, as you would in the workspace:

```sh
curl -skg -b cookies.txt -X POST -H "X-Requested-With: XMLHttpRequest" \
  -H "Content-Type: application/json" \
  -d '{"name":"Winch check","note":"Tutorial test note"}' \
  https://facet.localhost:3443/Api/equipment/ScratchNote
```

```json
{"data":{…,"name":"Winch check","note":"Tutorial test note"},"meta":{"id":"06H1G4M80CXBFN2MVM5AAZBJME",…,"display_name":"Winch check"}}
```

The doctype is live the moment the file is saved — no restart, no publish
step.

### If the sync fails

The server keeps the previous state and logs the exact field error. Change
the field type in the file above from `string` to `text` and save:

```text
[backend] … ERROR facet.dev.domain_watcher: [dev-sync] import for 'equipment' (./site-docs/examples/brightwater/equipment.facet-domain) failed: 422 equipment.ScratchNote: bundle doctype definition is invalid: field 'note': Unknown field type: "text" (known types: any, array, boolean, color, data, date, dateperiod, datetime, dictionary, duration, enum, file, integer, longtext, money, object, period, phone, reference, secret, string, url) — keeping previous state
```

Fix the file (back to `string`), save, and the sync goes through.

## 3. Export the domain as a bundle

The folder is already the bundle format, but the export command is how you
capture a domain that was built or edited elsewhere — for example after a
colleague models it in the Builder. Export the equipment domain:

```sh
scripts/facet domain:export equipment --output tmp/equipment.tar.gz
```

```text
== facet domain:export ==
[equipment] Exported to /home/you/facet/tmp/equipment.tar.gz
  doctypes:          4
  document views:    4
  collection views:  2 (general only; personal excluded)
```

The bundle is definition-only: doctypes, their document views, and the
general collection views. Documents are not included — `--with-documents`
adds them. The tarball holds one folder per doctype:

```sh
tar -tzf tmp/equipment.tar.gz | head
```

```text
./
./views/
./views/equipment.MaintenanceTicket/
./views/equipment.MaintenanceTicket/collection_views/…
./views/equipment.MaintenanceTicket/document_views/form.yml
./views/equipment.MaintenanceTicket/document_views/card.yml
./views/equipment.Item/
./views/equipment.Item/collection_views/…
```

Move that file to another instance and import it — the same bundle format
the example's `load.sh` uses on a fresh install.

## 4. Remove the doctype and watch the revert

Delete the file you created:

```sh
rm site-docs/examples/brightwater/equipment.facet-domain/doctypes/equipment.ScratchNote.yml
```

The watcher applies the removal: the doctype leaves the domain, and its
documents are tombstoned — deleted, with their history kept for the
retention window. The log names both facts:

```text
[backend] … WARN  facet.dev.domain_watcher: [dev-sync] doctype 'equipment.ScratchNote' left the bundle — discarding its 1 document(s)
[backend] … INFO  facet.dev.domain_watcher: [dev-sync] synced 'equipment' from './site-docs/examples/brightwater/equipment.facet-domain': 3 doctype(s) created, 0 updated, 0 unchanged, 0 document(s) replayed
```

Read the doctype after the revert: Facet answers `410 Gone` — the row is a
tombstone, not a never-existed row:

```sh
curl -skg -b cookies.txt -o /dev/null -w "%{http_code}\n" \
  -H "X-Requested-With: XMLHttpRequest" \
  https://facet.localhost:3443/Api/core/DocType/equipment.ScratchNote
```

```text
410
```

The domain is back to its three doctypes. Nothing else changed.

## What you learned

- A domain can live as files in a bundle folder, next to the app path.
- The dev watcher applies every save within a second, and a failed
  validation keeps the previous state.
- `facet domain:export` captures a live domain as a definition-only bundle.
- Removing a doctype from the folder tombstones it and its documents.

## Related

- [The dev domain watcher](/build/model/in-files/domain-watcher/) — the
  watch contract: config keys, modes, failure behavior.
- [Domain files](/build/model/in-files/domain-files/) — the bundle format
  file by file.
- [Move domains with bundles](/build/model/bundles/) — export and import
  between instances.
- [Facet from source](/build/dev-environment/) — the dev environment this
  tutorial runs in.
- [Choose how you build](/build/model/)
## Next

The files path and the Builder path meet at the same live domain. In
[Ship your first app](/build/first-hour/first-app/) you build the
Brightwater check-out app on top of the domains you now know.
