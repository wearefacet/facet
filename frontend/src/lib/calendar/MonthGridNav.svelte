<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	Story support for MonthGrid.stories.svelte. It owns the visible month as
	per-story state and renders prev/next buttons, so a play function (and a
	human in Storybook) can navigate months the same way the real surface does.
	The state lives in this component instance, so every story mount starts
	from `initialYear` / `initialMonth`.
-->

<script lang="ts">
	import type { Snippet } from 'svelte';

	let {
		initialYear,
		initialMonth,
		grid
	}: {
		initialYear: number;
		initialMonth: number;
		grid: Snippet<[{ year: number; month: number }]>;
	} = $props();

	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let year = $state(initialYear);
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let month = $state(initialMonth);

	function go(delta: number): void {
		month += delta;
		if (month < 1) {
			month = 12;
			year -= 1;
		} else if (month > 12) {
			month = 1;
			year += 1;
		}
	}
</script>

<div class="nav">
	<button type="button" onclick={() => go(-1)}>Previous month</button>
	<span class="label">{year}-{String(month).padStart(2, '0')}</span>
	<button type="button" onclick={() => go(1)}>Next month</button>
</div>

{@render grid({ year, month })}

<style>
	.nav {
		display: flex;
		gap: 8px;
		align-items: center;
		margin-bottom: 8px;
	}
	.label {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-2);
	}
</style>
