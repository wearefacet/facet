<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
	import AppCard from './AppCard.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Dashboard/AppCard',
		component: AppCard,
		tags: ['autodocs']
	});
</script>

<Story
	name="Usable"
	args={{ name: 'CRM Portal', slug: 'crm-portal', usable: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const link = canvas.getByRole('link', { name: 'CRM Portal' });
		await expect(link).toBeVisible();
		await expect(canvas.queryByText(m.apps_not_usable_title())).toBeNull();
		await expect(canvas.queryByText(m.apps_not_usable_body())).toBeNull();
	}}
/>

<Story
	name="NotUsable"
	args={{ name: 'HR Suite', slug: 'hr-suite', usable: false }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('HR Suite')).toBeVisible();
		await expect(canvas.getByText(m.apps_not_usable_title())).toBeVisible();
		await expect(canvas.getByText(m.apps_not_usable_body())).toBeVisible();
		// No link role — the card cannot navigate anywhere.
		await expect(canvas.queryByRole('link')).toBeNull();
	}}
/>
