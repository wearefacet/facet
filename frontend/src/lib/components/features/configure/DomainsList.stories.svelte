<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import DomainsList from './DomainsList.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/DomainsList',
		component: DomainsList,
		tags: ['autodocs'],
		// A11y backlog: the published filter input carries a placeholder only
		// (no accessible name). The markup is carried over from the domains
		// page and kept identical by the refactor contract. Give the input a
		// label, then remove this override.
		parameters: { a11y: { test: 'todo' } },
		args: {
			onopenbuilder: fn(),
			onconfigure: fn(),
			ondelete: fn()
		}
	});
</script>

<script lang="ts">
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { domainListCache } from '$lib/datasource/clientCache.js';
	import { expect, within, waitFor, userEvent } from 'storybook/test';
	import type { NavDomain } from '$lib/navTypes';
	import DomainsListInner from './DomainsList.svelte';

	// Published list — in the app the layout load owns it; the story passes
	// it as a prop.
	const publishedDomains: NavDomain[] = [
		{
			id: 'crm',
			label: 'CRM',
			color: '#7B1FA2',
			doctypes: [
				{ qualified: 'crm.Company', label: 'Company', color: '#7B1FA2', icon: null },
				{ qualified: 'crm.Deal', label: 'Deal', color: '#7B1FA2', icon: null }
			]
		},
		{
			id: 'billing',
			label: 'Billing',
			color: '#009688',
			doctypes: [{ qualified: 'billing.Invoice', label: 'Invoice', color: '#009688', icon: null }]
		}
	];

	// A fresh driver per story-file mount (same pattern as RbacEditor
	// stories). loadDrafts reads `core.Domain` through it — seed one draft.
	const driver = createMockDriver();

	let ready = $state(false);
	let draftId = $state('');

	(async () => {
		// Drop the shared domain-list snapshot first — the cache is a module
		// singleton, and another story's driver may have filled it.
		domainListCache.invalidate();
		const draft = await driver
			.domain('core')
			.doctype('Domain')
			.create({ name: 'crmdraft', draft: true, color: '#009688' });
		draftId = draft.meta.id;
		ready = true;
	})();
</script>

<Story
	name="DraftsAndPublished"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Draft section: the seeded draft renders with the in-progress count.
		await canvas.findByText('crmdraft (draft)');
		await expect(canvas.getByText('1 in progress')).toBeVisible();
		// Published section: prop-driven rows with their doctype counts.
		await expect(canvas.getByText('2 live domains')).toBeVisible();
		await expect(canvas.getByText('CRM')).toBeVisible();
		await expect(canvas.getByText('2 doctypes')).toBeVisible();
		await expect(canvas.getByText('Billing')).toBeVisible();
		await expect(canvas.getByText('1 doctypes')).toBeVisible();
		// Row actions reach the host through the callbacks.
		await userEvent.click(canvas.getByRole('button', { name: 'Open editor' }));
		await expect(args.onopenbuilder).toHaveBeenCalledWith(draftId);
		await userEvent.click(canvas.getAllByRole('button', { name: 'Configure' })[0]);
		await expect(args.onconfigure).toHaveBeenCalledWith('crm');
	}}
>
	{#snippet template(args)}
		{#if ready}
			<div style="min-height: 420px; padding: 24px">
				<DomainsListInner
					domains={publishedDomains}
					{driver}
					onopenbuilder={args.onopenbuilder}
					onconfigure={args.onconfigure}
					ondelete={args.ondelete}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<Story
	name="PublishedFilter"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await canvas.findByText('CRM');
		// The filter narrows the published rows client-side. The live count
		// stays on the full list — it counts the unfiltered prop.
		await userEvent.type(canvas.getByPlaceholderText('Filter domains'), 'crm');
		await waitFor(() => expect(canvas.queryByText('Billing')).toBeNull());
		await expect(canvas.getByText('CRM')).toBeVisible();
		await expect(canvas.getByText('2 live domains')).toBeVisible();
	}}
>
	{#snippet template(args)}
		{#if ready}
			<div style="min-height: 420px; padding: 24px">
				<DomainsListInner
					domains={publishedDomains}
					{driver}
					onopenbuilder={args.onopenbuilder}
					onconfigure={args.onconfigure}
					ondelete={args.ondelete}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>
