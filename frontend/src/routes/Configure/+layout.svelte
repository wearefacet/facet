<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import Topbar from '$lib/components/primitives/surfaces/Topbar.svelte';
	import SidebarShell from '$lib/components/primitives/surfaces/SidebarShell.svelte';
	import type { Crumb } from '$lib/components/primitives/surfaces/Topbar.svelte';
	import type { NavDomain } from '$lib/navTypes';
	import {
		ScrollText,
		Boxes,
		Users,
		UserCog,
		KeyRound,
		AppWindow,
		Coins,
		ListTree,
		Paperclip,
		Settings2,
		Wrench,
		ArrowLeft
	} from '@lucide/svelte';
	import { Tooltip } from 'bits-ui';
	import * as m from '$lib/paraglide/messages';
	import CommandPalette from '$lib/components/features/search/CommandPalette.svelte';
	import type { PaletteCommand } from '$lib/components/features/search/searchGroups.js';

	/**
	 * Configure shell layout.
	 *
	 * One sidebar, five sections (CONFIGURE / APPLICATIONS / ACCESS / SYSTEM /
	 * PLATFORM) per the configure UX brief. The PLATFORM section holds
	 * operator-level technical surfaces and renders only for roles with
	 * wildcard read (the admin marker). The top bar owns context state only —
	 * no draft controls live here, those belong to the builder shell. This
	 * layout is URL-driven: any `/Configure/*` path renders this shell.
	 * Published domains are editable in place; drafts route to the builder
	 * shell (`/Builder/:id`) and leave this shell entirely.
	 *
	 * The sidebar reuses the shared `SidebarShell` chrome (brand, collapse,
	 * user footer) exactly like the live and builder shells — only the middle
	 * nav content differs, provided via the `nav` snippet below.
	 */

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	import { getActiveRole, getAvailableRoles } from '$lib/role.svelte';
	import { switchActiveRole } from '$lib/auth.svelte';
	import { can } from '$lib/permissions.svelte.js';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import { bellProps } from '$lib/notifications.svelte';
	import { getAssistantOpen, toggleAssistantOpen } from '$lib/assistantOpen.svelte';

	type LayoutData = {
		domains: NavDomain[];
		account?: { id: string; display_name: string } | null;
		activeRole?: string | null;
		availableRoles?: string[];
		connectivity?: string[] | null;
		/** Workspace-assistant availability (`me.assistant.access`) — gates the
		 * top-bar pill. The floating window is mounted at the root layout. */
		assistantAccess?: boolean;
		/** Configured assistant display name (`me.assistant.name`). */
		assistantName?: string;
	};

	/** The static, paramless Configure routes the sidebar links to. */
	type ConfigureNavRoute =
		| '/Configure/domains'
		| '/Configure/apps'
		| '/Configure/access/roles'
		| '/Configure/access/assignments'
		| '/Configure/access/accounts'
		| '/Configure/currencies'
		| '/Configure/audit'
		| '/Configure/platform/indexes'
		| '/Configure/platform/maintenance'
		| '/Configure/platform/artifacts'
		| '/Configure/platform/settings';

	/** One sidebar row — `route` doubles as the active-highlight key. */
	interface ConfigureNavItem {
		label: string;
		route: ConfigureNavRoute;
		icon: typeof Boxes;
		/** Computed after the pathname match below. */
		active?: boolean;
	}

	/** One palette route entry — `icon` is the sidebar row's mark, kebab-case. */
	interface ConfigurePaletteRoute {
		id: string;
		label: string;
		route: ConfigureNavRoute;
		icon?: string;
	}

	// Active/available roles from the reactive store so the Switch Role submenu
	// updates immediately, falling back to the server snapshot before hydration.
	const activeRole = $derived(getActiveRole() ?? data.activeRole ?? null);
	const availableRoles = $derived(getAvailableRoles() ?? data.availableRoles ?? []);

	const sections = $derived.by(() => {
		const pathname = page.url.pathname;
		// Highlight rule: a section is active when the current pathname starts
		// with the section's root. Sub-items inherit highlight from their
		// parent section.
		const all: { label: string; items: ConfigureNavItem[] }[] = [
			{
				label: m.configure_section_configure(),
				items: [
					{ label: m.configure_domains_list_title(), route: '/Configure/domains', icon: Boxes }
				]
			},
			{
				label: m.configure_section_apps(),
				items: [{ label: m.configure_apps_title(), route: '/Configure/apps', icon: AppWindow }]
			},
			{
				label: m.configure_section_access(),
				items: [
					{ label: m.configure_roles_title(), route: '/Configure/access/roles', icon: KeyRound },
					{
						label: m.configure_assignments_title(),
						route: '/Configure/access/assignments',
						icon: Users
					},
					{
						label: m.configure_accounts_title(),
						route: '/Configure/access/accounts',
						icon: UserCog
					}
				]
			},
			{
				label: m.configure_section_system(),
				items: [
					{ label: m.configure_currencies_nav(), route: '/Configure/currencies', icon: Coins },
					{ label: m.audit_page_header(), route: '/Configure/audit', icon: ScrollText }
				]
			}
		];
		// PLATFORM - operator-level technical surfaces (settings, index
		// status, artifact browsing). Wildcard read is the admin marker, so
		// the whole section stays hidden for every other role. The settings
		// item is additionally gated on its own doctype read: the settings
		// expose infrastructure details (SMTP host, assistant endpoint) that
		// app-facing roles do not need, and the seed carves
		// core.SystemSettings out of the editor/viewer wildcard read — an
		// ungated item would render a 403 page for them (the permission
		// manifest aggregates `read *.*` without resolving except lists).
		const platform: { label: string; items: ConfigureNavItem[] } = {
			label: m.configure_section_platform(),
			items: [
				...(can('core.SystemSettings', 'read')
					? [
							{
								label: m.system_settings_nav(),
								route: '/Configure/platform/settings' as const,
								icon: Settings2
							}
						]
					: []),
				{
					label: m.platform_indexes_nav(),
					route: '/Configure/platform/indexes',
					icon: ListTree
				},
				{
					label: m.platform_maintenance_nav(),
					route: '/Configure/platform/maintenance',
					icon: Wrench
				},
				{
					label: m.platform_artifacts_nav(),
					route: '/Configure/platform/artifacts',
					icon: Paperclip
				}
			]
		};
		return all.concat(can('*.*', 'read') ? [platform] : []).map((section) => ({
			...section,
			items: section.items.map((item) => ({
				...item,
				active:
					item.route === '/Configure/audit'
						? pathname.startsWith(item.route)
						: pathname === item.route || pathname.startsWith(item.route + '/')
			}))
		}));
	});

	const crumbs = $derived<Crumb[]>(buildCrumbs(page.url.pathname));

	function buildCrumbs(pathname: string): Crumb[] {
		const segs = pathname.split('/').filter(Boolean);
		if (segs.length <= 1) return [{ label: 'Configure' }];
		return segs.map((seg, i) => ({
			label: seg.charAt(0).toUpperCase() + seg.slice(1),
			href: i < segs.length - 1 ? '/' + segs.slice(0, i + 1).join('/') : undefined
		}));
	}

	function navigate(route: ConfigureNavRoute) {
		goto(resolve(route));
	}

	// Exit configure mode — return to the live app.
	function handleExit() {
		goto(resolve('/'));
	}

	// Command palette. There is no nav model here on purpose: the palette's
	// Navigate/Recent/Records groups stay empty, and this command list — the
	// sidebar sections plus the exit — carries the surface instead. Each
	// entry reuses the sidebar's own navigation helper, and the PLATFORM
	// rows keep the sidebar's gates: wildcard read is the admin marker for
	// the section, and the settings item adds its doctype read on top (see
	// the `sections` derivation above for why).
	let paletteOpen = $state(false);

	const paletteCommands = $derived.by<PaletteCommand[]>(() => {
		// The icons reuse the sidebar rows' own Lucide marks (kebab-case), so a
		// palette row and its sidebar twin read as the same destination. The
		// exit has no destination mark — it renders the signature diamond.
		const routes: ConfigurePaletteRoute[] = [
			{
				id: 'domains',
				label: m.configure_domains_list_title(),
				route: '/Configure/domains',
				icon: 'boxes'
			},
			{
				id: 'apps',
				label: m.configure_apps_title(),
				route: '/Configure/apps',
				icon: 'app-window'
			},
			{
				id: 'roles',
				label: m.configure_roles_title(),
				route: '/Configure/access/roles',
				icon: 'key-round'
			},
			{
				id: 'assignments',
				label: m.configure_assignments_title(),
				route: '/Configure/access/assignments',
				icon: 'users'
			},
			{
				id: 'accounts',
				label: m.configure_accounts_title(),
				route: '/Configure/access/accounts',
				icon: 'user-cog'
			},
			{
				id: 'currencies',
				label: m.configure_currencies_nav(),
				route: '/Configure/currencies',
				icon: 'coins'
			},
			{
				id: 'audit',
				label: m.audit_page_header(),
				route: '/Configure/audit',
				icon: 'scroll-text'
			}
		];
		if (can('*.*', 'read')) {
			if (can('core.SystemSettings', 'read')) {
				routes.push({
					id: 'settings',
					label: m.system_settings_nav(),
					route: '/Configure/platform/settings',
					icon: 'settings-2'
				});
			}
			routes.push({
				id: 'indexes',
				label: m.platform_indexes_nav(),
				route: '/Configure/platform/indexes',
				icon: 'list-tree'
			});
			routes.push({
				id: 'maintenance',
				label: m.platform_maintenance_nav(),
				route: '/Configure/platform/maintenance',
				icon: 'wrench'
			});
			routes.push({
				id: 'artifacts',
				label: m.platform_artifacts_nav(),
				route: '/Configure/platform/artifacts',
				icon: 'paperclip'
			});
		}
		const list: PaletteCommand[] = routes.map((entry) => ({
			id: `configure.${entry.id}`,
			label: entry.label,
			run: () => navigate(entry.route)
		}));
		list.push({ id: 'configure.exit', label: m.configure_exit_button(), run: handleExit });
		return list;
	});

	// ── Domains list reload on permission refresh ─────────────────────────────────
	onPermissionRefresh(() => invalidateAll());

	let collapsed = $state(false);

	// The assistant pill mirrors the live shell: it renders only when the
	// account may use the workspace assistant (`me.assistant.access`), and it
	// toggles the same one open flag the floating window reads. The window
	// itself is mounted at the root layout (`AssistantHost`), so it floats over
	// this shell; the backend re-checks `assistant_access` on every create and
	// stream.
	const assistantAvailable = $derived(data.assistantAccess ?? false);
</script>

<!-- Collapsed rail: rows show only their icon, so the label moves to a
	tooltip on the right — same behaviour as the live NavPanel. -->
{#snippet tip(label: string, trigger: import('svelte').Snippet)}
	{#if collapsed}
		<Tooltip.Provider>
			<Tooltip.Root>
				<Tooltip.Trigger>
					{#snippet child({ props })}
						<span {...props} class="tip-anchor">
							{@render trigger()}
						</span>
					{/snippet}
				</Tooltip.Trigger>
				<Tooltip.Portal>
					<Tooltip.Content class="nav-tooltip" side="right" sideOffset={6}>
						{label}
						<Tooltip.Arrow />
					</Tooltip.Content>
				</Tooltip.Portal>
			</Tooltip.Root>
		</Tooltip.Provider>
	{:else}
		{@render trigger()}
	{/if}
{/snippet}

<div class="configure-shell" class:rail-collapsed={collapsed}>
	<SidebarShell
		{collapsed}
		ontoggle={(c) => (collapsed = c)}
		account={data.account}
		{activeRole}
		{availableRoles}
		connectivity={data.connectivity ?? []}
		onSwitchRole={async (role) => {
			await switchActiveRole(role);
		}}
		variant="lockup"
		title="Facet"
	>
		{#snippet nav()}
			<nav class="sections">
				{#each sections as section (section.label)}
					<div class="section">
						<span class="section-label">{section.label}</span>
						<ul>
							{#each section.items as item (item.route)}
								<li>
									{#snippet row()}
										<button
											class="nav-item"
											class:active={item.active}
											onclick={() => navigate(item.route)}
											aria-current={item.active ? 'page' : undefined}
										>
											<item.icon size={15} stroke-width={1.9} />
											<span>{item.label}</span>
										</button>
									{/snippet}
									{@render tip(item.label, row)}
								</li>
							{/each}
						</ul>
					</div>
				{/each}
			</nav>

			<div class="configrow">
				<button
					class="nav-item exit"
					onclick={handleExit}
					title={m.configure_exit_title()}
					aria-label={m.configure_exit_aria()}
				>
					<ArrowLeft size={16} stroke-width={1.8} />
					<span>{m.configure_exit_button()}</span>
					<span class="exit-tag">{m.configure_exit_tag()}</span>
				</button>
			</div>
		{/snippet}
	</SidebarShell>

	<!-- Only controls with a working behaviour: the bell is wired through
		`bellProps` (same as the live shell), the search trigger opens the
		Configure palette below, and the assistant pill toggles the workspace
		window when the account may use it. -->
	<Topbar
		{crumbs}
		showSearch
		onsearch={() => (paletteOpen = true)}
		showAssistant={assistantAvailable}
		assistantLabel={data.assistantName}
		assistantOpen={getAssistantOpen()}
		onassistant={toggleAssistantOpen}
		{...bellProps()}
	/>

	<main class="content">
		{@render children?.()}
	</main>

	<!-- Own palette instance: the live shell unmounts its one on Configure
		routes, so only this listener answers Cmd/Ctrl+K here. -->
	<CommandPalette bind:open={paletteOpen} commands={paletteCommands} activeDomain="" />
</div>

<style>
	.configure-shell {
		display: grid;
		height: 100vh;
		overflow: hidden;
		grid-template-columns: 252px minmax(0, 1fr);
		grid-template-rows: auto minmax(0, 1fr);
		grid-template-areas: 'side top' 'side main';
		transition: grid-template-columns 0.2s ease;
	}

	.configure-shell.rail-collapsed {
		grid-template-columns: 60px minmax(0, 1fr);
	}

	.sections {
		flex: 1;
		overflow-y: auto;
		padding: 8px 8px 16px;
		display: flex;
		flex-direction: column;
		gap: 18px;
		min-height: 0;
	}

	.section {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.section-label {
		padding: 4px 10px 6px;
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.06em;
		color: var(--text-3);
		text-transform: uppercase;
	}

	ul {
		list-style: none;
		padding: 0;
		margin: 0;
		display: flex;
		flex-direction: column;
		gap: 1px;
	}

	.nav-item {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 7px 10px;
		border: none;
		border-radius: var(--r-sm);
		background: transparent;
		color: var(--text-2);
		font: inherit;
		font-size: 13px;
		cursor: pointer;
		width: 100%;
		text-align: left;
		transition:
			background 0.12s ease,
			color 0.12s ease;
	}

	.nav-item:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.nav-item.active {
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	/* ── Collapsed rail ──────────────────────────────────── */
	:global(.rail-collapsed .section-label),
	:global(.rail-collapsed .nav-item span) {
		display: none;
	}

	:global(.rail-collapsed .section-label) {
		text-align: center;
		padding-inline: 0;
	}

	:global(.rail-collapsed .nav-item) {
		justify-content: center;
		padding-inline: 0;
	}

	/* Tooltip anchor wrapper — must not disturb the row layout. */
	.tip-anchor {
		display: block;
	}

	/* Collapsed-rail tooltip, shared with the live NavPanel. */
	:global(.nav-tooltip) {
		background: var(--surface-2);
		color: var(--text);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		padding: 6px 9px;
		font-family: var(--font-sans);
		font-size: 12px;
		line-height: 1.4;
		box-shadow: var(--sh-1);
	}

	/* ── Exit to live mode ────────────────────────────────── */
	.configrow {
		margin-top: auto;
		border-top: 1px solid var(--border);
		padding: 8px 8px 12px;
	}

	.configrow .nav-item.exit {
		color: var(--text-2);
	}

	:global(.rail-collapsed .configrow .nav-item span) {
		display: none;
	}

	.exit-tag {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		font-weight: 500;
		flex: none;
	}

	.content {
		grid-area: main;
		overflow-y: auto;
		min-width: 0;
		min-height: 0;
	}
</style>
