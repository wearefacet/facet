<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DropdownMenu from './DropdownMenu.svelte';
	import type { MenuItem } from './DropdownMenu.svelte';

	type Variant = 'primary' | 'secondary' | 'danger' | 'ghost';
	type Size = 'sm' | 'md' | 'lg';

	let {
		variant = 'primary',
		size = 'md',
		disabled = false,
		loading = false,
		caret = false,
		href,
		label,
		children,
		iconLeft,
		iconRight,
		onclick,
		type = 'button',
		/** When provided with `caret`, renders a dropdown menu triggered by the caret area. */
		menu,
		...rest
	}: {
		variant?: Variant;
		size?: Size;
		disabled?: boolean;
		loading?: boolean;
		/** Show a small dropdown-arrow indicator on the right (for split-button / submenu triggers). */
		caret?: boolean;
		/** When provided the button renders as an `<a>` element. */
		href?: string;
		/** Button label text (alternative to children snippet). */
		label?: string;
		/** Native `title` tooltip forwarded to the rendered element. */
		title?: string;
		children?: import('svelte').Snippet;
		/** Icon rendered to the left of the label / children. */
		iconLeft?: import('svelte').Snippet;
		/** Icon rendered to the right of the label / children (inside the content area, before caret). */
		iconRight?: import('svelte').Snippet;
		onclick?: (e: MouseEvent | KeyboardEvent) => void;
		type?: 'button' | 'submit' | 'reset';
		/** Dropdown menu items shown when `caret` is true and this is provided. When set,
			the whole button is the menu trigger — the click opens the menu, so `onclick`
			does not fire. Not combinable with `href`. The trigger wraps this element (one
			`<button>`), never the other way round: a nested DropdownMenu.Trigger inside
			the button would emit `<button><button>`, which breaks SSR hydration (see
			doc/frontend/bits-ui.md). */
		menu?: MenuItem[];
	} = $props();

	const isDisabled = $derived(disabled || loading);

	const hasMenu = $derived(Boolean(caret && menu && menu.length > 0));

	const cls = $derived(
		['btn', `btn-${variant}`, `btn-${size}`, loading ? 'btn-loading' : ''].filter(Boolean).join(' ')
	);

	// `menu` makes the whole element the menu trigger; an anchor would both open
	// the menu and navigate on one click. Fail loud instead of silently picking one.
	// svelte-ignore state_referenced_locally -- a mount-time contract check on the initial props is the point.
	if (menu && menu.length > 0 && href) {
		throw new Error(
			'Button: `menu` cannot be combined with `href` — render the menu trigger as a sibling of the link instead.'
		);
	}
</script>

{#snippet btnContent()}
	{#if loading}
		<span class="btn-spinner" aria-hidden="true"></span>
	{/if}
	{@render iconLeft?.()}
	<span class="btn-content">
		{@render children?.()}
		{label}
	</span>
	{@render iconRight?.()}
{/snippet}

{#if hasMenu}
	{#snippet menuTrigger(triggerProps: Record<string, unknown>)}
		<button
			{...triggerProps}
			{...rest}
			{type}
			class={cls}
			{disabled}
			aria-busy={loading ? 'true' : undefined}
		>
			{@render btnContent()}
			<span class="btn-caret-sep"></span>
			<span class="btn-caret" aria-hidden="true">▼</span>
		</button>
	{/snippet}
	<DropdownMenu label={label ?? ''} items={menu || []} align="end" triggerChild={menuTrigger} />
{:else if href}
	<!-- svelte-ignore a11y_missing_attribute -->
	<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- href is a resolved pathname (or download URL) supplied by the caller; the rule cannot see through the prop. -->
	<a {href} class={cls} aria-disabled={isDisabled ? 'true' : undefined} role="button" {...rest}>
		{@render btnContent()}
		{#if caret}
			<span class="btn-caret" aria-hidden="true">▼</span>
		{/if}
	</a>
{:else}
	<button
		{type}
		class={cls}
		{disabled}
		aria-busy={loading ? 'true' : undefined}
		onclick={isDisabled ? undefined : onclick}
		{...rest}
	>
		{@render btnContent()}
		{#if caret}
			<span class="btn-caret" aria-hidden="true">▼</span>
		{/if}
	</button>
{/if}

<style>
	/* ── Button base ────────────────────────────────────────────────────── */
	.btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 7px;
		font-family: var(--font-sans);
		font-weight: 600;
		font-size: 13px;
		line-height: 1;
		border: 1px solid var(--border);
		border-radius: var(--r);
		cursor: pointer;
		user-select: none;
		white-space: nowrap;
		text-decoration: none;
		transition:
			background 0.12s,
			box-shadow 0.12s,
			opacity 0.12s;
	}

	.btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.btn:disabled,
	.btn[aria-disabled='true'] {
		opacity: 0.45;
		cursor: not-allowed;
		pointer-events: none;
	}

	/* ── Loading state ──────────────────────────────────────────────────── */
	.btn-loading {
		pointer-events: none;
	}

	.btn-spinner {
		width: 1em;
		height: 1em;
		border: 2px solid currentColor;
		border-right-color: transparent;
		border-radius: 50%;
		animation: btn-spin 0.6s linear infinite;
		flex-shrink: 0;
	}

	@keyframes btn-spin {
		to {
			transform: rotate(360deg);
		}
	}

	/* ── Content & caret ────────────────────────────────────────────────── */
	.btn-content {
		display: inline-flex;
		align-items: center;
		gap: 6px;
	}

	.btn-caret {
		font-size: 0.6em;
		line-height: 1;
		margin-left: 2px;
		opacity: 0.7;
	}

	/* Separator between button content and dropdown caret area */
	.btn-caret-sep {
		width: 1px;
		height: 16px;
		background: currentColor;
		opacity: 0.15;
		margin-left: 6px;
		align-self: center;
	}

	/* ── Sizes ──────────────────────────────────────────────────────────── */
	.btn-sm {
		font-size: 11.5px;
		padding: 5px 9px;
		border-radius: var(--r-sm);
	}

	.btn-md {
		padding: 8px 13px;
	}

	.btn-lg {
		font-size: 15px;
		padding: 10px 20px;
	}

	/* ── Variants ────────────────────────────────────────────────────────── */
	/* Primary (accent fill) — matches guideline .btn.pri */
	.btn-primary {
		background: var(--accent);
		color: var(--on-accent);
		border-color: var(--accent);
	}

	.btn-primary:hover:not(:disabled) {
		background: var(--accent-press);
		border-color: var(--accent-press);
	}

	/* Secondary (default outline) — matches guideline default .btn */
	.btn-secondary {
		background: var(--surface);
		color: var(--text);
		border-color: var(--border);
	}

	.btn-secondary:hover:not(:disabled) {
		background: var(--surface-2);
		border-color: var(--border-strong);
	}

	/* Danger — matches guideline .btn.dn */
	.btn-danger {
		background: var(--danger);
		color: #fff;
		border-color: var(--danger);
	}

	.btn-danger:hover:not(:disabled) {
		opacity: 0.88;
	}

	/* Ghost (borderless, muted) */
	.btn-ghost {
		background: transparent;
		color: var(--text-2);
		border-color: transparent;
	}

	.btn-ghost:hover:not(:disabled) {
		background: var(--surface-2);
		color: var(--text);
	}
</style>
