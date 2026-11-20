<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		label,
		children,
		...rest
	}: {
		/** Tag text (alternative to children snippet). */
		label?: string;
		children?: import('svelte').Snippet;
	} = $props();
</script>

<span class="tag" {...rest}>
	{@render children?.()}
	{label}
</span>

<style>
	/* ── Tag — matches table.html .tag ───────────────────────────────────── */
	.tag {
		display: inline-flex;
		align-items: center;
		font-size: 11.5px;
		color: var(--text-2);
		background: var(--sunken);
		border-radius: var(--r-sm);
		padding: 2px 8px;
		font-weight: 500;
		white-space: nowrap;
	}
</style>
