# Assistant minimized bar: no move, no resize, no position persistence

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H0D4DCKGEGZQGF7NG0H7DEGF` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | frontend (workspace assistant) + packages/chat (same code) |
| Verdict | Confirmed. Deliberate design, but the gap is real |

## Summary

When the assistant is minimized to its bar, the bar is fixed: it cannot be
moved to another position or edge, it cannot be resized, and its position does
not persist. The code states the intent in comments — the bar is a docked
element, not a movable window. One detail makes it feel like a bug: the bar
shows a grab cursor and then ignores the drag.

## Evidence

All in `frontend/src/lib/components/features/chat/AssistantWindow.svelte`. The
package copy `packages/chat/src/chat/AssistantWindow.svelte` carries the same
code (geometry L192-199, drag guard L221-226).

- L187-194 — collapsed geometry: `y` is hard-pinned to the bottom dock
  (`window.innerHeight - HEADER_HEIGHT - DEFAULT_BOTTOM`). `x` and `width` are
  inherited from the expanded window. `height` is the constant 40 px. No edge
  switching exists anywhere.
- L216-226 — `onDragStart`:
  ```js
  // No dragging while collapsed — the bar is docked to the bottom edge;
  // moving it would detach it from the dock.
  if (collapsed) return;
  ```
- L413-416 — resize handles render only `{#if !maximized && !collapsed}`;
  L263-264 — the resize guard returns for both states. No collapsed-bar resize
  handle exists.
- `assistantWindowState.ts` L7-10, L20-25 — persisted keys are `open`,
  `collapsed`, `maximized`, `rail-width`, `width`, `height`. Position is NOT
  persisted, by documented decision ("the window resets to its default inset
  each session to avoid drift bugs"). Package copy: same keys under
  `facet.assistant.app.*`. So even in-session, the bar position resets on
  reload.

The expanded panel is draggable and resizable (header drag L350; resize
handles L417-447; rail width draggable and persisted in `ChatPanel.svelte`
L578-604). The gap is specific to the minimized state.

UX inconsistency: `.window-header` sets `cursor: grab` (L513). The collapsed
override changes only `border-bottom` (L519-521). Maximized gets
`cursor: default` (L501-503); collapsed does not. The bar looks grabbable but
silently ignores the drag.

## Root cause

A design decision, implemented as guards: the bar is a docked element, not a
movable window. The complaint is valid UX feedback, not a regression.

## Fix direction

- Both copies of `AssistantWindow.svelte`: lift the collapsed drag guard (or
  add a move mode for the bar), extend the collapsed geometry branch to honor a
  position or dock edge, add a width handle for the docked bar, and clamp to
  the viewport.
- Both copies of `assistantWindowState.ts`: add position keys plus read/write
  helpers if persistence is wanted.
- Document the state constraints (docked vs floating, which states allow
  move/resize) in design notes, as the issue asks.
- Minimum cosmetic fix if the bar stays non-draggable:
  `.assistant-window.collapsed .window-header { cursor: default; }`.
