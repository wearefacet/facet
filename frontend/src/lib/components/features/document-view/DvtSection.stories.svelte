<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtSection from './DvtSection.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtSection',
		component: DvtSection,
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
				id: 'test.1',
				mid: 'test.1',
				domain: 'test',
				doc_type: 'Test',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}
</script>

<Story
	name="Firmographics"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Firmographics')).toBeVisible();
		await expect(canvas.getByText('initech.com')).toBeVisible();
	}}
	args={{
		template: {
			type: 'section',
			label: 'Firmographics',
			children: [
				{ type: 'field', label: 'Domain', value: '$domain_name' },
				{ type: 'field', label: 'Revenue', value: '$annual_revenue' }
			]
		},
		document: doc({ domain_name: 'initech.com', annual_revenue: '2000000' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtSection template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptySection"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Notes')).toBeVisible();
	}}
	args={{
		template: {
			type: 'section',
			label: 'Notes',
			children: []
		},
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtSection template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="StackedSpacing"
	args={{
		template: {
			type: 'section',
			label: 'Contact',
			children: [
				{ type: 'field', label: 'Phone', value: '$phone' },
				{ type: 'field', label: 'Website', value: '$website' }
			]
		},
		document: doc({ phone: '+1 512 555 0100', website: 'https://initech.com' })
	}}
>
	{#snippet template(args)}
		<!-- Render two sections to assert the :not(:first-child) top margin. -->
		<div class="dvt-story-frame">
			<DvtSection
				template={{ type: 'section', label: 'First', children: [{ type: 'label', value: 'A' }] }}
				document={args.document}
			/>
			<DvtSection template={args.template} document={args.document} />
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
</style>
