<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent } from 'storybook/test';
	import DvtInputList from './DvtInputList.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputListNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputList',
		component: DvtInputList,
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
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Tags')).toBeVisible();
		// Seeded chips render; the input is present for new values.
		await expect(canvas.getByText('urgent')).toBeVisible();
		const input = canvas.getByPlaceholderText('Add a tag…');
		// Typing a value and pressing Enter appends a chip to the values bag.
		await userEvent.type(input, 'review{Enter}');
		await expect(canvas.getByText('review')).toBeVisible();
		// Removing a chip deletes the entry from the values bag.
		const remove = canvas.getByRole('button', { name: 'Remove urgent' });
		await userEvent.click(remove);
		await expect(canvas.queryByText('urgent')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-list',
			field: 'tags',
			label: 'Tags',
			placeholder: 'Add a tag…'
		} satisfies InputListNode,
		document: doc({ tags: ['urgent', 'review'] }),
		values: { tags: ['urgent', 'review'] }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputList
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="BlankSeededBagInitialises"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Tags')).toBeVisible();
		// The form seed's `''` cleared sentinel initialises to a mutable
		// string[] exactly like an absent key — the editor renders usable and
		// a new chip lands in the bag (B-105: the seed now covers arrays).
		const input = canvas.getByPlaceholderText('Add a tag…');
		await userEvent.type(input, 'fresh{Enter}');
		await expect(canvas.getByText('fresh')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-list',
			field: 'tags',
			label: 'Tags',
			placeholder: 'Add a tag…'
		} satisfies InputListNode,
		document: doc({}),
		values: { tags: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputList
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Tags')).toBeVisible();
		// Display mode renders each value as a chip, no editor.
		await expect(canvas.getByText('alpha')).toBeVisible();
		await expect(canvas.getByText('beta')).toBeVisible();
		await expect(canvas.queryByPlaceholderText('Add a tag…')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-list',
			field: 'tags',
			label: 'Tags'
		} satisfies InputListNode,
		document: doc({ tags: ['alpha', 'beta'] })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputList template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="Empty"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// An unset array field renders the em-dash placeholder in read-only mode.
		await expect(canvas.getByText('—')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-list',
			field: 'tags',
			label: 'Tags'
		} satisfies InputListNode,
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputList template={args.template} document={args.document} />
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
