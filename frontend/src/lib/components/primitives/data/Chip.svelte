<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	type Variant = 'default' | 'active';

	let {
		variant = 'default',
		label,
		closable = false,
		onclose,
		children,
		...rest
	}: {
		/** Visual variant: `default` (outline) or `active` (accent fill). */
		variant?: Variant;
		/** Label text (alternative to children snippet). */
		label?: string;
		/** Shows an × close button when true. */
		closable?: boolean;
		/** Called when the close button is clicked. */
		onclose?: () => void;
		children?: import('svelte').Snippet;
	} = $props();
</script>

<span class="chip" class:chip-active={variant === 'active'} role="status" {...rest}>
	{@render children?.()}
	{label}
	{#if closable}
		<button class="chip-x" onclick={onclose} aria-label={m.common_remove()}>&times;</button>
	{/if}
</span>

<style>
	/* ── Chip — matches design-guideline .chip ───────────────────────────── */
	.chip {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 6px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
		background: var(--surface);
		white-space: nowrap;
	}

	.chip:hover {
		border-color: var(--border-strong);
	}

	/* Active variant — accent fill */
	.chip-active {
		border-color: var(--accent);
		color: var(--accent-ink);
		background: var(--accent-weak);
	}

	/* Close button — matches .chip .x */
	.chip-x {
		margin: 0;
		padding: 0;
		border: none;
		background: none;
		font: inherit;
		font-size: 16px;
		line-height: 1;
		color: var(--text-3);
		cursor: pointer;
		display: inline-flex;
		align-items: center;
		justify-content: center;
	}

	.chip-x:hover {
		color: var(--text);
	}
</style>
