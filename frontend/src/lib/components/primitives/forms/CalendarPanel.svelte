<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Popover } from 'bits-ui';
	import { longDate, localizedWeekdayLabels, monthName } from '$lib/i18n/localeNames.js';
	import type { Wall } from '$lib/zonedTime.js';
	import { monthCells, nowWall, type CalendarCell } from './calendarGrid.js';

	let {
		open,
		disabled,
		tz,
		wall,
		dateOnly = false,
		slotH,
		slotMi,
		onselectday,
		onselectslot
	}: {
		/** True while the picker's popover is open. The panel renders no cells when closed. */
		open: boolean;
		disabled: boolean;
		/** IANA timezone for wall-clock entry. Anchors the view and the today mark. */
		tz: string;
		/** Wall-clock parts of the parsed segments. Null when the segments are incomplete. */
		wall: Wall | null;
		/** Date granularity: the picker edits a calendar date, so the quick time
		 *  slots are hidden and the panel commits on day pick. */
		dateOnly?: boolean;
		/** Hour and minute segment values. Highlight the matching quick slot. */
		slotH: string;
		slotMi: string;
		/** A day cell was clicked. The picker writes the date into its segments. */
		onselectday: (cell: CalendarCell) => void;
		/** A quick slot was clicked. The picker rewrites the time segments. */
		onselectslot: (hhmm: string) => void;
	} = $props();

	// Locale-aware month and weekday names come from `Intl` via the active
	// Paraglide locale — names are data, not messages.
	const MONTH_NAMES = Array.from({ length: 12 }, (_, i) => monthName(i + 1, true));
	const DOW_LABELS = localizedWeekdayLabels('monday');
	/** Quick time slots offered under the calendar grid. */
	const TIME_SLOTS = ['00:00', '06:00', '12:00', '16:00'];

	// Calendar panel state. `viewY`/`viewM` is the displayed month; `todayWall`
	// is captured when the panel opens so today/selected highlights stay stable.
	let viewY = $state(0);
	let viewM = $state(0);
	let todayWall = $state<Wall | null>(null);

	function openPanel() {
		const w = wall ?? nowWall(tz);
		viewY = w.y;
		viewM = w.m;
		todayWall = nowWall(tz);
	}

	// Anchor the calendar view to the current value each time the popover opens.
	$effect(() => {
		if (open && !disabled) openPanel();
	});

	function shiftView(delta: number) {
		let m = viewM + delta;
		let y = viewY;
		if (m < 1) {
			m = 12;
			y -= 1;
		} else if (m > 12) {
			m = 1;
			y += 1;
		}
		viewY = y;
		viewM = m;
	}

	const panelCells = $derived(open ? monthCells(viewY, viewM, wall, todayWall) : []);
</script>

<Popover.Portal>
	<Popover.Content
		class="dtp-panel"
		sideOffset={4}
		align="start"
		aria-label={dateOnly ? m.doc_dt_calendar_aria() : m.doc_dt_slots_aria()}
	>
		<div class="dtp-panel-head">
			<button
				type="button"
				class="dtp-nav"
				aria-label={m.doc_dt_prev_month_aria()}
				onclick={() => shiftView(-1)}
				tabindex={-1}
			>
				‹
			</button>
			<span class="dtp-panel-title" aria-live="polite">{MONTH_NAMES[viewM - 1]} {viewY}</span>
			<button
				type="button"
				class="dtp-nav"
				aria-label={m.doc_dt_next_month_aria()}
				onclick={() => shiftView(1)}
				tabindex={-1}
			>
				›
			</button>
		</div>
		<div class="dtp-dow">
			{#each DOW_LABELS as dow (dow)}
				<span class="dtp-dow-label">{dow}</span>
			{/each}
		</div>
		<div class="dtp-grid" role="grid" aria-label={m.doc_dt_calendar_aria()}>
			{#each panelCells as cell (cell.y + '-' + cell.m + '-' + cell.d)}
				<button
					type="button"
					role="gridcell"
					class="dtp-cell"
					class:dtp-cell-out={cell.out}
					class:dtp-cell-today={cell.today}
					class:dtp-cell-sel={cell.selected}
					aria-label={longDate(cell)}
					aria-selected={cell.selected}
					onclick={() => onselectday(cell)}
					tabindex={-1}
				>
					{cell.d}
				</button>
			{/each}
		</div>
		{#if !dateOnly}
			<div class="dtp-slots">
				{#each TIME_SLOTS as slot (slot)}
					<button
						type="button"
						class="dtp-slot"
						class:dtp-slot-on={slotH === slot.slice(0, 2) && slotMi === slot.slice(3, 5)}
						onclick={() => onselectslot(slot)}
						tabindex={-1}
					>
						{slot}
					</button>
				{/each}
			</div>
		{/if}
	</Popover.Content>
</Popover.Portal>

<style>
	/* ── Calendar panel ─────────────────────────────────────────────────── */
	/* Portalled to document.body via Bits UI Popover; Bits UI handles positioning. */
	/* :global() is required because the class is passed as a prop to a component,
	   so Svelte cannot scope it and would prune these styles as unused. */
	:global(.dtp-panel) {
		width: 252px;
		padding: 10px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-1);
	}

	.dtp-panel-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		margin-bottom: 6px;
	}

	.dtp-panel-title {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text);
	}

	.dtp-nav {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		padding: 0;
		font-size: 15px;
		line-height: 1;
		color: var(--text-2);
		background: none;
		border: none;
		border-radius: var(--r-sm);
		cursor: pointer;
	}

	.dtp-nav:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.dtp-dow,
	.dtp-grid {
		display: grid;
		grid-template-columns: repeat(7, minmax(0, 1fr));
		gap: 2px;
	}

	.dtp-dow {
		margin-bottom: 3px;
	}

	.dtp-dow-label {
		font-size: 10.5px;
		text-align: center;
		color: var(--text-3);
		padding: 2px 0;
	}

	.dtp-cell {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 26px;
		padding: 0;
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text);
		background: none;
		border: none;
		border-radius: var(--r-sm);
		cursor: pointer;
		position: relative;
		transition: background 0.1s;
	}

	.dtp-cell:hover {
		background: var(--sunken);
	}

	.dtp-cell-out {
		color: var(--text-3);
	}

	.dtp-cell-today::after {
		content: '';
		position: absolute;
		bottom: 3px;
		left: 50%;
		transform: translateX(-50%);
		width: 3px;
		height: 3px;
		border-radius: 50%;
		background: var(--accent-ink);
	}

	.dtp-cell-sel {
		background: var(--accent);
		color: var(--on-accent);
	}

	.dtp-cell-sel:hover {
		background: var(--accent-press);
	}

	.dtp-cell-sel::after {
		background: var(--on-accent);
	}

	.dtp-slots {
		display: flex;
		flex-wrap: wrap;
		gap: 5px;
		margin-top: 8px;
		padding-top: 8px;
		border-top: 1px solid var(--border);
	}

	.dtp-slot {
		padding: 3px 9px;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
		background: none;
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		cursor: pointer;
		transition:
			background 0.1s,
			color 0.1s;
	}

	.dtp-slot:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.dtp-slot-on {
		background: var(--accent);
		border-color: var(--accent);
		color: var(--on-accent);
	}

	.dtp-slot-on:hover {
		background: var(--accent-press);
		color: var(--on-accent);
	}
</style>
