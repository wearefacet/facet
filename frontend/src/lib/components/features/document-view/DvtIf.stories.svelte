<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DvtIf from './DvtIf.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtIf',
		component: DvtIf,
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
	name="TruthyField"
	args={{
		template: {
			type: 'if',
			field: 'status',
			children: [{ type: 'label', value: 'Active' }],
			else: [{ type: 'label', value: 'Inactive' }]
		},
		document: doc({ status: 'active' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtIf template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="FalsyField"
	args={{
		template: {
			type: 'if',
			field: 'status',
			children: [{ type: 'label', value: 'Active' }],
			else: [{ type: 'label', value: 'Inactive' }]
		},
		document: doc({ status: '' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtIf template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="EqualityCondition"
	args={{
		template: {
			type: 'if',
			field: 'priority',
			value: 'high',
			children: [{ type: 'capsule', value: 'High Priority' }],
			else: [{ type: 'capsule', value: 'Normal Priority' }]
		},
		document: doc({ priority: 'high' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtIf template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="EqualityConditionFalse"
	args={{
		template: {
			type: 'if',
			field: 'priority',
			value: 'high',
			children: [{ type: 'capsule', value: 'High Priority' }],
			else: [{ type: 'capsule', value: 'Normal Priority' }]
		},
		document: doc({ priority: 'low' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtIf template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="NoElseBranch"
	args={{
		template: {
			type: 'if',
			field: 'admin',
			children: [{ type: 'label', value: 'Admin user' }]
		},
		document: doc({ admin: true })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtIf template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="NoElseBranchHidden"
	args={{
		template: {
			type: 'if',
			field: 'admin',
			children: [{ type: 'label', value: 'Admin user' }]
		},
		document: doc({ admin: false })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtIf template={args.template} document={args.document} />
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
