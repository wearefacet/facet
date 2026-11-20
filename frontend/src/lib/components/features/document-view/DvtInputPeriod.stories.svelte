<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent } from 'storybook/test';
	import DvtInputPeriod from './DvtInputPeriod.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputPeriodNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputPeriod',
		component: DvtInputPeriod,
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

	/** A def exposing `scheduled_window` as a `period` field so the read-only
	 *  path routes through `DvtValue`'s daterange branch. */
	const periodDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Test',
		schema_version: 1,
		aggregate_root: false,
		fields: [{ key: 'scheduled_window', type: 'period', title: 'Scheduled Window' }],
		children: [],
		actions: []
	};
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Scheduled Window')).toBeVisible();
		// Each bound renders its stored instant as wall-clock segments — the
		// exact digits depend on the runner's timezone, so assert the shape.
		const start = canvas.getByRole('group', { name: 'Start' });
		await expect((within(start).getByLabelText('year') as HTMLInputElement).value).toMatch(
			/^\d{4}$/
		);
		const end = canvas.getByRole('group', { name: 'End' });
		await expect((within(end).getByLabelText('minute') as HTMLInputElement).value).toMatch(
			/^\d{2}$/
		);
	}}
	args={{
		template: {
			type: 'input-period',
			field: 'scheduled_window',
			label: 'Scheduled Window',
			required: true
		} satisfies InputPeriodNode,
		document: doc({
			scheduled_window: { start: '2026-08-01T09:00:00Z', end: '2026-08-15T17:30:00Z' }
		}),
		values: { scheduled_window: { start: '2026-08-01T09:00:00Z', end: '2026-08-15T17:30:00Z' } }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputPeriod
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TypingCommitsPairToValuesBag"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const start = canvas.getByRole('group', { name: 'Start' });
		const end = canvas.getByRole('group', { name: 'End' });
		await userEvent.type(within(start).getByLabelText('year'), '2026');
		await userEvent.type(within(start).getByLabelText('month'), '09');
		await userEvent.type(within(start).getByLabelText('day'), '01');
		await userEvent.type(within(start).getByLabelText('hour'), '08');
		await userEvent.type(within(start).getByLabelText('minute'), '00');
		await userEvent.type(within(end).getByLabelText('year'), '2026');
		await userEvent.type(within(end).getByLabelText('month'), '09');
		await userEvent.type(within(end).getByLabelText('day'), '10');
		await userEvent.type(within(end).getByLabelText('hour'), '18');
		await userEvent.type(within(end).getByLabelText('minute'), '30');
		// Object mutations through `args` are invisible to the play context
		// (workflow.md → CSF indexer and play-context args), so read the
		// committed pair from the footer. Wall time converts in the runner's
		// timezone — only the year is offset-safe to pin.
		await expect(
			canvas.getByText(
				/^2026-09-01T\d{2}:\d{2}:\d{2}\.\d{3}Z → 2026-09-10T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
			)
		).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-period',
			field: 'scheduled_window',
			label: 'Scheduled Window'
		} satisfies InputPeriodNode,
		document: doc({}),
		values: { scheduled_window: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputPeriod
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
				"start must be strictly before end (period bounds are '[)' — exclusive upper)"
			)
		).toBeVisible();
		await expect(canvas.getByRole('alert')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-period',
			field: 'scheduled_window',
			label: 'Scheduled Window',
			required: true
		} satisfies InputPeriodNode,
		document: doc({}),
		values: { scheduled_window: '' },
		fieldErrors: {
			scheduled_window: [
				{
					field: 'scheduled_window.start',
					message: "start must be strictly before end (period bounds are '[)' — exclusive upper)",
					code: 'invalid_range'
				}
			]
		}
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputPeriod
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
		await expect(canvas.getByText('Scheduled Window')).toBeVisible();
		// A read-only period renders through `FieldValue`'s daterange branch,
		// not the picker — wall time in the display zone, so assert the shape.
		await expect(canvas.queryByRole('group', { name: 'Start' })).toBeNull();
		await expect(canvas.getByText(/2026-08-01 \d{2}:\d{2}:\d{2} → /)).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-period',
			field: 'scheduled_window',
			label: 'Scheduled Window'
		} satisfies InputPeriodNode,
		document: doc({
			scheduled_window: { start: '2026-08-01T09:00:00Z', end: '2026-08-15T17:30:00Z' }
		}),
		def: periodDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputPeriod template={args.template} document={args.document} def={args.def} />
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
