<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect } from 'storybook/test';
	import DvtCapsule from './DvtCapsule.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtCapsule',
		component: DvtCapsule,
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
		template: { type: 'capsule', value: '$employee_id' },
		document: doc({ employee_id: 'EMP-0042' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtCapsule template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="LiteralText"
	args={{
		template: { type: 'capsule', value: 'New' },
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtCapsule template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="InterpolatedText"
	args={{
		template: { type: 'capsule', value: '$status' },
		document: doc({ status: 'active' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtCapsule template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="MissingField"
	args={{
		template: { type: 'capsule', value: '$missing_field' },
		document: doc({ name: 'Alice' })
	}}
	play={({ canvasElement }) => {
		// An empty resolution renders nothing — no empty pill shell.
		expect(canvasElement.querySelector('.dvt-capsule')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtCapsule template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<!-- Long label is truncated to 32 chars with an ellipsis, and the full value
     is exposed via the hover `title` so AT and tooltips can still read it. -->
<Story
	name="TruncatedLabel"
	args={{
		template: { type: 'capsule', value: '$project_name' },
		document: doc({
			project_name: 'Northwind Traders International Logistics Division — West Coast Hub'
		})
	}}
	play={({ canvasElement }) => {
		const capsule = canvasElement.querySelector('.dvt-capsule') as HTMLElement;
		expect(capsule).not.toBeNull();
		// Visible label is truncated and ends with the ellipsis.
		expect(capsule.textContent ?? '').toContain('…');
		expect((capsule.textContent ?? '').length).toBeLessThan(60);
		// The full label is preserved as the hover tooltip title.
		expect(capsule.getAttribute('title')).toBe(
			'Northwind Traders International Logistics Division — West Coast Hub'
		);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtCapsule template={args.template} document={args.document} />
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
