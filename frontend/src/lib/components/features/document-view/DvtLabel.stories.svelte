<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtLabel from './DvtLabel.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtLabel',
		component: DvtLabel,
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
	name="FieldValue"
	args={{
		template: { type: 'label', value: '$name' },
		document: doc({ name: 'Alice Johnson' })
	}}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('Alice Johnson')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtLabel template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="LiteralText"
	args={{
		template: { type: 'label', value: 'Invoice #2024-001' },
		document: doc({})
	}}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('Invoice #2024-001')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtLabel template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="NestedField"
	args={{
		template: { type: 'label', value: '$contact.email' },
		document: doc({ contact: { email: 'alice@example.com' } })
	}}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('alice@example.com')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtLabel template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="MissingField"
	args={{
		template: { type: 'label', value: '$missing_field' },
		document: doc({ name: 'Alice' })
	}}
	play={async ({ canvasElement }) => {
		// Missing $field references resolve to empty string rather than leaking
		// the raw `$token` placeholder into the UI.
		const label = canvasElement.querySelector('.dvt-label');
		await expect(label?.textContent ?? '').toBe('');
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtLabel template={args.template} document={args.document} />
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
