<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { ExternalLink } from '@lucide/svelte';
	import '../shared.css';

	let {
		href,
		label,
		...rest
	}: {
		/** The URL to open in a new tab. */
		href: string;
		/** Optional display label. Falls back to `href` when omitted. */
		label?: string;
	} = $props();

	const display = $derived(label ?? href);
</script>

<a
	class="url-link capsule-shell"
	{href}
	target="_blank"
	rel="noopener noreferrer external"
	title={m.doc_open_link_title({ href })}
	{...rest}
>
	<span class="capsule-shell-text">{display}</span>
	<span class="capsule-shell-icon" aria-hidden="true">
		<ExternalLink size={13} />
	</span>
</a>

<style>
	/* UrlLink — the shared capsule shell in its accent-ink link variant.
	   Shell (shape, border, fill, truncation, hover) comes from
	   `.capsule-shell`. */
	.url-link {
		--tint: var(--accent-ink);
		--capsule-shell-ink: var(--accent-ink);
	}
</style>
