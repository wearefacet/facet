<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { Snippet } from 'svelte';
	import * as m from '$lib/paraglide/messages';
	import { monthName } from '$lib/i18n/localeNames.js';

	type Day = { y: number; m: number; d: number };

	let {
		anchor,
		onpick,
		children
	}: {
		anchor: Day;
		onpick: (d: Day) => void;
		children?: Snippet;
	} = $props();

	const MONTHS = Array.from({ length: 12 }, (_, i) => monthName(i + 1));

	let viewYear = $state(new Date().getUTCFullYear());

	// Keep the picker's year in sync when the anchor changes externally (e.g.
	// after a prev/next navigation while the picker is open, or reopening it).
	// Guard the write: only update when the source actually changed, so the
	// effect never re-enters because of its own state mutation.
	$effect(() => {
		const y = anchor.y;
		if (viewYear !== y) viewYear = y;
	});

	function stepYear(delta: number) {
		viewYear += delta;
	}

	function pickMonth(m: number) {
		onpick({ y: viewYear, m, d: 1 });
	}

	function goToday() {
		const n = new Date();
		onpick({ y: n.getUTCFullYear(), m: n.getUTCMonth() + 1, d: n.getUTCDate() });
	}
</script>

<div class="dp-root" role="dialog" aria-label={m.calendar_jump_to_date()}>
	<div class="dp-head">
		<button
			type="button"
			class="dp-year-btn"
			onclick={() => stepYear(-1)}
			aria-label={m.calendar_previous_year()}
		>
			<i class="ti ti-chevron-left"></i>
		</button>
		<span class="dp-year">{viewYear}</span>
		<button
			type="button"
			class="dp-year-btn"
			onclick={() => stepYear(1)}
			aria-label={m.calendar_next_year()}
		>
			<i class="ti ti-chevron-right"></i>
		</button>
	</div>
	<div class="dp-months" role="grid">
		{#each MONTHS as label, i (label)}
			<button
				type="button"
				class="dp-month"
				class:on={viewYear === anchor.y && i + 1 === anchor.m}
				aria-label={`${label} ${viewYear}`}
				onclick={() => pickMonth(i + 1)}>{label}</button
			>
		{/each}
	</div>
	<button type="button" class="dp-today" onclick={goToday}>{m.calendar_today()}</button>
	{@render children?.()}
</div>

<style>
	.dp-root {
		display: flex;
		flex-direction: column;
		gap: 10px;
		width: 232px;
	}

	.dp-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 0 2px;
	}
	.dp-year-btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 26px;
		height: 26px;
		border: none;
		background: none;
		color: var(--text-2);
		cursor: pointer;
		border-radius: var(--r-sm);
		font: inherit;
	}
	.dp-year-btn:hover {
		background: var(--sunken);
		color: var(--text);
	}
	.dp-year-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}
	.dp-year {
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
		font-family: var(--font-mono);
	}

	.dp-months {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 4px;
	}
	.dp-month {
		padding: 6px 0;
		font-size: 12px;
		font-weight: 500;
		color: var(--text-2);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		cursor: pointer;
		font: inherit;
		transition:
			background 0.1s,
			color 0.1s,
			border-color 0.1s;
	}
	.dp-month:hover {
		background: var(--sunken);
		color: var(--text);
		border-color: var(--border-strong);
	}
	.dp-month.on {
		background: var(--accent-weak);
		color: var(--accent-ink);
		border-color: var(--accent);
		font-weight: 600;
	}
	.dp-month:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.dp-today {
		margin-top: 2px;
		padding: 6px 10px;
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		cursor: pointer;
		font: inherit;
	}
	.dp-today:hover {
		background: var(--sunken);
		color: var(--text);
	}
	.dp-today:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}
</style>
