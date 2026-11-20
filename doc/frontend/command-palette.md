# Command palette — global search and command surface

The top-bar search trigger's target: one command palette, open from the trigger or with `Cmd/Ctrl+K`, with four result groups — navigation, recent documents, record search, and shell actions. Serves the live shell and the Configure shell; Builder mode has no trigger but answers the keybind on its routes too (the nav model follows the active shell).

## Source files

- [`frontend/src/lib/components/features/search/CommandPalette.svelte`](../../frontend/src/lib/components/features/search/CommandPalette.svelte) — the Bits UI Dialog palette
- [`frontend/src/lib/components/features/search/CommandPalette.stories.svelte`](../../frontend/src/lib/components/features/search/CommandPalette.stories.svelte) — stories double as component tests
- [`frontend/src/lib/components/features/search/searchGroups.ts`](../../frontend/src/lib/components/features/search/searchGroups.ts) — pure: item assembly, local matching, grouping (Vitest-covered)
- [`frontend/src/lib/components/features/search/searchRecords.ts`](../../frontend/src/lib/components/features/search/searchRecords.ts) — pure: the record-search adapter to the search endpoint (Vitest-covered)

## Result groups

| # | Group | Source | Activation | Filter |
| --- | --- | --- | --- | --- |
| 1 | Navigate | nav model — domains, then doctypes of the active domain | `goto /{domain}` · `goto /{domain}/{doctype}` | local, instant |
| 2 | Recent | `getRecentDocuments(activeDomain)`; labels resolved as the dashboard does | show page | local |
| 3 | Records | the search endpoint (see [`../backend/search.md`](../backend/search.md)), debounced | root show page — a child hit resolves to its aggregate root | remote |
| 4 | Actions | command list supplied by the host shell (props) | per command | local; the host gates permissions |

Groups with no items do not render. The records group appears when its first results land; the other three are synchronous. In Configure there is no active domain, so only Navigate (configure surfaces) and Actions render there.

## Component contract

- Props: `open` (bindable), `commands: PaletteCommand[]`, `activeDomain: string`, optional `searchPlaceholder`. `PaletteCommand` is `{id, label, run()}` plus an optional group/icon. An action row renders the command's Lucide icon (kebab-case) through `DoctypeIcon`; a command without an icon renders the signature diamond.
- The `Cmd/Ctrl+K` keybind lives on a component-owned `<svelte:window>` listener, so it ships with every mount. It is not part of the global shortcuts registry.
- Inside: `↑`/`↓` move the selection across all visible rows, `Enter` activates, `Esc` closes — Bits UI `Dialog` owns the portal, focus trap, and initial focus.
- Activation navigates (records land on the root anchor's page) and closes. Selection resets when the visible row **keys** change — a query edit or results landing — not on every `rows` re-derivation. The backend churn behind an open palette (recent-label resolutions, search responses, nav rebuilds) keeps the same keys, so the highlight holds while the user is arrowing instead of snapping back to the first row.

## Mount points

Each shell mounts its own palette with its own command list; the guards keep exactly one `Cmd/Ctrl+K` listener alive at a time:

| Shell | Mount | Commands |
| --- | --- | --- |
| Root `+layout.svelte` (live + Builder) | `{#if authenticated && !isConfigureRoute && !isConsentRoute}` | page jumps — Builder, Configure, Apps, System settings, My settings, API keys, Webhooks (each keeps the gate its sidebar twin applies), then toggle sidebar, keyboard shortcuts, assistant (gated on an assistant surface) |
| `Configure/+layout.svelte` | always (Configure shell) | the section navigations + exit to live; the platform rows (settings, indexes, artifacts) render for wildcard-read roles, settings also gated on its doctype read |

Both shells pass `onsearch={() => paletteOpen = true}` to their `Topbar` trigger — the trigger stays a button, no inline results in the bar.

## Record search rules (`searchRecords.ts`)

- Trigger: query length ≥ 2, debounced at 250 ms (`SEARCH_DEBOUNCE_MS`); one request per burst; a sequence counter drops stale responses.
- Scope: the active domain by default (`GET /Api/{domain}/search`); the escalation row — "Search all domains for '…'" — re-runs the query app-wide (`GET /Api/search`), a scope chip marks the escalated state, and clicking it returns to the domain scope.
- Shaping: entries are root-anchored — child hits collapse per root (label = root `display_name`, subtitle = `ChildDoctype · child label` from the top-ranked child under that root); every hit inherits its group's `domain`/`doctype` (the contract carries them at group level only), and a group without both drops its rows. When escalated, rows carry a `domain · doctype` tag and the active domain's rows sort first (stable).
- Cost: no pagination — the user narrows the query; the server caps the response.
- Failure: a failed request drops the records group silently — no error state; the other groups stay usable.
- Transport: injectable fetch-like function; the default goes through `apiFetch` (the same fetch path the DataSources use). Stories and Vitest stub it.

## Testing

- **Vitest** covers both pure modules (`*.spec.ts` colocated): assembly, matching, ordering, and empty states; debounce/burst, minimum length, stale-drop, scope switch, response shaping, and the silent failure drop.
- **Stories** cover the component: groups render and filter, keyboard navigation and activation, one search call per burst (spy transport), the escalation row and chip, child → root rendering and activation.
