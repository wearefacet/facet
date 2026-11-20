<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	const SECONDS_PER_MINUTE = 60;
	const SECONDS_PER_HOUR = 60 * SECONDS_PER_MINUTE;
	const SECONDS_PER_DAY = 24 * SECONDS_PER_HOUR;

	let {
		value,
		...rest
	}: {
		/** Duration in seconds. Negative or non-finite values render as `0s`. */
		value: number;
	} = $props();

	const formatted = $derived(formatDuration(value));

	/**
	 * Format a seconds count as `2d 3h 15m 4s`, omitting leading and trailing
	 * zero segments. `0` renders as `0s` so the value is never blank.
	 */
	function formatDuration(raw: number): string {
		const total = Math.max(0, Math.floor(Number(raw) || 0));
		const days = Math.floor(total / SECONDS_PER_DAY);
		const rem = total - days * SECONDS_PER_DAY;
		const hours = Math.floor(rem / SECONDS_PER_HOUR);
		const remH = rem - hours * SECONDS_PER_HOUR;
		const minutes = Math.floor(remH / SECONDS_PER_MINUTE);
		const seconds = remH - minutes * SECONDS_PER_MINUTE;

		const parts: string[] = [];
		if (days > 0) parts.push(`${days}d`);
		if (hours > 0) parts.push(`${hours}h`);
		if (minutes > 0) parts.push(`${minutes}m`);
		if (seconds > 0) parts.push(`${seconds}s`);
		return parts.length > 0 ? parts.join(' ') : '0s';
	}
</script>

<span class="duration" {...rest}>
	{formatted}
</span>

<style>
	/* ── Duration ── matches design-guideline "Data is mono" rule ───────── */
	.duration {
		font-family: var(--font-mono);
		font-size: 13px;
		font-weight: 500;
		color: var(--text);
		white-space: nowrap;
	}
</style>
