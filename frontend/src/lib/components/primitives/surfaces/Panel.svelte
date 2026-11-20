<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		padding = true,
		children,
		...rest
	}: {
		/** Whether to apply default padding around content. Defaults to `true`. */
		padding?: boolean;
		children?: import('svelte').Snippet;
	} = $props();
</script>

<div class="panel" class:panel-nopad={!padding} role="region" {...rest}>
	{@render children?.()}
</div>

<style>
	/* ── Panel — matches design-guideline .panel ─────────────────────────── */
	.panel {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		padding: 20px 22px;
	}

	.panel-nopad {
		padding: 0;
	}
</style>
