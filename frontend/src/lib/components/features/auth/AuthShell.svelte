<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	AuthShell — the shared full-screen auth surface.

	Every public auth screen (login, consent, MFA challenge, enrollment,
	forced password change, reset request / confirm) centers one card on the
	gold-tinted ground. This component owns that chrome: the background, the
	card, the standard header (brand mark, rounded icon, title, sub), the
	inline error banner, and the footer-link row. The body and any footer
	links come from the caller.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import BrandMark from './BrandMark.svelte';

	let {
		maxWidth = 420,
		gap = 20,
		subMaxWidth = 320,
		icon,
		iconTint = 'accent',
		title,
		sub,
		error,
		header,
		footer,
		children
	}: {
		/** Card max width in px. */
		maxWidth?: number;
		/** Card gap in px. */
		gap?: number;
		/** Max width of the sub line in px. */
		subMaxWidth?: number;
		/** Content of the 48px round icon above the title; omit for no icon. */
		icon?: Snippet;
		/** Icon circle tint — `warn` for the forced-change surface. */
		iconTint?: 'accent' | 'warn';
		/** Heading text; a snippet may wrap parts of it in styled spans. */
		title?: Snippet | string;
		/** Sub line; a snippet for multi-part copy. */
		sub?: Snippet | string;
		/** Inline error banner (danger chrome, role=alert). */
		error?: string;
		/** Replaces the default header entirely (e.g. a horizontal brand row). */
		header?: Snippet;
		/** Footer row of quiet link buttons. */
		footer?: Snippet;
		children?: Snippet;
	} = $props();
</script>

<div class="auth-screen">
	<div class="auth-card" style:max-width="{maxWidth}px" style:gap="{gap}px">
		{#if header}
			{@render header()}
		{:else}
			<header class="auth-head">
				<BrandMark size={40} />
				{#if icon}
					<div class="auth-icon" class:auth-icon-warn={iconTint === 'warn'} aria-hidden="true">
						{@render icon()}
					</div>
				{/if}
				{#if title}
					<h1 class="auth-title">
						{#if typeof title === 'string'}{title}{:else}{@render title()}{/if}
					</h1>
				{/if}
				{#if sub}
					<div class="auth-sub" style:max-width="{subMaxWidth}px">
						{#if typeof sub === 'string'}{sub}{:else}{@render sub()}{/if}
					</div>
				{/if}
			</header>
		{/if}

		{#if error}
			<div class="auth-error" role="alert">
				<span aria-hidden="true">!</span>
				{error}
			</div>
		{/if}

		{@render children?.()}

		{#if footer}
			<div class="auth-links">
				{@render footer()}
			</div>
		{/if}
	</div>
</div>

<style>
	.auth-screen {
		min-height: 100vh;
		min-height: 100svh;
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 24px;
		background:
			radial-gradient(110% 70% at 50% -10%, var(--accent-weak) 0%, transparent 55%), var(--ground);
	}

	.auth-card {
		width: 100%;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-2);
		padding: 32px 30px 28px;
		display: flex;
		flex-direction: column;
	}

	.auth-head {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 10px;
		text-align: center;
	}

	.auth-icon {
		display: grid;
		place-items: center;
		width: 48px;
		height: 48px;
		border-radius: 50%;
		background: var(--accent-weak);
		color: var(--accent-ink);
		margin-top: 2px;
	}

	.auth-icon-warn {
		background: var(--warn-weak);
		color: var(--warn);
	}

	.auth-title {
		font-family: var(--font-display);
		font-weight: 600;
		font-size: 19px;
		letter-spacing: -0.01em;
		color: var(--text);
		margin: 0;
	}

	.auth-sub {
		font-size: 12.5px;
		color: var(--text-2);
		line-height: 1.5;
	}

	.auth-error {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 9px 11px;
		border-radius: var(--r);
		background: var(--danger-weak);
		color: var(--danger);
		font-size: 12.5px;
		border: 1px solid color-mix(in srgb, var(--danger) 30%, transparent);
	}

	.auth-error > span:first-child {
		display: grid;
		place-items: center;
		width: 16px;
		height: 16px;
		border-radius: 50%;
		background: var(--danger);
		color: #fff;
		font-size: 10px;
		font-weight: 700;
		flex: none;
	}

	.auth-links {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		flex-wrap: wrap;
		font-size: 12.5px;
		color: var(--text-3);
	}

	/* Footer link buttons are authored by the callers; style them here so the
	   whole chrome (including this row) stays consistent. */
	.auth-links :global(.link-btn) {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		font: inherit;
		font-size: 12.5px;
		color: var(--accent-ink);
		background: none;
		border: none;
		padding: 0;
		cursor: pointer;
		text-decoration: none;
		transition: opacity 0.12s;
	}

	.auth-links :global(.link-btn:hover) {
		opacity: 0.7;
	}

	.auth-links :global(.link-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
		border-radius: var(--r-sm);
	}

	@media (prefers-reduced-motion: reduce) {
		* {
			transition: none !important;
		}
	}
</style>
