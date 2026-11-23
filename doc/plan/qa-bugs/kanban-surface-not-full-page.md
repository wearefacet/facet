# Kanban view: surface does not fill the page; card stacks cut off

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H0D786J860VXNN434DBGW51F` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | frontend (kanban surface, collection views) |
| Verdict | Confirmed, with two corrections to the report |

## Summary

On a kanban collection view the board stops short of the viewport bottom. The
page below the bordered board is dead background. Card stacks do not render at
full height; they stop at a fixed cap with an inner scrollbar.

Two corrections against the report:

- Cards are not compressed. The board cuts the card stack at 560 px and shows
  an inner scrollbar. The visible symptom (squeezed-looking lanes) follows from
  the cap plus the non-filling board.
- The gap comes from three CSS rules that combine, not from one broken link.

## Evidence

Height chain — the viewport has room; the board does not use it:

1. `frontend/src/lib/components/primitives/surfaces/AppShell.svelte` L229-249 —
   `.app` is `height: 100vh; overflow: hidden`; `.main` is the scroll container
   (`overflow: auto; min-height: 0`).
2. `frontend/src/routes/[domain=notApi]/[doctype]/+page.svelte` L195-201,
   L257-262 — `.doctype-body` is a block scroll container (`flex: 1;
   min-height: 0; overflow: auto`). It is not a flex container, so children get
   no height from it.
3. `frontend/src/lib/components/primitives/data/ListView.svelte` L626-631 —
   `.listview` is the bordered host of every collection surface. It has no
   height of any kind, so its height equals its content height. The chain ends
   here.

Kanban surface:

4. `frontend/src/lib/kanban/Kanban.svelte` L219-230 — `.kb` has no height and
   `align-items: start`. Lanes do not stretch; each lane keeps its own content
   height.
5. `frontend/src/lib/kanban/KanbanLane.svelte` L153-160 — `.kb-cards` has
   `max-height: 560px; overflow-y: auto`. L104-112 — lane floor is
   `min-height: 200px`.

Net effect: board height = 14 px padding + tallest lane (header + card stack
capped at 560 px). On a viewport taller than ~620 px everything below the
bordered box is empty. The component stories confirm the symptom: they wrap the
board in a container with `min-height: 720px` so the layout has room
(`Kanban.stories.svelte` L186-190, L223).

## Root cause

- `.listview` is content-height inside a scrollable block parent.
- `.kb` has no fill height and `align-items: start`.
- `.kb-cards` caps at `max-height: 560px` instead of filling the lane.

## Fix direction

Three CSS edits:

- `ListView.svelte` `.listview` — make it a column flex box with
  `min-height: 100%` (or make `.doctype-body` a flex column and `.listview`
  `flex: 1`).
- `Kanban.svelte` `.kb` — add `flex: 1; min-height: 0`; drop `align-items:
  start` so lanes stretch. Keep `overflow-x: auto` — the horizontal board
  scroll stays, as the issue asks.
- `KanbanLane.svelte` `.kb-cards` — replace `max-height: 560px` with
  `flex: 1; min-height: 0`. The stack then fills the lane and scrolls inside
  it.

Blast radius: the Table and Calendar render in the same `.listview` host and
inherit the fill height. This needs a visual decision before implementation —
kanban-scoped class or global fill.

Side note: `frontend/example/design-guideline.html` and `table.html` (the
design reference cited by `doc/frontend/workflow.md` L69-70) are absent from
the working copy — only `.keep` exists. Restore or fix the reference.
