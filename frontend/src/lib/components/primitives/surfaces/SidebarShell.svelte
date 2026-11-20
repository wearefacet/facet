<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import {
		ChevronLeft,
		Moon,
		Sun,
		ChevronRight,
		User,
		Users,
		LogOut,
		Check,
		KeyRound,
		Webhook
	} from '@lucide/svelte';
	import { DropdownMenu } from 'bits-ui';
	import Logo from '$lib/components/primitives/content/Logo.svelte';
	import { getTheme, toggleTheme } from '$lib/theme.svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { logout } from '$lib/auth.svelte';
	import { roleDocIdToName, humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import type { IdentityProps } from './IdentityProps.js';
	import '../shared.css';

	/**
	 * SidebarShell — the shared rail chrome used by both the live NavPanel and
	 * the BuilderSidebar. Owns the <aside> wrapper, the brand row (logo +
	 * collapse toggle), and the footer (current account + settings/logout menu +
	 * theme toggle). The middle content is provided by the caller via the
	 * `nav` snippet, so both sidebars keep the same outer structure while the
	 * content can differ.
	 */

	let {
		collapsed = false,
		ontoggle = (_c: boolean) => {},
		/** Brand title: text next to the mark, or the alt of the lockup image. */
		title = 'Facet',
		/** Brand subtitle shown under the title (mark variant only). */
		subtitle = '',
		/** `mark` renders the gem with the `title` text beside it; `lockup`
		 * renders the gem and the wordmark baked into one image — the brand
		 * type matches the assets, and no text renders beside it. */
		variant = 'mark',
		account = undefined,
		activeRole = undefined,
		availableRoles = [] as string[],
		connectivity = undefined,
		onSwitchRole = async (_role: string) => {},
		nav,
		children
	}: {
		collapsed?: boolean;
		ontoggle?: (collapsed: boolean) => void;
		title?: string;
		subtitle?: string;
		variant?: 'mark' | 'lockup';
		nav?: import('svelte').Snippet;
		children?: import('svelte').Snippet;
	} & IdentityProps = $props();

	function handleCollapse() {
		ontoggle(!collapsed);
	}

	function handleMySettings() {
		goto(resolve('/Settings'));
	}

	/** The active role may hold API keys and webhooks (the `api` / `webhook`
	 * connectivity channels). Absent list = browser-only: the entries hide
	 * (the backend denies the routes regardless). */
	let canApiKeys = $derived(!connectivity || connectivity.includes('api'));
	let canWebhooks = $derived(!connectivity || connectivity.includes('webhook'));

	async function handleLogout() {
		await logout();
	}

	/** Human-friendly role label (`iam.Roles.production_editor` → `Production Editor`). */
	function roleLabel(role: string): string {
		return humanizeRoleName(roleDocIdToName(role));
	}

	/** Initials for the avatar — first letter of first and last name parts. */
	const accountInitials = $derived.by(() => {
		const name = account?.display_name?.trim();
		if (!name) return '—';
		const parts = name.split(/\s+/).filter(Boolean);
		if (parts.length === 0) return '—';
		if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
		return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
	});

	const theme = $derived(getTheme());
</script>

<aside class="side" class:rail-collapsed={collapsed}>
	<!-- ── Brand ────────────────────────────────────────── -->
	<div class="brand">
		<a class="brand-link" href={resolve('/')} title={m.common_back_to_dashboard()}>
			{#if variant === 'lockup'}
				<span class="mark mark-lockup">
					<!-- The lockup bakes the name into the image, so its alt is
					     the brand title — no text sits next to it to repeat. -->
					<Logo variant="lockup" size="sm" {title} />
				</span>
			{:else}
				<span class="mark">
					<!-- Decorative: the brand name renders as text next to the mark
					     (axe: image-redundant-alt). The link names itself through
					     its title attribute when the rail is collapsed. -->
					<Logo size="sm" title="" />
				</span>
				<div class="tx">
					<b>{title}</b>
					{#if subtitle}<small>{subtitle}</small>{/if}
				</div>
			{/if}
		</a>
		<button
			class="col"
			onclick={handleCollapse}
			title={collapsed ? m.nav_sidebar_expand() : m.nav_sidebar_collapse()}
			aria-label={collapsed ? m.nav_sidebar_expand() : m.nav_sidebar_collapse()}
		>
			{#if collapsed}
				<ChevronRight size={16} stroke-width={1.8} />
			{:else}
				<ChevronLeft size={16} stroke-width={1.8} />
			{/if}
		</button>
	</div>

	<!-- ── Middle content (nav) ─────────────────────────── -->
	{@render nav?.()}

	<!-- ── Footer ──────────────── -->
	<div class="foot">
		<DropdownMenu.Root>
			<DropdownMenu.Trigger
				class="foot-trigger"
				title={account?.display_name ?? m.common_administrator()}
			>
				<span class="av">{accountInitials}</span>
				<div class="who">
					{account?.display_name ?? m.common_administrator()}
					<small>{activeRole ? roleLabel(activeRole) : '—'}</small>
				</div>
			</DropdownMenu.Trigger>
			<DropdownMenu.Portal>
				<DropdownMenu.Content class="foot-menu menu-surface" sideOffset={6} align="start">
					<DropdownMenu.Item
						class="foot-item menu-item"
						onSelect={(e) => {
							e.preventDefault();
							handleMySettings();
						}}
					>
						<User class="foot-item-ic" size={15} stroke-width={1.8} />
						<span>{m.nav_my_settings()}</span>
					</DropdownMenu.Item>
					{#if canApiKeys}
						<DropdownMenu.Item
							class="foot-item menu-item"
							onSelect={(e) => {
								e.preventDefault();
								goto(resolve('/Settings/api-keys'));
							}}
						>
							<KeyRound class="foot-item-ic" size={15} stroke-width={1.8} />
							<span>{m.nav_api_keys()}</span>
						</DropdownMenu.Item>
					{/if}
					{#if canWebhooks}
						<DropdownMenu.Item
							class="foot-item menu-item"
							onSelect={(e) => {
								e.preventDefault();
								goto(resolve('/Settings/webhooks'));
							}}
						>
							<Webhook class="foot-item-ic" size={15} stroke-width={1.8} />
							<span>{m.nav_webhooks()}</span>
						</DropdownMenu.Item>
					{/if}
					<DropdownMenu.Separator class="menu-separator" />
					<!-- The submenu renders only when the account holds two or more
					     roles — with one role there is nothing to switch to. -->
					{#if availableRoles.length >= 2}
						<DropdownMenu.Sub>
							<DropdownMenu.SubTrigger class="foot-item menu-item">
								<Users class="foot-item-ic" size={15} stroke-width={1.8} />
								<span>{m.nav_switch_role()}</span>
								<ChevronRight class="foot-item-chev" size={14} stroke-width={2} />
							</DropdownMenu.SubTrigger>
							<DropdownMenu.Portal>
								<DropdownMenu.SubContent
									class="foot-menu menu-surface"
									sideOffset={6}
									alignOffset={-4}
								>
									{#each availableRoles as role (role)}
										<DropdownMenu.Item
											class="foot-item menu-item"
											disabled={role === activeRole}
											onSelect={(e) => {
												e.preventDefault();
												onSwitchRole(role);
											}}
										>
											{#if role === activeRole}
												<Check class="foot-item-check" size={14} stroke-width={2} />
											{:else}
												<span class="foot-item-check-spacer"></span>
											{/if}
											<span>{roleLabel(role)}</span>
										</DropdownMenu.Item>
									{/each}
								</DropdownMenu.SubContent>
							</DropdownMenu.Portal>
						</DropdownMenu.Sub>
					{/if}
					<DropdownMenu.Item
						class="foot-item menu-item"
						onSelect={(e) => {
							e.preventDefault();
							handleLogout();
						}}
					>
						<LogOut class="foot-item-ic" size={15} stroke-width={1.8} />
						<span>{m.nav_logout()}</span>
					</DropdownMenu.Item>
				</DropdownMenu.Content>
			</DropdownMenu.Portal>
		</DropdownMenu.Root>
		<button class="tgl" title={m.nav_toggle_theme()} onclick={() => toggleTheme()}>
			{#if theme === 'dark'}
				<Sun size={17} stroke-width={1.8} />
			{:else}
				<Moon size={17} stroke-width={1.8} />
			{/if}
		</button>
	</div>
</aside>

{@render children?.()}

<style>
	.side {
		grid-area: side;
		display: flex;
		flex-direction: column;
		min-height: 0;
		overflow: hidden;
		background: var(--surface);
		border-right: 1px solid var(--border);
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 14px 16px;
		border-bottom: 1px solid var(--border);
	}

	.brand-link {
		display: flex;
		align-items: center;
		gap: 10px;
		min-width: 0;
		flex: 1;
		text-decoration: none;
		color: inherit;
		border-radius: var(--r-sm);
	}

	.brand .mark {
		width: 26px;
		height: 26px;
		flex: none;
	}

	/* The lockup image is wide, not square — let the box follow it. */
	.brand .mark-lockup {
		width: auto;
		height: auto;
	}

	.brand .tx {
		min-width: 0;
		overflow: hidden;
		flex: 1;
	}

	.brand b {
		font-family: var(--font-display);
		font-weight: 600;
		font-size: 15px;
		letter-spacing: -0.01em;
		white-space: nowrap;
	}

	.brand small {
		display: block;
		font-size: 11px;
		color: var(--text-3);
		white-space: nowrap;
	}

	.brand .col {
		margin-left: auto;
		color: var(--text-3);
		width: 26px;
		height: 26px;
		display: grid;
		place-items: center;
		border-radius: 7px;
		flex: none;
		border: none;
		background: transparent;
		cursor: pointer;
	}

	.brand .col:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.rail-collapsed .brand .tx,
	.rail-collapsed .brand .mark,
	.rail-collapsed .foot .who,
	.rail-collapsed .foot .tgl {
		display: none;
	}

	.rail-collapsed .brand {
		justify-content: center;
	}

	.foot {
		border-top: 1px solid var(--border);
		padding: 10px 12px;
		display: flex;
		align-items: center;
		gap: 10px;
	}

	:global(.foot-trigger) {
		display: flex;
		align-items: center;
		gap: 10px;
		min-width: 0;
		flex: 1;
		padding: 0;
		border: none;
		background: none;
		font: inherit;
		color: inherit;
		text-align: left;
		cursor: pointer;
		border-radius: var(--r-sm);
	}

	:global(.foot-trigger:hover) {
		background: var(--sunken);
	}

	:global(.foot-trigger[data-state='open']) {
		background: var(--sunken);
	}

	.foot .av {
		width: 28px;
		height: 28px;
		border-radius: 8px;
		background: linear-gradient(135deg, var(--accent), var(--dt-invoice));
		color: #fff;
		display: grid;
		place-items: center;
		font-weight: 600;
		font-size: 12px;
		flex: none;
	}

	.foot .who {
		font-size: 12.5px;
		font-weight: 600;
		line-height: 1.2;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		min-width: 0;
	}

	.foot .who small {
		display: block;
		font-size: 10.5px;
		color: var(--text-3);
		font-weight: 400;
	}

	/* ── Footer menu — surface and item base come from the shared menu classes */
	:global(.foot-menu) {
		min-width: 180px;
		z-index: 200;
	}

	:global(.menu-item.foot-item) {
		gap: 9px;
	}

	:global(.foot-item-ic) {
		flex: none;
		opacity: 0.85;
	}

	:global(.foot-item-chev) {
		margin-left: auto;
		color: var(--text-3);
		flex: none;
	}

	:global(.foot-item-check) {
		flex: none;
		color: var(--accent-ink);
	}

	:global(.foot-item-check-spacer) {
		width: 14px;
		flex: none;
	}

	.tgl {
		margin-left: auto;
		width: 30px;
		height: 30px;
		border-radius: 8px;
		display: grid;
		place-items: center;
		color: var(--text-2);
		border: none;
		background: transparent;
		cursor: pointer;
	}

	.tgl:hover {
		background: var(--sunken);
		color: var(--text);
	}
</style>
