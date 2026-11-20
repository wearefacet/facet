<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataSource } from '$lib/datasource/interface.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import IconButton from '$lib/components/primitives/actions/IconButton.svelte';
	import { hashColor } from '$lib/utils/color.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import type { CalendarViewConfig, CalendarDiscriminatorKind } from '$lib/collectionView/types.js';
	import {
		buildCalendarWindowFilter,
		calendarDiscriminatorKind,
		calendarFetchWindow,
		humanizeLabel,
		overlapsVisibleWindow,
		resolveInterval,
		titleFallbackFields
	} from './discriminator.js';
	import MonthGrid from './MonthGrid.svelte';
	import WeekGrid from './WeekGrid.svelte';
	import * as m from '$lib/paraglide/messages';
	import { getLocale } from '$lib/paraglide/runtime';
	import { SYSTEM_TIMESTAMP_FIELD_DEFS } from '$lib/doctype/filters.js';
	import DatePicker from './DatePicker.svelte';
	import { Popover } from 'bits-ui';
	import { addDays } from './discriminator.js';

	type DocItem = DocumentResponse<Record<string, unknown>>;
	type Day = { y: number; m: number; d: number };

	let {
		driver,
		doctype,
		config,
		onChipClick
	}: {
		driver: DataDriver;
		doctype: DoctypeDef;
		config: CalendarViewConfig;
		onChipClick?: (docId: string) => void;
	} = $props();

	// ── Display state (UI only, not persisted) ──────────────────────────────
	let granularity = $state<'month' | 'week'>('month');
	const today = new Date();
	let anchor = $state<Day>({
		y: today.getUTCFullYear(),
		m: today.getUTCMonth() + 1,
		d: today.getUTCDate()
	});

	function setAnchor(d: Day) {
		anchor = d;
	}

	// ── Field resolution ──────────────────────────────────────────────────
	// Schema fields plus the system timestamp defs — a calendar view may
	// anchor on the `created_at` / `updated_at` meta keys of a doctype with
	// no date fields of its own. Schema fields keep precedence in the lookups
	// (the backend reserves both keys, so the defs never shadow one).
	const allFields = $derived([...doctype.fields, ...SYSTEM_TIMESTAMP_FIELD_DEFS]);
	const discriminatorField = $derived(allFields.find((f) => f.key === config.discriminator));
	const endField = $derived(
		config.end_field ? allFields.find((f) => f.key === config.end_field) : undefined
	);
	const colorByField = $derived(
		config.color_by ? allFields.find((f) => f.key === config.color_by) : undefined
	);
	const kind: CalendarDiscriminatorKind | null = $derived(
		calendarDiscriminatorKind(discriminatorField?.type, config.end_field)
	);

	const titleFallback = $derived(titleFallbackFields(allFields));

	// ── Navigation ────────────────────────────────────────────────────────────
	// Month mode snaps the anchor to day 1 of the previous/next month. Week
	// mode shifts the anchor by ±7 days (one full week) so back/forth moves a
	// whole week at a time, not one day.
	function prevMonth() {
		const targetM = anchor.m - 1;
		const d = new Date(Date.UTC(anchor.y, targetM - 1, 1));
		setAnchor({ y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: 1 });
	}
	function nextMonth() {
		const targetM = anchor.m + 1;
		const d = new Date(Date.UTC(anchor.y, targetM - 1, 1));
		setAnchor({ y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: 1 });
	}
	function prevWeek() {
		setAnchor(addDays(anchor, -7));
	}
	function nextWeek() {
		setAnchor(addDays(anchor, 7));
	}
	function prev() {
		if (granularity === 'month') {
			prevMonth();
		} else {
			prevWeek();
		}
	}
	function next() {
		if (granularity === 'month') {
			nextMonth();
		} else {
			nextWeek();
		}
	}

	function goToday() {
		const n = new Date();
		setAnchor({ y: n.getUTCFullYear(), m: n.getUTCMonth() + 1, d: n.getUTCDate() });
	}

	// ── Header label ──────────────────────────────────────────────────────────
	const headerLabel = $derived.by(() => {
		const locale = getLocale();
		if (granularity === 'month') {
			return new Intl.DateTimeFormat(locale, {
				month: 'long',
				year: 'numeric',
				timeZone: 'UTC'
			}).format(new Date(Date.UTC(anchor.y, anchor.m - 1, 1)));
		}
		// Week mode shows the first-to-last day of the visible week.
		const w = calendarFetchWindow(anchor.y, anchor.m, config.week_start, 7, anchor.d);
		const start = new Date(w.gridStart);
		const end = addDays(
			{ y: start.getUTCFullYear(), m: start.getUTCMonth() + 1, d: start.getUTCDate() },
			6
		);
		const fmt = (d: Date) =>
			new Intl.DateTimeFormat(locale, { month: 'short', day: 'numeric', timeZone: 'UTC' }).format(
				d
			);
		return `${fmt(start)} – ${fmt(new Date(Date.UTC(end.y, end.m - 1, end.d)))}`;
	});

	// ── Visible window ───────────────────────────────────────────────────────
	// The grid renders from `gridStart` (first day of the week containing the
	// 1st of the month). The fetch range starts one day earlier (`fetchFrom`):
	// dates are always stored in GMT and the server does not know the client's
	// timezone, so a document whose GMT date falls on the boundary day must
	// still be fetched.
	const window = $derived.by(() =>
		granularity === 'month'
			? calendarFetchWindow(anchor.y, anchor.m, config.week_start)
			: calendarFetchWindow(anchor.y, anchor.m, config.week_start, 7, anchor.d)
	);
	const toInstant = $derived(window.fetchTo);
	const fetchFromInstant = $derived(window.fetchFrom);
	const fromIsoDate = $derived(toIsoDate(new Date(fetchFromInstant)));
	const toIsoDate2 = $derived(toIsoDate(new Date(toInstant)));

	function toIsoDate(d: Date): string {
		return (
			d.getUTCFullYear() +
			'-' +
			String(d.getUTCMonth() + 1).padStart(2, '0') +
			'-' +
			String(d.getUTCDate()).padStart(2, '0')
		);
	}

	function toIsoInstant(t: number): string {
		return new Date(t).toISOString();
	}

	const fromDay = $derived.by(() => {
		const d = new Date(fetchFromInstant);
		return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() };
	});
	const toDay = $derived.by(() => {
		const d = new Date(toInstant);
		// Make the window inclusive on the upper end (subtract 1 day).
		return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: Math.max(1, d.getUTCDate() - 1) };
	});

	// ── Data fetch ───────────────────────────────────────────────────────────
	const datasource = $derived(
		driver.domain(doctype.domain).doctype<Record<string, unknown>>(doctype.doctype) as DataSource<
			Record<string, unknown>
		>
	);

	let items = $state<DocItem[]>([]);
	let loading = $state(true);
	let firstLoad = $state(true);
	let error = $state<string | null>(null);

	// Re-fetch when the window, discriminator, or filters change. We over-fetch
	// a wide window (the production backend will accept any ISO-8601 range
	// filter via the GiST `&&` operator; the MockDataSource falls back to
	// gte/lte which works for all single-field discriminator kinds).
	//
	// Only the very first load flips `loading` (which swaps the grid for a
	// "Loading…" placeholder). Subsequent navigations keep the previous grid
	// mounted with `firstLoad` false, so prev/next does not destroy and recreate
	// the grid — that is what caused the visible flicker on navigation.
	$effect(() => {
		void [anchor.y, anchor.m, anchor.d];
		void granularity;
		const c = config;
		const k = kind;
		if (!k) {
			loading = false;
			firstLoad = false;
			items = [];
			return;
		}
		if (firstLoad) loading = true;
		error = null;
		let cancelled = false;
		// `date` kinds bound on calendar dates in month mode — their stored
		// values are `YYYY-MM-DD` strings. `datetime` kinds must send full UTC
		// instants in every mode: the backend normalizes timestamp filter
		// values through RFC-3339 and degrades an unparseable bound to a
		// FALSE clause (a date-only bound would silently match nothing).
		const dateKind = k === 'date' || k === 'date-range';
		const fromBound =
			dateKind && granularity === 'month' ? fromIsoDate : toIsoInstant(fetchFromInstant);
		const toBound = dateKind && granularity === 'month' ? toIsoDate2 : toIsoInstant(toInstant);
		const filter = buildCalendarWindowFilter(c, k, fromBound, toBound, c.filters);
		// Native range fields (`period` / `dateperiod`) emit no window filter
		// (see `buildCalendarWindowFilter`); fetch a wide window and overlap
		// client-side so the MockDataSource (no `__overlaps`) renders them.
		const nativeRange = !c.end_field && (k === 'date-range' || k === 'datetime-range');
		// The system timestamps live on `meta`, not in the content map —
		// flatten them onto the row (content wins on a same-named schema
		// field, mirroring the Table's loader) so `resolveInterval` and the
		// title template read a `created_at` / `updated_at` discriminator
		// like any datetime field.
		const flatten = (doc: DocItem): DocItem => ({
			...doc,
			data: {
				created_at: doc.meta.created_at,
				updated_at: doc.meta.updated_at,
				...doc.data
			}
		});
		datasource
			.list({ filters: filter, items: 500 })
			.then((res) => {
				if (cancelled) return;
				const rows = res.data.map(flatten);
				items = nativeRange
					? rows.filter((doc) =>
							overlapsVisibleWindow(
								resolveInterval(doc.data, c, k),
								fromDay,
								toDay,
								fetchFromInstant,
								toInstant
							)
						)
					: rows;
			})
			.catch((e: unknown) => {
				if (cancelled) return;
				items = [];
				error = errorMessage(e, m.calendar_load_failed());
			})
			.finally(() => {
				if (!cancelled) {
					loading = false;
					firstLoad = false;
				}
			});
		return () => {
			cancelled = true;
		};
	});

	// ── Field labels (humanized fallback when no explicit `title`) ──────────
	// Toolbar never prints the raw discriminator field key — it always shows
	// the field's human label so the surface is non-technical.
	const colorByLabel = $derived(
		colorByField?.title ?? (config.color_by ? humanizeLabel(config.color_by) : null)
	);

	// ── Color legend (color_by enum) ─────────────────────────────
	// The legend is prefixed by the color-by field label (e.g. `Status:`),
	// then lists each enum value with its swatch. Absent entirely when the
	// color_by field is missing or not an enum.
	const legend = $derived.by(() => {
		if (colorByField?.type !== 'enum' || !colorByField.values) return [];
		return colorByField.values.map((v) => ({
			label: v.label ?? v.key,
			color: v.color ?? hashColor(v.key)
		}));
	});
</script>

<div class="cal-root">
	<div class="cal-header">
		<div class="cal-header-left">
			<span class="cal-title">{doctype.doctype}</span>
			<span class="cal-subtitle"
				>{doctype.domain} · {items.length} {items.length === 1 ? 'doc' : 'docs'}</span
			>
		</div>
	</div>

	<div class="cal-toolbar">
		<Popover.Root>
			<Popover.Trigger class="cal-cur">
				{headerLabel}
				<i class="ti ti-chevron-down cal-cur-chev" aria-hidden="true"></i>
			</Popover.Trigger>
			<Popover.Portal>
				<Popover.Content class="cal-picker" sideOffset={6} align="start">
					<DatePicker onpick={setAnchor} {anchor} />
				</Popover.Content>
			</Popover.Portal>
		</Popover.Root>
		<div class="cal-toolbar-right">
			<IconButton label={m.calendar_previous()} onclick={prev}>
				<svg
					viewBox="0 0 24 24"
					width="14"
					height="14"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
				>
					<path d="M15 18l-6-6 6-6" />
				</svg>
			</IconButton>
			<IconButton label={m.calendar_next()} onclick={next}>
				<svg
					viewBox="0 0 24 24"
					width="14"
					height="14"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
				>
					<path d="M9 18l6-6-6-6" />
				</svg>
			</IconButton>
			<IconButton label={m.calendar_today()} onclick={goToday}>
				<svg
					viewBox="0 0 24 24"
					width="14"
					height="14"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
				>
					<circle cx="12" cy="12" r="3" />
					<path d="M12 1v3M12 20v3M1 12h3M20 12h3" />
				</svg>
			</IconButton>
			<div class="cal-seg" role="tablist">
				<button
					type="button"
					role="tab"
					aria-selected={granularity === 'month'}
					class="cal-seg-btn"
					class:on={granularity === 'month'}
					onclick={() => (granularity = 'month')}>{m.calendar_month()}</button
				>
				<button
					type="button"
					role="tab"
					aria-selected={granularity === 'week'}
					class="cal-seg-btn"
					class:on={granularity === 'week'}
					onclick={() => (granularity = 'week')}>{m.calendar_week()}</button
				>
			</div>
		</div>
	</div>

	{#if !kind}
		<div class="cal-empty">{m.calendar_discriminator_invalid()}</div>
	{:else if firstLoad && loading}
		<div class="cal-empty">{m.common_loading()}</div>
	{:else if error}
		<div class="cal-empty cal-error">{error}</div>
	{:else if granularity === 'month'}
		<div class:cal-grid-loading={loading}>
			<MonthGrid
				{items}
				discriminator={config.discriminator}
				{kind}
				{discriminatorField}
				{endField}
				{colorByField}
				titleTemplate={config.title_template}
				fallbackFields={titleFallback}
				year={anchor.y}
				month={anchor.m}
				weekStart={config.week_start}
				{onChipClick}
			/>
		</div>
	{:else}
		<div class:cal-grid-loading={loading}>
			<WeekGrid
				{items}
				discriminator={config.discriminator}
				{kind}
				{discriminatorField}
				{endField}
				{colorByField}
				titleTemplate={config.title_template}
				fallbackFields={titleFallback}
				year={anchor.y}
				month={anchor.m}
				day={anchor.d}
				weekStart={config.week_start}
				{onChipClick}
			/>
		</div>
	{/if}

	{#if legend.length > 0}
		<div class="cal-legend">
			<span class="cal-legend-prefix">{colorByLabel}:</span>
			{#each legend as l (l.label)}
				<span class="cal-legend-item">
					<span class="cal-legend-swatch" style="background: {l.color};"></span>{l.label}
				</span>
			{/each}
			<span class="cal-legend-hint"><i class="ti ti-plus"></i> click a cell to create</span>
		</div>
	{/if}
</div>

<style>
	.cal-root {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		overflow: hidden;
		display: flex;
		flex-direction: column;
		font-family: var(--font-sans);
	}

	.cal-header {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 10px 14px;
		border-bottom: 1px solid var(--border);
	}
	.cal-title {
		font-size: 15px;
		font-weight: 600;
	}
	.cal-subtitle {
		font-size: 12px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.cal-toolbar {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 8px 14px;
		border-bottom: 1px solid var(--border);
		flex-wrap: wrap;
	}
	.cal-toolbar-right {
		margin-left: auto;
		display: flex;
		align-items: center;
		gap: 6px;
	}
	:global(.cal-cur) {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font-size: 13px;
		font-weight: 600;
		min-width: 96px;
		text-align: center;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 6px 10px;
		cursor: pointer;
		font: inherit;
		font-weight: 600;
		transition:
			background 0.12s,
			border-color 0.12s;
	}
	:global(.cal-cur:hover) {
		background: var(--sunken);
		border-color: var(--border-strong);
	}
	:global(.cal-cur:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}
	.cal-cur-chev {
		font-size: 11px;
		color: var(--text-3);
	}

	:global(.cal-picker) {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-2);
		padding: 12px;
		z-index: 50;
		font-family: var(--font-sans);
	}

	.cal-grid-loading {
		opacity: 0.55;
		pointer-events: none;
		transition: opacity 0.12s;
	}

	.cal-seg {
		display: flex;
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
		font-size: 12px;
	}
	.cal-seg-btn {
		padding: 4px 12px;
		background: var(--surface);
		color: var(--text-2);
		border: none;
		cursor: pointer;
		font: inherit;
	}
	.cal-seg-btn + .cal-seg-btn {
		border-left: 1px solid var(--border);
	}
	.cal-seg-btn.on {
		background: var(--surface-2);
		color: var(--accent-ink);
		font-weight: 600;
	}
	.cal-seg-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -2px;
	}

	.cal-empty {
		padding: 32px 14px;
		text-align: center;
		color: var(--text-3);
		font-size: 13px;
	}
	.cal-error {
		color: var(--danger);
	}

	.cal-legend {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 8px 14px;
		font-size: 11px;
		color: var(--text-2);
		border-top: 1px solid var(--border);
		background: var(--surface-2);
	}
	.cal-legend-prefix {
		font-weight: 600;
		color: var(--text-2);
	}
	.cal-legend-item {
		display: inline-flex;
		align-items: center;
		gap: 5px;
	}
	.cal-legend-swatch {
		display: inline-block;
		width: 8px;
		height: 8px;
		border-radius: 2px;
	}
	.cal-legend-hint {
		margin-left: auto;
		color: var(--text-3);
	}
</style>
