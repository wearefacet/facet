<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DoctypeRegistry } from './doctypeSchematic.js';
	import { buildDomainSchematic } from './doctypeSchematic.js';
	import { positionsPayload, type SchematicPositions } from './layout.js';
	import Schematic from './Schematic.svelte';

	let {
		registry,
		domain,
		selected,
		onnodeclick,
		storedPositions,
		onlayoutsave
	}: {
		/** A driver with a `doctypeDefinitions` map (e.g. `MockDataDriver`). */
		registry: DoctypeRegistry;
		/** Domain name to render (e.g. `"hr"`, `"crm"`). */
		domain: string;
		/** Optional id of the currently selected node. */
		selected?: string;
		/** Called when a node is clicked, with the qualified doctype id. */
		onnodeclick?: (id: string) => void;
		/** Saved positions for this domain (`core.SchematicLayout`), merged
		 *  over the computed column layout. Null = no saved layout yet. */
		storedPositions?: SchematicPositions | null;
		/** Called when a node drag ends, with the full positions map (x/y
		 *  rounded to integer pixels) — the persistence seam
		 *  (schematic.md → Persistence). */
		onlayoutsave?: (positions: SchematicPositions) => void;
	} = $props();

	const schematic = $derived(buildDomainSchematic(registry, domain, storedPositions));

	// The persistence seam. Drag deltas are sub-pixel floats under zoom, and
	// core.SchematicLayout stores integer pixels — round (and drop keys with
	// no live node) before the map leaves the schematic.
	function handleLayoutCommit(positions: SchematicPositions) {
		onlayoutsave?.(positionsPayload(schematic.nodes, positions));
	}
</script>

<Schematic {schematic} {selected} {onnodeclick} onlayoutcommit={handleLayoutCommit} />
