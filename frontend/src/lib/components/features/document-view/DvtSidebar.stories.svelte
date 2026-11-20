<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtSidebar from './DvtSidebar.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtSidebar',
		component: DvtSidebar,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' }
		}
	});

	function doc(data: Record<string, unknown>) {
		return {
			data,
			meta: {
				id: 'crm.Company.1',
				mid: 'crm.Company.1',
				domain: 'crm',
				doc_type: 'Company',
				version: 3,
				schema_version: 1,
				created_at: '2025-03-14T09:00:00Z',
				updated_at: '2026-08-14T09:00:00Z'
			} satisfies DocumentMeta
		};
	}
</script>

<Story
	name="WithOwnerAndRecordMeta"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// "Owner" appears as both a section eyebrow (h3) and a field label, so
		// assert the heading role to disambiguate.
		await expect(canvas.getByRole('heading', { name: 'Owner' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Record' })).toBeVisible();
		await expect(canvas.getByText('Created')).toBeVisible();
		// History link is present and points at the audit route.
		const historyLink = canvas.getByRole('link', { name: /v3/ });
		await expect(historyLink).toHaveAttribute('href', '/crm/Company/1/history');
	}}
	args={{
		template: {
			type: 'sidebar',
			children: [
				{
					type: 'section',
					label: 'Owner',
					children: [{ type: 'field', label: 'Owner', value: '$owner_id' }]
				},
				{ type: 'record-meta', history: true }
			]
		},
		document: doc({ owner_id: 'iam.Account.42' }),
		historyHref: '/crm/Company/1/history'
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame dvt-story-frame--narrow">
			<DvtSidebar
				template={args.template}
				document={args.document}
				historyHref={args.historyHref}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EmptySidebar"
	args={{
		template: { type: 'sidebar', children: [] },
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame dvt-story-frame--narrow">
			<DvtSidebar template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<style>
	.dvt-story-frame {
		display: block;
		width: 100%;
		max-width: 720px;
		margin: 0 auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 120px;
	}

	/* Sidebar is a narrow rail — render it at the width it ships at. */
	.dvt-story-frame--narrow {
		max-width: 240px;
	}
</style>
