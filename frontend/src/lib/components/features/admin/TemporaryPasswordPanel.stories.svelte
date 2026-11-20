<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import TemporaryPasswordPanel from './TemporaryPasswordPanel.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Admin/TemporaryPasswordPanel',
		component: TemporaryPasswordPanel,
		tags: ['autodocs'],
		args: {
			open: true,
			password: 'K7mXw2QpR9tVz4Lc',
			email: 'ada@company.com',
			regenerated: false
		}
	});
</script>

<script lang="ts">
	import { expect, within, waitFor } from 'storybook/test';
</script>

<!--
	The panel is a Bits UI dialog — content mounts into `document.body`, so the
	`play` functions query `within(document.body)`. The copy interaction is
	left to manual review: `navigator.clipboard` permissions are not guaranteed
	in the headless browser.
-->

<Story
	name="Shows the password once with the warning"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Temporary password generated')).toBeVisible());
		await expect(body.getByText('K7mXw2QpR9tVz4Lc')).toBeVisible();
		await expect(body.getByText('Copy')).toBeVisible();
		// The shown-only-now warning is the point of the surface.
		await expect(body.getByText(/Shown only now/)).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 420px;">
			<TemporaryPasswordPanel
				open={args.open}
				password={args.password}
				email={args.email}
				regenerated={args.regenerated}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Regenerated heading"
	args={{ open: true, regenerated: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Temporary password regenerated')).toBeVisible());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 420px;">
			<TemporaryPasswordPanel
				open={args.open}
				password={args.password}
				email={args.email}
				regenerated={args.regenerated}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="No password renders nothing"
	play={async () => {
		await expect(within(document.body).queryByText('Temporary password generated')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="position: relative; width: 100%; min-height: 120px;">
			<TemporaryPasswordPanel open password={null} email={null} />
		</div>
	{/snippet}
</Story>
