<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		value,
		...rest
	}: {
		/** CSS color value to display (hex, rgb, hsl, etc.). */
		value: string;
	} = $props();
</script>

<span class="color-swatch" {...rest}>
	<span class="color-swatch-chip" style={`background:${value}`}></span>
	<span class="color-swatch-code">{value}</span>
</span>

<style>
	.color-swatch {
		display: inline-flex;
		align-items: center;
		gap: 6px;
	}

	.color-swatch-chip {
		width: 14px;
		height: 14px;
		border-radius: 3px;
		border: 1px solid var(--border-strong);
		flex: none;
	}

	.color-swatch-code {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-2);
	}
</style>
