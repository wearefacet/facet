# ChatPanel — re-selecting a generating conversation does not re-lock the composer

Status: **resolved (2026-11-24).** Root cause identified, fixed, and covered
by `ChatInput.stories.svelte` → `LockedBusy` plus the `ChatPanel.stories.svelte`
→ `ActiveOnLoad` play.

## Symptom

In the refactored `ChatPanel`, select a conversation whose turn is running
server-side (an orphaned turn, the reload-mid-turn state), switch to an idle
conversation, then switch back to the generating one. The composer must lock
again (`textarea.disabled === true`). It stayed unlocked.

The `ChatPanel.stories.svelte` → `ActiveOnLoad` play failed on the same
assertion. The other play that failed alongside it,
`WorkspaceAssistant.stories.svelte` → `ThreadKeepsContentAcrossCollapse`, had a
different cause (see the second section below).

## Root cause

The panel side was never broken. `handleSelect` re-fetched the turns on every
re-selection, found the `running` row, and set `busy = true` — the thinking
placeholder rendered correctly on the third click.

The lock came from `ChatInput`: `locked` was `$derived(disabled)` — `busy` was
not part of it. Before the refactor, `ChatPanel` passed `disabled={busy ||
unconfigured}`; the per-conversation refactor changed the prop to
`disabled={unconfigured}` to keep the composer editable during a live turn (a
send then queues). That removal also dropped the orphaned-turn lock, which the
batch-A queue path does not cover: an orphaned turn has no live stream, so a
queued message would never drain, and the backend would 409 it.

The probe logs that made this confusing ("the third `handleSelect` never
ran") were the artifact of `waitFor` swallowing callback errors: a failing
`disabled === true` wait simply retried until the test budget ran out, so the
steps after it never logged.

## Fix

- `ChatInput.svelte`: `locked = $derived(disabled || busy)`. `busy` alone keeps
  the textarea editable (the live-turn queue); `disabled` alone stays the hard
  lockout; both together are a locked busy state. The `busy` JSDoc states the
  contract.
- `ChatPanel.svelte`: a new `orphanLocked` flag, set with `busy = true` when
  `handleSelect` finds a `running` row, and cleared wherever `busy` is cleared
  (selection change, `handleNew`, `settleSession`, context reset). The panel
  passes `disabled={unconfigured || orphanLocked}`.
- `ChatInput.stories.svelte`: new `LockedBusy` story (textbox disabled, Stop
  button enabled).

## Second failure — `ThreadKeepsContentAcrossCollapse`

That play asserted `winScope.getByText('find my active customers')`, a single
match when written. The auto-title feature (same refactor) now renders the
first user message in the rail row too, so the text matches twice — the
`cl-excerpt` span and the thread bubble. The play now targets the bubble with
`getAllByText(...).at(-1)` (the rail renders before the thread).

## Validation

- `pnpm vitest run --project storybook src/lib/components/features/chat/` —
  82 passed.
- `pnpm check` — 0 errors, 0 warnings.
- `pnpm exec eslint` on the touched files — clean.

The temporary isolated repro
(`frontend/src/lib/components/features/chat/ReproReselect.stories.svelte`) was
deleted after the fix; `ActiveOnLoad` covers the regression.
