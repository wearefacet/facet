<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { TemplateNode } from '$lib/template-types.js';
	import DoctypeIcon from '$lib/components/primitives/data/DoctypeIcon.svelte';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import DocumentViewTemplate from '$lib/components/features/document-view/DocumentViewTemplate.svelte';

	/**
	 * One card on the kanban board — the `DocumentCard` shell, minus the
	 * per-card fetch: the document already arrived with the lane query.
	 *
	 * The identity head (doctype icon, display name, relative updated time)
	 * is the click target and opens the peek drawer via `onCardClick`. The
	 * body renders the doctype's `card` view template through
	 * `DocumentViewTemplate` inside a bounded container. When the doctype
	 * has no `card` template the body is omitted and the card is the
	 * identity alone — full-page templates never mount in a compact card.
	 *
	 * The root carries `data-doc-id` and, when `draggable` is set, starts an
	 * HTML5 drag carrying the document id — the lane drop PATCHes the target
	 * lane's value from it.
	 */
	let {
		doc,
		doctype,
		driver,
		cardTemplate = null,
		onCardClick,
		draggable = false,
		onDragStart,
		onDragEnd
	}: {
		/** The document response straight from the lane's `list()` call. */
		doc: DocumentResponse<Record<string, unknown>>;
		/** Parsed doctype definition — drives the icon and the DVT field types. */
		doctype: DoctypeDef;
		/** Driver handed to the DVT for reference hydration. */
		driver: DataDriver;
		/** The resolved `card` template node, or null for the identity-only body. */
		cardTemplate?: TemplateNode | null;
		/** Fired when the card's identity head is clicked. */
		onCardClick?: (docId: string) => void;
		/** Whether the card starts an HTML5 drag. */
		draggable?: boolean;
		/** Fired on the card's `dragstart`. */
		onDragStart?: () => void;
		/** Fired when the drag session ends (drop or cancel). */
		onDragEnd?: () => void;
	} = $props();

	const displayName = $derived(
		doc.meta.display_name && doc.meta.display_name.length > 0 ? doc.meta.display_name : doc.meta.id
	);

	function open(): void {
		onCardClick?.(doc.meta.id);
	}

	function handleDragStart(e: DragEvent): void {
		if (e.dataTransfer) {
			e.dataTransfer.setData('text/plain', doc.meta.id);
			e.dataTransfer.effectAllowed = 'move';
		}
		onDragStart?.();
	}
</script>

<!-- Drag-and-drop is pointer-only in this version — the drag handlers are
	progressive enhancement on top of the card, whose interactive paths (open
	via the identity head) stay keyboard-reachable. -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="kb-card"
	class:kb-card-draggable={draggable}
	data-doc-id={doc.meta.id}
	{draggable}
	ondragstart={handleDragStart}
	ondragend={() => onDragEnd?.()}
>
	<button type="button" class="kb-card-head" onclick={open} title={displayName}>
		<DoctypeIcon icon={doctype.icon} color={doctype.color} size={11} active />
		<span class="kb-card-title">{displayName}</span>
		<RelativeTime date={doc.meta.updated_at} />
	</button>
	{#if cardTemplate}
		<div class="kb-card-body">
			<DocumentViewTemplate template={cardTemplate} document={doc} {driver} def={doctype} />
		</div>
	{/if}
</div>

<style>
	.kb-card {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-1);
		overflow: hidden;
		min-width: 0;
		display: flex;
		flex-direction: column;
		/* Flex child of the lane's scrollable stack. `overflow: hidden`
		   zeroes the automatic minimum size, so the default shrink would
		   compact the card to the lane height instead of overflowing —
		   the stack scrolls in the lane, cards keep their natural height. */
		flex-shrink: 0;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.kb-card:hover {
		border-color: var(--border-strong);
		box-shadow: var(--sh-2);
	}

	.kb-card.kb-card-draggable {
		cursor: grab;
	}

	.kb-card-head {
		display: flex;
		align-items: center;
		gap: 7px;
		width: 100%;
		padding: 6px 9px;
		border: none;
		border-bottom: 1px solid var(--border);
		background: var(--surface-2, var(--sunken));
		color: var(--text);
		text-align: left;
		cursor: pointer;
		font: inherit;
		min-width: 0;
		transition: background 0.12s ease;
	}

	.kb-card-head:hover,
	.kb-card-head:focus-visible {
		background: var(--sunken);
	}

	.kb-card-head:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: -2px;
	}

	.kb-card-title {
		font-family: var(--font-display);
		font-size: 12px;
		font-weight: 600;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		flex: 1;
	}

	.kb-card-head :global(.relative-time) {
		flex-shrink: 0;
	}

	.kb-card-body {
		max-height: 260px;
		/* Vertical scroll only — wide template content clips instead of
		   pushing the card wider than its lane. */
		overflow-x: hidden;
		overflow-y: auto;
		padding: 8px;
	}

	/* The DVT renders its own chrome; pull the first rule out of the gutter. */
	.kb-card-body :global(.dvt-root:first-child) {
		margin-top: 0;
	}
</style>
