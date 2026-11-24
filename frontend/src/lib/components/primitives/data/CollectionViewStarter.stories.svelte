<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import CollectionViewStarter from './CollectionViewStarter.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import type { CollectionSurface } from '$lib/collectionView/types.js';

	/** Unrestricted creator — the surface cards render. */
	const adminManifest = { '*.*': ['*'] };

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/CollectionViewStarter',
		component: CollectionViewStarter,
		tags: ['autodocs'],
		args: {
			oncreate: () => {}
		}
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within, fireEvent } from 'storybook/test';

	// Local log for the create callback — the play reads it back.
	let created: CollectionSurface[] = $state([]);
</script>

<!--
	The starter is the listing's zero-views state. The cards report the picked
	surface through `oncreate`; the host opens the editor preselected to it.
-->

<Story
	name="Default"
	play={async ({ canvasElement }) => {
		created = [];
		await sleep(50);
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('heading', { name: 'No views yet' })).toBeVisible();
		// Three selectable surfaces (the grid surface is not offered — it
		// does not exist yet).
		await expect(canvas.getByRole('button', { name: /Table/ })).toBeVisible();
		await expect(canvas.getByRole('button', { name: /Kanban/ })).toBeVisible();
		await expect(canvas.getByRole('button', { name: /Calendar/ })).toBeVisible();

		// Picking a card reports the surface to the host.
		await fireEvent.click(canvas.getByRole('button', { name: /Kanban/ }));
		await sleep(20);
		expect(created.length).toBe(1);
		expect(created[0]).toBe('kanban');
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="width: 700px; height: 420px; position: relative;">
				<CollectionViewStarter oncreate={(s) => (created = [...created, s])} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="NoCreatePermission"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// Fail-closed manifest: no cards, only the explanatory note.
		await expect(canvas.getByRole('heading', { name: 'No views yet' })).toBeVisible();
		await expect(canvas.queryByRole('button', { name: /Table/ })).toBeNull();
		await expect(canvas.getByText(/Someone with permission to create views/)).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={null}>
			<div style="width: 700px; height: 420px; position: relative;">
				<CollectionViewStarter oncreate={() => {}} />
			</div>
		</CanFixture>
	{/snippet}
</Story>
