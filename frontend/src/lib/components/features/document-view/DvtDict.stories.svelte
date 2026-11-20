<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DvtDict from './DvtDict.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtDict',
		component: DvtDict,
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
	name="SimpleDict"
	args={{
		template: {
			type: 'dict',
			field: 'attributes',
			children: [
				{ type: 'field', label: 'Key', value: '$key' },
				{ type: 'field', label: 'Value', value: '$value' }
			]
		},
		document: doc({
			attributes: { color: 'red', size: 'M', weight: 'light' }
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtDict template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyDict"
	args={{
		template: {
			type: 'dict',
			field: 'metadata',
			children: [{ type: 'field', label: 'Key', value: '$key' }]
		},
		document: doc({ metadata: {} })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtDict template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="MissingField"
	args={{
		template: {
			type: 'dict',
			field: 'nonexistent',
			children: [{ type: 'field', label: 'Key', value: '$key' }]
		},
		document: doc({ name: 'Alice' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtDict template={args.template} document={args.document} />
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
