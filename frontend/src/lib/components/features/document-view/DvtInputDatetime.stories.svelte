<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent } from 'storybook/test';
	import DvtInputDatetime from './DvtInputDatetime.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputDatetimeNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputDatetime',
		component: DvtInputDatetime,
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

	/** A def exposing `ends_at` as a `datetime` field so the read-only path
	 *  routes through `DvtValue`'s datetime branch (`RelativeTime`). */
	const datetimeDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Test',
		schema_version: 1,
		aggregate_root: false,
		fields: [{ key: 'ends_at', type: 'datetime', title: 'Ends at' }],
		children: [],
		actions: []
	};
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Ends at')).toBeVisible();
		// The stored UTC instant renders as wall-clock segments — the exact
		// digits depend on the runner's timezone, so assert the shape.
		const year = canvas.getByLabelText('year') as HTMLInputElement;
		await expect(year.value).toMatch(/^\d{4}$/);
		const minute = canvas.getByLabelText('minute') as HTMLInputElement;
		await expect(minute.value).toMatch(/^\d{2}$/);
	}}
	args={{
		template: {
			type: 'input-datetime',
			field: 'ends_at',
			label: 'Ends at',
			required: true
		} satisfies InputDatetimeNode,
		document: doc({ ends_at: '2026-08-15T09:30:00Z' }),
		values: { ends_at: '2026-08-15T09:30:00Z' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDatetime
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TypingCommitsUtcToValuesBag"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText('year'), '2027');
		await userEvent.type(canvas.getByLabelText('month'), '03');
		await userEvent.type(canvas.getByLabelText('day'), '01');
		await userEvent.type(canvas.getByLabelText('hour'), '10');
		await userEvent.type(canvas.getByLabelText('minute'), '00');
		// Object mutations through `args` are invisible to the play context
		// (workflow.md → CSF indexer and play-context args), so read the committed
		// UTC instant from the picker's footer. Wall time converts in the runner's
		// timezone — only the year is offset-safe to pin.
		await expect(canvas.getByText(/^2027-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/)).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-datetime',
			field: 'ends_at',
			label: 'Ends at'
		} satisfies InputDatetimeNode,
		document: doc({}),
		values: { ends_at: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDatetime
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
		await expect(canvas.getByText('Ends at is required')).toBeVisible();
		await expect(canvas.getByRole('alert')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-datetime',
			field: 'ends_at',
			label: 'Ends at',
			required: true
		} satisfies InputDatetimeNode,
		document: doc({}),
		values: { ends_at: '' },
		fieldErrors: { ends_at: [{ message: 'Ends at is required' }] }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDatetime
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				fieldErrors={args.fieldErrors}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Ends at')).toBeVisible();
		// A read-only datetime renders through `RelativeTime`, not the picker.
		await expect(canvas.queryByLabelText('year')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-datetime',
			field: 'ends_at',
			label: 'Ends at'
		} satisfies InputDatetimeNode,
		document: doc({ ends_at: '2026-08-15T09:30:00Z' }),
		def: datetimeDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDatetime template={args.template} document={args.document} def={args.def} />
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
