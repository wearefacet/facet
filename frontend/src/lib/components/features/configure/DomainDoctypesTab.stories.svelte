<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import type { MockDataDriver } from '$lib/datasource/MockDriver';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { SchematicLayoutSource, SchematicPositions } from '../../schematic/layout.js';
	import DomainDoctypesTab from './DomainDoctypesTab.svelte';

	const driver: MockDataDriver = createMockDriver();

	// Mirror DomainEditor's derivation: the domain's definitions parsed into
	// typed DoctypeDef rows, sorted by name.
	const productionDoctypes: DoctypeDef[] = [...driver.doctypeDefinitions.entries()]
		.filter(([qualified]) => qualified.startsWith('production.'))
		.map(([, raw]) => parseDoctypeDef(structuredClone(raw)))
		.sort((a, b) => a.doctype.localeCompare(b.doctype));

	// One source instance per story, held at module level so each play
	// asserts against the same object the component received through args.
	const savedLayout = memoryLayoutSource({ 'production.Team': { x: 620, y: 40 } });
	const noLayout = memoryLayoutSource(null);

	// A load that rejects — the 403 a scoped role without the
	// `core.SchematicLayout` read gets (B-383).
	const brokenLayout: SchematicLayoutSource = {
		load: fn(async () => Promise.reject(new Error('read denied'))),
		save: fn(async () => {})
	};

	/**
	 * In-memory layout source — the seam that stands in for the HTTP
	 * `core.SchematicLayout` source. `saved()` records what reached the
	 * source, so a play can assert the debounced write.
	 */
	function memoryLayoutSource(initial: SchematicPositions | null) {
		let lastSaved: SchematicPositions | null = null;
		const source: SchematicLayoutSource = {
			load: fn(async () => (initial ? structuredClone(initial) : null)),
			save: fn(async (_domain: string, positions: SchematicPositions) => {
				lastSaved = structuredClone(positions);
			})
		};
		return { source, saved: () => lastSaved };
	}

	/** The schematic node button for one doctype label (not the list row). */
	function schematicNode(canvas: ReturnType<typeof within>, label: string) {
		const nodes = canvas
			.getAllByText(label)
			.map((el: Element) => el.closest('button.sch-node'))
			.filter((el: Element | null): el is HTMLButtonElement => el !== null);
		expect(nodes, `one schematic node for ${label}`).toHaveLength(1);
		return nodes[0];
	}

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/DomainDoctypesTab',
		component: DomainDoctypesTab,
		tags: ['autodocs'],
		args: {
			domain: 'production',
			doctypes: productionDoctypes,
			registry: driver
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): this tab is part
		// of the DomainEditor surface, whose stories carry the same override.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="SavedLayoutMergesOverComputed"
	args={{ layoutSource: savedLayout.source }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The saved Team corner wins; Project has no saved entry and keeps
		// the computed column position (first root at 40/40).
		await waitFor(() => {
			expect(schematicNode(canvas, 'Team').style.left).toBe('620px');
			expect(schematicNode(canvas, 'Team').style.top).toBe('40px');
		});
		expect(schematicNode(canvas, 'Project').style.left).toBe('40px');
		expect(schematicNode(canvas, 'Project').style.top).toBe('40px');
		// Children keep their computed column (x = 260) unless saved.
		expect(schematicNode(canvas, 'Task').style.left).toBe('260px');
	}}
/>

<Story
	name="MissingDocumentFallsBackToComputed"
	args={{ layoutSource: noLayout.source }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The load resolves null (no document yet) — every node keeps the
		// deterministic two-column layout. Roots stack at x = 40.
		await waitFor(() => {
			expect(noLayout.source.load).toHaveBeenCalled();
		});
		expect(schematicNode(canvas, 'Project').style.left).toBe('40px');
		expect(schematicNode(canvas, 'Project').style.top).toBe('40px');
		expect(schematicNode(canvas, 'Team').style.left).toBe('40px');
		expect(schematicNode(canvas, 'Team').style.top).toBe('192px');
		// A missing document is not a failed read — the note stays hidden.
		await expect(canvas.queryByText(/The saved layout could not be read/)).toBeNull();
	}}
/>

<Story
	name="FailedReadFallsBackWithNote"
	args={{ layoutSource: brokenLayout }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The read failed (403 for a role without the `core.SchematicLayout`
		// read, B-383) — every node keeps the computed layout, and the note
		// chip labels the fallback instead of degrading silently.
		await waitFor(() => {
			expect(brokenLayout.load).toHaveBeenCalled();
		});
		expect(schematicNode(canvas, 'Project').style.left).toBe('40px');
		expect(schematicNode(canvas, 'Project').style.top).toBe('40px');
		await expect(canvas.getByText(/The saved layout could not be read/)).toBeInTheDocument();
	}}
/>

<Story
	name="DragEndSavesDebounced"
	args={{ layoutSource: noLayout.source }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const node = schematicNode(canvas, 'Project');
		const box = node.getBoundingClientRect();
		const startX = box.x + 20;
		const startY = box.y + 20;

		await userEvent.pointer([
			{ keys: '[MouseLeft>]', target: node, coords: { x: startX, y: startY } },
			{ coords: { x: startX + 80, y: startY + 60 } },
			{ keys: '[/MouseLeft]' }
		]);

		// The save rides a 500 ms debounce after the drag end. The map is
		// full (one entry per node) and the dragged corner moved down-right
		// (client px convert 1:1 unless the stage is scaled).
		await waitFor(
			() => {
				expect(noLayout.saved()).not.toBeNull();
			},
			{ timeout: 3000 }
		);
		const saved = noLayout.saved() as SchematicPositions;
		const keys = Object.keys(saved).sort();
		expect(keys).toEqual([
			'production.Project',
			'production.Task',
			'production.Team',
			'production.TeamMember'
		]);
		expect(saved['production.Project'].x).toBeGreaterThan(40);
		expect(saved['production.Project'].y).toBeGreaterThan(40);
		expect(Number.isInteger(saved['production.Project'].x)).toBe(true);
	}}
/>
