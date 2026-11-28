<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { FieldDef } from '$lib/doctype/types.js';
	import { hashColor } from '$lib/utils/color.js';
	import { localizedWeekdayLabels } from '$lib/i18n/localeNames.js';
	import type { CalendarViewConfig, CalendarDiscriminatorKind } from '$lib/collectionView/types.js';
	import {
		compareDay,
		formatDay,
		isInMonth,
		monthGridWeeks,
		resolveInterval,
		renderCalendarTitle,
		allocateRangeBars,
		cellChipVisibility,
		shouldCollapseCell,
		shouldCollapseRowBars,
		type CalendarInterval,
		type RangeBar
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
		weekStart: 'monday' | 'sunday';
		onChipClick?: (docId: string) => void;
	} = $props();

	const weekdayLabels = $derived(localizedWeekdayLabels(weekStart));

	const weeks = $derived(monthGridWeeks(year, month, weekStart));

	// Cell metrics for chip-capacity calc — match the CSS values below.
	const CELL_MIN_HEIGHT = 84;
	const CELL_HEADER_H = 18;
	const LANE_HEIGHT = 16;
	const CHIP_HEIGHT = 20;

	// Maximum multi-day range-bar lanes a week row will render before the row
	// collapses all its bars into one `X documents` group bar (click → list).
	const MAX_RESERVED_LANES = 3;

	// Resolve intervals for every document; pair with the original item.
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
				if (!interval.startDay && !interval.start) return null;
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

	// Per-chip intervals array (parallel to resolvedChips) for lane allocation.
	const chipIntervals = $derived(resolvedChips.map((r) => r.interval));

	// Range bars come from a pure function — they handle both date-range and
	// datetime-range kinds (datetime-range degrades to single-day chips unless
	// the UTC day differs between start and end).
	const bars = $derived(allocateRangeBars(chipIntervals, weeks));

	// Per-week-row max lane used (reserved lane block height).
	const reservedLanes = $derived(
		weeks.map((_, ri) => {
			const lanes = bars.filter((b) => b.rowIndex === ri);
			return lanes.length > 0 ? Math.max(...lanes.map((b) => b.lane)) + 1 : 0;
		})
	);

	// Per-week-row: when the reserved-lane block would exceed the budget, the
	// row collapses all its multi-day bars into one `X documents` group bar.
	const collapsedRows = $derived(
		weeks.map((_, ri) => shouldCollapseRowBars(reservedLanes[ri], MAX_RESERVED_LANES))
	);

	// Effective reserved-lane count used for chip placement: a collapsed row
	// reserves a single lane slot for the group bar (the bars themselves are no
	// longer rendered individually).
	const effectiveReservedLanes = $derived(
		weeks.map((_, ri) => (collapsedRows[ri] ? 1 : reservedLanes[ri]))
	);

	// Vertical pixel offset at which single-day chips must start inside a cell,
	// so they render below the reserved-lane block (range bars live at the top
	// of the row; without this offset, chips would collide with the bars).
	const cellChipTopOffset = $derived(effectiveReservedLanes.map((n) => n * (LANE_HEIGHT + 2)));

	// Union column span of the row's multi-day bars (min start col → max end
	// col). The collapsed group bar is drawn within this span only, not across
	// the full week — empty trailing days (e.g. Sunday when bars end Friday)
	// stay clear so single-day chips there don't sit under the group bar.
	function rowBarSpan(ri: number): { startCol: number; span: number } | null {
		const rowBars = bars.filter((b) => b.rowIndex === ri);
		if (rowBars.length === 0) return null;
		const minStart = Math.min(...rowBars.map((b) => b.startCol));
		const maxEnd = Math.max(...rowBars.map((b) => b.startCol + b.span));
		return { startCol: minStart, span: maxEnd - minStart };
	}

	// All-day chips per week row — single-day chips (date / datetime without
	// range expansion / date-range with single day).
	type PlacedChip = Resolved & { rowIndex: number; colIndex: number };
	const chipsPerCell = $derived.by<Map<string, PlacedChip[]>>(() => {
		// Plain Map, no untrack: a reactive map's tracked get/set self-dirties a
		// derivation, but untracking the whole body leaves nothing tracked — the
		// derived would then evaluate once and freeze at mount. Plain reads and
		// writes cannot self-dirty it, so it keeps tracking its real inputs
		// (resolvedChips, bars, weeks) and recomputes when they change.
		const out = new Map<string, PlacedChip[]>();
		// Track which chips are rendered as bars to avoid double-rendering.
		const barChipIndexes = new Set(bars.map((b) => b.chipIndex));

		for (let ci = 0; ci < resolvedChips.length; ci++) {
			if (barChipIndexes.has(ci)) continue;
			const r = resolvedChips[ci];
			const day = r.interval.startDay ?? dayOfInstant(r.interval.start ?? Date.now());
			for (let ri = 0; ri < weeks.length; ri++) {
				const week = weeks[ri];
				const col = week.findIndex((d) => compareDay(d, day) === 0);
				if (col >= 0) {
					const key = `${ri}:${col}`;
					const list = out.get(key) ?? [];
					list.push({ ...r, rowIndex: ri, colIndex: col });
					out.set(key, list);
					break;
				}
			}
		}
		return out;
	});

	// Today's day bucket (for the highlight on the matching cell).
	const today = $derived.by(() => {
		const now = new Date();
		return { y: now.getUTCFullYear(), m: now.getUTCMonth() + 1, d: now.getUTCDate() };
	});

	function dayOfInstant(t: number): { y: number; m: number; d: number } {
		const d = new Date(t);
		return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() };
	}

	function chipColor(data: Record<string, unknown>, field: FieldDef | undefined): string {
		if (!field) return hashColor('calendar-chip');
		if (field.type === 'enum') {
			const v = String(data[field.key] ?? '');
			const entry = field.values?.find((x) => x.key === v);
			return entry?.color ?? hashColor(v || field.key);
		}
		return hashColor(field.key);
	}

	// Overflow population for the "+N more" popover per cell.
	type OverflowKey = string;
	let overflowOpen = $state<OverflowKey | null>(null);

	// Per-week-row boolean: when the group bar is open for the row's bars.
	let barGroupOpen = $state<number | null>(null);

	function cellKey(ri: number, ci: number): string {
		return `${ri}:${ci}`;
	}

	function cellChipCount(ri: number, ci: number): number {
		return (chipsPerCell.get(cellKey(ri, ci)) ?? []).length;
	}

	function cellVisibility(ri: number, ci: number) {
		// Uses the effective reserved-lane count (1 when bars are collapsed).
		return cellChipVisibility(
			cellChipCount(ri, ci),
			CELL_MIN_HEIGHT,
			effectiveReservedLanes[ri],
			LANE_HEIGHT,
			CHIP_HEIGHT,
			CELL_HEADER_H
		);
	}

	function visibleChipsForCell(ri: number, ci: number): PlacedChip[] {
		const list = chipsPerCell.get(cellKey(ri, ci)) ?? [];
		return list.slice(0, cellVisibility(ri, ci).visible);
	}

	function hiddenCountForCell(ri: number, ci: number): number {
		return cellVisibility(ri, ci).hidden;
	}

	function cellCollapsed(ri: number, ci: number): boolean {
		const total = cellChipCount(ri, ci);
		const visibleSlots = cellVisibility(ri, ci).visible;
		return shouldCollapseCell(total, visibleSlots);
	}

	function popoverChipsForCell(ri: number, ci: number): PlacedChip[] {
		return chipsPerCell.get(cellKey(ri, ci)) ?? [];
	}

	function barChipsForRow(ri: number): PlacedChip[] {
		const rowBars = bars.filter((b) => b.rowIndex === ri);
		return rowBars.map((b) => {
			const r = resolvedChips[b.chipIndex];
			return { ...r, rowIndex: ri, colIndex: b.startCol };
		});
	}

	function barChipCountForRow(ri: number): number {
		return bars.filter((b) => b.rowIndex === ri).length;
	}

	// Bar position helpers (absolute, inside the week row).
	const LANE_TOP_OFFSET = CELL_HEADER_H + 2;
	function barStyle(bar: RangeBar): string {
		const left = (bar.startCol / 7) * 100;
		const width = (bar.span / 7) * 100;
		const top = LANE_TOP_OFFSET + bar.lane * (LANE_HEIGHT + 2);
		return `left: calc(${left}% + 4px); width: calc(${width}% - 8px); top: ${top}px;`;
	}
	function groupBarStyle(span: { startCol: number; span: number }): string {
		const left = (span.startCol / 7) * 100;
		const width = (span.span / 7) * 100;
		return `left: calc(${left}% + 4px); width: calc(${width}% - 8px); top: ${LANE_TOP_OFFSET}px;`;
	}

	// Container ref — used to close popovers on outside pointer/click.
	let rootEl: HTMLElement | null = null;

	// Close any open list popover when a pointer event lands outside the grid
	// container, or when Escape is pressed. Each open button stops propagation
	// on its own click so this listener only fires for genuinely outside clicks.
	$effect(() => {
		if (!overflowOpen && barGroupOpen === null) return;
		const onPointerDown = (e: PointerEvent) => {
			if (rootEl && e.target instanceof Node && !rootEl.contains(e.target)) {
				overflowOpen = null;
				barGroupOpen = null;
			}
		};
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape') {
				overflowOpen = null;
				barGroupOpen = null;
			}
		};
		window.addEventListener('pointerdown', onPointerDown);
		window.addEventListener('keydown', onKey);
		return () => {
			window.removeEventListener('pointerdown', onPointerDown);
			window.removeEventListener('keydown', onKey);
		};
	});
</script>

<div class="cal-month" role="grid" bind:this={rootEl}>
	<div class="cal-weekday-row" role="row">
		{#each weekdayLabels as label (label)}
			<div class="cal-weekday" role="columnheader">{label}</div>
		{/each}
	</div>

	{#each weeks as week, ri (ri)}
		<div class="cal-week" role="row" style="min-height: {CELL_MIN_HEIGHT}px; position: relative;">
			{#each week as day, ci (formatDay(day))}
				<div
					class="cal-cell"
					class:out={!isInMonth(day, year, month)}
					class:today={today.y === day.y && today.m === day.m && today.d === day.d}
					role="gridcell"
					aria-label={formatDay(day)}
				>
					<span class="cal-daynum">{day.d}</span>
					{#if cellChipTopOffset[ri] > 0}
						<div
							class="cal-cell-spacer"
							style="flex: 0 0 {cellChipTopOffset[ri]}px; height: {cellChipTopOffset[ri]}px;"
							aria-hidden="true"
						></div>
					{/if}
					{#if cellCollapsed(ri, ci)}
						<!-- Dense cell: collapse to one `X documents` group chip (click → list). -->
						<button
							type="button"
							class="cal-chip cal-group-chip"
							aria-haspopup="dialog"
							aria-expanded={overflowOpen === cellKey(ri, ci)}
							onclick={(e) => {
								e.stopPropagation();
								overflowOpen = overflowOpen === cellKey(ri, ci) ? null : cellKey(ri, ci);
							}}
							onkeydown={(e) => {
								if (e.key === 'Enter' || e.key === ' ') {
									e.preventDefault();
									e.stopPropagation();
									overflowOpen = overflowOpen === cellKey(ri, ci) ? null : cellKey(ri, ci);
								}
							}}>{m.calendar_items_count({ count: cellChipCount(ri, ci) })}</button
						>
					{:else}
						{#each visibleChipsForCell(ri, ci) as r (r.item.meta.id)}
							<button
								type="button"
								class="cal-chip"
								style="background: {r.color}22; color: {r.color};"
								title={r.title}
								onclick={(e) => {
									e.stopPropagation();
									onChipClick?.(r.item.meta.id);
								}}
								onkeydown={(e) => {
									if (e.key === 'Enter' || e.key === ' ') {
										e.preventDefault();
										e.stopPropagation();
										onChipClick?.(r.item.meta.id);
									}
								}}>{r.title}</button
							>
						{/each}
						{#if hiddenCountForCell(ri, ci) > 0}
							<button
								type="button"
								class="cal-more"
								aria-haspopup="dialog"
								aria-expanded={overflowOpen === cellKey(ri, ci)}
								onclick={(e) => {
									e.stopPropagation();
									overflowOpen = overflowOpen === cellKey(ri, ci) ? null : cellKey(ri, ci);
								}}>+{hiddenCountForCell(ri, ci)} more</button
							>
						{/if}
					{/if}
				</div>
			{/each}

			<!-- Range bars — absolutely positioned over the day cells of this week. -->
			{#if collapsedRows[ri]}
				{@const span = rowBarSpan(ri)}
				{#if span}
					<!-- Dense row: collapse all multi-day bars into one group bar covering only
						the union of their day columns (click → list). -->
					<button
						type="button"
						class="cal-bar cal-group-bar"
						style={groupBarStyle(span)}
						aria-haspopup="dialog"
						aria-expanded={barGroupOpen === ri}
						onclick={(e) => {
							e.stopPropagation();
							barGroupOpen = barGroupOpen === ri ? null : ri;
						}}
						onkeydown={(e) => {
							if (e.key === 'Enter' || e.key === ' ') {
								e.preventDefault();
								e.stopPropagation();
								barGroupOpen = barGroupOpen === ri ? null : ri;
							}
						}}>{m.calendar_items_count({ count: barChipCountForRow(ri) })}</button
					>
				{/if}
			{:else}
				{#each bars.filter((b) => b.rowIndex === ri) as bar (`${bar.rowIndex}:${bar.startCol}:${bar.chipIndex}`)}
					{@const r = resolvedChips[bar.chipIndex]}
					<button
						type="button"
						class="cal-bar"
						style="background: {r.color}22; color: {r.color}; {barStyle(bar)}"
						title={r.title}
						onclick={(e) => {
							e.stopPropagation();
							onChipClick?.(r.item.meta.id);
						}}
						onkeydown={(e) => {
							if (e.key === 'Enter' || e.key === ' ') {
								e.preventDefault();
								e.stopPropagation();
								onChipClick?.(r.item.meta.id);
							}
						}}>{r.title}</button
					>
				{/each}
			{/if}

			{#if overflowOpen && Number(overflowOpen!.split(':')[0]) === ri}
				{@const ci = Number(overflowOpen!.split(':')[1])}
				{@const cellList = popoverChipsForCell(ri, ci)}
				{#if cellList.length > 0}
					<div class="cal-popover" role="dialog" aria-label={m.calendar_day_items_aria()}>
						{#each cellList as r (r.item.meta.id)}
							<button
								type="button"
								class="cal-chip cal-chip-pop"
								style="background: {r.color}22; color: {r.color};"
								title={r.title}
								onclick={(e) => {
									e.stopPropagation();
									overflowOpen = null;
									onChipClick?.(r.item.meta.id);
								}}
								onkeydown={(e) => {
									if (e.key === 'Enter' || e.key === ' ') {
										e.preventDefault();
										e.stopPropagation();
										overflowOpen = null;
										onChipClick?.(r.item.meta.id);
									}
								}}>{r.title}</button
							>
						{/each}
					</div>
				{/if}
			{/if}

			{#if barGroupOpen === ri}
				{@const rowList = barChipsForRow(ri)}
				{#if rowList.length > 0}
					<div class="cal-popover" role="dialog" aria-label={m.calendar_week_docs_aria()}>
						{#each rowList as r (r.item.meta.id)}
							<button
								type="button"
								class="cal-chip cal-chip-pop"
								style="background: {r.color}22; color: {r.color};"
								title={r.title}
								onclick={(e) => {
									e.stopPropagation();
									barGroupOpen = null;
									onChipClick?.(r.item.meta.id);
								}}
								onkeydown={(e) => {
									if (e.key === 'Enter' || e.key === ' ') {
										e.preventDefault();
										e.stopPropagation();
										barGroupOpen = null;
										onChipClick?.(r.item.meta.id);
									}
								}}>{r.title}</button
							>
						{/each}
					</div>
				{/if}
			{/if}
		</div>
	{/each}
</div>

<style>
	.cal-month {
		display: flex;
		flex-direction: column;
		font-family: var(--font-sans);
	}

	.cal-weekday-row {
		display: grid;
		grid-template-columns: repeat(7, minmax(0, 1fr));
		border-bottom: 1px solid var(--border);
	}
	.cal-weekday {
		padding: 6px 8px;
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--text-3);
	}

	.cal-week {
		display: grid;
		grid-template-columns: repeat(7, minmax(0, 1fr));
		border-bottom: 1px solid var(--border);
		position: relative;
	}
	.cal-week:last-child {
		border-bottom: none;
	}

	.cal-cell {
		position: relative;
		min-height: 84px;
		padding: 4px;
		border-right: 1px solid var(--border);
		border-bottom: none;
		background: var(--surface);
		text-align: left;
		display: flex;
		flex-direction: column;
		gap: 2px;
		font-family: var(--font-sans);
		cursor: pointer;
		overflow: hidden;
	}
	.cal-cell:last-child {
		border-right: none;
	}
	.cal-cell:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -2px;
	}
	.cal-cell.out {
		background: var(--sunken);
	}

	.cal-daynum {
		font-size: 11px;
		color: var(--text-2);
		align-self: flex-start;
	}
	.cal-cell.today .cal-daynum {
		color: var(--accent-ink);
		font-weight: 700;
	}

	/* Spacer pushing single-day chips below the reserved range-bar lane block. */
	.cal-cell-spacer {
		flex: 0 0 auto;
		width: 0;
	}

	.cal-chip {
		font-size: 11px;
		padding: 2px 5px;
		border-radius: var(--r-sm);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		cursor: pointer;
	}
	.cal-chip:hover {
		filter: brightness(0.88);
		box-shadow: 0 0 0 1px currentColor;
		z-index: 2;
	}
	.cal-chip:focus-visible {
		outline: 1.5px solid var(--accent-ink);
		outline-offset: 1px;
	}
	.cal-chip-pop {
		display: block;
		width: 100%;
		text-align: left;
		margin: 2px 0;
	}

	/* Collapsed single-day cell — one `X documents` chip (click → list). */
	.cal-group-chip {
		background: var(--sunken);
		color: var(--text-2);
		border: 1px solid var(--border-strong);
		width: 100%;
		margin-top: 2px;
	}
	.cal-group-chip:hover {
		background: var(--surface-2);
		color: var(--accent-ink);
	}
	.cal-group-chip:focus-visible {
		outline: 1.5px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.cal-more {
		margin-top: auto;
		align-self: flex-start;
		background: none;
		border: none;
		padding: 2px 5px;
		font-size: 11px;
		color: var(--text-3);
		cursor: pointer;
		border-radius: var(--r-sm);
		font-family: var(--font-sans);
	}
	.cal-more:hover {
		background: var(--sunken);
		color: var(--accent-ink);
	}

	.cal-bar {
		position: absolute;
		font-size: 11px;
		padding: 2px 6px;
		border-radius: var(--r-sm);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		cursor: pointer;
		z-index: 1;
	}
	.cal-bar:hover {
		filter: brightness(0.88);
		box-shadow: 0 0 0 1px currentColor;
		z-index: 2;
	}
	.cal-bar:focus-visible {
		outline: 1.5px solid var(--accent-ink);
		outline-offset: 1px;
	}

	/* Collapsed row — one `X documents` bar spanning the whole row (click → list). */
	.cal-group-bar {
		position: absolute;
		font-size: 11px;
		padding: 2px 6px;
		border-radius: var(--r-sm);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		cursor: pointer;
		background: var(--sunken);
		color: var(--text-2);
		border: 1px solid var(--border-strong);
		z-index: 1;
	}
	.cal-group-bar:hover {
		background: var(--surface-2);
		color: var(--accent-ink);
	}
	.cal-group-bar:focus-visible {
		outline: 1.5px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.cal-popover {
		position: absolute;
		top: 24px;
		left: 0;
		right: 0;
		background: var(--surface);
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		padding: 6px;
		box-shadow: var(--sh-2);
		z-index: 5;
		max-height: 200px;
		overflow-y: auto;
	}
</style>
