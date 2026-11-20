<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DocumentResponse } from '$lib/datasource/types';
	import * as m from '$lib/paraglide/messages';
	import type { FieldDef } from '$lib/doctype/types.js';
	import { hashColor } from '$lib/utils/color.js';
	import { localizedWeekdayLabels } from '$lib/i18n/localeNames.js';
	import type { CalendarViewConfig, CalendarDiscriminatorKind } from '$lib/collectionView/types.js';
	import {
		compareDay,
		formatDay,
		monthGridWeeks,
		resolveInterval,
		renderCalendarTitle,
		clusterWeekChips,
		type CalendarInterval
	} from './discriminator.js';

	type DocItem = DocumentResponse<Record<string, unknown>>;

	let {
		items,
		discriminator,
		kind,
		discriminatorField,
		endField,
		colorByField,
		titleTemplate,
		fallbackFields,
		year,
		month,
		day,
		weekStart,
		onChipClick
	}: {
		items: DocItem[];
		discriminator: CalendarViewConfig['discriminator'];
		kind: CalendarDiscriminatorKind;
		discriminatorField: FieldDef | undefined;
		endField: FieldDef | undefined;
		colorByField: FieldDef | undefined;
		titleTemplate: string | null | undefined;
		fallbackFields: { key: string }[];
		year: number;
		month: number;
		day: number;
		weekStart: 'monday' | 'sunday';
		onChipClick?: (docId: string) => void;
	} = $props();

	const weekdayLabels = $derived(localizedWeekdayLabels(weekStart));

	// Visible week = the row of the month grid whose 7 days bracket the anchor
	// day. The parent always passes `(year, month, day)` of a day inside the
	// desired week; we find the matching row instead of assuming row 0 (which
	// would only be correct when the anchor lives in the month's first week).
	const weeks = $derived(monthGridWeeks(year, month, weekStart));
	const weekDays = $derived.by(() => {
		const anchor = { y: year, m: month, d: day };
		return (
			weeks.find((w) => compareDay(anchor, w[0]) >= 0 && compareDay(anchor, w[6]) <= 0) ?? weeks[0]
		);
	});

	const HOUR_ROW_H = 48; // px per hour
	const HOUR_START = 0; // hours from midnight; full-day grid 0..24
	const HOUR_END = 24;
	const HOURS = $derived.by(() => {
		const arr: number[] = [];
		for (let h = HOUR_START; h < HOUR_END; h += 2) arr.push(h);
		return arr;
	});

	const today = $derived.by(() => {
		const n = new Date();
		const d = { y: n.getUTCFullYear(), m: n.getUTCMonth() + 1, d: n.getUTCDate() };
		return d;
	});

	type Resolved = {
		item: DocItem;
		interval: CalendarInterval;
		title: string;
		color: string;
	};

	const resolvedChips = $derived.by<Resolved[]>(() => {
		if (!discriminatorField) return [];
		const cfg: CalendarViewConfig = {
			discriminator: discriminator,
			end_field: endField?.key ?? null,
			color_by: colorByField?.key ?? null,
			title_template: titleTemplate ?? null,
			week_start: weekStart
		};
		return items
			.map((item): Resolved | null => {
				const interval = resolveInterval(item.data, cfg, kind);
				// date-kind discriminators carry startDay with a null start instant;
				// drop a document only when it has neither (malformed or missing).
				if (!interval.start && !interval.startDay) return null;
				const title =
					renderCalendarTitle(item.data, titleTemplate, fallbackFields, item.meta?.display_name) ||
					item.meta?.id ||
					'—';
				return {
					item,
					interval,
					title,
					color: chipColor(item.data, colorByField)
				};
			})
			.filter((r): r is Resolved => r !== null);
	});

	const chipIntervals = $derived(resolvedChips.map((r) => r.interval));

	// datetime-kind chips on the hour grid.
	const placed = $derived(clusterWeekChips(chipIntervals, weekDays));

	// All-day chips: date kind, date-range, and datetime-range whose end day
	// differs from the start day (these "span" rather than anchor a time).
	type AllDayChip = Resolved & { dayCol: number; spanCols: number };
	const allDayChips = $derived.by<AllDayChip[]>(() => {
		const out: AllDayChip[] = [];
		for (const r of resolvedChips) {
			if (r.interval.kind === 'datetime' || r.interval.kind === 'datetime-range') {
				// datetime-range only goes all-day when it multi-days in month
				// view, but in week view it gets true positioning — UNLESS the
				// end day differs from the start day, in which case it spans.
				if (r.interval.start != null && (r.interval.end ?? r.interval.start) === r.interval.start) {
					// true single-instant: position on the hour grid, not all-day.
					continue;
				}
				const startDay = r.interval.startDay;
				const endDay = r.interval.endDay;
				if (!startDay || !endDay) continue;
				const dayCol = weekDays.findIndex((d) => compareDay(d, startDay) === 0);
				if (dayCol < 0) continue;
				// Span: clamp end-day difference within this week.
				const endCol = Math.max(
					dayCol,
					weekDays.findIndex((d) => compareDay(d, endDay) === 0)
				);
				const spanCols = endCol === -1 ? 1 : Math.max(1, endCol - dayCol + 1);
				if (r.interval.kind === 'datetime-range' && compareDay(startDay, endDay) === 0) continue;
				out.push({ ...r, dayCol: dayCol < 0 ? 0 : dayCol, spanCols: Math.min(7, spanCols) });
				continue;
			}
			// date / date-range — all-day gutter.
			if (!r.interval.startDay || !r.interval.endDay) continue;
			const dayCol = weekDays.findIndex((d) => compareDay(d, r.interval.startDay!) === 0);
			if (dayCol < 0) continue;
			const endColIdx = weekDays.findIndex((d) => compareDay(d, r.interval.endDay!) === 0);
			const span = endColIdx === -1 ? 1 : Math.max(1, endColIdx - dayCol + 1);
			out.push({ ...r, dayCol, spanCols: Math.min(7 - dayCol, span) });
		}
		return out;
	});

	function chipColor(data: Record<string, unknown>, field: FieldDef | undefined): string {
		if (!field) return hashColor('calendar-chip');
		if (field.type === 'enum') {
			const v = String(data[field.key] ?? '');
			const entry = field.values?.find((x) => x.key === v);
			return entry?.color ?? hashColor(v || field.key);
		}
		return hashColor(field.key);
	}

	function timeLabel(hour: number): string {
		return String(hour).padStart(2, '0') + ':00';
	}

	// Day column header label, e.g. "Wed 18" / "mer. 18".
	function dayHeader(day: { y: number; m: number; d: number }, i: number): string {
		return `${weekdayLabels[i]} ${day.d}`;
	}

	function isToday(day: { y: number; m: number; d: number }): boolean {
		return today.y === day.y && today.m === day.m && today.d === day.d;
	}

	// Top/height of a placed chip in pixels.
	function chipTop(c: { startMin: number }): number {
		return (c.startMin / 60) * HOUR_ROW_H;
	}
	function chipHeight(c: { durationMin: number }): number {
		return Math.max(16, (c.durationMin / 60) * HOUR_ROW_H - 2);
	}
	function chipLeft(c: { colInCluster: number; clusterSize: number }): string {
		if (c.clusterSize <= 1) return '0';
		const pct = (c.colInCluster / c.clusterSize) * 100;
		return `calc(${pct}% + 2px)`;
	}
	function chipWidth(c: { clusterSize: number }): string {
		if (c.clusterSize <= 1) return 'calc(100% - 4px)';
		return `calc(${100 / c.clusterSize}% - 4px)`;
	}
</script>

<div class="cal-week" role="grid">
	<div class="cal-week-header" role="row">
		<div class="cal-gutter-corner"></div>
		{#each weekDays as day, i (formatDay(day))}
			<div class="cal-dayhead" class:today={isToday(day)} role="columnheader">
				{dayHeader(day, i)}
			</div>
		{/each}
	</div>

	<div class="cal-body">
		<!-- All-day gutter row -->
		<div class="cal-allday-row" role="row">
			<div class="cal-gutter">{m.calendar_all_day()}</div>
			<div class="cal-allday-col-wrap">
				{#each allDayChips as r (r.item.meta.id)}
					<button
						type="button"
						class="cal-chip cal-allday-chip"
						style="left: calc({(r.dayCol / 7) * 100}% + 2px); width: calc({(r.spanCols / 7) *
							100}% - 4px); background: {r.color}22; color: {r.color};"
						title={r.title}
						onclick={() => onChipClick?.(r.item.meta.id)}
						onkeydown={(e) => {
							if (e.key === 'Enter' || e.key === ' ') {
								e.preventDefault();
								onChipClick?.(r.item.meta.id);
							}
						}}>{r.title}</button
					>
				{/each}
			</div>
		</div>

		<div class="cal-hour-grid">
			<div class="cal-gutter-col">
				{#each HOURS as h (h)}
					<div class="cal-hour-label" style="height: {HOUR_ROW_H * 2}px;">{timeLabel(h)}</div>
				{/each}
			</div>
			<div class="cal-day-cols">
				{#each weekDays as day, _i (formatDay(day))}
					<div class="cal-day-col" class:today={isToday(day)}>
						{#each HOURS as h (h)}
							<div class="cal-hour-line" style="height: {HOUR_ROW_H * 2}px;"></div>
						{/each}
					</div>
				{/each}

				<!-- Hour-grid chips (datetime / datetime-range true positioning). -->
				{#each placed as c (`${c.dayCol}:${c.cluster}:${c.colInCluster}:${c.chipIndex}`)}
					{@const r = resolvedChips[c.chipIndex]}
					<button
						type="button"
						class="cal-chip cal-time-chip"
						style="left: calc({(c.dayCol / 7) * 100}% + 2px); top: {chipTop(
							c
						)}px; height: {chipHeight(c)}px; {chipLeft(c)} {chipWidth(
							c
						)} background: {r.color}22; color: {r.color};"
						title={r.title}
						onclick={() => onChipClick?.(r.item.meta.id)}
						onkeydown={(e) => {
							if (e.key === 'Enter' || e.key === ' ') {
								e.preventDefault();
								onChipClick?.(r.item.meta.id);
							}
						}}>{r.title}</button
					>
				{/each}
			</div>
		</div>
	</div>
</div>

<style>
	.cal-week {
		font-family: var(--font-sans);
		display: flex;
		flex-direction: column;
	}

	.cal-week-header {
		display: grid;
		grid-template-columns: 44px repeat(7, minmax(0, 1fr));
		border-bottom: 1px solid var(--border);
	}
	.cal-gutter-corner {
		background: var(--surface);
	}
	.cal-dayhead {
		padding: 6px 8px;
		font-size: 11px;
		font-weight: 600;
		color: var(--text-2);
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}
	.cal-dayhead.today {
		color: var(--accent-ink);
	}

	.cal-body {
		display: grid;
		grid-template-rows: auto 1fr;
		overflow: auto;
	}

	.cal-allday-row {
		display: grid;
		grid-template-columns: 44px 1fr;
		border-bottom: 1px solid var(--border);
		min-height: 24px;
		align-items: center;
	}
	.cal-gutter {
		font-size: 11px;
		color: var(--text-3);
		font-family: var(--font-mono);
		padding: 2px 6px;
		text-align: right;
	}
	.cal-allday-col-wrap {
		position: relative;
		min-height: 24px;
		padding: 2px 0;
	}
	.cal-allday-chip {
		position: absolute;
		top: 2px;
		font-size: 11px;
		padding: 2px 6px;
		border-radius: var(--r-sm);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		cursor: pointer;
	}
	.cal-allday-chip:focus-visible {
		outline: 1.5px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.cal-hour-grid {
		display: grid;
		grid-template-columns: 44px 1fr;
		position: relative;
	}
	.cal-gutter-col {
		border-right: 1px solid var(--border);
	}
	.cal-hour-label {
		font-size: 11px;
		color: var(--text-3);
		font-family: var(--font-mono);
		padding: 2px 6px;
		text-align: right;
		border-bottom: 1px solid var(--border);
		box-sizing: border-box;
	}
	.cal-day-cols {
		position: relative;
		display: grid;
		grid-template-columns: repeat(7, minmax(0, 1fr));
	}
	.cal-day-col {
		border-right: 1px solid var(--border);
		box-sizing: border-box;
	}
	.cal-day-col:last-child {
		border-right: none;
	}
	.cal-day-col.today {
		background: var(--accent-weak);
	}
	.cal-hour-line {
		border-bottom: 1px solid var(--border);
		box-sizing: border-box;
	}
	.cal-hour-line:last-child {
		border-bottom: none;
	}

	.cal-chip {
		cursor: pointer;
	}
	.cal-chip:hover {
		filter: brightness(0.88);
		box-shadow: 0 0 0 1px currentColor;
		z-index: 2;
	}
	.cal-time-chip {
		position: absolute;
		font-size: 11px;
		padding: 3px 5px;
		border-radius: var(--r-sm);
		overflow: hidden;
		white-space: nowrap;
		text-overflow: ellipsis;
		z-index: 1;
	}
	.cal-time-chip:focus-visible {
		outline: 1.5px solid var(--accent-ink);
		outline-offset: 1px;
		z-index: 2;
	}
</style>
