<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Search, Bell, Sparkles } from '@lucide/svelte';

	export interface Crumb {
		/** Display label. */
		label: string;
		/** Optional href; when omitted the crumb is non-clickable (e.g. the current page when not the last). */
		href?: string;
		/** Hover text. The crumb builder puts the raw id here, so a resolved
		 *  document label stays copyable. */
		title?: string;
	}

	let {
		crumbs = [],
		searchPlaceholder = m.nav_search_placeholder(),
		searchKbds = '⌘K',
		showSearch = true,
		onsearch = () => {},
		assistantLabel = m.assistant_title(),
		showAssistant = true,
		assistantOpen = false,
		onassistant = () => {},
		showNotifications = true,
		notificationsCount = 0,
		onnotifications = () => {},
		children
	}: {
		crumbs?: Crumb[];
		searchPlaceholder?: string;
		/** Key hint shown in the search trigger. */
		searchKbds?: string;
		/** Whether the search trigger renders at all. The trigger must not
		 * render without a working `onsearch` — a shell with no search target
		 * passes `false` instead of showing a dead control. */
		showSearch?: boolean;
		/** Called when the search trigger is clicked / activated. */
		onsearch?: () => void;
		/** Label for the assistant button. */
		assistantLabel?: string;
		/** Whether the assistant button renders at all. Gated on
		 * `me.assistant.access` — accounts without an enabling role get no
		 * workspace-assistant entry point. */
		showAssistant?: boolean;
		/** True while the assistant surface is open; mirrors onto the button's
		 * pressed state and title. */
		assistantOpen?: boolean;
		/** Called when the assistant button is clicked. */
		onassistant?: () => void;
		/** Whether the notifications bell renders at all. The layout passes the
		 * account's in-app notification preference; off removes the bell. */
		showNotifications?: boolean;
		/** Unread count for the notifications badge. `0` hides the badge. */
		notificationsCount?: number;
		/** Called when the notifications button is clicked. */
		onnotifications?: () => void;
		/** Extra content rendered in the right-side cluster, after the bell. */
		children?: import('svelte').Snippet;
	} = $props();

	const hasNotifications = $derived(notificationsCount > 0);
</script>

<header class="top">
	<nav class="crumb" aria-label={m.nav_breadcrumb_aria()}>
		{#each crumbs as crumb, i (crumb.label + i)}
			{#if i > 0}<span class="sep" aria-hidden="true">/</span>{/if}
			{#if crumb.href && i < crumbs.length - 1}
				<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- crumb hrefs arrive from the host layout's crumb builder; the rule cannot see through the model. -->
				<a href={crumb.href} title={crumb.title}>{crumb.label}</a>
			{:else if i === crumbs.length - 1}
				<b title={crumb.title}>{crumb.label}</b>
			{:else}
				<span title={crumb.title}>{crumb.label}</span>
			{/if}
		{/each}
	</nav>

	<div class="actions">
		{#if showSearch}
			<button class="search" onclick={onsearch} type="button">
				<Search size={15} stroke-width={2} />
				<span class="search-text">{searchPlaceholder}</span>
				<kbd>{searchKbds}</kbd>
			</button>
		{/if}

		{#if showAssistant}
			<button
				class="ag"
				onclick={onassistant}
				type="button"
				title={assistantOpen ? m.nav_assistant_close() : m.nav_assistant_open()}
				aria-label={m.nav_assistant_toggle_aria()}
				aria-pressed={assistantOpen}
			>
				<span class="pulse" aria-hidden="true"></span>
				<Sparkles size={14} stroke-width={1.8} />
				{assistantLabel}
			</button>
		{/if}

		{#if showNotifications}
			<button
				class="iconbtn"
				class:with-badge={hasNotifications}
				onclick={onnotifications}
				type="button"
				title={m.nav_notifications()}
				aria-label={m.nav_notifications()}
			>
				<Bell size={18} stroke-width={1.8} />
				{#if hasNotifications}
					<span class="nt-badge" aria-hidden="true"
						>{notificationsCount > 9 ? '9+' : notificationsCount}</span
					>
				{/if}
			</button>
		{/if}

		{@render children?.()}
	</div>
</header>

<style>
	.top {
		grid-area: top;
		height: var(--topbar-h);
		background: var(--surface);
		border-bottom: 1px solid var(--border);
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 0 18px;
	}

	/* ── Breadcrumbs ─────────────────────────────────────── */
	.crumb {
		display: flex;
		align-items: center;
		gap: 9px;
		font-size: 13px;
		color: var(--text-2);
		min-width: 0;
	}

	.crumb a {
		color: var(--text-2);
		text-decoration: none;
	}

	.crumb a:hover {
		color: var(--text);
	}

	.crumb b {
		color: var(--text);
		font-weight: 600;
	}

	.crumb .sep {
		color: var(--text-3);
	}

	/* ── Right-side cluster ──────────────────────────────── */
	/* The auto margin sits on the cluster, not on the search button:
		the bell keeps the top-right corner even when search and the
		assistant pill are hidden. */
	.actions {
		margin-left: auto;
		display: flex;
		align-items: center;
		gap: 14px;
	}

	/* ── Search trigger ───────────────────────────────── */
	.search {
		width: min(420px, 38vw);
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 7px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface-2);
		color: var(--text-3);
		font-size: 13px;
		cursor: text;
		font: inherit;
		text-align: left;
	}

	.search:hover {
		border-color: var(--border-strong);
	}

	.search:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.search-text {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.search kbd {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11px;
		border: 1px solid var(--border);
		border-radius: 5px;
		padding: 1px 6px;
		flex: none;
	}

	/* ── Assistant button ────────────────────────────────── */
	.ag {
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 6px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
		background: var(--surface);
		cursor: pointer;
		flex: none;
	}

	.ag:hover {
		border-color: var(--border-strong);
		color: var(--text);
	}

	.ag:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.ag .pulse {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--ok);
		box-shadow: 0 0 0 3px var(--ok-weak);
		flex: none;
	}

	/* ── Notifications icon button ───────────────────────── */
	.iconbtn {
		width: 34px;
		height: 34px;
		border-radius: 9px;
		display: grid;
		place-items: center;
		color: var(--text-2);
		background: none;
		border: none;
		cursor: pointer;
		position: relative;
		flex: none;
	}

	.iconbtn:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.iconbtn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.nt-badge {
		position: absolute;
		top: 3px;
		right: 3px;
		min-width: 15px;
		height: 15px;
		padding: 0 3px;
		border-radius: var(--r-pill);
		background: var(--danger);
		color: #fff;
		font-size: 9px;
		font-weight: 700;
		line-height: 15px;
		text-align: center;
	}
</style>
