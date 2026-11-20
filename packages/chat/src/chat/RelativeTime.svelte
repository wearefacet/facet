<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	RelativeTime — a short relative label with the exact datetime one hover
	away. Ported from the main application's `primitives/data/RelativeTime`
	down to the conversation rail's needs: a semantic `<time>` element with a
	`title` tooltip replaces the Bits UI tooltip (the package carries no
	headless-widget dependency), and the label logic lives in
	`relativeTime.ts`.
-->
<script lang="ts">
	import { formatFullDate, relativeTime } from './relativeTime.js';

	let {
		date,
		class: klass = ''
	}: {
		/** A date string (ISO 8601) or Date object to display relative to now. */
		date: string | Date;
		class?: string;
	} = $props();

	const formatted = $derived(relativeTime(date));
	const full = $derived(formatFullDate(date));
	const blank = $derived(formatted === '—');
	const iso = $derived(typeof date === 'string' ? date : date.toISOString());
</script>

<time class="relative-time {klass}" datetime={iso} title={full}>
	{#if blank}
		<span class="relative-time-blank">—</span>
	{:else}
		{formatted}
	{/if}
</time>

<style>
	/* ── RelativeTime ── matches design-guideline "Data is mono" rule ──── */
	.relative-time {
		font-family: var(--facet-font-mono);
		font-size: 12px;
		color: var(--facet-text-2);
		white-space: nowrap;
	}

	/* Blank (unparseable) date — muted dash. */
	.relative-time-blank {
		color: var(--facet-text-3);
	}
</style>
