<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	BrandMark — the Facet diamond logo.
	Thin wrapper around `Display/Logo` so auth screens can use the same mark
	with the same API. Kept as its own component because several auth screens
	import it directly.
-->
<script lang="ts">
	import Logo from '../../primitives/content/Logo.svelte';

	let {
		size = 32,
		title = 'Facet'
	}: {
		size?: number;
		title?: string;
	} = $props();

	// Map the BrandMark pixel size to a Logo preset, defaulting to the nearest.
	const preset = $derived(
		size <= 16 ? 'xs' : size <= 24 ? 'sm' : size <= 32 ? 'md' : size <= 48 ? 'lg' : 'xl'
	);
</script>

<Logo size={preset} {title} />
