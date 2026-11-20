<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import McpEndpoints from './McpEndpoints.svelte';
	import type { McpEndpoint } from '$lib/mcp/endpoints.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Settings/McpEndpoints',
		component: McpEndpoints,
		tags: ['autodocs']
	});

	const endpoints: McpEndpoint[] = [
		{ role: 'iam.Roles.editor', url: 'https://facet.example.com/Api/_mcp/iam.Roles.editor' },
		{ role: 'iam.Roles.viewer', url: 'https://facet.example.com/Api/_mcp/iam.Roles.viewer' }
	];
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
</script>

<!--
	The API surface is injected (`endpoints` / `loadEndpoints` props), so every
	story runs against mocks — no backend and no `apiFetch` involved.
-->

<Story
	name="ListsEndpointPerRole"
	args={{ endpoints }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);

		// One row per held role, with the humanized role label.
		await waitFor(() => expect(canvas.getByText('Editor')).toBeVisible());
		await expect(canvas.getByText('Viewer')).toBeVisible();

		// The URLs render verbatim in their readonly mono fields.
		await expect(
			canvas.getByText('https://facet.example.com/Api/_mcp/iam.Roles.editor')
		).toBeVisible();
		await expect(
			canvas.getByText('https://facet.example.com/Api/_mcp/iam.Roles.viewer')
		).toBeVisible();

		// One copy button per row; clicking flips it to "Copied" without
		// altering the URL. Headless Chromium may reject clipboard writes, so
		// stub the API first (same pattern as ApiKeyRevealDialog's story).
		const copyButtons = canvas.getAllByRole('button', { name: 'Copy' });
		await expect(copyButtons).toHaveLength(2);
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: async () => {} },
			configurable: true
		});
		await userEvent.click(copyButtons[0]);
		await waitFor(() => {
			expect(canvas.getByRole('button', { name: 'Copied' })).toBeVisible();
		});
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 300px; max-width: 900px;">
			<McpEndpoints endpoints={args.endpoints} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyState"
	args={{
		loadEndpoints: async () => []
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText(/None of your roles/)).toBeVisible());
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 300px; max-width: 900px;">
			<McpEndpoints loadEndpoints={args.loadEndpoints} />
		</div>
	{/snippet}
</Story>

<Story
	name="LoadError"
	args={{
		loadEndpoints: async () => {
			throw new Error('Server unreachable');
		}
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByRole('alert')).toBeVisible());
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 300px; max-width: 900px;">
			<McpEndpoints loadEndpoints={args.loadEndpoints} />
		</div>
	{/snippet}
</Story>
