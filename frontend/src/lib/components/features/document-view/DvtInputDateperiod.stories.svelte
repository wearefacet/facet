<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent } from 'storybook/test';
	import DvtInputDateperiod from './DvtInputDateperiod.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputDateperiodNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputDateperiod',
		component: DvtInputDateperiod,
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

	/** A def exposing `scheduled_days` as a `dateperiod` field so the
	 *  read-only path routes through `DvtValue`'s daterange branch. */
	const dateperiodDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Test',
		schema_version: 1,
		aggregate_root: false,
		fields: [{ key: 'scheduled_days', type: 'dateperiod', title: 'Scheduled Days' }],
		children: [],
		actions: []
	};
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Scheduled Days')).toBeVisible();
		// Date bounds edit calendar-date segments — no time segments anywhere.
		const start = canvas.getByRole('group', { name: 'Start' });
		await expect(within(start).getByLabelText('day')).toHaveValue('01');
		await expect(within(start).queryByLabelText('hour')).toBeNull();
		const end = canvas.getByRole('group', { name: 'End' });
		await expect(within(end).getByLabelText('day')).toHaveValue('15');
	}}
	args={{
		template: {
			type: 'input-dateperiod',
			field: 'scheduled_days',
			label: 'Scheduled Days',
			required: true
		} satisfies InputDateperiodNode,
		document: doc({ scheduled_days: { start: '2026-08-01', end: '2026-08-15' } }),
		values: { scheduled_days: { start: '2026-08-01', end: '2026-08-15' } }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDateperiod
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TypingCommitsYmdPairToValuesBag"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const start = canvas.getByRole('group', { name: 'Start' });
		const end = canvas.getByRole('group', { name: 'End' });
		await userEvent.type(within(start).getByLabelText('year'), '2026');
		await userEvent.type(within(start).getByLabelText('month'), '09');
		await userEvent.type(within(start).getByLabelText('day'), '01');
		await userEvent.type(within(end).getByLabelText('year'), '2026');
		await userEvent.type(within(end).getByLabelText('month'), '09');
		await userEvent.type(within(end).getByLabelText('day'), '15');
		// Calendar dates commit verbatim — read the pair from the footer
		// (values-bag writes are invisible to the play context).
		await expect(canvas.getByText('2026-09-01 → 2026-09-15')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-dateperiod',
			field: 'scheduled_days',
			label: 'Scheduled Days'
		} satisfies InputDateperiodNode,
		document: doc({}),
		values: { scheduled_days: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDateperiod
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
		// The per-bound backend message attributes to the one field.
		await expect(
			canvas.getByText(
				"start must be on or before end (dateperiod bounds are '[]' — inclusive both ends)"
			)
		).toBeVisible();
		await expect(canvas.getByRole('alert')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-dateperiod',
			field: 'scheduled_days',
			label: 'Scheduled Days',
			required: true
		} satisfies InputDateperiodNode,
		document: doc({}),
		values: { scheduled_days: '' },
		fieldErrors: {
			scheduled_days: [
				{
					field: 'scheduled_days.end',
					message:
						"start must be on or before end (dateperiod bounds are '[]' — inclusive both ends)",
					code: 'invalid_range'
				}
			]
		}
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDateperiod
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
		await expect(canvas.getByText('Scheduled Days')).toBeVisible();
		// Calendar dates render verbatim — no timezone conversion.
		await expect(canvas.queryByRole('group', { name: 'Start' })).toBeNull();
		await expect(canvas.getByText('2026-08-01 → 2026-08-15')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-dateperiod',
			field: 'scheduled_days',
			label: 'Scheduled Days'
		} satisfies InputDateperiodNode,
		document: doc({ scheduled_days: { start: '2026-08-01', end: '2026-08-15' } }),
		def: dateperiodDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputDateperiod template={args.template} document={args.document} def={args.def} />
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
