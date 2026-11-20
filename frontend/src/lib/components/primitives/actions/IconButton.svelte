<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		label,
		disabled = false,
		onclick,
		class: className = '',
		children,
		...rest
	}: {
		/** Accessible label for the button (required for icon-only buttons). */
		label: string;
		disabled?: boolean;
		onclick?: (e: MouseEvent) => void;
		/** Extra CSS classes applied to the button element. */
		class?: string;
		/** Reflects the button's pressed state (e.g. a pinned toggle). */
		'aria-pressed'?: boolean;
		children?: import('svelte').Snippet;
	} = $props();
</script>

<button class="icon-btn {className}" aria-label={label} {disabled} {onclick} {...rest}>
	{@render children?.()}
</button>

<style>
	/* ── Icon button — matches fullpage .iconbtn ────────────────────────── */
	.icon-btn {
		width: 34px;
		height: 34px;
		border-radius: 9px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		color: var(--text-2);
		border: none;
		background: none;
		font: inherit;
		cursor: pointer;
		transition:
			background 0.12s,
			color 0.12s;
		flex-shrink: 0;
	}

	.icon-btn:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.icon-btn:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}

	.icon-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
