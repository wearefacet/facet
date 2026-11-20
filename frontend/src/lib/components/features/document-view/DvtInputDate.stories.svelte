<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent } from 'storybook/test';
	import DvtInputDate from './DvtInputDate.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputDateNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputDate',
		component: DvtInputDate,
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

	/** A def exposing `scheduled_on` as a `date` field so the read-only path
	 *  routes through `DvtValue`'s verbatim date branch. */
	const dateDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Test',
		schema_version: 1,
		aggregate_root: false,
		fields: [{ key: 'scheduled_on', type: 'date', title: 'Scheduled On' }],
		children: [],
		actions: []
	};
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Scheduled On')).toBeVisible();
		// The stored calendar date renders verbatim in the date segments —
		// never wall-converted — and no time segments render.
		await expect(canvas.getByLabelText('year')).toHaveValue('2026');
		await expect(canvas.getByLabelText('month')).toHaveValue('08');
		await expect(canvas.getByLabelText('day')).toHaveValue('15');
		await expect(canvas.queryByLabelText('hour')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-date',
			field: 'scheduled_on',
			label: 'Scheduled On',
			required: true
		} satisfies InputDateNode,
		document: doc({ scheduled_on: '2026-08-15' }),
		values: { scheduled_on: '2026-08-15' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDate
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TypingCommitsYmdToValuesBag"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText('year'), '2026');
		await userEvent.type(canvas.getByLabelText('month'), '09');
		await userEvent.type(canvas.getByLabelText('day'), '15');
		// The committed value is the typed calendar date, visible verbatim in
		// the segments (date granularity renders no footer readout).
		await expect(canvas.getByLabelText('year')).toHaveValue('2026');
		await expect(canvas.getByLabelText('month')).toHaveValue('09');
		await expect(canvas.getByLabelText('day')).toHaveValue('15');
	}}
	args={{
		template: {
			type: 'input-date',
			field: 'scheduled_on',
			label: 'Scheduled On'
		} satisfies InputDateNode,
		document: doc({}),
		values: { scheduled_on: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDate
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
		await expect(
			canvas.getByText("is not a valid ISO 8601 date (expected YYYY-MM-DD): 'garbage'")
		).toBeVisible();
		await expect(canvas.getByRole('alert')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-date',
			field: 'scheduled_on',
			label: 'Scheduled On',
			required: true
		} satisfies InputDateNode,
		document: doc({}),
		values: { scheduled_on: '' },
		fieldErrors: {
			scheduled_on: [
				{
					field: 'scheduled_on',
					message: "is not a valid ISO 8601 date (expected YYYY-MM-DD): 'garbage'",
					code: 'invalid_format'
				}
			]
		}
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDate
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
		await expect(canvas.getByText('Scheduled On')).toBeVisible();
		// A read-only date renders verbatim through `FieldValue`'s date
		// branch, not the picker.
		await expect(canvas.queryByLabelText('year')).toBeNull();
		await expect(canvas.getByText('2026-08-15')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-date',
			field: 'scheduled_on',
			label: 'Scheduled On'
		} satisfies InputDateNode,
		document: doc({ scheduled_on: '2026-08-15' }),
		def: dateDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDate template={args.template} document={args.document} def={args.def} />
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
