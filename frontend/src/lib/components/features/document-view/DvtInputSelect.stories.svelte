<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtInputSelect from './DvtInputSelect.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputSelectNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputSelect',
		component: DvtInputSelect,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			values: { control: 'object' }
		}
	});

	function doc(data: Record<string, unknown>): DocumentResponse {
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

	const industryOptions = [
		{ value: 'technology', label: 'Technology' },
		{ value: 'finance', label: 'Finance' },
		{ value: 'healthcare', label: 'Healthcare' }
	];
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Industry')).toBeVisible();
		// The current value flows into the combobox input.
		await expect(canvas.getByDisplayValue('Technology')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-select',
			field: 'industry',
			label: 'Industry',
			options: industryOptions
		} satisfies InputSelectNode,
		document: doc({ industry: 'technology' }),
		values: { industry: 'technology' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSelect
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="WithError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Industry is required')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-select',
			field: 'industry',
			label: 'Industry',
			options: industryOptions,
			required: true
		} satisfies InputSelectNode,
		document: doc({}),
		values: { industry: '' },
		fieldErrors: { industry: [{ message: 'Industry is required' }] }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSelect
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				fieldErrors={args.fieldErrors}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnlyEnum"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Industry')).toBeVisible();
		// A read-only enum renders the selected option's label as a Badge.
		await expect(canvas.getByText('Technology')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-select',
			field: 'industry',
			label: 'Industry',
			options: industryOptions
		} satisfies InputSelectNode,
		document: doc({ industry: 'technology' }),
		def: {
			domain: 'test',
			doctype: 'Test',
			schema_version: 1,
			aggregate_root: false,
			fields: [
				{
					key: 'industry',
					type: 'enum',
					title: 'Industry',
					values: [
						{ key: 'technology', label: 'Technology' },
						{ key: 'finance', label: 'Finance' }
					]
				}
			],
			children: [],
			actions: []
		}
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSelect template={args.template} document={args.document} def={args.def} />
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
		min-height: 80px;
	}
</style>
