# Schematic (frontend)

Reusable "boxes and arrows" renderer for the Facet frontend. Draws a set of
labelled, coloured nodes connected by directed edges, with drag-to-move
support. The doctype-specific adapter (`DomainSchematic`) turns a domain's
doctype definitions into the abstract model the generic renderer consumes.

**Source files:** `frontend/src/lib/components/schematic/`

---

## Architecture

The schematic is split into three layers so the block/arrow rendering can be
reused for any schema, not just doctypes:

```
types.ts              Abstract model (SchematicNode, SchematicEdge, Schematic)
geometry.ts           Pure layout math — border endpoints, bezier paths, viewBox
Schematic.svelte      Generic renderer — nodes + SVG edges + drag state
SchematicNode.svelte  A single block — pointer-drag + click disambiguation
doctypeSchematic.ts   Doctype → Schematic adapter (the only doctype-aware code)
DomainSchematic.svelte  Doctype-aware wrapper around Schematic
layout.ts             Position persistence helpers (parse, merge, payload, debounce)
layoutSource.ts       HTTP-backed layout source against core.SchematicLayout
```

### Abstract model (`types.ts`)

| Type | Fields | Notes |
|---|---|---|
| `SchematicNode` | `id, label, color, tagline?, taglineKind?, x, y, width, height` | Position is top-left, in schematic coordinate space (1 unit = 1 CSS px). |
| `SchematicEdge` | `from, to, kind, label?` | `kind` is `'composition'` (solid + filled diamond at the owner) or `'reference'` (dashed + open arrow). |
| `Schematic` | `nodes, edges` | Complete schematic. |

### Geometry (`geometry.ts`)

Pure, side-effect-free helpers operating on `SchematicNode`:

| Function | Returns | Purpose |
|---|---|---|
| `center(n)` | `{x, y}` | Geometric center of a node. |
| `borderPoint(a, b)` | `{x, y}` | Where the ray from `a`'s center toward `b`'s center exits `a`'s border. |
| `bezierPath(from, to)` | SVG `d` string | Cubic-bezier path between two nodes' borders. |
| `bezierMid(from, to)` | `{x, y}` | Approximate midpoint of the bezier (for label placement). |
| `fitViewBox(nodes, padding)` | `{x, y, width, height}` | Bounding box over all nodes + padding. |

### Doctype adapter (`doctypeSchematic.ts`)

`buildDomainSchematic(registry, domain, stored?)` reads a domain's doctype
definitions from a `DoctypeRegistry` (any object with a `doctypeDefinitions:
Map<string, Record>` — `MockDataDriver` satisfies this) and produces a
`Schematic`.

Relationship encoding:

| Relationship | Source | Edge kind |
|---|---|---|
| Composition (parent → child) | `children: { role: { doctype } }` on the root, or `member_of: <Root>` on the child | `composition` |
| Reference (root → referenced root) | A `reference`-typed field (or `array` of `reference`) whose target is an aggregate root in the same domain | `reference` |

Composition edges from both `children` and `member_of` are deduped by
`(from, to)`. References that duplicate a composition edge are skipped.

Color: the doctype `color` field is used when present; otherwise
`hashColor(qualifiedName)` (from `$lib/utils/color.ts`) produces a stable
OKLCH-based hue.

Layout: a simple deterministic two-column layout — aggregate roots in column
0, children grouped under their `member_of` root in column 1. The optional
`stored` argument is a saved positions map; a node with a saved entry keeps
the saved corner, every other node keeps the computed position, and saved
keys with no matching node are ignored.

---

## Drag-to-move

`Schematic.svelte` owns mutable node positions in a `$state` map. The incoming
`schematic` prop is treated as the initial layout; dragging mutates only
positions, leaving labels/colors/edges intact. Edges and the stage size
recompute reactively from the merged positions.

When a drag ends, `Schematic.svelte` calls `onlayoutcommit` with a plain copy
of the full positions map. That callback is the persistence seam — see
[Persistence](#persistence).

`SchematicNode.svelte` uses Pointer Events (`pointerdown` → `pointermove` →
`pointerup`) with a 3px dead zone to distinguish a click from a drag:

- **Click** (no movement beyond the dead zone): fires `onclick(id)`.
- **Drag** (movement beyond the dead zone): fires `ondragstart`, then
  `ondragmove(id, dx, dy)` with incremental screen-pixel deltas, then
  `ondragend`. The parent (`Schematic`) converts screen deltas to schematic
  units by dividing by the stage's rendered scale (1px/unit by default, but
  robust to CSS zoom).

Pointer capture is used so the drag continues even if the pointer leaves the
node. `setPointerCapture` / `releasePointerCapture` are guarded with
try/catch for synthetic-event environments (tests).

When the `schematic` prop identity changes (e.g. switching Storybook
stories, or a saved layout arriving from the load), an `$effect` rebuilds
the positions map from the new schematic's nodes — but it does not read
`positions`, avoiding a reactivity cycle.

---

## Persistence

Dragged positions persist as a shared canonical layout on the seeded
doctype `core.SchematicLayout` (B-172).

**What is stored.** One document per target domain, hosted in `core`. The
content carries two fields: `domain` — the arranged domain's
`core.Domain` row id — and `positions`, a dictionary keyed by the target
domain's qualified doctype ids, each value `{x, y}` in schematic pixels
(integers). One domain has exactly one layout document; the doctype's Lua
create/update hooks admit one row per domain, refuse a domain that does
not exist, and gate writes on domain-editor membership.

**Where it lives.** The row is created lazily on the first drag save, so
its id is a server-assigned ULID — clients look the document up by its
`domain` field (an equality-filtered list on
`/Api/core/SchematicLayout`), never by id. No document in the list means
no saved layout yet.

**Restore semantics.** On mount, the doctypes tab loads the layout
document for the current domain and merges the stored positions over the
deterministic two-column layout: a node with a stored entry keeps the
stored corner; nodes without one keep the computed position; stored keys
whose doctype no longer exists are ignored. A read failure also falls
back to the computed layout. There is no WebSocket subscription — a
reload (or a re-mount of the tab) restores the saved layout.

**Save semantics.** Each drag end schedules a save with a 500 ms
debounce; the save writes the full positions map of the current nodes.
`DomainSchematic` rounds each `x`/`y` to an integer pixel before it emits
the map (`positionsPayload`) — drag deltas are sub-pixel floats under
zoom, and the doctype stores integers. Between simultaneous arrangers
the last write wins; a concurrent first save loses the backend race (the
create hook refuses the second row for a domain, 422) and converges on
its next save.

**History retention.** Drag saves are high-churn, low-value history:
`mutations.retention_overrides` pins `core.SchematicLayout` to 7 days in
every `config.{env}.yml`. The compaction pass folds anything older into
one synthetic snapshot, so the layout's audit trail and rollback depth
span one week. Write-time coalescing (`mutations.coalesce_window_minutes`)
additionally folds same-actor save bursts between drags into one row.

**Wiring.**

- `schematic/layout.ts` — pure helpers: `parseStoredPositions`,
  `mergePositions`, `positionsPayload`, `createLayoutSaver`, and the
  `SchematicLayoutSource` interface.
- `schematic/layoutSource.ts` — `createHttpSchematicLayoutSource()`, the
  HTTP-backed source against `core.SchematicLayout`.
- `features/configure/DomainDoctypesTab.svelte` — loads on mount, passes
  the stored map down, saves (debounced) on drag end. Stories inject an
  in-memory source through the `layoutSource` prop.

---

## Public API

### `Schematic.svelte`

```svelte
<Schematic {schematic} {selected} onnodeclick={(id) => ...} />
```

| Prop | Type | Default | Description |
|---|---|---|---|
| `schematic` | `Schematic` | required | Nodes + edges to render. |
| `selected` | `string` | — | Id of the currently selected node (adds `.sel` class). |
| `onnodeclick` | `(id: string) => void` | — | Called on click (pointerdown+up with no drag). |
| `onlayoutcommit` | `(positions) => void` | — | Called when a drag ends, with a copy of the full positions map. |

Nodes are draggable; edges follow automatically.

### `DomainSchematic.svelte`

```svelte
<DomainSchematic {registry} domain="hr" {selected} onnodeclick={(id) => ...} />
```

| Prop | Type | Default | Description |
|---|---|---|---|
| `registry` | `DoctypeRegistry` | required | A driver with a `doctypeDefinitions` map (e.g. `MockDataDriver`). |
| `domain` | `string` | required | Domain name (e.g. `"hr"`, `"crm"`). |
| `selected` | `string` | — | Id of the currently selected node. |
| `onnodeclick` | `(id: string) => void` | — | Called with the qualified doctype id (e.g. `"hr.Candidate"`). |
| `storedPositions` | `SchematicPositions \| null` | — | Saved positions merged over the computed layout. |
| `onlayoutsave` | `(positions) => void` | — | Called when a drag ends, with the full positions map (x/y rounded to integer pixels). |

### `hashColor(seed)` — `$lib/utils/color.ts`

```ts
import { hashColor } from '$lib/utils/color.ts';
hashColor('hr.Candidate'); // → "#A1B2C3" (stable, OKLCH-based)
```

Deterministic hex color from a string seed. Used as the fallback when a
doctype has no explicit `color`. Lightness and chroma are fixed (L=0.58,
C=0.11); only the hue varies with the seed, so all hash colors share the same
visual weight across light and dark themes.

---

## Storybook

`DomainSchematic.stories.svelte` renders five domains (`hr`, `crm`, `core`,
`iam`, `identity`) from the shared `createMockDriver()`. Each story shows the
domain's doctypes as draggable nodes with composition (gold diamond) and
reference (dashed arrow) edges.