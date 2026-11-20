<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtArray from './DvtArray.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtArray',
		component: DvtArray,
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
	name="ObjectArray"
	args={{
		template: {
			type: 'array',
			field: 'skills',
			children: [
				{ type: 'field', label: 'Skill', value: '$name' },
				{ type: 'field', label: 'Level', value: '$level' }
			]
		},
		document: doc({
			skills: [
				{ name: 'TypeScript', level: 'expert' },
				{ name: 'Crystal', level: 'advanced' },
				{ name: 'PostgreSQL', level: 'intermediate' }
			]
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtArray template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="PrimitiveArray"
	args={{
		template: {
			type: 'array',
			field: 'tags',
			children: [{ type: 'label', value: '$value' }]
		},
		document: doc({
			tags: ['frontend', 'svelte', 'typescript']
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtArray template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<!-- Inline layout (the default): primitive items flow in one wrapping row —
     the pill-list pattern. -->
<Story
	name="InlinePillList"
	args={{
		template: {
			type: 'array',
			field: 'pages',
			children: [{ type: 'capsule', value: 'p. $value' }]
		},
		document: doc({ pages: ['4', '1-5', '12', '23', '31-33', '48'] })
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('p. 4')).toBeVisible();
		await expect(canvas.getByText('p. 1-5')).toBeVisible();
		await expect(canvas.getByText('p. 31-33')).toBeVisible();
		// The row is a single wrapping flex container holding every capsule.
		const row = canvasElement.querySelector('.dvt-array-inline');
		expect(row).not.toBeNull();
		expect(row!.querySelectorAll('.dvt-capsule').length).toBe(6);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtArray template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<!-- Stack layout: one bordered block per item, the explicit opt-out. -->
<Story
	name="StackLayout"
	args={{
		template: {
			type: 'array',
			field: 'tags',
			layout: 'stack',
			children: [{ type: 'label', value: '$value' }]
		},
		document: doc({ tags: ['frontend', 'svelte'] })
	}}
	play={async ({ canvasElement }) => {
		await expect(canvasElement.textContent).toContain('frontend');
		// No inline row — each item renders its own bordered block.
		expect(canvasElement.querySelector('.dvt-array-inline')).toBeNull();
		expect(canvasElement.querySelectorAll('.dvt-array-primitive').length).toBe(2);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtArray template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<!-- Empty children render nothing per item — no empty bordered blocks. -->
<Story
	name="EmptyChildrenRendersNothing"
	args={{
		template: {
			type: 'array',
			field: 'tags',
			children: []
		},
		document: doc({ tags: ['a', 'b', 'c'] })
	}}
	play={async ({ canvasElement }) => {
		expect(canvasElement.querySelector('.dvt-array-card')).toBeNull();
		expect(canvasElement.querySelector('.dvt-array-primitive')).toBeNull();
		expect(canvasElement.querySelector('.dvt-array-inline')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtArray template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyArray"
	args={{
		template: {
			type: 'array',
			field: 'items',
			children: [{ type: 'label', value: '$name' }]
		},
		document: doc({ items: [] })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtArray template={args.template} document={args.document} />
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
