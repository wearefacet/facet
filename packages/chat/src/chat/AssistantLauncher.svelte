<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '../messages.js';
	import Bot from '@lucide/svelte/icons/bot';

	/**
	 * Floating launcher — the round button the floating mount shows in the
	 * bottom-right corner while the window is closed (`bubble` option). One
	 * click hands the request back to the host element through `onopen`.
	 */

	let {
		/** Accessible name — the configured assistant name. */
		label = m.assistant_title(),
		/** Called when the user clicks the launcher. */
		onopen = undefined
	}: {
		label?: string;
		onopen?: () => void;
	} = $props();
</script>

<button
	class="launcher"
	aria-label={m.assistant_open_aria()}
	title={label}
	onclick={() => onopen?.()}
>
	<Bot size={24} stroke-width={1.8} />
</button>

<style>
	/* Same corner the window docks to, so launcher and window trade places
	   instead of stacking. Same z-index layer as the window shell. */
	.launcher {
		position: fixed;
		right: 20px;
		bottom: 20px;
		width: 52px;
		height: 52px;
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 0;
		border: 1px solid var(--facet-border-strong, var(--facet-border));
		border-radius: var(--facet-r-pill);
		background: var(--facet-accent);
		color: var(--facet-on-accent);
		cursor: pointer;
		box-shadow:
			0 10px 30px rgba(0, 0, 0, 0.18),
			0 2px 8px rgba(0, 0, 0, 0.08);
		z-index: 1000;
	}
	.launcher:hover {
		background: var(--facet-accent-press);
	}
	.launcher:focus-visible {
		outline: 2px solid var(--facet-accent-ink);
		outline-offset: 2px;
	}
</style>
