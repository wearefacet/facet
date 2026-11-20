<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within } from 'storybook/test';
	import Schematic from './Schematic.svelte';
	import type { Schematic as SchematicModel } from './types.js';

	// Abstract boxes-and-arrows fixture — no doctype catalogue needed. Two
	// edge kinds exercise both markers: composition (solid + diamond) and
	// reference (dashed + arrow).
	const demo: SchematicModel = {
		nodes: [
			{
				id: 'crm.Company',
				label: 'Company',
				color: 'var(--dt-shipment)',
				icon: 'briefcase',
				tagline: 'aggregate root',
				taglineKind: 'root',
				x: 40,
				y: 40,
				width: 160,
				height: 56
			},
			{
				id: 'crm.Contact',
				label: 'Contact',
				color: 'var(--dt-contact)',
				icon: 'users',
				tagline: 'child of Company',
				taglineKind: 'child',
				x: 300,
				y: 40,
				width: 160,
				height: 56
			},
			{
				id: 'crm.Deal',
				label: 'Deal',
				color: 'var(--dt-invoice)',
				icon: 'handshake',
				x: 170,
				y: 190,
				width: 160,
				height: 56
			}
		],
		edges: [
			{ from: 'crm.Company', to: 'crm.Contact', kind: 'composition', label: 'contacts' },
			{ from: 'crm.Company', to: 'crm.Deal', kind: 'reference', label: 'opportunities' }
		]
	};

	const single: SchematicModel = {
		nodes: [
			{
				id: 'hr.Sole',
				label: 'Sole',
				color: 'var(--dt-task)',
				icon: 'box',
				x: 40,
				y: 40,
				width: 160,
				height: 56
			}
		],
		edges: []
	};

	// Click spy — one slot, reset at the top of the play.
	let lastNodeId: string | undefined = undefined;
	const onnodeclick = (id: string) => {
		lastNodeId = id;
	};

	const { Story } = defineMeta({
		title: 'Components/Schematic/Schematic',
		component: Schematic,
		tags: ['autodocs'],
		args: { schematic: demo }
	});
</script>

<Story
	name="Default"
	args={{ onnodeclick }}
	play={async ({ canvasElement }) => {
		lastNodeId = undefined;
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Company')).toBeVisible();
		await expect(canvas.getByText('Contact')).toBeVisible();
		await expect(canvas.getByText('Deal')).toBeVisible();
		await expect(canvas.getByText('contacts')).toBeVisible();
		await expect(canvas.getByText('opportunities')).toBeVisible();
		// A pointer press + release with no drag reports the node id.
		await userEvent.click(canvas.getByRole('button', { name: 'Company aggregate root' }));
		await expect(lastNodeId).toBe('crm.Company');
	}}
/>

<Story name="Selected" args={{ selected: 'crm.Company' }} />

<Story
	name="NoEdges"
	args={{ schematic: single }}
	play={async ({ canvasElement }) => {
		// A lone island renders and carries no edge labels.
		await expect(within(canvasElement).getByText('Sole')).toBeVisible();
		await expect(within(canvasElement).queryByText('contacts')).toBeNull();
	}}
/>
