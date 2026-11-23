# ChatPanel — re-selecting a generating conversation does not re-lock the composer

Status: **open, reproduced in isolation, root cause not yet identified.**
Filed from the per-conversation turn-state refactor of `ChatPanel.svelte`
(batch 2 of the assistant QA plan, uncommitted at filing time).

## Symptom

In the refactored `ChatPanel`, select a conversation whose turn is running
server-side (an orphaned turn, the reload-mid-turn state), switch to an idle
conversation, then switch back to the generating one. The composer must lock
again (`textarea.disabled === true`). It stays unlocked.

Storybook play assertion: `AssertionError: expected false to be true` — the
`textarea().disabled` check after the third click.

## Isolated reproduction

The failing interaction lives in its own one-story file — no dependence on the
main `ChatPanel.stories.svelte`:

- Story file: `frontend/src/lib/components/features/chat/ReproReselect.stories.svelte`
  (temporary, marked for deletion when fixed)
- Component: `frontend/src/lib/components/features/chat/ChatPanel.svelte`
- Mock driver: `frontend/src/lib/assistant/mock/MockAssistantDriver.ts`
  (+ `mock/turn.ts`, `mock/conversation.ts`, `mock/session.ts`)

Run:

```sh
cd frontend
pnpm vitest run --project storybook src/lib/components/features/chat/ReproReselect.stories.svelte
```

Observed (2026-11-24, chromium):

```
FAIL  src/lib/components/features/chat/ReproReselect.stories.svelte > ReselectLocksComposer
AssertionError: expected false to be true // Object.is equality
Test Files  1 failed (1)
Tests       1 failed (1)
```

The story does exactly three things:

1. Click the rail row of `gen` (a conversation with a seeded `running` turn and
   no live stream) → thread shows `Thinking…`, composer locks. **Passes.**
2. Click the rail row of `idle` (seeded running turn, then settled to
   `done`/`Idle reply.`) → thread shows the reply, composer unlocks. **Passes.**
3. Click `gen`'s row again → thread shows `Thinking…` again, composer must
   lock. **Fails — `disabled` stays `false`.**

## What the refactor changed (context for the reader)

`ChatPanel.svelte` previously held one `turns` array plus a panel-wide
`streaming` flag, and blocked rail navigation while streaming (the original QA
tickets: "cannot add a 3rd thread", "cannot switch back"). The refactor moved
live turn state into a per-conversation record:

```ts
interface ConvSession {
	turns: Turn[]; parts: AgentPart[]; streaming: boolean;
	baseLen: number; agentTurnId: number; turnToken: string | null;
	cancelIntent: boolean; pending: string[];   // pending = batch-A queue
}
const sessions = new Map<string, ConvSession>();   // plain (non-reactive) Map
let sessionsVersion = $state(0);                   // bump = invalidation signal
```

The thread the template renders is derived per selection:

```ts
const turns = $derived.by<Turn[]>(() => {
	void sessionsVersion;
	const s = conversation ? sessions.get(conversation.id) : null;
	return s ? [...s.turns] : [];
});
```

`handleSelect` no longer blocks on `streaming`; when the freshly listed turns
contain a `running` row it sets `busy = true`, captures
`running.turn_token`, and starts `watchOrphanedTurn(...)` (unchanged polling
logic, now session-scoped writes). `handleNew` no longer blocks either. Sends
during a turn queue into `session.pending` and drain on settle (batch A).

Full diff of the refactor is in the working tree, uncommitted, on top of
commit `7d5059a` (batch 1). Touched files: `ChatPanel.svelte`, `ChatInput.svelte`,
`ChatBubble.svelte`, `ConversationList.svelte`, `assistant/types.ts`,
`assistant/AssistantDriver.ts`, `assistant/http-assistant-driver.ts`,
`assistant/title.ts` (new), `assistant/mock/*`, `messages/en.json`,
`messages/fr.json`; backend `src/assistant/{conversation,routes,title}.cr`.

## Evidence collected so far

1. **The mock helpers are correct.** A standalone Vitest probe against the
   mock (`seedRunningTurn` then `settleRunningTurn`, then `listTurns`)
   returns `['done']` — no running row left behind:

   ```text
   PROBE statuses [ 'done' ] n= 1   ✓ server  probe (1 test) 5ms
   ```

2. **`handleSelect` instrumentation (console probes, since removed) showed the
   missing third call.** With probes at the top of `handleSelect` (before every
   early return) and after `listTurns`, a run of the `ActiveOnLoad` story
   logged exactly two `select` calls for three click attempts in the play:

   ```text
   PROBE select X6HK0F same= false streaming= undefined pending= undefined
   PROBE select listed 1 running= true seqOk= true      ← click 1 (gen) ✓
   PROBE select M3WX35 same= false streaming= undefined pending= undefined
   PROBE select listed 1 running= true seqOk= true      ← click 2 ???
   ```

   The third click (back to `gen`) produced **no log** — `handleSelect` never
   ran for it. Two readings are possible and the evidence is ambiguous:
   - (a) click 2's log is the *idle* row but reports `running= true`, which
     contradicts the standalone mock probe; or
   - (b) click 2's log is missing and the two logs are clicks 1 and 3 —
     meaning the idle click never reached `onselect`.
   Story interlacing across the file's other stories made the earlier logs
   ambiguous; the isolated repro file now exists to disambiguate (see next
   steps).

3. **A rail-node race was ruled out as the sole cause.** The rows re-render
   when `activeId` flips (the `ConversationList` `activeId` prop changes with
   `busy`), so a click can dispatch on a detached node and silently no-op.
   The repro's clicks therefore retry with their outcome
   (`waitFor(click + expect)`), which re-queries fresh nodes — the failure
   persists even with retries, so a stale node alone does not explain it.

4. **The first select works and locks.** `running= true` path sets
   `busy = true` and starts the orphan watch; `Thinking…` renders and the
   composer locks. Only the re-select fails to re-lock.

## Working hypotheses (ranked)

- **H1 — the cancelled orphan watch leaves the session unwatchable.** Click 1
  starts `watchOrphanedTurn` (token A). Click 2 (`handleSelect(idle)`) calls
  `cancelWatch()` → token bump → watch A's `finally` sees `token !==
  watchToken` and **skips `settleSession`** (by design). Click 3 re-selects
  `gen`: session is not `streaming`, `pending` empty → `listTurns` → running
  row found → `busy = true` + watch B. This path *should* re-lock. If the
  third click never reaches `handleSelect` (evidence point 2), find the
  dispatcher-level cause first (see next steps).
- **H2 — a `$derived` invalidation gap hides the `busy` write.** `busy` is
  plain `$state`, so H2 would require the template to read a stale
  derived — unlikely, but the `sessionsVersion` invalidation chain has one
  known subtlety already fixed once (see "Note on the reactivity trap").
- **H3 — the third click lands on the *thread bubble* of the still-selected
  conversation** rather than the rail row: `rowOf()` takes `getAllByText(...)[0]`,
  which assumes the rail (rendered first in DOM order) owns the first match.
  If a rerender ever inverts that, the click hits a non-interactive bubble and
  no handler runs — matching the missing third `handleSelect` log exactly.

## Note on a reactivity trap already fixed once

The first cut of the refactor derived `turns` from an `activeSession` derived
(`turns = activeSession?.turns ?? []`). A derived downstream of another derived
only re-runs when the upstream output reference changes; the session object
reference never changes, and `.turns` is an untracked plain property — the
thread froze (see `doc/frontend/workflow.md` → deep property mutations on
shared proxy objects). Fixed by making each template-facing derived read
`sessionsVersion` directly and return a fresh shallow copy. The current bug is
**not** that trap — the thread updates correctly on clicks 1 and 2.

## Next steps for the investigating session

1. Run the isolated repro (command above). Confirm the failure.
2. Re-add the two probes to `ChatPanel.svelte` (both were removed to clean the
   tree):
   - top of `handleSelect`, before the early returns:

     ```ts
     console.log('PROBE select', selected.id.slice(-6),
         'same=', selected.id === conversation?.id,
         'streaming=', sessions.get(selected.id)?.streaming,
         'pending=', sessions.get(selected.id)?.pending.length);
     ```

   - right after `const running = listed.find(...)`:

     ```ts
     console.log('PROBE select listed', listed.length,
         'running=', !!running, 'seqOk=', seq === selectSeq);
     ```

   Also probe the click targets from the repro story:
   `console.log('PROBE click', title, rowOf(title).className)` before each
   click, to test H3 directly.
3. Disambiguate evidence point 2 on the isolated file (no interlacing from
   other stories): does the idle click log? does the third click log? Does the
   third click's `listTurns` show the running row?
4. If the third click never reaches `onselect`, dump the rail row's DOM at
   click time (H3): is `getAllByText('still there?')[0]` inside
   `button.cl-row`? Check `ConversationList`'s `{#each conversations as conv
   (conv.id)}` keyed reconciliation and the `activeId`-driven rerender.
5. If `handleSelect` runs and sets `busy = true` but the composer stays
   unlocked, inspect the `busy`-derived chain into `ChatInput`
   (`ChatPanel.svelte` template: `<ChatInput {busy} ... />`,
   `ChatInput.svelte` `locked = $derived(disabled)`).
6. Fix, then run the full chat cluster:
   `pnpm vitest run --project storybook src/lib/components/features/chat/`
   — the main `ChatPanel.stories.svelte` `ActiveOnLoad` play must pass again
   (it currently fails the same way), plus `pnpm check` and
   `pnpm exec eslint` on the touched files.

## Known-good baseline

- Batch 1 commit: `7d5059a` (list-view drag-reorder + preview banner label).
- All 216 story files / 1360 tests passed on batch 1 (before the ChatPanel
  refactor).
- Backend (`make check`) compiles clean with the conversation-title changes.
- Current story-suite state during the refactor: 3 failures
  (`ActiveOnLoad`, `ThreadKeepsContentAcrossCollapse`,
  `CappedTurn`-related label updates already applied) — the isolated repro
  file reproduces the core failure without any of the suite's noise.
