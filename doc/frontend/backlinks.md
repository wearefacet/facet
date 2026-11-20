# Backlinks Panel

The backlinks surface shows, on a document's show page, which live documents
reference it — the inverse of the reference fields and inline links the
document itself carries. The backend derives the data from the projection
`links` column (see [`../backend/links.md`](../backend/links.md)); the
frontend consumes it read-only. Backlinks stay **informational**: delete is
never blocked by referring documents.

Two surfaces mount on the show route (`/[domain]/[doctype]/[id]`):

- **Referenced-by section** — a stub-row list under the view template. Each
  row links to the referrer's show route, labelled by `display_name` (the id
  when the referrer's doctype declares no template) with the doctype name as
  the secondary tag. The section self-hides when the document has no
  referrers — an empty list is metadata noise, not a state worth a
  placeholder. Past the `items` cap (default 50) a "N more" hint summarizes
  the tail.
- **Delete confirmation warning** — before the confirm dialog opens, the
  route calls the same endpoint; when referrers exist the message gains
  "{count} document(s) reference it — deleting it leaves those links
  dangling". A failed lookup (no read grant on a referrer doctype, offline)
  falls back to the plain confirm.

## Source Files

| File                                                                 | Role                                                                                                                              |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `src/lib/datasource/types.ts`                                        | `BackrefItem`, `BackrefsParams`, `BackrefsResponse` — the endpoint's `{ data, meta: { target, total, capped } }` shapes            |
| `src/lib/datasource/interface.ts`                                    | `DocumentRef.backrefs(params?)` — the document-level accessor                                                                       |
| `src/lib/datasource/DocumentDataSource.ts`                           | HTTP implementation — thin GET wrapper over `/Api/:domain/:doctype/:id/backrefs`                                                   |
| `src/lib/datasource/MockDataSource.ts`                               | Mock implementation — `onBackrefs(docId, items)` registers stub rows per document id (stories and tests)                            |
| `src/lib/datasource/DocumentDataSource.spec.ts`                      | URL construction (path + `items` cap + 404 mapping) and mock registration specs (Vitest `server` project)                           |
| `src/lib/components/features/document-view/BacklinksPanel.svelte`    | The "Referenced by" section — fetch, stub rows, cap hint, error row, self-hiding empty state                                        |
| `src/lib/components/features/document-view/BacklinksPanel.stories.svelte` | Stories double as component tests (play functions): populated, capped, and empty variants                                      |
| `src/routes/[domain=notApi]/[doctype]/[id]/+page.svelte`             | Mounts the panel below the view template and fetches the referrer count for the delete confirmation                                |

## DataSource API

`backrefs()` rides the standard `DocumentRef`, so every driver serves it:

```typescript
const refs = await driver.domain('hr').doctype('Team').doc(id).backrefs({ items: 50 });
// refs.data   => [{ id, domain, doc_type, display_name }]  (stub rows)
// refs.meta   => { target: 'urn:facet:hr:Team:…', total, capped }
```

Authorization is server-side and matches the rest of the read surface: a
missing, tombstoned, or denied target rejects with `DataSourceError` `404`
(non-disclosing), and referrer rows never leak past the caller's list
visibility (the backend AND-composes each readable doctype's list scope).
Unreadable referrers are simply absent — the panel renders what arrives.

The mock driver has no link extraction, so stories seed the rows a document
should report:

```typescript
const ds = driver.domain('bref').doctype('Team', [{ id: 't1', name: 'Core' }]) as MockDataSource;
ds.onBackrefs('t1', [{ id: 'p1', domain: 'bref', doc_type: 'Project', display_name: 'Apollo' }]);
```
