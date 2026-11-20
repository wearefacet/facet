<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { Schematic, SchematicEdge, SchematicNode } from './types.js';
	import { bezierMid, bezierPath, fitViewBox } from './geometry.js';
	import SchematicNodeComp from './SchematicNode.svelte';

	let {
		schematic,
		selected,
		onnodeclick,
		onlayoutcommit
	}: {
		schematic: Schematic;
		/** Optional id of the currently selected node. */
		selected?: string;
		/** Called when a node is clicked (pointerdown+up with no drag). */
		onnodeclick?: (id: string) => void;
		/** Called when a node drag ends, with a plain copy of the full
		 *  positions map — the persistence seam (schematic.md → Persistence). */
		onlayoutcommit?: (positions: Record<string, { x: number; y: number }>) => void;
	} = $props();

	// ── Mutable node positions ──────────────────────────────────────────────
	// The incoming `schematic` is treated as the initial layout. We keep a
	// `$state` map of per-node position overrides so dragging mutates only the
	// positions, leaving labels/colors/edges intact. Edges and the stage size
	// recompute reactively from the merged positions.
	// Initial positions from the first schematic. The $effect below rebuilds
	// this when `schematic` changes (e.g. switching Storybook stories).
	// svelte-ignore state_referenced_locally — intentional: we only want the
	// initial value here; updates are handled by the $effect.
	let positions = $state<Record<string, { x: number; y: number }>>(
		Object.fromEntries(schematic.nodes.map((n) => [n.id, { x: n.x, y: n.y }]))
	);

	// Reset overrides when the schematic identity changes (e.g. switching
	// Storybook stories). Comparing by reference is correct: buildDomainSchematic
	// returns a fresh object each time.
	//
	// We must NOT read `positions` inside the $effect — doing so would create a
	// dependency cycle (drag mutates positions → effect reruns → resets). So we
	// rebuild the positions map from scratch and reassign, which the $effect
	// tracks via `schematic` only.
	let lastSchematic: Schematic | null = null;
	$effect(() => {
		const s = schematic;
		if (s === lastSchematic) return;
		lastSchematic = s;
		const next: Record<string, { x: number; y: number }> = {};
		for (const n of s.nodes) next[n.id] = { x: n.x, y: n.y };
		positions = next;
	});

	// Merge the original node with any position override.
	// Reading `positions` at the top level of the $derived ensures Svelte
	// tracks the whole state object (not just individual keys accessed
	// inside a .map callback), so reassigning `positions` reliably retriggers.
	const liveNodes = $derived.by(() => {
		const pos = positions;
		return schematic.nodes.map((n) => {
			const p = pos[n.id];
			return p ? { ...n, x: p.x, y: p.y } : n;
		});
	});

	const byId = $derived(new Map(liveNodes.map((n) => [n.id, n])));
	// The stage is sized to the content extent (in schematic units) so the SVG
	// and the absolutely-positioned nodes share one 1px-per-unit coordinate
	// space. No viewBox: SVG user units == CSS pixels, edges line up with nodes.
	const stage = $derived(fitViewBox(liveNodes));

	function edgeEndpoints(e: SchematicEdge): { from: SchematicNode; to: SchematicNode } | null {
		const from = byId.get(e.from);
		const to = byId.get(e.to);
		if (!from || !to) return null;
		return { from, to };
	}

	function pathFor(e: SchematicEdge): string {
		const ends = edgeEndpoints(e);
		if (!ends) return '';
		return bezierPath(ends.from, ends.to);
	}

	function labelPos(e: SchematicEdge): { x: number; y: number } | null {
		const ends = edgeEndpoints(e);
		if (!ends) return null;
		return bezierMid(ends.from, ends.to);
	}

	function handleNodeClick(id: string) {
		onnodeclick?.(id);
	}

	// A drag ended — hand the full current layout to the persistence seam.
	// Plain copy: the $state proxy keeps mutating as the next drag starts.
	function handleDragEnd(_id: string) {
		onlayoutcommit?.(Object.fromEntries(Object.entries(positions).map(([k, v]) => [k, { ...v }])));
	}

	// ── Drag handling ──────────────────────────────────────────────────────
	// ondragmove receives screen-pixel deltas; since the stage renders at
	// 1px per schematic unit (no CSS transform), screen px == schematic px.
	// We divide by the stage's rendered scale to stay correct under zoom.
	let stageEl: HTMLDivElement | null = $state(null);

	function scale(): number {
		if (!stageEl) return 1;
		const rect = stageEl.getBoundingClientRect();
		// rect.width is the rendered width; stage.width is the schematic width.
		return rect.width > 0 ? rect.width / stage.width : 1;
	}

	function handleDragMove(id: string, dx: number, dy: number) {
		const s = scale();
		if (s === 0) return;
		const p = positions[id];
		if (!p) return;
		// Mutate the existing $state record in place — Svelte 5's deep proxy
		// reactivity picks up property changes and retriggers $derived.
		positions[id] = { x: p.x + dx / s, y: p.y + dy / s };
	}
</script>

<div class="schematic">
	<div bind:this={stageEl} class="stage" style="width: {stage.width}px; height: {stage.height}px">
		<svg class="edges" width={stage.width} height={stage.height}>
			<defs>
				<marker
					id="sch-diamond"
					viewBox="0 0 12 12"
					refX="6"
					refY="6"
					markerWidth="11"
					markerHeight="11"
					orient="auto-start-reverse"
				>
					<path class="mk-diamond" d="M6 0 L12 6 L6 12 L0 6 Z" />
				</marker>
				<marker
					id="sch-arrow"
					viewBox="0 0 12 12"
					refX="9"
					refY="6"
					markerWidth="11"
					markerHeight="11"
					orient="auto"
				>
					<path class="mk-arrow" d="M3 2 L9 6 L3 10" />
				</marker>
			</defs>

			{#each schematic.edges as edge (edge.from + edge.to + edge.kind)}
				{#if edge.kind === 'composition'}
					<path class="edge comp" d={pathFor(edge)} marker-start="url(#sch-diamond)" />
				{:else}
					<path class="edge ref" d={pathFor(edge)} marker-end="url(#sch-arrow)" />
				{/if}
			{/each}
		</svg>

		{#each schematic.edges as edge (edge.from + edge.to + edge.kind)}
			{#if edge.label}
				{@const pos = labelPos(edge)}
				{#if pos}
					<span class="elbl" style="left: {pos.x}px; top: {pos.y}px">{edge.label}</span>
				{/if}
			{/if}
		{/each}

		{#each liveNodes as node (node.id)}
			<SchematicNodeComp
				{node}
				selected={node.id === selected}
				onclick={handleNodeClick}
				ondragmove={handleDragMove}
				ondragend={handleDragEnd}
			/>
		{/each}
	</div>
</div>

<style>
	.schematic {
		position: relative;
		width: 100%;
		height: 100%;
		min-height: 420px;
		overflow: auto;
		background:
			radial-gradient(
					circle at center,
					color-mix(in srgb, var(--text-3) 9%, transparent) 1px,
					transparent 1px
				)
				0 0 / 22px 22px,
			var(--ground);
	}

	.stage {
		position: relative;
		flex: none;
	}

	.edges {
		position: absolute;
		left: 0;
		top: 0;
		overflow: visible;
		pointer-events: none;
	}

	.edge {
		fill: none;
	}
	.edge.comp {
		stroke: var(--accent);
		stroke-width: 1.8;
		marker-start: url(#sch-diamond);
	}
	.edge.ref {
		stroke: var(--text-3);
		stroke-width: 1.5;
		stroke-dasharray: 5 4;
	}

	.mk-diamond {
		fill: var(--accent);
	}
	.mk-arrow {
		stroke: var(--text-3);
		fill: none;
		stroke-width: 1.6;
		stroke-linecap: round;
		stroke-linejoin: round;
	}

	.elbl {
		position: absolute;
		transform: translate(-50%, -50%);
		font-family: var(--font-mono);
		font-size: 10px;
		color: var(--text-3);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		padding: 1px 7px;
		white-space: nowrap;
		pointer-events: none;
	}

	@media (prefers-reduced-motion: reduce) {
		.schematic * {
			transition: none !important;
		}
	}
</style>
