<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { getDomainLabel } from '$lib/navState.svelte';
	import { resolve } from '$app/paths';
	import type { SaveFlashStatus } from '$lib/utils/saveFlash.svelte.js';
	import * as m from '$lib/paraglide/messages';

	let {
		domain,
		name,
		color,
		draft = false,
		sourceDomain,
		flash,
		tab,
		doctypeCount,
		editorCount,
		grantCount,
		contextSetCount,
		checkIssueCount,
		onsave,
		ontabselect,
		crumb
	}: {
		/** Domain id — breadcrumb label source and the mono id chip. */
		domain: string;
		/** Display name for the page title (parent falls back to the domain id). */
		name: string;
		/** Accent color for the identity tint mark (undefined → var(--accent)). */
		color?: string;
		/** Draft domain — shows the draft badge, source line, and the check tab. */
		draft?: boolean;
		/** Domain the draft was branched from; shows the source line when set. */
		sourceDomain?: string;
		/** Save-flash state from the parent's `createSaveFlash()` (status + message). */
		flash: { status: SaveFlashStatus; message?: string };
		/** Active tab — URL-driven via the Builder route. */
		tab: 'overview' | 'doctypes' | 'editors' | 'grants' | 'check';
		doctypeCount: number;
		/** Count of `core.DomainEditor` grant rows on this domain. */
		editorCount: number;
		grantCount: number;
		contextSetCount: number;
		/** Draft check issues; renders the warn count next to the check tab. */
		checkIssueCount: number;
		onsave: () => void;
		/** Tab switches navigate via `goto` in the parent so the URL reflects
		 *  the user's location and browser back/forward works. */
		ontabselect: (tab: 'overview' | 'doctypes' | 'editors' | 'grants' | 'check') => void;
		/** Header crumb link — label plus resolved href. When unset, the crumb
		 *  targets the Builder landing, the draft editor's home surface. */
		crumb?: { label: string; href: string };
	} = $props();
</script>

<div class="dhead">
	<div class="crumb">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- crumb.href is resolved by the caller; the rule cannot see through the prop. -->
		<a href={crumb?.href ?? resolve('/Builder')}>{crumb?.label ?? m.nav_builder()}</a>
		<span class="sep">/</span>
		<b>{getDomainLabel(domain)}</b>
	</div>
	<div class="idrow">
		<span class="fx" style="--tint:{color ?? 'var(--accent)'}"></span>
		<h1>{name}</h1>
		<span class="dom">{domain}</span>
		{#if draft}
			<span class="draftbadge">{m.configure_domains_draft_badge()}</span>
			{#if sourceDomain}
				<span class="src">{m.configure_domains_draft_source({ name: sourceDomain })}</span>
			{/if}
		{/if}
		<span class="sp"></span>
		<button
			class="save-btn"
			class:saved={flash.status === 'saved'}
			class:error={flash.status === 'error'}
			onclick={onsave}
			disabled={flash.status === 'saving'}
			title={flash.message ?? ''}
		>
			{#if flash.status === 'saving'}
				{m.common_saving()}
			{:else if flash.status === 'saved'}
				{m.common_saved()}
			{:else if flash.status === 'error'}
				{flash.message
					? m.configure_save_failed_reason({ message: flash.message })
					: m.configure_save_failed()}
			{:else}
				{m.common_save()}
			{/if}
		</button>
	</div>
	<div class="dtabs">
		<button class:on={tab === 'overview'} onclick={() => ontabselect('overview')}>
			{m.configure_domains_tab_overview()}
		</button>
		<button class:on={tab === 'doctypes'} onclick={() => ontabselect('doctypes')}>
			{m.nav_group_doctypes()}<span class="n">{doctypeCount}</span>
		</button>
		<button class:on={tab === 'editors'} onclick={() => ontabselect('editors')}>
			{m.configure_domains_tab_editors()}<span class="n">{editorCount}</span>
		</button>
		<button class:on={tab === 'grants'} onclick={() => ontabselect('grants')}>
			{m.configure_domains_tab_grants()}<span class="n">{grantCount + contextSetCount}</span>
		</button>
		{#if draft}
			<button class:on={tab === 'check'} onclick={() => ontabselect('check')}>
				{m.configure_domains_tab_check()}{#if checkIssueCount > 0}<span class="n warn"
						>{checkIssueCount}</span
					>{/if}
			</button>
		{/if}
	</div>
</div>

<style>
	/* ── Header ─────────────────────────────────────────────────────────── */
	.dhead {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 18px 24px 0;
		background: var(--surface);
		border-bottom: 1px solid var(--border);
	}

	.crumb {
		display: flex;
		align-items: center;
		gap: 7px;
		font-size: 12px;
		color: var(--text-3);
	}
	.crumb a {
		color: var(--text-2);
		text-decoration: none;
	}
	.crumb a:hover {
		color: var(--text);
	}
	.crumb .sep {
		opacity: 0.5;
	}
	.crumb b {
		color: var(--text);
		font-weight: 600;
	}

	.idrow {
		display: flex;
		align-items: center;
		gap: 12px;
	}
	.idrow .fx {
		width: 18px;
		height: 18px;
		border-radius: 5px;
		background: var(--tint);
		flex: none;
	}
	.idrow h1 {
		font-family: var(--font-display);
		font-size: 22px;
		font-weight: 600;
		letter-spacing: -0.01em;
		margin: 0;
	}
	.idrow .dom {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: 5px;
		padding: 2px 8px;
	}
	.idrow .draftbadge {
		font-size: 10.5px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border-radius: 4px;
		padding: 2px 7px;
	}
	.idrow .src {
		font-size: 11.5px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}
	.idrow .sp {
		flex: 1;
	}
	.save-btn {
		font: inherit;
		font-size: 12.5px;
		font-weight: 600;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border: 1px solid transparent;
		border-radius: var(--r);
		padding: 6px 14px;
		cursor: pointer;
		transition:
			background 0.12s,
			border-color 0.12s;
	}
	.save-btn:hover {
		border-color: var(--accent);
	}
	.save-btn.saved {
		color: var(--text-2);
		background: var(--sunken);
	}
	.save-btn:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}
	.save-btn.error {
		color: var(--danger, #dc2626);
		background: var(--danger-weak, transparent);
		border-color: var(--danger, #dc2626);
	}

	.dtabs {
		display: flex;
		gap: 2px;
		margin-top: 6px;
	}
	.dtabs button {
		font: inherit;
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-3);
		background: none;
		border: none;
		border-bottom: 2px solid transparent;
		padding: 8px 14px;
		cursor: pointer;
		display: inline-flex;
		align-items: center;
		gap: 7px;
		transition: color 0.12s;
	}
	.dtabs button:hover {
		color: var(--text);
	}
	.dtabs button.on {
		color: var(--text);
		border-bottom-color: var(--accent);
	}
	.dtabs button .n {
		font-size: 10.5px;
		font-family: var(--font-mono);
		background: var(--sunken);
		border-radius: 4px;
		padding: 1px 6px;
		color: var(--text-3);
	}
	.dtabs button.on .n {
		background: var(--accent-weak);
		color: var(--accent-ink);
	}
	.dtabs button .n.warn {
		background: var(--warn-weak, rgba(217, 119, 6, 0.12));
		color: var(--warn);
	}
	.dtabs button.on .n.warn {
		background: var(--warn);
		color: var(--on-accent, #1a1a1a);
	}
</style>
