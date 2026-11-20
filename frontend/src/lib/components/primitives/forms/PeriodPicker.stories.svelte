<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn } from 'storybook/test';
	import PeriodPicker from './PeriodPicker.svelte';
	import type { PeriodValue } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/PeriodPicker',
		component: PeriodPicker,
		tags: ['autodocs'],
		args: {
			label: 'Scheduled window',
			mode: 'datetime',
			timezone: 'UTC'
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): the embedded
		// DatetimePicker segments dim through opacity while disabled, which axe
		// flags as insufficient contrast. Same backlog as the DatetimePicker
		// stories; fix there, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/** The pair a prepopulated `period` story edits. */
	const SET_PERIOD: PeriodValue = {
		start: '2026-08-01T09:00:00.000Z',
		end: '2026-08-15T17:30:00.000Z'
	};

	/** The pair a prepopulated `dateperiod` story edits. */
	const SET_DATEPERIOD: PeriodValue = { start: '2026-08-01', end: '2026-08-15' };
</script>

<!-- ── mode: "datetime" — a `period` field (UTC timestamp bounds) ─────── -->

<Story
	name="DatetimeEmpty"
	args={{ value: '' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// One label over the pair, Start/End sub-labels, bare segment fields.
		await expect(canvas.getByText('Scheduled window')).toBeVisible();
		await expect(canvas.getByText('Start')).toBeVisible();
		await expect(canvas.getByText('End')).toBeVisible();
		// Two segment rows: one per bound.
		await expect(canvas.getAllByPlaceholderText('YYYY')).toHaveLength(2);
		// The footer reports the unset pair; Clear has nothing to clear.
		await expect(canvas.getByText('not set')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Clear' })).toBeDisabled();
	}}
/>

<Story
	name="DatetimePrepopulated"
	args={{ value: SET_PERIOD }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Each bound renders its stored instant as wall-clock segments (UTC
		// here). Scope by the Start/End sub-groups — both pickers use the
		// same segment aria-labels.
		const start = canvas.getByRole('group', { name: 'Start' });
		const end = canvas.getByRole('group', { name: 'End' });
		await expect(within(start).getByLabelText('day')).toHaveValue('01');
		await expect(within(start).getByLabelText('hour')).toHaveValue('09');
		await expect(within(end).getByLabelText('day')).toHaveValue('15');
		await expect(within(end).getByLabelText('minute')).toHaveValue('30');
		// The footer shows the committed pair.
		await expect(
			canvas.getByText('2026-08-01T09:00:00.000Z → 2026-08-15T17:30:00.000Z')
		).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Clear' })).toBeEnabled();
	}}
/>

<Story
	name="DatetimeTypingCommitsPair"
	args={{ value: '', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const start = canvas.getByRole('group', { name: 'Start' });
		const end = canvas.getByRole('group', { name: 'End' });
		// Fill the start bound completely.
		await userEvent.type(within(start).getByLabelText('year'), '2026');
		await userEvent.type(within(start).getByLabelText('month'), '09');
		await userEvent.type(within(start).getByLabelText('day'), '01');
		await userEvent.type(within(start).getByLabelText('hour'), '08');
		await userEvent.type(within(start).getByLabelText('minute'), '00');
		// A half-set range is not representable — nothing commits yet.
		await expect(args.onchange).not.toHaveBeenCalledWith({
			start: expect.anything(),
			end: expect.anything()
		});
		// Completing the end bound commits the pair in one write.
		await userEvent.type(within(end).getByLabelText('year'), '2026');
		await userEvent.type(within(end).getByLabelText('month'), '09');
		await userEvent.type(within(end).getByLabelText('day'), '10');
		await userEvent.type(within(end).getByLabelText('hour'), '18');
		await userEvent.type(within(end).getByLabelText('minute'), '30');
		await expect(args.onchange).toHaveBeenLastCalledWith({
			start: '2026-09-01T08:00:00.000Z',
			end: '2026-09-10T18:30:00.000Z'
		});
	}}
/>

<Story
	name="CommitRuleHoldsOnPartialEdit"
	args={{ value: SET_PERIOD, onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const start = canvas.getByRole('group', { name: 'Start' });
		const startYear = within(start).getByLabelText('year');
		// Clear the start bound — a partial edit must never wipe the set pair.
		await userEvent.clear(startYear);
		await expect(args.onchange).not.toHaveBeenCalled();
		// The committed value holds: the footer still shows the full pair.
		await expect(
			canvas.getByText('2026-08-01T09:00:00.000Z → 2026-08-15T17:30:00.000Z')
		).toBeVisible();
		// Completing the start bound again commits the new pair.
		await userEvent.type(startYear, '2027');
		await expect(args.onchange).toHaveBeenLastCalledWith({
			start: '2027-08-01T09:00:00.000Z',
			end: '2026-08-15T17:30:00.000Z'
		});
	}}
/>

<Story
	name="DatetimeOrderHint"
	args={{
		value: { start: '2026-08-10T09:00:00.000Z', end: '2026-08-20T09:00:00.000Z' },
		onchange: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const end = canvas.getByRole('group', { name: 'End' });
		// Move the end bound before the start — `period` bounds are `[)`.
		const endDay = within(end).getByLabelText('day');
		await userEvent.clear(endDay);
		await userEvent.type(endDay, '05');
		// The backend's message family renders on the End control, and the
		// pair still commits — the backend verdict wins on save.
		await expect(canvas.getByRole('alert')).toHaveTextContent(/strictly before end/);
		await expect(args.onchange).toHaveBeenLastCalledWith({
			start: '2026-08-10T09:00:00.000Z',
			end: '2026-08-05T09:00:00.000Z'
		});
	}}
/>

<Story
	name="ClearResetsBothBounds"
	args={{ value: SET_PERIOD, onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Clear' }));
		// Clearing both bounds commits ''.
		await expect(args.onchange).toHaveBeenLastCalledWith('');
		await expect(canvas.getByText('not set')).toBeVisible();
		const start = canvas.getByRole('group', { name: 'Start' });
		await expect(within(start).getByLabelText('year')).toHaveValue('');
	}}
/>

<Story
	name="Disabled"
	args={{ value: SET_PERIOD, disabled: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const start = canvas.getByRole('group', { name: 'Start' });
		await expect(within(start).getByLabelText('year')).toBeDisabled();
		const end = canvas.getByRole('group', { name: 'End' });
		await expect(within(end).getByLabelText('year')).toBeDisabled();
		await expect(canvas.getByRole('button', { name: 'Clear' })).toBeDisabled();
	}}
/>

<!-- ── mode: "date" — a `dateperiod` field (calendar-date bounds) ─────── -->

<Story
	name="DateModePrepopulated"
	args={{ mode: 'date', value: SET_DATEPERIOD }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Date bounds edit calendar dates — no time segments anywhere.
		const start = canvas.getByRole('group', { name: 'Start' });
		await expect(within(start).getByLabelText('day')).toHaveValue('01');
		await expect(within(start).queryByLabelText('hour')).toBeNull();
		const end = canvas.getByRole('group', { name: 'End' });
		await expect(within(end).getByLabelText('day')).toHaveValue('15');
		await expect(within(end).queryByLabelText('minute')).toBeNull();
		// Calendar dates render verbatim in the footer.
		await expect(canvas.getByText('2026-08-01 → 2026-08-15')).toBeVisible();
	}}
/>

<Story
	name="DateModeTypingCommitsYmdPair"
	args={{ mode: 'date', value: '', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const start = canvas.getByRole('group', { name: 'Start' });
		const end = canvas.getByRole('group', { name: 'End' });
		await userEvent.type(within(start).getByLabelText('year'), '2026');
		await userEvent.type(within(start).getByLabelText('month'), '08');
		await userEvent.type(within(start).getByLabelText('day'), '01');
		await userEvent.type(within(end).getByLabelText('year'), '2026');
		await userEvent.type(within(end).getByLabelText('month'), '08');
		await userEvent.type(within(end).getByLabelText('day'), '15');
		// Calendar dates commit verbatim — no conversion, no time part.
		await expect(args.onchange).toHaveBeenLastCalledWith({
			start: '2026-08-01',
			end: '2026-08-15'
		});
	}}
/>

<Story
	name="DateModeEqualBoundsAllowed"
	args={{ mode: 'date', value: { start: '2026-08-01', end: '2026-08-01' } }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// `dateperiod` bounds are inclusive both ends — start may equal end
		// (a single-day range), so no order hint renders.
		await expect(canvas.queryByRole('alert')).toBeNull();
		await expect(canvas.getByText('2026-08-01 → 2026-08-01')).toBeVisible();
	}}
/>

<Story
	name="DateModeOrderHint"
	args={{ mode: 'date', value: { start: '2026-08-10', end: '2026-08-20' }, onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const end = canvas.getByRole('group', { name: 'End' });
		// Move the end date before the start — `[]` bounds allow equality only.
		const endDay = within(end).getByLabelText('day');
		await userEvent.clear(endDay);
		await userEvent.type(endDay, '01');
		await expect(canvas.getByRole('alert')).toHaveTextContent(/on or before end/);
		await expect(args.onchange).toHaveBeenLastCalledWith({
			start: '2026-08-10',
			end: '2026-08-01'
		});
	}}
/>

<Story
	name="WithError"
	args={{ value: '', error: 'Scheduled window must be an object with start and end' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A 422 on the field surfaces through the shared error line.
		await expect(
			canvas.getByText('Scheduled window must be an object with start and end')
		).toBeVisible();
		await expect(canvas.getByRole('alert')).toBeVisible();
	}}
/>
