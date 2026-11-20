<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	type Level = 'hi' | 'md' | 'lo';

	let {
		value = 0,
		level = undefined,
		levels = undefined,
		showLabel = true,
		...rest
	}: {
		/** Confidence percentage (0–100). */
		value?: number;
		/** Explicit level override. Auto-derived from `value` + `levels` thresholds when not set. */
		level?: Level;
		/**
		 * Threshold boundaries for auto color as a fraction pair `[lo, md]`
		 * where values are 0–1. Defaults to `[0.33, 0.66]`.
		 * Set to `null` for a solid neutral fill (no semantic color).
		 */
		levels?: [number, number] | null;
		/** Whether to show the percentage label. Defaults to `true`. */
		showLabel?: boolean;
	} = $props();

	const clamped = $derived(Math.max(0, Math.min(100, value)));

	const thresholds = $derived(levels ?? [0.33, 0.66]);

	const autoLevel = $derived.by(() => {
		if (thresholds === null) return null;
		const [lo, md] = thresholds;
		const pct = clamped / 100;
		if (pct < lo) return 'lo' as const;
		if (pct < md) return 'md' as const;
		return 'hi' as const;
	});

	const resolvedLevel: Level | null = $derived(level ?? autoLevel);

	const cls = $derived(
		[
			'confidence-bar',
			resolvedLevel === null ? 'confidence-bar-solid' : `confidence-bar-${resolvedLevel}`
		].join(' ')
	);
</script>

<span class={cls} role="img" aria-label={m.common_confidence_aria({ percent: clamped })} {...rest}>
	<span class="confidence-bar-track">
		<i class="confidence-bar-fill" style="width: {clamped}%"></i>
	</span>
	{#if showLabel}
		{clamped}%
	{/if}
</span>

<style>
	/* ── Confidence bar — matches design-guideline .conf ────────────────── */
	.confidence-bar {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		font-family: var(--font-mono);
		font-size: 12px;
		white-space: nowrap;
	}

	.confidence-bar-track {
		width: 42px;
		height: 5px;
		border-radius: 3px;
		background: var(--sunken);
		overflow: hidden;
		flex-shrink: 0;
	}

	.confidence-bar-fill {
		display: block;
		height: 100%;
		border-radius: 3px;
		transition: width 0.2s ease;
	}

	/* Level colors */
	.confidence-bar-hi {
		color: var(--ok);
	}

	.confidence-bar-hi .confidence-bar-fill {
		background: var(--ok);
	}

	.confidence-bar-md {
		color: var(--warn);
	}

	.confidence-bar-md .confidence-bar-fill {
		background: var(--warn);
	}

	.confidence-bar-lo {
		color: var(--danger);
	}

	.confidence-bar-lo .confidence-bar-fill {
		background: var(--danger);
	}

	/* Solid (neutral) — no semantic color */
	.confidence-bar-solid {
		color: var(--text-3);
	}

	.confidence-bar-solid .confidence-bar-fill {
		background: var(--text-3);
	}
</style>
