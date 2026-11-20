<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ApiKeyRevealDialog from './ApiKeyRevealDialog.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Settings/ApiKeyRevealDialog',
		component: ApiKeyRevealDialog,
		tags: ['autodocs'],
		args: {
			open: true,
			created: {
				key: 'fct_abc123def456ghi789jkl012mno',
				display_prefix: 'fct_abc123',
				expires_at: null
			}
		}
	});
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
</script>

<!--
	Bits UI `Dialog.Portal` mounts content into `document.body`, so the play
	functions query `within(document.body)`.
-->

<Story
	name="DefaultKeyShownOnceWithCopyButton"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('API key created')).toBeVisible());

		// The raw key renders in full.
		await expect(body.getByText('fct_abc123def456ghi789jkl012mno')).toBeVisible();
		// The one-time warning is present.
		await expect(body.getByText('only once', { exact: false })).toBeVisible();
		await expect(body.getByRole('button', { name: 'Copy' })).toBeVisible();
		// No expiry note when the key never expires.
		await expect(body.queryByText(/stops working after/)).toBeNull();

		// Clean up so later stories see a single dialog in the portal.
		await userEvent.click(body.getByRole('button', { name: 'Done' }));
		await waitFor(() => {
			expect(body.queryByText('API key created')).toBeNull();
		});
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<ApiKeyRevealDialog open={args.open} created={args.created} />
		</div>
	{/snippet}
</Story>

<Story
	name="CopyShowsConfirmationState"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		// Headless Chromium may reject clipboard writes; stub the API so the
		// click deterministically reaches the "Copied" state.
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: async () => {} },
			configurable: true
		});
		await waitFor(() => expect(body.getByText('API key created')).toBeVisible());

		await userEvent.click(body.getByRole('button', { name: 'Copy' }));
		// The button flips to the "Copied" state.
		await waitFor(() => {
			expect(body.getByRole('button', { name: 'Copied' })).toBeVisible();
		});

		await userEvent.click(body.getByRole('button', { name: 'Done' }));
		await waitFor(() => {
			expect(body.queryByText('API key created')).toBeNull();
		});
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<ApiKeyRevealDialog open={args.open} created={args.created} />
		</div>
	{/snippet}
</Story>

<Story
	name="WithExpiry"
	args={{
		open: true,
		created: {
			key: 'fct_abc123def456ghi789jkl012mno',
			display_prefix: 'fct_abc123',
			expires_at: new Date(Date.now() + 7 * 86400_000).toISOString()
		}
	}}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('API key created')).toBeVisible());
		await expect(body.getByText(/stops working after/)).toBeVisible();

		await userEvent.click(body.getByRole('button', { name: 'Done' }));
		await waitFor(() => {
			expect(body.queryByText('API key created')).toBeNull();
		});
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<ApiKeyRevealDialog open={args.open} created={args.created} />
		</div>
	{/snippet}
</Story>
