<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		active = false,
		children,
		...rest
	}: {
		/** Whether this pane is visible. */
		active?: boolean;
		children?: import('svelte').Snippet;
	} = $props();
</script>

<div class="tabpane" class:tabpane-on={active} role="tabpanel" {...rest}>
	{@render children?.()}
</div>

<style>
	/* ── TabPane — matches .tabpane / .tabpane.on ────────────────────────── */
	.tabpane {
		display: none;
	}

	.tabpane-on {
		display: block;
		animation: tab-fade 0.2s ease;
	}

	@keyframes tab-fade {
		from {
			opacity: 0;
			transform: translateY(4px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}
</style>
