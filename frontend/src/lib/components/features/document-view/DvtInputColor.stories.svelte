<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtInputColor from './DvtInputColor.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputColorNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputColor',
		component: DvtInputColor,
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

	/** A minimal def exposing `color` as a `color` field so the read-only path
	 *  routes through the `ColorSwatch` branch. */
	const colorDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Test',
		schema_version: 1,
		aggregate_root: false,
		fields: [{ key: 'color', type: 'color', title: 'Display Color' }],
		children: [],
		actions: []
	};
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Display Color')).toBeVisible();
		await expect(canvas.getByDisplayValue('#5B8DEF')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-color',
			field: 'color',
			label: 'Display Color'
		} satisfies InputColorNode,
		document: doc({ color: '#5B8DEF' }),
		values: { color: '#5B8DEF' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputColor
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
		await expect(canvas.getByText('Display Color')).toBeVisible();
		// A read-only color field renders a swatch, not an editable textbox.
		await expect(canvas.queryByRole('textbox')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-color',
			field: 'color',
			label: 'Display Color'
		} satisfies InputColorNode,
		document: doc({ color: '#B05E2E' }),
		def: colorDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputColor template={args.template} document={args.document} def={args.def} />
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
