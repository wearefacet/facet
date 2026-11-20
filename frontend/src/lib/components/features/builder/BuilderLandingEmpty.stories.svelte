<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import BuilderLandingEmpty from './BuilderLandingEmpty.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Builder/BuilderLandingEmpty',
		component: BuilderLandingEmpty,
		tags: ['autodocs']
	});
</script>

<!--
	The guidance names the sidebar's "New domain" button, so the copy is gated
	on the same `core.Domain` create grant. CanFixture sets the permission
	manifest synchronously during initialization, before the `<Can>` inside
	reads it.
-->

<Story
	name="WithCreatePermission"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText(/No draft domains yet/)).toBeInTheDocument();
		await expect(canvas.getByText('New domain')).toBeInTheDocument();
		await expect(canvas.getByText('Edit existing')).toBeInTheDocument();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'core.Domain': ['create', 'read'] }}>
			<BuilderLandingEmpty />
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="WithoutCreatePermission"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The sidebar hides "New domain" for this role — the copy must not
		// name it, and the neutral line renders instead.
		await expect(canvas.queryByText('New domain')).toBeNull();
		await expect(canvas.queryByText('Edit existing')).toBeNull();
		await expect(canvas.getByText('No drafts in progress.')).toBeInTheDocument();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'core.Domain': ['read'] }}>
			<BuilderLandingEmpty />
		</CanFixture>
	{/snippet}
</Story>
