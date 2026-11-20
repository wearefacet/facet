<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Copy, Check } from '@lucide/svelte';
	import '../shared.css';

	/**
	 * CopyCapsule — a mono capsule that copies its value to the clipboard on
	 * click and flashes a check icon. One component serves every
	 * copy-on-click text capsule (emails, phone numbers, and future ones);
	 * the text truncates with ellipsis when narrow.
	 */

	let {
		/** Value to display and to copy to the clipboard. */
		value,
		/** Optional display label. Falls back to `value` when omitted. */
		label,
		...rest
	}: {
		value: string;
		label?: string;
	} = $props();

	let copied = $state(false);

	const display = $derived(label ?? value);

	async function handleCopy() {
		try {
			await navigator.clipboard.writeText(value);
			copied = true;
			setTimeout(() => (copied = false), 1800);
		} catch {
			// Clipboard API unavailable — fail quietly.
			// The user can still select and copy the text manually.
		}
	}
</script>

<button
	class="copy-capsule capsule-shell"
	onclick={handleCopy}
	title={m.doc_copy_capsule_title({ value })}
	aria-label={m.doc_copy_capsule_aria({ value })}
	{...rest}
>
	<span class="capsule-shell-text">{display}</span>
	<span class="capsule-shell-icon" class:copy-capsule-copied={copied} aria-hidden="true">
		{#if copied}
			<Check size={13} class="check" />
		{:else}
			<Copy size={13} />
		{/if}
	</span>
</button>

<style>
	/* CopyCapsule — the shared capsule shell in its neutral mono variant.
	   Shell (shape, border, fill, truncation) comes from `.capsule-shell`. */
	.copy-capsule {
		--capsule-shell-width: 22ch;
		--capsule-shell-font: var(--font-mono);
		--capsule-shell-size: 11.5px;
		--capsule-shell-line: 18px;
	}

	/* Hover deepens the neutral tint before the shell re-mixes it. */
	.copy-capsule:hover {
		--tint: var(--text-2);
	}

	/* The muted icon and its green copied state are copy-specific. */
	.copy-capsule .capsule-shell-icon {
		opacity: 0.6;
		color: var(--text-3);
	}

	.copy-capsule:hover .capsule-shell-icon {
		color: var(--text-2);
	}

	/* Copied state — keep the icon visible and green.
	   The lucide svg carries a plain `.check` class we set ourselves. */
	.copy-capsule-copied :global(.check) {
		color: var(--ok);
	}
</style>
