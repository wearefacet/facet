<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within } from 'storybook/test';
	import SchematicNode from './SchematicNode.svelte';
	import type { SchematicNode as NodeType } from './types.js';

	const baseNode: NodeType = {
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
	};

	const childNode: NodeType = {
		id: 'crm.Contact',
		label: 'Contact',
		color: 'var(--dt-contact)',
		icon: 'users',
		tagline: 'child of Company',
		taglineKind: 'child',
		x: 90,
		y: 100,
		width: 160,
		height: 56
	};

	const minimalNode: NodeType = {
		id: 'core.Ledger',
		label: 'Ledger',
		color: '#4a5774',
		x: 60,
		y: 60,
		width: 160,
		height: 56
	};

	// Click spies — reset at the top of each play.
	let lastClicked: string | undefined = undefined;
	let lastDragStart: string | undefined = undefined;
	const onNodeClick = (id: string) => {
		lastClicked = id;
	};
	const onDragStart = (id: string) => {
		lastDragStart = id;
	};

	const { Story } = defineMeta({
		title: 'Components/Schematic/SchematicNode',
		component: SchematicNode,
		tags: ['autodocs']
	});
</script>

<Story
	name="Default"
	play={async ({ canvasElement }) => {
		lastClicked = undefined;
		lastDragStart = undefined;
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Company')).toBeVisible();
		await expect(canvas.getByText('aggregate root')).toBeVisible();
		// A press + release with no movement is a click, not a drag — the
		// node id reaches `onclick` and `ondragstart` stays silent.
		await userEvent.click(canvas.getByRole('button', { name: 'Company aggregate root' }));
		await expect(lastClicked).toBe('crm.Company');
		await expect(lastDragStart).toBeUndefined();
	}}
>
	{#snippet template()}
		<div class="node-frame">
			<SchematicNode node={baseNode} onclick={onNodeClick} ondragstart={onDragStart} />
		</div>
	{/snippet}
</Story>

<Story
	name="ChildTagline"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Contact')).toBeVisible();
		await expect(canvas.getByText('child of Company')).toBeVisible();
	}}
>
	{#snippet template()}
		<div class="node-frame">
			<SchematicNode node={childNode} onclick={onNodeClick} />
		</div>
	{/snippet}
</Story>

<Story name="Selected">
	{#snippet template()}
		<div class="node-frame">
			<SchematicNode node={baseNode} selected />
		</div>
	{/snippet}
</Story>

<Story
	name="Minimal"
	play={async ({ canvasElement }) => {
		lastClicked = undefined;
		const canvas = within(canvasElement);
		// No icon (diamond fallback) and no tagline — the node still clicks.
		await expect(canvas.getByText('Ledger')).toBeVisible();
		await expect(canvas.queryByText('aggregate root')).toBeNull();
		await userEvent.click(canvas.getByRole('button', { name: 'Ledger' }));
		await expect(lastClicked).toBe('core.Ledger');
	}}
>
	{#snippet template()}
		<div class="node-frame">
			<SchematicNode node={minimalNode} onclick={onNodeClick} />
		</div>
	{/snippet}
</Story>

<style>
	/* Nodes position absolutely — the frame gives them a relative box. */
	.node-frame {
		position: relative;
		width: 360px;
		height: 220px;
		margin: 24px auto;
		background: var(--ground);
		border: 1px dashed var(--border);
		border-radius: var(--r);
		overflow: hidden;
	}
</style>
