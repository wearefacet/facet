<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent } from 'storybook/test';
	import DvtInputToggle from './DvtInputToggle.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputToggleNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputToggle',
		component: DvtInputToggle,
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
		await expect(canvas.getByText('Remote worker')).toBeVisible();
		// Clicking the switch flips the bound value in the values bag.
		const toggle = canvas.getByRole('switch');
		await expect(toggle).toHaveAttribute('aria-checked', 'false');
		await userEvent.click(toggle);
		await expect(toggle).toHaveAttribute('aria-checked', 'true');
	}}
	args={{
		template: {
			type: 'input-toggle',
			field: 'is_remote',
			label: 'Remote worker'
		} satisfies InputToggleNode,
		document: doc({ is_remote: false }),
		values: { is_remote: false }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputToggle
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
		await expect(canvas.getByText('Remote worker')).toBeVisible();
		// A read-only toggle renders the boolean state as ✕/✓, not a switch.
		await expect(canvas.getByText(/✓ Yes/)).toBeVisible();
		await expect(canvas.queryByRole('switch')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-toggle',
			field: 'is_remote',
			label: 'Remote worker'
		} satisfies InputToggleNode,
		document: doc({ is_remote: true })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputToggle template={args.template} document={args.document} />
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
