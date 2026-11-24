<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { TemplateNode } from '$lib/template-types.js';
	import type { KanbanLane } from '$lib/collectionView/types.js';
	import KanbanCard from './KanbanCard.svelte';

	/**
	 * One lane of the kanban board — header (colour dot, label, mono count
	 * badge) over a scrollable card stack. Each lane owns its loading,
	 * error, and empty state independently, so one denied or failing lane
	 * does not blank the board.
	 *
	 * The "Show more" action renders while the lane's last page came back
	 * full (`items.length === cap` — the table's next-page rule); clicking
	 * it bumps the lane's fetch cap and re-fetches only this lane. The
	 * count badge keeps showing the capped `meta.count`.
	 *
	 * Drag & drop: when `droppable` is set the lane is an active drop target
	 * (write target resolved, a drag is in flight, not the source lane) and
	 * highlights while a card hovers over it; the drop hands the card id to
	 * `onDrop`. Cards drag from the lane when `cardDraggable` is set.
	 */
	let {
		lane,
		items,
		loading,
		error,
		count,
		cap,
		doctype,
		driver,
		cardTemplate = null,
		onShowMore,
		onCardClick,
		cardDraggable = false,
		droppable = false,
		onCardDragStart,
		onDragEnd,
		onDrop
	}: {
		/** The lane definition (label, optional colour, filter). */
		lane: KanbanLane;
		/** Documents fetched for this lane. */
		items: DocumentResponse<Record<string, unknown>>[];
		/** Whether the lane's fetch is in flight. */
		loading: boolean;
		/** Set when the lane's fetch failed; the rest of the board stays live. */
		error: string | null;
		/** Capped count from the response `meta.count` ("at least N"). */
		count: number | null;
		/** The lane's current fetch cap — full-page rule input for Show more. */
		cap: number;
		/** Parsed doctype definition — handed to each card. */
		doctype: DoctypeDef;
		/** Driver handed to each card. */
		driver: DataDriver;
		/** The resolved `card` template node, or null for identity-only cards. */
		cardTemplate?: TemplateNode | null;
		/** Fired when the user asks for the next page of this lane. */
		onShowMore?: () => void;
		/** Fired when a card's identity head is clicked. */
		onCardClick?: (docId: string) => void;
		/** Whether this lane's cards can start a drag. */
		cardDraggable?: boolean;
		/** Whether this lane accepts a drop right now (drives the highlight
		 *  and the drop handling). */
		droppable?: boolean;
		/** Fired on a card's `dragstart` with the card's document id. */
		onCardDragStart?: (docId: string) => void;
		/** Fired when a dragged card's drag session ends (drop or cancel). */
		onDragEnd?: () => void;
		/** Fired when a card drops on this lane, with the card's document id. */
		onDrop?: (docId: string) => void;
	} = $props();

	// Lane containers are keyed by index (see Kanban.svelte) and cards carry
	// `data-doc-id`, so a move resolves the write target by lane position.
	const showMore = $derived(!loading && error === null && items.length > 0 && items.length === cap);

	// ── Drop target ─────────────────────────────────────
	let dragOver = $state(false);

	function handleDragOver(e: DragEvent): void {
		if (!droppable) return;
		e.preventDefault();
		if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
		dragOver = true;
	}

	function handleDragLeave(e: DragEvent): void {
		// Child elements (cards) fire dragleave as the pointer crosses them —
		// keep the highlight while the pointer stays inside the lane.
		const related = e.relatedTarget as Node | null;
		if (related && e.currentTarget instanceof Node && e.currentTarget.contains(related)) return;
		dragOver = false;
	}

	function handleDrop(e: DragEvent): void {
		dragOver = false;
		if (!droppable) return;
		e.preventDefault();
		const docId = e.dataTransfer?.getData('text/plain');
		if (docId) onDrop?.(docId);
	}
</script>

<!-- The drop target is progressive enhancement on the lane — pointer-only
	drag-and-drop (see KanbanCard); the lane's data stays reachable through
	the list surfaces without it. -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="kb-col"
	class:kb-droppable={droppable}
	class:kb-drag-over={dragOver}
	ondragover={handleDragOver}
	ondragleave={handleDragLeave}
	ondrop={handleDrop}
>
	<div class="kb-col-head">
		<span class="kb-dot" style={`background: ${lane.color ?? 'var(--text-3)'};`} aria-hidden="true"
		></span>
		<span class="kb-col-label">{lane.label}</span>
		{#if count !== null}
			<span class="kb-col-count">{count}</span>
		{/if}
	</div>

	<div class="kb-cards">
		{#if loading && items.length === 0}
			<div class="kb-placeholder">{m.list_views_loading()}</div>
		{:else if error}
			<div class="kb-lane-error" role="alert">{error}</div>
		{:else if items.length === 0}
			<div class="kb-placeholder">{m.kanban_lane_empty()}</div>
		{:else}
			{#each items as doc (doc.meta.id)}
				<KanbanCard
					{doc}
					{doctype}
					{driver}
					{cardTemplate}
					{onCardClick}
					draggable={cardDraggable}
					onDragStart={() => onCardDragStart?.(doc.meta.id)}
					{onDragEnd}
				/>
			{/each}
			{#if loading}
				<div class="kb-placeholder">{m.list_views_loading()}</div>
			{/if}
		{/if}
	</div>

	{#if showMore}
		<div class="kb-more">
			<button type="button" class="kb-more-btn" onclick={() => onShowMore?.()}>
				{m.kanban_show_more()}
			</button>
		</div>
	{/if}
</div>

<style>
	.kb-col {
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		display: flex;
		flex-direction: column;
		min-height: 200px;
		min-width: 0;
	}

	.kb-col.kb-droppable {
		border-style: dashed;
	}

	.kb-col.kb-drag-over {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.kb-col-head {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 13px 14px;
		font-size: 12.5px;
		font-weight: 600;
		letter-spacing: 0.02em;
		border-bottom: 1px solid var(--border);
	}

	.kb-dot {
		width: 8px;
		height: 8px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex-shrink: 0;
	}

	.kb-col-label {
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.kb-col-count {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 400;
		color: var(--text-3);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		padding: 0 8px;
		flex-shrink: 0;
	}

	/* The stack fills the lane below the header. The lane height caps the
	   stack, and a tall stack scrolls inside the lane. */
	.kb-cards {
		padding: 10px;
		display: flex;
		flex-direction: column;
		gap: 9px;
		flex: 1;
		min-height: 0;
		overflow-y: auto;
	}

	.kb-placeholder {
		color: var(--text-3);
		font-size: 12px;
		padding: 4px 2px;
	}

	.kb-lane-error {
		color: var(--danger);
		font-size: 12px;
		padding: 4px 2px;
	}

	.kb-more {
		padding: 0 10px 10px;
	}

	.kb-more-btn {
		width: 100%;
		padding: 5px 0;
		font: inherit;
		font-size: 12px;
		color: var(--text-2);
		background: none;
		border: 1px dashed var(--border);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			color 0.12s,
			border-color 0.12s;
	}

	.kb-more-btn:hover {
		color: var(--accent-ink);
		border-color: var(--border-strong);
	}

	.kb-more-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}
</style>
