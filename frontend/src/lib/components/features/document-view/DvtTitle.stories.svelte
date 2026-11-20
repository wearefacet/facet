<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DvtTitle from './DvtTitle.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtTitle',
		component: DvtTitle,
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
	name="TitleLevel1"
	args={{
		template: { type: 'title', value: '$first_name $last_name', level: 1 },
		document: doc({ first_name: 'Alice', last_name: 'Johnson' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtTitle template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="TitleLevel2"
	args={{
		template: { type: 'title', value: 'Employee Record', level: 2 },
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtTitle template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="TitleLevel3"
	args={{
		template: { type: 'title', value: '$department Overview', level: 3 },
		document: doc({ department: 'Engineering' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtTitle template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="TitleDefaultLevel"
	args={{
		template: { type: 'title', value: 'Default Heading (h2)' },
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtTitle template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="TitleWithNestedField"
	args={{
		template: { type: 'title', value: '$contact.name', level: 2 },
		document: doc({ contact: { name: 'Bob Smith' } })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtTitle template={args.template} document={args.document} />
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
