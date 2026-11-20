# Keyboard shortcuts

Global keyboard shortcuts for the web UI: one registry, one `window` keydown
dispatcher, and a `?` cheat-sheet dialog. A shortcut never fights the browser
or the OS — browser-reserved combos (`Ctrl/Cmd+N`/`T`/`W`, `Ctrl+J`) are not
used, bare keys never fire while typing, and `Mod` is `⌘` on macOS and `Ctrl`
elsewhere.

## Source files

| File | Role |
|---|---|
| `frontend/src/lib/shortcuts.svelte.ts` | Registry, dispatcher, guards, help-open store, key formatting |
| `frontend/src/lib/components/primitives/surfaces/ShortcutsDialog.svelte` | Cheat-sheet dialog (`?`) |
| `frontend/src/routes/+layout.svelte` | Attaches the dispatcher (`<svelte:window>`), registers the global scope |
| `frontend/src/lib/table/Table.svelte` | List navigation + search-focus registrations |
| `frontend/src/lib/components/features/document-view/DocumentForm.svelte` | `Mod+S` / `Mod+Enter` save |
| `frontend/src/lib/components/features/chat/AssistantWindow.svelte` | `Escape` minimizes the floating window (local handler) |
| `frontend/src/lib/components/primitives/surfaces/QuickViewHost.svelte` | `Enter` opens the peek drawer's document full-page (capture-phase listener while the drawer is open) |
| `frontend/messages/en.json` / `fr.json` | `shortcuts_*` labels |

## Public API — `$lib/shortcuts.svelte.ts`

| Export | Purpose |
|---|---|
| `registerGlobalShortcuts(entries)` | Registers app-wide entries (root layout). Returns the unregister cleanup. |
| `registerRouteShortcuts(entries)` | Registers the active page's entries. Dedupes on `id`; call from an `$effect` and return the cleanup so route scope never leaks across navigations. |
| `handleShortcutKeydown(e)` | The single dispatcher — attach with `<svelte:window onkeydown>`. |
| `getRegisteredShortcuts()` | Snapshot of active entries (route scope first). The cheat sheet reads it per open. |
| `getShortcutsHelpOpen()` / `setShortcutsHelpOpen(v)` | Cheat-sheet open state (the one signal here; written from event handlers only). |
| `isTypingTarget(target)` | True on `input` / `textarea` / `select` / `contenteditable`. |
| `isInteractiveTarget(target)` | True on controls that own Enter/Space natively (buttons, links, widgets). |
| `insideDialog(target)` | True when the focus sits inside an open dialog — the dispatcher's dialog guard, shared with component-owned key listeners. |
| `isModCombo(e)` | True when the event carries exactly the platform `Mod` (no Shift/Alt, no opposite command key) — the command-modifier rule of `keyMatches`, shared with component-owned Mod-combo listeners. |
| `isMacPlatform()` / `modKeyLabel()` / `formatKeys(keys)` | Platform resolution and `<kbd>` hints (`Mod+K` → `['⌘','K']`). |

A `ShortcutEntry` carries `id`, `keys` (canonical form: `Mod+K`, `C`, `?`,
`/`, `Escape`, `Enter`, `ArrowDown`), a resolved `label`, a `group`
(`general` / `list` / `document`), an optional `allowRepeat`, an optional
`when(e)` gate, and a `handler(e)` that returns whether it acted — only then
does the dispatcher `preventDefault`.

## Guard rails (match order)

1. Skip events already `defaultPrevented`, in IME composition, or whose
   target sits inside a modal dialog (`role="dialog"`) — Bits UI owns the
   keyboard there.
2. Bare keys never fire with `Meta`/`Ctrl`/`Alt` held — those combos belong
   to the browser or OS (`Ctrl+C`, `Cmd+P`, …).
3. `Mod` resolves per platform (`⌘` vs `Ctrl`); the opposite modifier never
   satisfies a `Mod` binding, and a `Mod` entry matches its own key only,
   without `Shift`/`Alt` — browser-reserved combos (`Ctrl+C` copy,
   `Ctrl+Shift+I` devtools) reach the browser untouched.
4. Bare keys never fire from typing targets, except `Escape`.
5. Held keys repeat only with `allowRepeat` (row navigation).
6. Route scope matches before global scope.

The registry holds plain arrays only — no signal writes anywhere in the
register/unregister path. A module-`$state` bump inside a registering
component's `$effect` loops Svelte's update graph
(`effect_update_depth_exceeded`); the cheat sheet instead re-reads the
registry each time Bits UI mounts its content (per open).

## Wired shortcuts

| Key | Action | Registered by |
|---|---|---|
| `Mod+K` | Open / close the command palette | `CommandPalette` (component-owned `<svelte:window>` listener — not a registry entry; mirrors the dispatcher's `defaultPrevented` + dialog guards) — see [`command-palette.md`](command-palette.md) |
| `Mod+I` | Toggle the assistant window | Root layout (gated on an assistant surface) |
| `Mod+\` | Collapse / expand the sidebar | Root layout |
| `?` | Open the cheat sheet | Root layout |
| `C` | New record on a doctype list | List page (gated on `create`) |
| `j` / `k`, `↓` / `↑` | Move the row highlight | Table (when rows open via peek) |
| `Enter` | Open the highlighted row | Table |
| `Enter` (peek drawer open) | Open the displayed document's full show page — the same target as the drawer header's external-link affordance | `QuickViewHost` (capture-phase window listener while the drawer is open — the table's own `Enter` route entry is registered first, so it would otherwise re-open the peek; the listener keeps native `Enter` on focused controls, typing targets, and dialogs) |
| `Escape` | Clear the row highlight | Table |
| `/` | Focus the list search input | Table (when the doctype has a `search` template) |
| `E` | Edit the record | Show page (gated on `update`) |
| `Mod+S`, `Mod+Enter` | Save the form | `DocumentForm` |
| `Escape` (focus inside) | Minimize the assistant window | `AssistantWindow` (local handler) |

## Testing

- `frontend/src/lib/shortcuts.test.ts` — pure-logic Vitest suite (matching,
  guards, registry lifecycle, dispatcher semantics).
- `ShortcutsDialog.stories.svelte` — component tests: grouped rendering with
  the platform mod label, close-through-Bits-UI store round trip.
