<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Tooltip } from 'bits-ui';
	import { formatFullDate, relativeTime } from '$lib/utils/relativeTime.js';
	import { displayTimezone } from '$lib/settings.svelte';
	import '../shared.css';

	let {
		date,
		class: klass = '',
		...rest
	}: {
		/** A date string (ISO 8601) or Date object to display relative to now. */
		date: string | Date;
		class?: string;
		[key: string]: unknown;
	} = $props();

	const formatted = $derived(relativeTime(date));
	const full = $derived(formatFullDate(date, displayTimezone()));
	const blank = $derived(formatted === '—');
</script>

<!--
	Every relative date renders through this single component so the exact
	datetime is always one hover away. The trigger stays a semantic `<time>`
	element (via the `child` snippet) so the relative label reads naturally
	and the tooltip is reachable by keyboard focus.
-->
<Tooltip.Provider>
	<Tooltip.Root>
		<Tooltip.Trigger>
			{#snippet child({ props })}
				{@const { type: _type, ...timeProps } = props}
				<time
					{...timeProps}
					class="relative-time {klass}"
					datetime={typeof date === 'string' ? date : date?.toISOString()}
					{...rest}
				>
					{#if blank}
						<span class="relative-time-blank">—</span>
					{:else}
						{formatted}
					{/if}
				</time>
			{/snippet}
		</Tooltip.Trigger>
		<Tooltip.Portal>
			<Tooltip.Content class="tooltip-pop relative-time-tooltip" sideOffset={4}>
				{full}
				<Tooltip.Arrow />
			</Tooltip.Content>
		</Tooltip.Portal>
	</Tooltip.Root>
</Tooltip.Provider>

<style>
	/* ── RelativeTime ── matches design-guideline "Data is mono" rule ──── */
	.relative-time {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-2);
		white-space: nowrap;
	}

	/* Blank (unparseable) date — muted dash, no tooltip affordance. */
	.relative-time-blank {
		color: var(--text-3);
	}

	/* Tooltip content — the shared tooltip shape in the mono data font. */
	:global(.tooltip-pop.relative-time-tooltip) {
		--tooltip-font: var(--font-mono);
	}
</style>
