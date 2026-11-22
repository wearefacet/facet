<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	/**
	 * Presentational usage meter for the assistant composer — a thin fill bar
	 * plus one line of text ("62% of the 30-day budget used"). When part of
	 * the total is an estimate (the provider reported no token counts and the
	 * turn was billed on a character count), a second line marks it so a
	 * budget decision never rests on a silent guess.
	 *
	 * The host hides it entirely when the account has no budget
	 * (`budget: null`), so this component always receives a finite budget.
	 */

	let {
		used,
		estimated = 0,
		budget,
		windowDays
	}: {
		/** Tokens billed to the caller inside the current window. */
		used: number;
		/** The part of `used` that is a character-count estimate, not a report. */
		estimated?: number;
		/** Effective token budget (finite — unlimited accounts never mount this). */
		budget: number;
		/** Window length in days, shown in the text line. */
		windowDays: number;
	} = $props();

	/** Used share, rounded up to the percent and clamped at 100. */
	const percent = $derived(budget > 0 ? Math.min(100, Math.round((used / budget) * 100)) : 100);

	/** Share of the total that is estimated, 0 when nothing is estimated. */
	const estimatedPercent = $derived(used > 0 ? Math.round((estimated / used) * 100) : 0);
</script>

<div class="usage-meter" role="status">
	<div class="meter-bar" aria-hidden="true">
		<div class="meter-fill" style:width="{percent}%"></div>
	</div>
	<span class="meter-text">{m.assistant_usage_meter({ percent, days: windowDays })}</span>
	{#if estimated > 0}
		<span class="meter-estimated">
			{m.assistant_usage_meter_estimated({ percent: estimatedPercent })}
		</span>
	{/if}
</div>

<style>
	.usage-meter {
		display: flex;
		flex-direction: column;
		gap: 4px;
		font-size: 12px;
		color: var(--text-3);
	}

	.meter-bar {
		height: 4px;
		border-radius: var(--r-pill);
		background: var(--border);
		overflow: hidden;
	}

	.meter-fill {
		height: 100%;
		border-radius: inherit;
		background: var(--accent);
	}

	.meter-estimated {
		font-size: 11px;
		color: var(--text-4, var(--text-3));
	}
</style>
