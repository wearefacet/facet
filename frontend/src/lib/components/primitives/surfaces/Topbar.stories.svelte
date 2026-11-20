<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import Topbar from './Topbar.svelte';
	import type { Crumb } from './Topbar.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/Topbar',
		component: Topbar,
		tags: ['autodocs'],
		argTypes: {
			crumbs: { control: 'object' },
			notificationsCount: { control: 'number' },
			assistantLabel: { control: 'text' },
			searchPlaceholder: { control: 'text' }
		}
	});
</script>

<script lang="ts">
	const defaultCrumbs: Crumb[] = [
		{ label: 'Logistics Ops', href: '#' },
		{ label: 'Invoices', href: '#' },
		{ label: 'Table' }
	];

	const longCrumbs: Crumb[] = [
		{ label: 'Logistics Ops', href: '#' },
		{ label: 'Invoices', href: '#' },
		{ label: 'Draft', href: '#' },
		{ label: 'Q3 2026', href: '#' },
		{ label: 'Vendor Kuehne + Nagel', href: '#' },
		{ label: 'INV-0486' }
	];
</script>

<Story name="Default" args={{ crumbs: defaultCrumbs, notificationsCount: 3 }}>
	{#snippet template(args)}
		<div style="height:56px;border-bottom:1px solid var(--border)">
			<Topbar crumbs={args.crumbs} notificationsCount={args.notificationsCount} />
		</div>
	{/snippet}
</Story>

<Story name="No Notifications" args={{ crumbs: defaultCrumbs, notificationsCount: 0 }}>
	{#snippet template(args)}
		<div style="height:56px;border-bottom:1px solid var(--border)">
			<Topbar crumbs={args.crumbs} notificationsCount={args.notificationsCount} />
		</div>
	{/snippet}
</Story>

<Story name="Long Breadcrumb" args={{ crumbs: longCrumbs, notificationsCount: 12 }}>
	{#snippet template(args)}
		<div style="height:56px;border-bottom:1px solid var(--border)">
			<Topbar crumbs={args.crumbs} notificationsCount={args.notificationsCount} />
		</div>
	{/snippet}
</Story>

<Story name="Empty Breadcrumb" args={{ crumbs: [], notificationsCount: 0 }}>
	{#snippet template(args)}
		<div style="height:56px;border-bottom:1px solid var(--border)">
			<Topbar crumbs={args.crumbs} notificationsCount={args.notificationsCount} />
		</div>
	{/snippet}
</Story>

<Story
	name="HiddenNotifications"
	args={{ crumbs: defaultCrumbs, showNotifications: false, notificationsCount: 3 }}
	play={async ({ canvasElement }) => {
		// The account disabled in-app notifications: no bell renders at all,
		// even with an unread count.
		const canvas = within(canvasElement);
		await expect(canvas.queryByRole('button', { name: 'Notifications' })).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="height:56px;border-bottom:1px solid var(--border)">
			<Topbar
				crumbs={args.crumbs}
				showNotifications={args.showNotifications}
				notificationsCount={args.notificationsCount}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="HiddenSearch"
	args={{ crumbs: defaultCrumbs }}
	play={async ({ canvasElement }) => {
		// No shell renders the search trigger until the app has a search
		// surface — a control without a behaviour is a dead affordance.
		const canvas = within(canvasElement);
		await expect(canvas.queryByRole('button', { name: /Search records/ })).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="height:56px;border-bottom:1px solid var(--border)">
			<Topbar crumbs={args.crumbs} showSearch={false} />
		</div>
	{/snippet}
</Story>
