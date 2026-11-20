<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { SidecarSurfaceProps } from '$lib/surfaces/registry.js';
	import type { Action } from 'svelte/action';
	import Avatar from '$lib/components/primitives/content/Avatar.svelte';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import Markdown from '$lib/components/primitives/content/Markdown.svelte';
	import { can } from '$lib/permissions.svelte';
	import { resolveRefLabel } from '$lib/datasource/qualifiedRef.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { buildThreads, flattenThreads, type Comment } from './commentThreads.js';
	import { untrack } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';
	import { Pencil, Trash2, CornerDownRight, ChevronDown, ChevronRight, X } from '@lucide/svelte';

	/**
	 * CommentSurface — the threaded comment sidecar for `core.Comment`
	 * (registered under the `comment` surface id by `surfaces.ts`).
	 *
	 * Comments render oldest first (ULID ids sort by creation order),
	 * assembled into a reply tree from the flat list: a row nests under the
	 * comment named by its `reply_to` reference. The list endpoint returns
	 * only live rows, so a tombstoned parent leaves its replies without a
	 * parent row — the surface stands in a muted `<deleted>` placeholder
	 * node at the root and nests the live replies under it, so the chain
	 * below the break stays visible. Indentation caps at `MAX_INDENT`;
	 * deeper replies flatten into the last indent bucket with a "replying
	 * to @author" note. The backend accepts replies at any depth; the cap
	 * is presentation only.
	 *
	 * Each comment resolves its `author` reference on demand — the ref value
	 * is a qualified `iam.Account.<id>`; failures degrade to an unknown
	 * author. The shared composer submits `{ body }`, or `{ body, reply_to }`
	 * while a reply is armed: the backend (and the mock driver) set the
	 * `target` column on the route's behalf, and the author is forced
	 * server-side via Lua on create.
	 *
	 * Edit/delete affordances are UI hints gated on `can('core.Comment',
	 * 'update' | 'delete')`, the reply affordance on the host create grant
	 * — production roles scope edits to `$mine` and the backend re-checks
	 * every mutation.
	 */
	let { driver, hostDef, hostDoc, segment, onchanged, onReferenceClick }: SidecarSurfaceProps =
		$props();

	const qualifiedHost = $derived(`${hostDef.domain}.${hostDef.doctype}`);
	// Nested sidecar create is implied by the host's `create` grant.
	const canCreate = $derived(can(qualifiedHost, 'create'));
	const canEdit = $derived(can('core.Comment', 'update'));
	const canDelete = $derived(can('core.Comment', 'delete'));

	let rows = $state<Comment[] | null>(null);
	let loading = $state(false);
	let errorMsg = $state<string | null>(null);
	let listSeq = 0;

	// ── Author identity ─────────────────────────────────────────────────────
	// Resolved on demand after each list fetch; cached per reference value in
	// reactive state so the render only reads settled data. `null` = unknown
	// author (unresolvable reference or failed lookup).

	type Author = { name: string; initials: string };
	let authors = $state<Record<string, Author | null>>({});
	const authorsStarted = new SvelteSet<string>();

	function initialsOf(name: string): string {
		const parts = name.trim().split(/\s+/).filter(Boolean);
		if (parts.length === 0) return '?';
		return (parts[0][0] + (parts[1]?.[0] ?? '')).toUpperCase();
	}

	async function resolveAuthor(ref: unknown): Promise<void> {
		const key = String(ref ?? '');
		// untrack: a tracked read + the `add` write inside the load effect
		// would re-run that effect and orphan this fetch (workflow.md →
		// "The equality-guard trap in writeback effects").
		if (!key || untrack(() => authorsStarted.has(key))) return;
		untrack(() => authorsStarted.add(key));
		// Unqualified refs and failed lookups resolve to `null` — an unknown
		// author, never a wrong one.
		const name = await resolveRefLabel(driver, key);
		authors[key] = name ? { name, initials: initialsOf(name) } : null;
	}

	function authorOf(ref: unknown): { name: string; initials: string } {
		const key = String(ref ?? '');
		const resolved = key ? authors[key] : undefined;
		return resolved ?? { name: m.doc_comment_unknown_author(), initials: '?' };
	}

	// ── Data ────────────────────────────────────────────────────────────────

	async function load(): Promise<void> {
		const my = ++listSeq;
		loading = true;
		errorMsg = null;
		try {
			const res = await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.list({ items: 200 });
			if (my !== listSeq) return;
			// Oldest first — ULID ids sort by creation order.
			const sorted = [...res.data].sort((a, b) =>
				a.meta.id < b.meta.id ? -1 : a.meta.id > b.meta.id ? 1 : 0
			);
			rows = sorted as unknown as Comment[];
			for (const row of sorted) void resolveAuthor(row.data['author']);
		} catch (e) {
			if (my !== listSeq) return;
			rows = null;
			errorMsg = errorMessage(e, m.doc_comments_load_failed());
		} finally {
			if (my === listSeq) loading = false;
		}
	}

	$effect(() => {
		void hostDef;
		void hostDoc.meta.id;
		void segment;
		void load();
	});

	// ── Thread assembly ───────────────────────────────────────────────────
	// The flat list (oldest first) folds into a reply tree keyed by
	// `reply_to`. The assembly rules — the `<deleted>` stand-in for a
	// tombstoned parent, the indent cap with its "replying to @author"
	// note, and collapse — live in `commentThreads.ts`.

	let collapsedIds = $state<Record<string, boolean>>({});

	let threads = $derived.by(() => {
		if (rows === null) return null;
		return flattenThreads(buildThreads(rows), collapsedIds, (ref) => authorOf(ref).name);
	});

	// ── Composer ────────────────────────────────────────────────────────────

	let draft = $state('');
	let submitting = $state(false);
	let submitError = $state<string | null>(null);
	// Bound to the composer editor's fullscreen flag. A Ctrl/Cmd+Enter send
	// from the overlay must land back on the inline composer; a failed send
	// keeps the overlay open.
	let composerExpanded = $state(false);

	async function submit(): Promise<void> {
		const body = draft.trim();
		if (!body || submitting || !canCreate) return;
		submitting = true;
		submitError = null;
		try {
			// `target` is set by the route; `author` is forced server-side.
			// With a reply armed, the payload adds `reply_to` (the bare id —
			// Normalize qualifies it server-side).
			await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.create(replyToId === null ? { body } : { body, reply_to: replyToId });
			draft = '';
			replyToId = null;
			composerExpanded = false;
			await load();
			onchanged?.();
		} catch (e) {
			submitError = errorMessage(
				e,
				replyToId === null ? m.doc_comment_add_failed() : m.doc_comment_reply_failed()
			);
		} finally {
			submitting = false;
		}
	}

	// ── Reply mode ──────────────────────────────────────────────────────
	// The per-comment reply affordance arms the shared composer instead of
	// opening a second box: a "replying to {name}" chip sits above the
	// input, the target card highlights, and the next submit carries
	// `reply_to`. Submits the bare id — Normalize qualifies it to
	// `core.Comment.<id>` server-side.

	let replyToId = $state<string | null>(null);
	let composerEl = $state<HTMLElement | null>(null);

	let replyTargetName = $derived.by(() => {
		if (replyToId === null || rows === null) return null;
		const row = rows.find((r) => r.meta.id === replyToId);
		return row === undefined ? null : authorOf(row.data['author']).name;
	});

	// The armed target vanished from the live list (tombstoned elsewhere):
	// drop the stale reply mode instead of submitting a doomed `reply_to`.
	$effect(() => {
		if (replyToId !== null && rows !== null && !rows.some((r) => r.meta.id === replyToId)) {
			replyToId = null;
		}
	});

	function startReply(row: Comment): void {
		replyToId = row.meta.id;
		composerEl?.scrollIntoView({ block: 'nearest' });
		composerEl?.querySelector<HTMLElement>('.ProseMirror')?.focus();
	}

	function cancelReply(): void {
		replyToId = null;
	}

	// ── Ctrl/Cmd+Enter submit ───────────────────────────────────────
	// Mirrors the assistant input: the chord sends from the composer or
	// the edit box, plain Enter still inserts a newline. Listens in the
	// capture phase on the wrapper so the Milkdown editor never sees the
	// chord — a keymap reacting after the send cleared the draft would
	// re-fill the composer with stale text.
	const submitShortcut: Action<HTMLElement, () => void> = (node, onsubmit) => {
		let handler = onsubmit;
		const onKeydown = (e: KeyboardEvent) => {
			if (e.key !== 'Enter' || (!e.ctrlKey && !e.metaKey)) return;
			e.preventDefault();
			e.stopPropagation();
			handler();
		};
		node.addEventListener('keydown', onKeydown, true);
		return {
			update(next: () => void) {
				handler = next;
			},
			destroy() {
				node.removeEventListener('keydown', onKeydown, true);
			}
		};
	};

	// ── Long-comment clamp ──────────────────────────────────────────
	// Only relatively long bodies — over ~10 prose lines — clamp, with a
	// Show more / Show less toggle. Shorter bodies render in full.
	// `longIds[id]`: `true` once the body renders taller than the clamp,
	// `false` when it fits. The measure compares the rendered scroll height
	// against the clamp threshold — valid in both states (clamped content
	// reports its full scrollHeight; expanded content is simply taller than
	// the threshold). A ResizeObserver drives it because the Milkdown
	// editor mounts its content asynchronously: the first paint cannot
	// decide, and edits change the height later.
	const CLAMP_MAX_PX = 216; // ~10 prose lines at the editor's 13.5px/1.6 base
	let longIds = $state<Record<string, boolean>>({});
	let expandedIds = $state<Record<string, boolean>>({});

	function isExpanded(row: Comment): boolean {
		return expandedIds[row.meta.id] === true;
	}

	function shouldClamp(row: Comment): boolean {
		return !isExpanded(row) && longIds[row.meta.id] !== false;
	}

	const clampObserver: Action<HTMLElement, string> = (node, id) => {
		let current = String(id ?? '');
		const measure = () => {
			longIds[current] = node.scrollHeight > CLAMP_MAX_PX + 1;
		};
		// The `.markdown` child carries the real content height even while
		// the clamped wrapper clips it — observe it, not the wrapper.
		const target = (node.firstElementChild as HTMLElement) ?? node;
		const ro = new ResizeObserver(measure);
		ro.observe(target);
		requestAnimationFrame(measure);
		return {
			update(next: string) {
				current = String(next ?? '');
			},
			destroy() {
				ro.disconnect();
			}
		};
	};

	// ── Edit / delete ───────────────────────────────────────────────────────

	let editingId = $state<string | null>(null);
	let editDraft = $state('');
	let mutatingId = $state<string | null>(null);
	let mutationError = $state<string | null>(null);

	function startEdit(row: Comment): void {
		editingId = row.meta.id;
		editDraft = String(row.data['body'] ?? '');
		mutationError = null;
	}

	function cancelEdit(): void {
		editingId = null;
		editDraft = '';
		mutationError = null;
	}

	async function saveEdit(row: Comment): Promise<void> {
		if (mutatingId || editingId !== row.meta.id) return;
		const body = editDraft.trim();
		if (!body) return;
		mutatingId = row.meta.id;
		mutationError = null;
		try {
			await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.doc(row.meta.id)
				.update({ body });
			editingId = null;
			editDraft = '';
			await load();
			onchanged?.();
		} catch (e) {
			mutationError = errorMessage(e, m.doc_comment_save_failed());
		} finally {
			mutatingId = null;
		}
	}

	async function remove(row: Comment): Promise<void> {
		// Destructive action: confirm first, matching the show route. The
		// global ConfirmDialog host lives in the app layout (not inside
		// stories), so the promise-based `confirm()` store would hang there.
		if (!window.confirm(m.doc_comment_delete_confirm())) return;
		mutatingId = row.meta.id;
		mutationError = null;
		try {
			await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.doc(row.meta.id)
				.delete();
			await load();
			onchanged?.();
		} catch (e) {
			mutationError = errorMessage(e, m.doc_comment_delete_failed());
		} finally {
			mutatingId = null;
		}
	}
</script>

<div class="comment-surface">
	{#if errorMsg}
		<div class="cs-error">{errorMsg}</div>
	{:else if loading}
		<div class="cs-status" aria-live="polite">{m.doc_comments_loading()}</div>
	{:else if rows !== null && rows.length === 0}
		<div class="cs-empty">{m.doc_comments_empty()}</div>
	{/if}

	{#if rows !== null && rows.length > 0}
		<ul class="cs-thread">
			{#each threads as entry (entry.row.meta.id)}
				{@const row = entry.row}
				{@const author = authorOf(row.data['author'])}
				{@const replyTargeted = replyToId === row.meta.id}
				{@const showActions = (canCreate || canEdit || canDelete) && editingId !== row.meta.id}
				<li
					class="cs-comment"
					class:cs-comment-replying={replyTargeted}
					class:cs-comment-deleted={entry.deleted}
					data-comment-id={row.meta.id}
					data-depth={entry.depth}
					style="--cs-depth: {entry.depth}"
				>
					<div class="cs-comment-head">
						{#if entry.descendantCount > 0}
							<button
								class="cs-collapse"
								type="button"
								onclick={() => (collapsedIds[row.meta.id] = !collapsedIds[row.meta.id])}
								aria-label={collapsedIds[row.meta.id]
									? m.doc_comment_replies_expand()
									: m.doc_comment_replies_collapse()}
							>
								{#if collapsedIds[row.meta.id]}
									<ChevronRight size={12} strokeWidth={2} aria-hidden="true" />
								{:else}
									<ChevronDown size={12} strokeWidth={2} aria-hidden="true" />
								{/if}
								<span class="cs-collapse-count">{entry.descendantCount}</span>
							</button>
						{/if}
						{#if entry.deleted}
							<!-- Stand-in for a tombstoned parent: no body, no affordances
							 (the backend rejects replies to tombstones anyway). -->
							<span class="cs-deleted-label">&lt;deleted&gt;</span>
						{:else}
							<Avatar initials={author.initials} size="sm" alt={author.name} />
							<span class="cs-author">{author.name}</span>
							<RelativeTime date={row.meta.created_at} />
							{#if entry.replyToName !== null}
								<span class="cs-reply-note">
									{m.doc_comment_reply_note({ name: entry.replyToName })}
								</span>
							{/if}
							{#if showActions}
								<span class="cs-actions">
									{#if canCreate}
										<button
											class="cs-action"
											type="button"
											disabled={mutatingId !== null}
											onclick={() => startReply(row)}
											aria-label={m.doc_comment_reply_aria()}
										>
											<CornerDownRight size={12} strokeWidth={2} aria-hidden="true" />
										</button>
									{/if}
									{#if canEdit}
										<button
											class="cs-action"
											type="button"
											disabled={mutatingId !== null}
											onclick={() => startEdit(row)}
											aria-label={m.doc_comment_edit_aria()}
										>
											<Pencil size={12} strokeWidth={2} aria-hidden="true" />
										</button>
									{/if}
									{#if canDelete}
										<button
											class="cs-action"
											type="button"
											disabled={mutatingId !== null}
											onclick={() => remove(row)}
											aria-label={m.doc_comment_delete_aria()}
										>
											<Trash2 size={12} strokeWidth={2} aria-hidden="true" />
										</button>
									{/if}
								</span>
							{/if}
						{/if}
					</div>
					{#if !entry.deleted}
						{#if editingId === row.meta.id}
							<div class="cs-edit" use:submitShortcut={() => void saveEdit(row)}>
								<Markdown
									mode="write"
									bare
									value={editDraft}
									onchange={(v) => (editDraft = v)}
									domain={hostDef.domain}
								/>
								{#if mutationError}
									<span class="cs-mutation-error" role="alert">{mutationError}</span>
								{/if}
								<div class="cs-edit-actions">
									<button class="cs-btn cs-btn-cancel" type="button" onclick={cancelEdit}>
										Cancel
									</button>
									<button
										class="cs-btn cs-btn-primary"
										type="button"
										disabled={mutatingId === row.meta.id || editDraft.trim().length === 0}
										onclick={() => saveEdit(row)}
									>
										{mutatingId === row.meta.id ? m.common_saving() : m.common_save()}
									</button>
								</div>
							</div>
						{:else}
							<div class="cs-body-wrap">
								<div
									class="cs-body"
									class:cs-clamped={shouldClamp(row)}
									class:cs-expanded={isExpanded(row)}
									style="--cs-clamp: {CLAMP_MAX_PX}px"
									data-testid="comment-body-{row.meta.id}"
									use:clampObserver={row.meta.id}
								>
									<Markdown
										value={String(row.data['body'] ?? '')}
										readonly
										bare
										{onReferenceClick}
									/>
								</div>
								{#if longIds[row.meta.id]}
									{#if isExpanded(row)}
										<div class="cs-more-row">
											<button
												class="cs-more"
												type="button"
												onclick={() => (expandedIds[row.meta.id] = false)}
											>
												{m.doc_comment_show_less()}
											</button>
										</div>
									{:else}
										<button
											class="cs-more cs-more-overlay"
											type="button"
											onclick={() => (expandedIds[row.meta.id] = true)}
										>
											{m.doc_comment_show_more()}
										</button>
									{/if}
								{/if}
							</div>
						{/if}
					{/if}
				</li>
			{/each}
		</ul>
	{/if}

	{#if mutationError && editingId === null}
		<span class="cs-mutation-error" role="alert">{mutationError}</span>
	{/if}

	<!-- Composer: locked hint when the host create grant is missing (UI hint
		only — the backend re-checks the nested-create grant). -->
	{#if canCreate}
		<div
			class="cs-composer"
			data-testid="comment-composer"
			bind:this={composerEl}
			use:submitShortcut={() => void submit()}
		>
			{#if replyTargetName !== null}
				<span class="cs-reply-chip">
					<CornerDownRight size={12} strokeWidth={2} aria-hidden="true" />
					{m.doc_comment_replying_note({ name: replyTargetName })}
					<button
						class="cs-reply-chip-cancel"
						type="button"
						onclick={cancelReply}
						aria-label={m.doc_comment_reply_cancel_aria()}
					>
						<X size={12} strokeWidth={2} aria-hidden="true" />
					</button>
				</span>
			{/if}
			<Markdown
				mode="write"
				bare
				value={draft}
				placeholder={replyToId === null
					? m.doc_comment_placeholder()
					: m.doc_comment_reply_placeholder()}
				onchange={(v) => (draft = v)}
				domain={hostDef.domain}
				bind:expanded={composerExpanded}
			/>
			{#if submitError}
				<span class="cs-mutation-error" role="alert">{submitError}</span>
			{/if}
			<div class="cs-composer-actions">
				<button
					class="cs-btn cs-btn-primary"
					type="button"
					disabled={submitting || draft.trim().length === 0}
					onclick={submit}
				>
					{submitting ? m.doc_comment_posting() : m.doc_comment_button()}
				</button>
			</div>
		</div>
	{:else}
		<div class="cs-composer-locked">{m.doc_comments_forbidden()}</div>
	{/if}
</div>

<style>
	.comment-surface {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 4px 0;
	}

	.cs-status,
	.cs-empty {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
		padding: 12px;
		text-align: center;
		border: 1px dashed var(--border);
		border-radius: var(--r);
	}

	.cs-error {
		font-size: 12px;
		color: var(--danger);
		padding: 8px 10px;
		border: 1px solid var(--danger-weak);
		border-radius: var(--r);
		background: var(--danger-weak);
	}

	.cs-thread {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.cs-comment {
		display: flex;
		flex-direction: column;
		gap: 5px;
		padding: 9px 10px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
		transition:
			border-color 0.12s,
			background 0.12s;
		/* Reply indent — set per row via the `--cs-depth` custom property
		 * (capped in the script; presentation only). */
		margin-left: calc(var(--cs-depth, 0) * 1.25rem);
	}

	.cs-collapse {
		display: inline-flex;
		align-items: center;
		gap: 2px;
		padding: 0 4px;
		height: 22px;
		color: var(--text-3);
		background: transparent;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		cursor: pointer;
		transition:
			color 0.12s,
			border-color 0.12s,
			background 0.12s;
	}

	.cs-collapse:hover {
		color: var(--text);
		background: var(--sunken);
		border-color: var(--border-strong);
	}

	.cs-collapse:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.cs-collapse-count {
		font-size: 11px;
		font-weight: 600;
	}

	.cs-reply-note {
		font-size: 11.5px;
		color: var(--text-3);
		font-style: italic;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	/* The armed reply target: the gold tint mirrors the composer chip. */
	.cs-comment-replying {
		border-color: var(--accent-ink);
		background: var(--accent-weak);
	}

	/* Stand-in card for a tombstoned parent: muted, dashed, body-less —
	 * present only so its live replies keep their nesting. */
	/* "Replying to {name}" pill above the composer input while a reply is
	 * armed — tinted like the highlighted target card, with the cancel
	 * button tucked into the right edge. */
	.cs-reply-chip {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		align-self: flex-start;
		font-size: 12px;
		font-weight: 500;
		padding: 2px 4px 2px 8px;
		border-radius: var(--r);
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	.cs-reply-chip-cancel {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 16px;
		height: 16px;
		padding: 0;
		color: inherit;
		background: transparent;
		border: none;
		border-radius: var(--r-sm);
		cursor: pointer;
	}

	.cs-reply-chip-cancel:hover {
		color: var(--text);
	}

	.cs-reply-chip-cancel:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.cs-comment-deleted {
		background: transparent;
		border-style: dashed;
		opacity: 0.8;
	}

	.cs-deleted-label {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
	}

	.cs-comment-head {
		display: flex;
		align-items: center;
		gap: 7px;
		min-height: 22px;
	}

	.cs-author {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text);
	}

	.cs-actions {
		display: inline-flex;
		gap: 4px;
		margin-left: auto;
	}

	.cs-action {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		padding: 0;
		color: var(--text-3);
		background: transparent;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		cursor: pointer;
		transition:
			color 0.12s,
			border-color 0.12s,
			background 0.12s;
	}

	.cs-action:hover:not(:disabled) {
		color: var(--text);
		background: var(--sunken);
		border-color: var(--border-strong);
	}

	.cs-action:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.cs-action:disabled {
		opacity: 0.5;
		cursor: default;
	}

	.cs-body-wrap {
		position: relative;
		min-width: 0;
	}

	.cs-body {
		min-width: 0;
		position: relative;
	}

	/* Relatively long bodies (~10 prose lines or more) clamp to the height
	 * from the script — single source of truth via the `--cs-clamp` custom
	 * property. The cut fades into the card background and the toggle sits
	 * centred on it; expanded bodies flow fully on an inset surface strip.
	 * Short bodies are unaffected — max-height only caps. */
	.cs-body.cs-clamped {
		max-height: var(--cs-clamp);
		overflow: hidden;
	}

	.cs-body.cs-clamped::after {
		content: '';
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		height: 44px;
		background: linear-gradient(to bottom, transparent, var(--surface-2));
		pointer-events: none;
	}

	/* Inside the tinted reply target the fade follows the card tint. */
	.cs-comment-replying .cs-body.cs-clamped::after {
		background: linear-gradient(to bottom, transparent, var(--accent-weak));
	}

	/* Opened state: the full body sits on an inset strip that spans the
	 * card width — padding keeps prose aligned with the author row. */
	.cs-body.cs-expanded {
		background: var(--surface);
		border-radius: var(--r);
		padding: 8px 10px;
		margin: 0 -10px;
	}

	.cs-more {
		font: inherit;
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
	}

	.cs-more-overlay {
		position: absolute;
		bottom: 4px;
		left: 50%;
		transform: translateX(-50%);
		z-index: 1;
		padding: 2px 10px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text-2);
		box-shadow: var(--sh-1);
	}

	.cs-more-overlay:hover {
		color: var(--text);
		border-color: var(--border-strong);
	}

	.cs-more-row {
		display: flex;
		justify-content: center;
		margin-top: 2px;
	}

	.cs-more-row .cs-more {
		padding: 0;
		border: none;
		background: none;
		color: var(--accent);
	}

	.cs-more-row .cs-more:hover {
		text-decoration: underline;
	}

	.cs-more:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	/* The readonly body runs bare with zero editor inset — the comment card
	 * provides the padding, so prose aligns with the author row (matching
	 * the sidecar panel mockup). */
	.cs-body :global(.markdown .milkdown-host .milkdown-root .ProseMirror) {
		padding: 0;
	}

	.cs-edit {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.cs-edit-actions,
	.cs-composer-actions {
		display: flex;
		justify-content: flex-end;
		gap: 6px;
	}

	.cs-btn {
		padding: 4px 12px;
		font-size: 12px;
		font-weight: 600;
		border-radius: var(--r);
		cursor: pointer;
	}

	.cs-btn-cancel {
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border-strong);
	}

	.cs-btn-cancel:hover {
		background: var(--sunken);
	}

	.cs-btn-primary {
		color: var(--on-accent);
		background: var(--accent);
		border: 1px solid var(--accent);
	}

	.cs-btn-primary:hover:not(:disabled) {
		background: var(--accent-press);
	}

	.cs-btn:disabled {
		opacity: 0.6;
		cursor: default;
	}

	.cs-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.cs-mutation-error {
		font-size: 11.5px;
		color: var(--danger);
	}

	.cs-composer {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 10px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
		/* Stick to the bottom of the sidecar rail's scrollport: with a long
		 * thread the reply box stays reachable without scrolling to the end. */
		position: sticky;
		bottom: 0;
		z-index: 1;
	}

	.cs-composer-locked {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
		padding: 12px;
		text-align: center;
		border: 1px dashed var(--border);
		border-radius: var(--r);
	}
</style>
