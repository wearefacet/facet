<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fireEvent, fn } from 'storybook/test';
	import DatetimePicker from './DatetimePicker.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/DatetimePicker',
		component: DatetimePicker,
		tags: ['autodocs'],
		args: {
			label: 'Shift start',
			timezone: 'UTC'
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="Empty"
	args={{ label: 'Scheduled at', value: '', timezone: 'Asia/Kolkata' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Segment placeholders are visible and the picker reports "not set".
		await expect(canvas.getByPlaceholderText('YYYY')).toBeVisible();
		await expect(canvas.getByPlaceholderText('DD')).toBeVisible();
		// The footer renders local text and zone label in one span.
		await expect(canvas.getByText(/not set/)).toBeVisible();
		// Clear is disabled when there is nothing to clear.
		await expect(canvas.getByRole('button', { name: 'Clear' })).toBeDisabled();
	}}
/>

<Story
	name="Prepopulated"
	args={{ label: 'Shift start', value: '2026-08-15T09:30:00Z', timezone: 'Asia/Kolkata' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// 09:30 UTC displays as 15:00 wall-clock in Kolkata (+5:30).
		await expect(canvas.getByLabelText('year')).toHaveValue('2026');
		await expect(canvas.getByLabelText('month')).toHaveValue('08');
		await expect(canvas.getByLabelText('day')).toHaveValue('15');
		await expect(canvas.getByLabelText('hour')).toHaveValue('15');
		await expect(canvas.getByLabelText('minute')).toHaveValue('00');
		await expect(canvas.getByText(/2026-08-15 15:00/)).toBeVisible();
		await expect(canvas.getByText(/GMT\+5:30/)).toBeVisible();
	}}
/>

<Story
	name="TypingCommitsUtc"
	args={{ label: 'Type a time', value: '', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText('year'), '2026');
		await userEvent.type(canvas.getByLabelText('month'), '09');
		await userEvent.type(canvas.getByLabelText('day'), '15');
		await userEvent.type(canvas.getByLabelText('hour'), '14');
		await userEvent.type(canvas.getByLabelText('minute'), '30');
		// Wall time in UTC converts straight to UTC ISO on commit.
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-09-15T14:30:00.000Z');
	}}
/>

<Story
	name="FillStyleEntryCommitsUtc"
	args={{ label: 'Paste a time', value: '', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Fill-style entry (paste, autofill) delivers one long digit string in a
		// single event. The digits spread over the segments instead of cutting
		// at the first one, and the value commits.
		fireEvent.input(canvas.getByLabelText('year'), { target: { value: '202609151430' } });
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-09-15T14:30:00.000Z');
		await expect(canvas.getByLabelText('year')).toHaveValue('2026');
		await expect(canvas.getByLabelText('month')).toHaveValue('09');
		await expect(canvas.getByLabelText('day')).toHaveValue('15');
		await expect(canvas.getByLabelText('hour')).toHaveValue('14');
		await expect(canvas.getByLabelText('minute')).toHaveValue('30');
	}}
/>

<Story
	name="PartialEditHoldsSetValue"
	args={{ label: 'Hold the value', value: '2026-08-15T13:00:00Z', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// One keystroke into a set picker starts a partial edit. The last
		// committed value holds — nothing emits, so an abandoned edit never
		// wipes the bound value and never writes '' into the bag.
		fireEvent.input(canvas.getByLabelText('year'), { target: { value: '9' } });
		await expect(args.onchange).not.toHaveBeenCalled();
		await expect(canvas.getByLabelText('year')).toHaveValue('9');
		// The footer still shows the held value.
		await expect(canvas.getByText('2026-08-15T13:00:00Z')).toBeVisible();
		// Completing the edit releases the hold and commits the new value.
		fireEvent.input(canvas.getByLabelText('year'), { target: { value: '9026' } });
		await expect(args.onchange).toHaveBeenLastCalledWith('9026-08-15T13:00:00.000Z');
	}}
/>

<Story
	name="TypedDateWithoutTimeCommitsMidnight"
	args={{ label: 'Date without time', value: '', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// A full date with the time left empty commits midnight — the calendar
		// day-pick precedent. The typed date no longer drops on save.
		await userEvent.type(canvas.getByLabelText('year'), '2026');
		await userEvent.type(canvas.getByLabelText('month'), '09');
		await userEvent.type(canvas.getByLabelText('day'), '15');
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-09-15T00:00:00.000Z');
		// The footer renders the committed midnight; the time entry stays
		// untouched — the midnight lives in the value, not in the segments.
		await expect(canvas.getByText(/2026-09-15 00:00/)).toBeVisible();
		await expect(canvas.getByLabelText('hour')).toHaveValue('');
		await expect(canvas.getByLabelText('minute')).toHaveValue('');
		// Fill-style entry reaches the same commit.
		fireEvent.input(canvas.getByLabelText('year'), { target: { value: '20261109' } });
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-11-09T00:00:00.000Z');
	}}
/>

<Story
	name="ArrowKeysBump"
	args={{ label: 'Nudge', value: '2026-01-15T10:30:00Z', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const hour = canvas.getByLabelText('hour');
		hour.focus();
		await fireEvent.keyDown(hour, { key: 'ArrowUp' });
		// 10:30 UTC + 1 hour = 11:30 UTC.
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-01-15T11:30:00.000Z');
		const minute = canvas.getByLabelText('minute');
		minute.focus();
		await fireEvent.keyDown(minute, { key: 'ArrowUp' });
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-01-15T11:31:00.000Z');
	}}
/>

<Story
	name="DayClampsToMonth"
	args={{ label: 'Clamp day', value: '2026-03-31T00:00:00Z', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const month = canvas.getByLabelText('month');
		month.focus();
		// March has 31 days, April has 30 — the day clamps automatically.
		await fireEvent.keyDown(month, { key: 'ArrowUp' });
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-04-30T00:00:00.000Z');
	}}
/>

<Story
	name="SummerDaylightTime"
	args={{ label: 'Summer shift', value: '2026-07-01T04:00:00Z', timezone: 'America/New_York' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// 04:00 UTC = 00:00 wall-clock in New York during daylight time (EDT).
		await expect(canvas.getByLabelText('hour')).toHaveValue('00');
		await expect(canvas.getByText(/GMT-4/)).toBeVisible();
	}}
/>

<Story
	name="WinterStandardTime"
	args={{ label: 'Winter shift', value: '2026-01-15T05:00:00Z', timezone: 'America/New_York' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// 05:00 UTC = 00:00 wall-clock in New York during standard time (EST).
		await expect(canvas.getByLabelText('hour')).toHaveValue('00');
		await expect(canvas.getByText(/GMT-5/)).toBeVisible();
	}}
/>

<Story
	name="NowButton"
	args={{ label: 'Clock in', value: '', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Now' }));
		// Now sets the value to the current instant in UTC.
		const mock = args.onchange as unknown as ReturnType<typeof fn>;
		await expect(mock).toHaveBeenCalledTimes(1);
		const called = mock.mock.calls[0][0] as string;
		await expect(called.endsWith('Z')).toBe(true);
	}}
/>

<Story
	name="ClearButton"
	args={{ label: 'Clearable', value: '2026-05-01T12:00:00Z', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const clear = canvas.getByRole('button', { name: 'Clear' });
		await expect(clear).toBeEnabled();
		await userEvent.click(clear);
		await expect(args.onchange).toHaveBeenLastCalledWith('');
		await expect(canvas.getByText(/not set/)).toBeVisible();
		await expect(canvas.getByLabelText('year')).toHaveValue('');
	}}
/>

<Story
	name="ClearEmitsEmptyAfterPartialEdit"
	args={{
		label: 'Clear after partial',
		value: '2026-08-15T13:00:00Z',
		timezone: 'UTC',
		onchange: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// A partial edit holds the set value, and the explicit Clear still
		// resets it — the one path that emits ''.
		fireEvent.input(canvas.getByLabelText('hour'), { target: { value: '0' } });
		await expect(args.onchange).not.toHaveBeenCalled();
		const clear = canvas.getByRole('button', { name: 'Clear' });
		await expect(clear).toBeEnabled();
		await userEvent.click(clear);
		await expect(args.onchange).toHaveBeenLastCalledWith('');
		await expect(canvas.getByLabelText('year')).toHaveValue('');
	}}
/>

<Story
	name="Disabled"
	args={{ label: 'Locked', value: '2026-05-01T12:00:00Z', timezone: 'UTC', disabled: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByLabelText('year')).toBeDisabled();
		await expect(canvas.getByRole('button', { name: 'Now' })).toBeDisabled();
		await expect(canvas.getByRole('button', { name: 'Clear' })).toBeDisabled();
	}}
/>

<Story
	name="WithError"
	args={{
		label: 'Quota',
		value: '2026-05-01T12:00:00Z',
		timezone: 'UTC',
		error: 'Must be within the current pay period'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Must be within the current pay period')).toBeVisible();
		await expect(canvas.getByRole('alert')).toBeVisible();
	}}
/>

<Story
	name="FollowsUserTimezoneSetting"
	args={{ label: 'Uses my timezone', value: '2026-08-15T09:30:00Z' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// With no explicit timezone, the picker resolves the user's saved
		// timezone (or the browser zone) and labels it in the footer.
		await expect(canvas.getByText(/GMT/)).toBeVisible();
	}}
/>

<Story
	name="CalendarPanelSelectDay"
	args={{ label: 'Pick a day', value: '2026-08-10T09:00:00Z', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Open calendar' }));
		// Panel is portalled to document.body (Bits UI Popover), so query the
		// whole document, not the canvas-scoped element.
		const docBody = within(document.body);
		await expect(docBody.getByText('August 2026')).toBeVisible();
		await userEvent.click(docBody.getByRole('gridcell', { name: 'August 20, 2026' }));
		// Day selection keeps the existing time (09:00 UTC) and commits.
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-08-20T09:00:00.000Z');
		await expect(canvas.getByLabelText('day')).toHaveValue('20');
	}}
/>

<Story
	name="CalendarPanelQuickSlot"
	args={{ label: 'Pick a slot', value: '2026-08-10T09:00:00Z', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Open calendar' }));
		// Panel is portalled to document.body, so query there for panel buttons.
		const docBody = within(document.body);
		await userEvent.click(docBody.getByRole('button', { name: '06:00' }));
		// A quick slot rewrites the time segments on the current date.
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-08-10T06:00:00.000Z');
	}}
/>

<Story
	name="CalendarPanelMonthNavigation"
	args={{ label: 'Browse months', value: '2026-08-10T09:00:00Z', timezone: 'UTC', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Open calendar' }));
		// Panel is portalled to document.body, so query there for panel buttons.
		const docBody = within(document.body);
		await userEvent.click(docBody.getByRole('button', { name: 'Next month' }));
		await expect(docBody.getByText('September 2026')).toBeVisible();
		// Navigating months alone never commits a value.
		await expect(args.onchange).not.toHaveBeenCalled();
	}}
/>

<Story
	name="Compact"
	args={{ label: 'From', value: '2026-08-15T09:30:00Z', timezone: 'UTC', compact: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Compact mode renders the bare segment field only — the label feeds
		// the group's aria-label, and footer/actions are omitted.
		await expect(canvas.getByLabelText('year')).toHaveValue('2026');
		await expect(canvas.queryByRole('button', { name: 'Now' })).toBeNull();
		await expect(canvas.queryByRole('button', { name: 'Clear' })).toBeNull();
		await expect(canvas.queryByText(/GMT/)).toBeNull();
	}}
/>

<!-- ── Date granularity (granularity="date") ──────────────────────────── -->

<Story
	name="DateGranularityEmpty"
	args={{ label: 'Hire date', value: '', timezone: 'UTC', granularity: 'date' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Only the calendar-date segments render — no hour/minute inputs.
		await expect(canvas.getByPlaceholderText('YYYY')).toBeVisible();
		await expect(canvas.getByPlaceholderText('DD')).toBeVisible();
		await expect(canvas.queryByLabelText('hour')).toBeNull();
		await expect(canvas.queryByLabelText('minute')).toBeNull();
		// The footer time readout is hidden — a calendar date has no zone.
		await expect(canvas.queryByText(/GMT/)).toBeNull();
		await expect(canvas.getByRole('button', { name: 'Clear' })).toBeDisabled();
	}}
/>

<Story
	name="DateGranularityPrepopulated"
	args={{ label: 'Hire date', value: '2026-08-15', timezone: 'UTC', granularity: 'date' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The stored calendar date renders verbatim — never wall-converted.
		await expect(canvas.getByLabelText('year')).toHaveValue('2026');
		await expect(canvas.getByLabelText('month')).toHaveValue('08');
		await expect(canvas.getByLabelText('day')).toHaveValue('15');
		await expect(canvas.queryByLabelText('hour')).toBeNull();
	}}
/>

<Story
	name="DateGranularityTypingCommitsYmd"
	args={{ label: 'Type a date', value: '', timezone: 'UTC', granularity: 'date', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText('year'), '2026');
		await userEvent.type(canvas.getByLabelText('month'), '09');
		await userEvent.type(canvas.getByLabelText('day'), '15');
		// The commit is the calendar date exactly — no time, no zone suffix.
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-09-15');
	}}
/>

<Story
	name="DateGranularityFillStyleCommitsYmd"
	args={{ label: 'Paste a date', value: '', timezone: 'UTC', granularity: 'date', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// One fill event with the whole calendar date. The digits overflow from
		// the year segment into month and day, and the date commits verbatim.
		fireEvent.input(canvas.getByLabelText('year'), { target: { value: '20261109' } });
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-11-09');
		await expect(canvas.getByLabelText('year')).toHaveValue('2026');
		await expect(canvas.getByLabelText('month')).toHaveValue('11');
		await expect(canvas.getByLabelText('day')).toHaveValue('09');
	}}
/>

<Story
	name="DateGranularityFillOverflowsIntoNextSegment"
	args={{
		label: 'Overflow date',
		value: '2026-08-10',
		timezone: 'UTC',
		granularity: 'date',
		onchange: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// A fill event on one segment hands its extra digits to the next one.
		// The year keeps its set value; month and day take the overflow.
		fireEvent.input(canvas.getByLabelText('month'), { target: { value: '1109' } });
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-11-09');
		await expect(canvas.getByLabelText('year')).toHaveValue('2026');
		await expect(canvas.getByLabelText('month')).toHaveValue('11');
		await expect(canvas.getByLabelText('day')).toHaveValue('09');
	}}
/>

<Story
	name="DateGranularityNowCommitsToday"
	args={{ label: 'Anchor date', value: '', timezone: 'UTC', granularity: 'date', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Now' }));
		// "Now" on a date field commits today's calendar date, not an instant.
		const mock = args.onchange as unknown as ReturnType<typeof fn>;
		await expect(mock).toHaveBeenCalledTimes(1);
		const called = mock.mock.calls[0][0] as string;
		await expect(called).toMatch(/^\d{4}-\d{2}-\d{2}$/);
	}}
/>

<Story
	name="DateGranularityClear"
	args={{
		label: 'Expiry date',
		value: '2026-05-01',
		timezone: 'UTC',
		granularity: 'date',
		onchange: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const clear = canvas.getByRole('button', { name: 'Clear' });
		await expect(clear).toBeEnabled();
		await userEvent.click(clear);
		await expect(args.onchange).toHaveBeenLastCalledWith('');
		await expect(canvas.getByLabelText('year')).toHaveValue('');
	}}
/>

<Story
	name="DateGranularityCalendarDayPick"
	args={{
		label: 'Pick a date',
		value: '2026-08-15',
		timezone: 'UTC',
		granularity: 'date',
		onchange: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Open calendar' }));
		// Panel is portalled to document.body (Bits UI Popover), so query the
		// whole document, not the canvas-scoped element.
		const docBody = within(document.body);
		await expect(docBody.getByText('August 2026')).toBeVisible();
		// Date granularity hides the quick time slots.
		await expect(docBody.queryByRole('button', { name: '06:00' })).toBeNull();
		await userEvent.click(docBody.getByRole('gridcell', { name: 'August 20, 2026' }));
		// The day pick is the whole commit — a plain calendar date.
		await expect(args.onchange).toHaveBeenLastCalledWith('2026-08-20');
		await expect(canvas.getByLabelText('day')).toHaveValue('20');
	}}
/>
