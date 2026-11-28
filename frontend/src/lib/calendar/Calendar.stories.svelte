<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import Calendar from '$lib/calendar/Calendar.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { MockDataSource } from '$lib/datasource/MockDataSource.js';
	import { parseDoctypeDef } from '$lib/doctype/types.js';
	import type { CalendarViewConfig } from '$lib/collectionView/types.js';

	const driver = createMockDriver();

	function defFor(qualified: string) {
		const raw = driver.getDoctypeDefinition(qualified);
		if (!raw) throw new Error(`Missing doctype definition for ${qualified}`);
		return parseDoctypeDef(raw as Record<string, unknown>);
	}

	const mtDef = defFor('ops.MaintenanceTask');

	// A doctype with no date/datetime/period/dateperiod field — the system
	// `created_at` meta key anchors the grid. LoginEvent declares only
	// string/enum/longtext fields; the seeded events carry explicit created_at
	// instants on three distinct days inside the current month so each month
	// cell holds at most one chip (no density collapse).
	const loginDef = defFor('iam.LoginEvent');
	const loginDs = driver.domain('iam').doctype('LoginEvent') as unknown as MockDataSource<
		Record<string, unknown>
	>;

	function isoAtDay(dayOffset: number): string {
		const n = new Date();
		const base = Date.UTC(n.getUTCFullYear(), n.getUTCMonth(), n.getUTCDate());
		return new Date(base + dayOffset * 86_400_000 + 9.5 * 3_600_000).toISOString();
	}

	{
		const n = new Date();
		const today = n.getUTCDate();
		const monthDays = new Date(Date.UTC(n.getUTCFullYear(), n.getUTCMonth() + 1, 0)).getUTCDate();
		// Today plus two neighbours clamped into the current month.
		const offsets = [0, today > 1 ? -1 : 2, today < monthDays ? 1 : -2];
		for (const [i, offset] of offsets.entries()) {
			const id = `login_evt_${i}`;
			loginDs.docs.set(id, {
				id,
				domain: 'iam',
				doc_type: 'LoginEvent',
				content: { account_id: 'acc_seed', event: 'login', details: 'seeded for story' },
				version: 1,
				schema_version: 1,
				created_at: isoAtDay(offset),
				updated_at: isoAtDay(offset),
				mutations: [],
				deleted_at: null
			});
		}
	}

	const { Story } = defineMeta({
		title: 'Components/Data/Calendar',
		component: Calendar,
		tags: ['autodocs'],
		args: {
			driver,
			doctype: mtDef
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within, userEvent } from 'storybook/test';

	// Default config: scheduled_window is a period (datetime-range).
	const cfgWindow: CalendarViewConfig = {
		discriminator: 'scheduled_window',
		end_field: null,
		color_by: 'status',
		title_template: '{{ name }} {{ subject }}',
		week_start: 'monday'
	};

	// Discriminator on `scheduled_days` (dateperiod → date-range).
	const cfgDays: CalendarViewConfig = {
		discriminator: 'scheduled_days',
		end_field: null,
		color_by: 'status',
		title_template: '{{ name }} {{ subject }}',
		week_start: 'monday'
	};

	// Two-field datetime range: starts_at + ends_at.
	const cfgStartsEnds: CalendarViewConfig = {
		discriminator: 'starts_at',
		end_field: 'ends_at',
		color_by: 'status',
		title_template: '{{ name }}',
		week_start: 'monday'
	};

	// Single `date` discriminator.
	const cfgOn: CalendarViewConfig = {
		discriminator: 'scheduled_on',
		end_field: null,
		color_by: 'status',
		title_template: '{{ name }}',
		week_start: 'monday'
	};

	// Single `datetime` discriminator.
	const cfgStarts: CalendarViewConfig = {
		discriminator: 'starts_at',
		end_field: null,
		color_by: 'status',
		title_template: '{{ name }}',
		week_start: 'monday'
	};

	// Window discriminator restricted to `planned` tasks via persisted filters.
	// The month grid shows the whole month, so the filters also narrow it to the
	// anchor week: `status__eq: planned` alone leaves every planned task in
	// view, and a month cell keeps a single chip — the later `Pump` / `Valve`
	// pair overflows into a `+N` badge, which pushes `Audit` out of the
	// rendered text. The window bounds ride the `scheduled_on` date scalar (the
	// chips are laid out by their real window).
	//
	// The seed shifts every MaintenanceTask by one global offset so `Filter swap`
	// lands on *today*, and `Calibrate A` / `Calibrate E` land on today+2. A
	// hard-coded window would only match on one run date, so the bounds are
	// computed from the same anchor the seed uses (today, ±0/+2 days).
	function isoDayFromToday(dayOffset: number): string {
		const n = new Date();
		return new Date(Date.UTC(n.getUTCFullYear(), n.getUTCMonth(), n.getUTCDate() + dayOffset))
			.toISOString()
			.slice(0, 10);
	}

	const cfgFiltered: CalendarViewConfig = {
		discriminator: 'scheduled_window',
		end_field: null,
		color_by: 'status',
		title_template: '{{ name }}',
		week_start: 'monday',
		filters: {
			status__eq: 'planned',
			scheduled_on__gte: isoDayFromToday(0),
			scheduled_on__lte: isoDayFromToday(2)
		}
	};

	// System `created_at` meta key as discriminator — used when the doctype
	// has no date field of its own (iam.LoginEvent).
	const cfgCreatedAt: CalendarViewConfig = {
		discriminator: 'created_at',
		end_field: null,
		color_by: null,
		title_template: '{{ event }}',
		week_start: 'monday'
	};
</script>

<!--
	Calendar stories are wrapped in a sized container so the absolutely-positioned
	range bars and time-grid chips have room to lay out. The `min-height` is
	critical: otherwise the Storybook `fullscreen` layout collapses to zero
	height.
-->

<Story
	name="MonthTimerange"
	args={{ config: cfgWindow }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// Header shows month + year for the default anchor (today).
		await expect(canvas.getByRole('grid')).toBeVisible();
		// Toolbar no longer prints the discriminator field key; the legend carries
		// the color_by field label as a prefix.
		await expect(canvas.getByText('Status:')).toBeVisible();
		// Legend visible because color_by is an enum (status).
		await expect(canvas.getByText('Planned')).toBeVisible();
		await expect(canvas.getByText('Done')).toBeVisible();
		await expect(canvas.getByText('Blocked')).toBeVisible();
		// A seeded task chip must render (dates are shifted relative to today).
		// The seed shifts *every* task by one global offset, so `Filter swap`
		// (anchor day = today) sits on today only when today's day-of-month is 25.
		// Read the chip by title, which every chip carries whatever the run date.
		await expect(canvas.getByTitle(/Filter swap/)).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="GroupBarClosesOnOutsideClick"
	args={{ config: cfgWindow }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// Open a collapsed multi-day group bar. The seed re-anchors dates to
		// today, so the shutdown cluster (4 overlapping spans) sits inside one
		// week row on some weekdays and splits over two rows on others — one
		// group bar per collapsed row. Any bar opens the same list popover.
		const groupBars = canvas.getAllByRole('button', { name: '4 documents' });
		await expect(groupBars.length).toBeGreaterThan(0);
		await userEvent.click(groupBars[0]);
		await sleep(60);
		const popover = canvas.getByRole('dialog', { name: 'All documents in this week' });
		await expect(popover).toBeVisible();
		// Click outside the calendar grid (the toolbar header is outside `.cal-month`).
		await userEvent.click(canvas.getByText('Status:'));
		await sleep(60);
		await expect(canvas.queryByRole('dialog', { name: 'All documents in this week' })).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="WeekTimerange"
	args={{ config: cfgWindow }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// Switch to week view by clicking the segmented-control tab.
		const weekTab = canvas.getByRole('tab', { name: 'Week' });
		await userEvent.click(weekTab);
		await sleep(60);
		await expect(weekTab).toHaveAttribute('aria-selected', 'true');
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story name="MonthDateRange" args={{ config: cfgDays }}>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="TwoFieldDatetimeRange"
	args={{ config: cfgStartsEnds }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// Two-field range still renders the grid and the legend prefix.
		await expect(canvas.getByRole('grid')).toBeVisible();
		await expect(canvas.getByText('Status:')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="SingleDate"
	args={{ config: cfgOn }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// `date` discriminator — grid + legend render without the kind badge.
		await expect(canvas.getByRole('grid')).toBeVisible();
		await expect(canvas.getByText('Status:')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story name="SingleDatetime" args={{ config: cfgStarts }}>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="MetaKeyDiscriminator"
	args={{ config: cfgCreatedAt }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// The grid renders for a doctype with no date fields — anchored on the
		// system `created_at` meta key, resolved through the timestamp defs.
		await expect(canvas.getByRole('grid')).toBeVisible();
		// Each seeded event places one chip on its created day.
		await expect(canvas.getAllByTitle('login')).toHaveLength(3);
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={loginDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="FilteredByStatus"
	args={{ config: cfgFiltered }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// The persisted `status__eq: planned` filter hides non-planned tasks.
		// The pinned `scheduled_on` window (today → today+2) keeps the planned
		// tasks of the anchor week: `Calibrate A` and `Calibrate E` sit at
		// today+2, always inside the grid whatever the run date. Chips are read
		// by title, which every chip carries.
		await expect(canvas.getByTitle('Calibrate A')).toBeVisible();
		await expect(canvas.getByTitle('Calibrate E')).toBeVisible();
		// A `done` task (`Filter swap`, on today) stays in view and must not render.
		await expect(canvas.queryByTitle('Filter swap')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="WeekNavigationAdvancesBySevenDays"
	args={{ config: cfgStarts }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// Switch to week view.
		await userEvent.click(canvas.getByRole('tab', { name: 'Week' }));
		await sleep(80);
		// Compute the expected headers from real date arithmetic so the test
		// stays correct across month and year boundaries. The Calendar anchors
		// on the UTC date (all its grid math is UTC), so the expectation must
		// use UTC too: deriving the week from the LOCAL date breaks whenever
		// the two dates differ — e.g. a run shortly after local midnight early
		// on a Monday, when UTC is still Sunday and the Monday-anchored week
		// is the previous one (the observed off-by-7-days failure).
		//
		// The anchor starts on day 1 of the current month (the month grid needs
		// it to start on the week of the 1st), so week view shows the week
		// holding the 1st and `Next` advances it by seven days.
		const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
		const now = new Date();
		// UTC day number of a calendar day of the anchor month (`0` = the last day
		// of the previous month, `32` = the first of the next one).
		const monthDayMs = (day: number): number =>
			Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), day);
		const mondayOf = (day: number): number => {
			const ms = monthDayMs(day);
			return ms - ((new Date(ms).getUTCDay() + 6) % 7) * 86_400_000;
		};
		const expectedHeaders = (day: number): string[] => {
			const startMs = mondayOf(day);
			return WEEKDAYS.map((label, i) => {
				const d = new Date(startMs + i * 86_400_000);
				return `${label} ${d.getUTCDate()}`;
			});
		};
		const before = [...canvas.getAllByRole('columnheader')].map(
			(el) => el.textContent?.trim() ?? ''
		);
		await expect(before).toEqual(expectedHeaders(1));
		await userEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(80);
		const after = [...canvas.getAllByRole('columnheader')].map(
			(el) => el.textContent?.trim() ?? ''
		);
		await expect(after).toEqual(expectedHeaders(8));
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="FarJumpViaPicker"
	args={{ config: cfgWindow }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// Header label is now a popover trigger button.
		const trigger = canvas.getByRole('button', { name: /^[A-Z][a-z]+ \d{4}$/ });
		const beforeText = trigger.textContent ?? '';
		await userEvent.click(trigger);
		await sleep(150);
		// Picker content is portalled to document.body (Bits UI Portal), so
		// query the whole document, not the canvas-scoped element.
		const docBody = within(document.body);
		await userEvent.click(docBody.getByRole('button', { name: 'Next year' }));
		await sleep(80);
		await userEvent.click(docBody.getByRole('button', { name: /^Jan \d{4}$/ }));
		await sleep(150);
		// Header label changed to January of a later year.
		const newLabel = canvas.getByText(/^January \d{4}$/);
		await expect(newLabel).toBeVisible();
		await expect(newLabel.textContent).not.toBe(beforeText);
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="WeekNavigationShowsAnchorWeek"
	args={{ config: cfgStarts }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('tab', { name: 'Week' }));
		await sleep(80);
		// Click Next 3 times; after each click the visible week must still
		// contain the anchor day (proves the visible week is derived from the
		// anchor, not from the month's first row).
		for (let i = 0; i < 3; i++) {
			await userEvent.click(canvas.getByRole('button', { name: 'Next' }));
			await sleep(60);
		}
		// All 7 day-column headers must be present (the grid did not collapse).
		const headers = canvas.getAllByRole('columnheader');
		await expect(headers.length).toBe(7);
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="NavigationChangesHeader"
	args={{ config: cfgWindow }}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// Read the current month label before navigating.
		const labelEl = canvas.getByText(/^[A-Z][a-z]+ \d{4}$/, { exact: true });
		const before = labelEl.textContent;
		await userEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(60);
		const after = canvas.getByText(/^[A-Z][a-z]+ \d{4}$/, { exact: true }).textContent;
		await expect(after).not.toBe(before);
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Calendar {driver} doctype={mtDef} config={args.config} />
		</div>
	{/snippet}
</Story>
