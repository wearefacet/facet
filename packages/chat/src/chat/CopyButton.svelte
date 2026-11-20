<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	CopyButton — copy-to-clipboard with "Copied" feedback.
	Ported from the main application's `primitives/data/CopyButton` down to
	the surfaces the chat package uses (the quiet icon-only button on chat
	turns and thought blocks), with the package's plain messages module in
	place of paraglide.
-->
<script lang="ts">
	import * as m from '../messages.js';
	import Copy from '@lucide/svelte/icons/copy';
	import Check from '@lucide/svelte/icons/check';
	import { copyText } from './clipboard.js';

	let {
		value,
		label = m.common_copy(),
		copiedLabel = m.common_copied(),
		variant = 'outline',
		size = 'md',
		title,
		oncopied,
		iconOnly = false
	}: {
		/** The text to place on the clipboard. */
		value: string;
		/** Label while idle. */
		label?: string;
		/** Label during the copied confirmation window. */
		copiedLabel?: string;
		/** `outline` — bordered surface button; `ghost` — quiet text-style button; `primary` — accent fill. */
		variant?: 'outline' | 'ghost' | 'primary';
		/** `sm` fits compact rows and panels; `md` is the dialog default. */
		size?: 'sm' | 'md';
		/** Native `title` tooltip; falls back to the current label. */
		title?: string;
		/** Called after a successful copy. */
		oncopied?: () => void;
		/** Icon-only mode: no visible label; `title` (or `label`) is the
		 * accessible name, the copied feedback is the icon flip alone. */
		iconOnly?: boolean;
	} = $props();

	/** The copied confirmation window — long enough to read, short enough to retry. */
	const FEEDBACK_MS = 1800;

	let copied = $state(false);
	let timer: ReturnType<typeof setTimeout> | undefined;

	$effect(() => () => clearTimeout(timer));

	async function handleCopy(): Promise<void> {
		if (!value) return;
		const ok = await copyText(value);
		if (!ok) return;
		copied = true;
		oncopied?.();
		clearTimeout(timer);
		timer = setTimeout(() => (copied = false), FEEDBACK_MS);
	}
</script>

<button
	type="button"
	class="copy-btn"
	class:copied
	class:copy-ghost={variant === 'ghost'}
	class:copy-primary={variant === 'primary'}
	class:copy-sm={size === 'sm'}
	class:copy-icon={iconOnly}
	onclick={handleCopy}
	{title}
	aria-label={iconOnly ? (title ?? label) : undefined}
>
	{#if copied}
		<Check size={14} stroke-width={2} aria-hidden="true" />
	{:else}
		<Copy size={14} stroke-width={1.8} aria-hidden="true" />
	{/if}
	{#if !iconOnly}<span class="copy-label">{copied ? copiedLabel : label}</span>{/if}
</button>

<style>
	.copy-btn {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		flex: none;
		padding: 0 14px;
		height: 32px;
		border: 1px solid var(--facet-border-strong);
		border-radius: var(--facet-r);
		background: var(--facet-surface);
		color: var(--facet-text);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		transition:
			background 0.12s,
			border-color 0.12s,
			color 0.12s;
	}

	.copy-btn:hover {
		background: var(--facet-surface-2);
	}

	.copy-btn.copied {
		border-color: var(--facet-ok);
		background: var(--facet-ok-weak);
		color: var(--facet-ok);
	}

	.copy-btn:focus-visible {
		outline: 2px solid var(--facet-accent-ink);
		outline-offset: 2px;
	}

	.copy-sm {
		height: 26px;
		padding: 0 10px;
		font-size: 11.5px;
		gap: 5px;
	}

	.copy-ghost {
		display: inline-flex;
		align-items: center;
		background: none;
		border: none;
		height: auto;
		padding: 2px;
		color: var(--facet-text-3);
		font-size: 12px;
		font-weight: 500;
	}

	.copy-ghost:hover {
		background: none;
		color: var(--facet-text);
	}

	.copy-ghost.copy-sm {
		padding: 2px;
	}

	.copy-primary {
		border-color: var(--facet-accent);
		background: var(--facet-accent);
		color: var(--facet-on-accent);
	}

	.copy-primary:hover {
		background: var(--facet-accent-press);
		border-color: var(--facet-accent-press);
	}

	.copy-primary.copied {
		border-color: var(--facet-ok);
		background: var(--facet-ok-weak);
		color: var(--facet-ok);
	}

	/* Icon-only — quiet square button for dense surfaces (chat turns). */
	.copy-icon {
		width: 24px;
		height: 24px;
		padding: 0;
		justify-content: center;
		border: none;
		background: none;
		color: var(--facet-text-3);
	}
	.copy-icon:hover {
		background: var(--facet-sunken);
		color: var(--facet-text);
	}
	.copy-icon.copied {
		border-color: transparent;
		background: none;
		color: var(--facet-ok);
	}
	.copy-icon.copy-sm {
		width: 20px;
		height: 20px;
	}

	.copy-label {
		white-space: nowrap;
	}
</style>
