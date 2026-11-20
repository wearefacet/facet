<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		href,
		label,
		children,
		...rest
	}: {
		/** URL for the link. */
		href: string;
		/** Link text (alternative to children snippet). */
		label?: string;
		children?: import('svelte').Snippet;
	} = $props();
</script>

<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- href is resolved (or fragment) by the caller; the rule cannot see through the prop. -->
<a {href} class="lnk" {...rest}>
	{@render children?.()}
	{label}
</a>

<style>
	/* ── Link — matches design-guideline .lnk ────────────────────────────── */
	.lnk {
		color: var(--accent-ink);
		font-weight: 600;
		text-decoration: none;
		border-bottom: 1px solid color-mix(in srgb, var(--accent-ink) 35%, transparent);
		cursor: pointer;
		transition: border-color 0.12s;
	}

	.lnk:hover {
		border-bottom-color: var(--accent-ink);
	}
</style>
