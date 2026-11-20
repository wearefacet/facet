<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import NoRoleScreen from './NoRoleScreen.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/NoRoleScreen',
		component: NoRoleScreen,
		tags: ['autodocs'],
		args: {
			onrefresh: fn()
		}
	});
</script>

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
</script>

<Story name="Default">
	{#snippet template()}
		<NoRoleScreen />
	{/snippet}
</Story>

<Story
	name="ShowsMessageAndRefreshes"
	args={{ onrefresh: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText(m.auth_no_role_title())).toBeVisible();
		await expect(canvas.getByText(m.auth_no_role_sub())).toBeVisible();
		await userEvent.click(canvas.getByRole('button', { name: m.auth_no_role_refresh() }));
		await expect(args.onrefresh).toHaveBeenCalledTimes(1);
		// The screen owns the browser-tab title too — no stale title from the
		// previous surface stays (F05-08).
		await expect(document.title).toBe(m.auth_no_role_page_title());
		// The screen also offers the way out — a sign-out button (no click: it
		// would fire the real logout request).
		await expect(canvas.getByRole('button', { name: m.nav_logout() })).toBeVisible();
	}}
>
	{#snippet template(args)}
		<NoRoleScreen onrefresh={args.onrefresh} />
	{/snippet}
</Story>
