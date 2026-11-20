<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { SchematicNode } from './types.js';
	import DoctypeIcon from '../primitives/data/DoctypeIcon.svelte';

	let {
		node,
		selected = false,
		dragging = $bindable(false),
		onclick: onclickProp,
		ondragstart,
		ondragmove,
		ondragend
	}: {
		node: SchematicNode;
		selected?: boolean;
		/** Bindable — true while a drag is in progress. */
		dragging?: boolean;
		/** Called on click (pointerdown + pointerup with no significant movement). */
		onclick?: (id: string) => void;
		/** Called when a drag starts, with the node id. */
		ondragstart?: (id: string) => void;
		/** Called on each drag move, with the delta in schematic-space pixels. */
		ondragmove?: (id: string, dx: number, dy: number) => void;
		/** Called when a drag ends, with the node id. */
		ondragend?: (id: string) => void;
	} = $props();

	const taglineKind = $derived(node.taglineKind ?? 'neutral');

	// ── Pointer drag ──────────────────────────────────────────────────────
	// We track the pointer start position and the node's start position. On
	// pointermove we compute the delta in screen pixels and convert it to
	// schematic-space pixels by dividing by the stage's CSS scale (the stage
	// is rendered at 1px per schematic unit, so scale is typically 1, but we
	// divide by getBoundingClientRect to be robust to CSS transforms/zoom).
	let dragOrigin: { px: number; py: number; moved: boolean } | null = null;

	function onpointerdown(e: PointerEvent) {
		// Only left button starts a drag.
		if (e.button !== 0) return;
		dragOrigin = { px: e.clientX, py: e.clientY, moved: false };
		try {
			(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		} catch {
			// setPointerCapture can throw under synthetic events in tests.
		}
	}

	function onpointermove(e: PointerEvent) {
		if (!dragOrigin) return;
		const dx = e.clientX - dragOrigin.px;
		const dy = e.clientY - dragOrigin.py;
		if (!dragOrigin.moved && Math.hypot(dx, dy) < 3) return; // dead zone → click
		if (!dragOrigin.moved) {
			dragOrigin.moved = true;
			dragging = true;
			ondragstart?.(node.id);
		}
		ondragmove?.(node.id, dx, dy);
		// Reset origin so subsequent moves are incremental — ondragmove receives
		// deltas since the last event, not since drag start.
		dragOrigin.px = e.clientX;
		dragOrigin.py = e.clientY;
	}

	function release(e: PointerEvent) {
		try {
			(e.currentTarget as HTMLElement).releasePointerCapture?.(e.pointerId);
		} catch {
			// releasePointerCapture throws if no active pointer capture exists
			// (e.g. synthetic events in tests). Safe to ignore.
		}
	}

	function onpointerup(e: PointerEvent) {
		const origin = dragOrigin;
		dragOrigin = null;
		release(e);
		if (!origin) return;
		if (!origin.moved) {
			onclickProp?.(node.id);
		} else {
			dragging = false;
			ondragend?.(node.id);
		}
	}

	function onpointercancel(e: PointerEvent) {
		const origin = dragOrigin;
		dragOrigin = null;
		release(e);
		if (origin?.moved) {
			dragging = false;
			ondragend?.(node.id);
		}
	}
</script>

<button
	type="button"
	class="sch-node"
	class:sel={selected}
	class:drag={dragging}
	class:tag-root={taglineKind === 'root'}
	class:tag-child={taglineKind === 'child'}
	style="--nt: {node.color}; left: {node.x}px; top: {node.y}px; width: {node.width}px; height: {node.height}px"
	{onpointerdown}
	{onpointermove}
	{onpointerup}
	{onpointercancel}
>
	<span class="nh">
		<DoctypeIcon icon={node.icon} color={node.color} active />
		<span class="nm">{node.label}</span>
	</span>
	{#if node.tagline}
		<span class="tagline">
			<span class="d" aria-hidden="true"></span>
			{node.tagline}
		</span>
	{/if}
</button>

<style>
	/* ── Schematic node — matches design-guideline .node ────────────────── */
	.sch-node {
		position: absolute;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		box-shadow: var(--sh-1);
		padding: 10px 11px 10px 13px;
		cursor: pointer;
		overflow: hidden;
		display: flex;
		flex-direction: column;
		gap: 6px;
		font: inherit;
		color: inherit;
		text-align: left;
		/* Lift the dragged node above its siblings and the edge layer. */
		z-index: 1;
	}

	.sch-node::before {
		content: '';
		position: absolute;
		left: 0;
		top: 0;
		bottom: 0;
		width: 4px;
		background: var(--nt, var(--accent));
	}

	.sch-node:hover {
		border-color: var(--border-strong);
		box-shadow: var(--sh-2);
	}

	.sch-node.sel {
		border-color: var(--accent);
		box-shadow:
			0 0 0 3px var(--accent-weak),
			var(--sh-2);
	}

	.sch-node.drag {
		cursor: grabbing;
		z-index: 5;
		box-shadow: var(--sh-2);
		user-select: none;
	}

	.nh {
		display: flex;
		align-items: center;
		gap: 7px;
	}

	.nm {
		font-family: var(--font-display);
		font-weight: 600;
		font-size: 13px;
	}

	.tagline {
		display: flex;
		align-items: center;
		gap: 5px;
		font-size: 9.5px;
		font-weight: 700;
		letter-spacing: 0.04em;
		text-transform: uppercase;
	}

	.tagline .d {
		width: 7px;
		height: 7px;
		transform: rotate(45deg);
		border-radius: 1px;
	}

	.tag-root .tagline {
		color: var(--accent-ink);
	}
	.tag-root .tagline .d {
		background: var(--accent);
	}

	.tag-child .tagline {
		color: var(--text-3);
	}
	.tag-child .tagline .d {
		background: transparent;
		border: 1.3px solid var(--text-3);
	}
</style>
