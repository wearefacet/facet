<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { untrack } from 'svelte';
	import { flattenNavDoctypes, type NavDomain, type NavDoctype } from '$lib/navTypes';
	import { Select, Tooltip, Popover } from 'bits-ui';
	import { ChevronDown, ChevronRight, Search, Pin, Settings } from '@lucide/svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import DoctypeIcon from '../data/DoctypeIcon.svelte';
	import SidebarShell from './SidebarShell.svelte';
	import Can from './Can.svelte';
	import { getCount, getCountsVersion, loadForDomain } from '$lib/navCounts.svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import '../shared.css';
	import type { IdentityProps } from './IdentityProps.js';

	let {
		collapsed = false,
		ontoggle = (_c: boolean) => {},
		/** Driver-derived domain model. When omitted, the component does not render the domain selector. */
		domains = undefined,
		/** Id of the domain shown as active in the selector. Two-way bindable. */
		activeDomainId = $bindable(''),
		/** Qualified name of the highlighted doctype in the list. */
		activeDoctype = undefined,
		account = undefined,
		activeRole = undefined,
		availableRoles = [] as string[],
		connectivity = undefined as string[] | undefined,
		onSwitchRole = async (_role: string) => {},
		/** Called when the user toggles a doctype's pinned state. */
		onpin = (_qualified: string) => {},
		/** Driver used to fetch per-doctype counts lazily when a domain becomes
		 *  active. When omitted, counts are never fetched and badges show `—`. */
		driver = undefined,

		children
	}: {
		/** Whether the panel is collapsed to rail mode. */
		collapsed?: boolean;
		/** Called when the user clicks the collapse toggle. */
		ontoggle?: (collapsed: boolean) => void;
		/** Driver-derived domain model. When omitted, the component does not render the domain selector. */
		domains?: NavDomain[];
		/** Id of the domain shown as active in the selector. Two-way bindable. */
		activeDomainId?: string;
		/** Qualified name of the highlighted doctype in the list. */
		activeDoctype?: string;
		/** Called when the user toggles a doctype's pinned state. */
		onpin?: (qualified: string) => void;
		/** Driver used to fetch per-doctype counts lazily when a domain becomes
		 *  active. When omitted, counts are never fetched and badges show `—`. */
		driver?: DataDriver;

		children?: import('svelte').Snippet;
		/** Authenticated account, active role and role switching. */
	} & IdentityProps = $props();

	function handleConfigure() {
		goto(resolve('/Configure/domains'));
	}

	// Selecting a domain in the sidebar navigates to that domain's live
	// dashboard (`/{domain}`). The local `activeDomainId` write gives the
	// doctype list immediate feedback before `goto` resolves; the root layout's
	// URL-sync effect re-confirms the same value once navigation lands, so the
	// click is not clobbered. Navigation always issues to `/iam` so the user
	// can return to the dashboard from any deep page of the same domain.
	function handleDomainSelect(id: string) {
		activeDomainId = id;
		goto(resolve('/[domain=notApi]', { domain: id }));
	}

	const activeDomain = $derived(
		domains && domains.length > 0
			? (domains.find((d) => d.id === activeDomainId) ?? domains[0])
			: undefined
	);

	// Doctypes the user pinned, in their original order, and the rest. Pinning
	// is a top-level concept: nested composition children render inside their
	// parent's subtree and carry no pin control.
	const pinnedDoctypes = $derived(
		activeDomain ? activeDomain.doctypes.filter((dt) => dt.pinned) : []
	);
	const unpinnedDoctypes = $derived(
		activeDomain ? activeDomain.doctypes.filter((dt) => !dt.pinned) : []
	);

	function handlePin(dt: NavDoctype) {
		onpin(dt.qualified);
	}

	// ── Tree expansion ─────────────────────────────────────────────────
	// Subtrees start expanded — the builder must see child doctypes without an
	// extra click — and the caret collapses a branch. Keyed by qualified name;
	// an absent key means "expanded".
	let subtreeCollapsed = $state<Record<string, boolean>>({});

	function toggleSubtree(e: MouseEvent, qualified: string) {
		e.preventDefault();
		e.stopPropagation();
		subtreeCollapsed[qualified] = !subtreeCollapsed[qualified];
	}

	// Keep the active doctype's branch visible: when the highlight moves into
	// a collapsed subtree (e.g. via the search popover), re-expand its
	// ancestors. The write is untracked so the effect never re-runs on its own
	// mutation (workflow.md → "The equality-guard trap in writeback effects").
	$effect(() => {
		const active = activeDoctype;
		const domain = activeDomain;
		if (!active || !domain) return;
		const ancestors: string[] = [];
		const walk = (list: NavDoctype[], chain: string[]): boolean => {
			for (const dt of list) {
				if (dt.qualified === active) {
					ancestors.push(...chain);
					return true;
				}
				if (dt.children?.length && walk(dt.children, [...chain, dt.qualified])) return true;
			}
			return false;
		};
		if (walk(domain.doctypes, []) && ancestors.length > 0) {
			untrack(() => {
				for (const q of ancestors) delete subtreeCollapsed[q];
			});
		}
	});

	// ── Doctype search ────────────────────────────────────────────────
	// The sidebar shows a compact button; clicking it opens a floating input
	// (Popover) that filters the doctype list client-side. A query flattens
	// the tree: matches render flat so a child hit is visible without its
	// parent's context.
	let searchOpen = $state(false);
	let searchQuery = $state('');

	const flatDoctypes = $derived(activeDomain ? flattenNavDoctypes(activeDomain.doctypes) : []);
	const filteredFlat = $derived(filterDoctypes(flatDoctypes));
	const filteredPinnedDoctypes = $derived(filteredFlat.filter((dt) => dt.pinned));
	const filteredUnpinnedDoctypes = $derived(filteredFlat.filter((dt) => !dt.pinned));

	function filterDoctypes(list: NavDoctype[]): NavDoctype[] {
		const q = searchQuery.trim().toLowerCase();
		if (!q) return list;
		return list.filter(
			(dt) => dt.label.toLowerCase().includes(q) || dt.qualified.toLowerCase().includes(q)
		);
	}

	// Lazy count fetch: when the active domain changes (or on first mount),
	// request counts for that domain's doctypes in parallel. Doctypes already
	// fetched or in-flight are skipped by `loadForDomain`. No fetch issues when
	// `driver` is absent (e.g. the static mockup story).
	//
	// The plain-`let` shadow prevents redundant calls when the effect re-runs
	// with the same domain and counts version, following the codebase's
	// writeback-effect convention. Reading the counts version keeps the effect
	// subscribed to cache invalidations: an import completion bumps it, and
	// the re-run refetches the dropped entries without a navigation (F02-02).
	// Reading `driver` keeps the effect subscribed to its identity, not to
	// `domains` (which the user can mutate).
	let lastLoadedKey: string | undefined;
	$effect(() => {
		const id = activeDomain?.id;
		const countsVersion = getCountsVersion();
		if (!driver || !id) return;
		const loadedKey = `${id}:${countsVersion}`;
		if (loadedKey === lastLoadedKey) return;
		lastLoadedKey = loadedKey;
		const doctypes = flatDoctypes;
		if (doctypes.length === 0) return;
		void loadForDomain(driver, doctypes);
	});
</script>

<SidebarShell
	{collapsed}
	{ontoggle}
	{account}
	{activeRole}
	{availableRoles}
	{connectivity}
	{onSwitchRole}
	variant="lockup"
	title="Facet"
>
	{#snippet nav()}
		<!-- ── Domain selector ──────────────────────────────── -->
		{#if domains}
			<Select.Root type="single" value={activeDomainId} onValueChange={handleDomainSelect}>
				<Select.Trigger class="domain">
					<span class="dot" style={activeDomain ? `background:${activeDomain.color}` : ''}></span>
					<div class="tx">
						<div class="t">{activeDomain ? activeDomain.label : ''}</div>
						<div class="s">
							{m.nav_domain_summary({
								domains: domains.length,
								doctypes: activeDomain ? flattenNavDoctypes(activeDomain.doctypes).length : 0
							})}
						</div>
					</div>
					<span class="chev"><ChevronDown size={14} stroke-width={2} /></span>
				</Select.Trigger>
				<Select.Portal>
					<Select.Content class="domain-dropdown menu-surface" align="start" sideOffset={4}>
						<Select.Viewport>
							{#each domains as d (d.id)}
								<Select.Item value={d.id} class="domain-item menu-item">
									{#snippet children({ selected: _selected, highlighted })}
										<span class="dot" style={`background:${d.color}`}></span>
										<span class="domain-item-label" class:domain-item-highlighted={highlighted}
											>{d.label}</span
										>
										<span class="domain-item-count">{flattenNavDoctypes(d.doctypes).length}</span>
									{/snippet}
								</Select.Item>
							{/each}
						</Select.Viewport>
					</Select.Content>
				</Select.Portal>
			</Select.Root>
		{/if}

		<!-- ── Nav search ───────────────────────────────────── -->
		<Popover.Root bind:open={searchOpen}>
			<Popover.Trigger class="navsearch-btn" aria-label={m.nav_search_doctype_aria()}>
				<Search size={14} stroke-width={2} />
			</Popover.Trigger>
			<Popover.Portal>
				<Popover.Content class="navsearch-pop" side="right" align="start" sideOffset={8}>
					<div class="navsearch-field">
						<Search size={14} stroke-width={2} />
						<input
							type="search"
							class="navsearch-input"
							placeholder={m.nav_search_doctype_placeholder()}
							bind:value={searchQuery}
						/>
					</div>
					{#if searchQuery.trim() && activeDomain}
						<ul class="navsearch-results">
							{#each filteredPinnedDoctypes as dt (dt.qualified)}
								<li>
									<a
										href={resolve('/[domain=notApi]/[doctype]', {
											domain: activeDomain.id,
											doctype: dt.label
										})}>{dt.label}</a
									>
								</li>
							{/each}
							{#each filteredUnpinnedDoctypes as dt (dt.qualified)}
								<li>
									<a
										href={resolve('/[domain=notApi]/[doctype]', {
											domain: activeDomain.id,
											doctype: dt.label
										})}>{dt.label}</a
									>
								</li>
							{/each}
							{#if filteredPinnedDoctypes.length === 0 && filteredUnpinnedDoctypes.length === 0}
								<li class="navsearch-empty">{m.nav_search_empty()}</li>
							{/if}
						</ul>
					{/if}
				</Popover.Content>
			</Popover.Portal>
		</Popover.Root>

		<!-- ── Navigation ───────────────────────────────────── -->
		<nav class="nav">
			{#snippet row(dt: NavDoctype, domain: NavDomain, depth: number, tree: boolean)}
				{#if collapsed}
					<Tooltip.Provider>
						<Tooltip.Root>
							<Tooltip.Trigger>
								{#snippet child({ props })}
									<a
										{...props}
										href={resolve('/[domain=notApi]/[doctype]', {
											domain: domain.id,
											doctype: dt.label
										})}
										class="nav-btn"
										class:on={dt.qualified === activeDoctype}
										aria-label={dt.label}
									>
										<DoctypeIcon icon={dt.icon} color={dt.color} active />
									</a>
								{/snippet}
							</Tooltip.Trigger>
							<Tooltip.Portal>
								<Tooltip.Content class="tooltip-pop" side="right" sideOffset={6}>
									{dt.label}
									<Tooltip.Arrow />
								</Tooltip.Content>
							</Tooltip.Portal>
						</Tooltip.Root>
					</Tooltip.Provider>
				{:else}
					<a
						href={resolve('/[domain=notApi]/[doctype]', {
							domain: domain.id,
							doctype: dt.label
						})}
						class="nav-btn"
						class:has-pin={tree && depth === 0}
						class:on={dt.qualified === activeDoctype}
						aria-label={dt.label}
						style:padding-left={depth > 0 ? `${10 + depth * 16}px` : undefined}
					>
						{#if tree}
							{#if dt.children?.length}
								<button
									class="tw"
									class:open={!subtreeCollapsed[dt.qualified]}
									aria-expanded={!subtreeCollapsed[dt.qualified]}
									aria-label={!subtreeCollapsed[dt.qualified]
										? m.nav_tree_collapse()
										: m.nav_tree_expand()}
									title={!subtreeCollapsed[dt.qualified]
										? m.nav_tree_collapse()
										: m.nav_tree_expand()}
									onclick={(e) => toggleSubtree(e, dt.qualified)}
								>
									<ChevronRight size={12} stroke-width={2} />
								</button>
							{:else}
								<span class="tw tw-none"></span>
							{/if}
						{/if}
						<DoctypeIcon icon={dt.icon} color={dt.color} active />
						<span class="lbl">{dt.label}</span><span class="ct"
							>{getCount(dt.qualified) ?? '—'}</span
						>
						{#if tree && depth === 0}
							<button
								class="pin-btn"
								title={dt.pinned ? m.nav_unpin() : m.nav_pin()}
								aria-label={dt.pinned
									? m.nav_unpin_aria({ name: dt.label })
									: m.nav_pin_aria({ name: dt.label })}
								onclick={(e) => {
									e.preventDefault();
									e.stopPropagation();
									handlePin(dt);
								}}
							>
								<Pin class={dt.pinned ? 'pin' : 'pin-ic'} size={13} />
							</button>
						{/if}
					</a>
					{#if tree && dt.children?.length && !subtreeCollapsed[dt.qualified]}
						{#each dt.children as child (child.qualified)}
							{@render row(child, domain, depth + 1, true)}
						{/each}
					{/if}
				{/if}
			{/snippet}

			{#if activeDomain && searchQuery.trim()}
				{#if filteredPinnedDoctypes.length > 0}
					<div class="grp"><span class="gl"></span>{m.nav_group_pinned()}</div>
					{#each filteredPinnedDoctypes as dt (dt.qualified)}
						{@render row(dt, activeDomain, 0, false)}
					{/each}
				{/if}
				<div class="grp"><span class="gl"></span>{m.nav_group_doctypes()}</div>
				{#each filteredUnpinnedDoctypes as dt (dt.qualified)}
					{@render row(dt, activeDomain, 0, false)}
				{/each}
				{#if filteredFlat.length === 0}
					<div class="navsearch-inline-empty">
						{m.nav_search_inline_empty({ query: searchQuery.trim() })}
					</div>
				{/if}
			{:else if activeDomain && pinnedDoctypes.length > 0}
				<div class="grp"><span class="gl"></span>{m.nav_group_pinned()}</div>
				{#each pinnedDoctypes as dt (dt.qualified)}
					{@render row(dt, activeDomain, 0, true)}
				{/each}
			{/if}

			{#if activeDomain && (unpinnedDoctypes.length > 0 || searchQuery.trim())}
				<div class="grp"><span class="gl"></span>{m.nav_group_doctypes()}</div>
				{#each unpinnedDoctypes as dt (dt.qualified)}
					{@render row(dt, activeDomain, 0, true)}
				{/each}
			{/if}

			<Can doctype="core.DocType" action="update">
				<div class="configrow">
					<button
						class="nav-btn"
						onclick={handleConfigure}
						title={m.nav_configure()}
						aria-label={m.nav_configure()}
					>
						<Settings class="ic" size={16} stroke-width={1.8} />
						<span class="lbl">{m.nav_configure()}</span>
						<span
							class="ct"
							style="font-size: 9.5px; letter-spacing: 0.04em; text-transform: uppercase"
							>{m.nav_configure_admin()}</span
						>
					</button>
				</div>
			</Can>
		</nav>
	{/snippet}
	{@render children?.()}
</SidebarShell>

<style>
	/* ── Collapsed rail hiding ────────────────────────────── */
	:global(.rail-collapsed .domain .tx),
	:global(.rail-collapsed .domain .chev),
	:global(.rail-collapsed .grp),
	:global(.rail-collapsed .nav-btn .lbl),
	:global(.rail-collapsed .nav-btn .ct),
	:global(.rail-collapsed .nav-btn .pin),
	:global(.rail-collapsed .nav-btn .tw),
	:global(.rail-collapsed .nav-btn .pin-btn) {
		display: none;
	}

	:global(.rail-collapsed .domain) {
		justify-content: center;
		padding: 9px 0;
	}

	:global(.rail-collapsed .nav-btn) {
		justify-content: center;
		padding: 9px 0;
	}

	/* ── Domain ───────────────────────────────────────────── */
	/* `Select.Trigger` renders the <button>, so the rule must be :global. */
	:global(.domain) {
		margin: 12px 12px 8px;
		padding: 8px 10px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		display: flex;
		align-items: center;
		gap: 9px;
		background: var(--surface-2);
		cursor: pointer;
		font: inherit;
		color: inherit;
		text-align: left;
		width: calc(100% - 24px);
	}

	:global(.domain:hover) {
		border-color: var(--border-strong);
	}

	:global(.domain[data-state='open']) {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	:global(.domain .dot) {
		width: 9px;
		height: 9px;
		border-radius: 3px;
		background: var(--dt-shipment);
		transform: rotate(45deg);
		flex: none;
	}

	:global(.domain .t) {
		font-weight: 600;
		font-size: 13px;
		white-space: nowrap;
	}

	:global(.domain .s) {
		font-size: 11px;
		color: var(--text-3);
	}

	:global(.domain .chev) {
		margin-left: auto;
		color: var(--text-3);
		display: flex;
		align-items: center;
	}

	/* ── Domain dropdown (portal-rendered) — surface + item base are shared */
	:global(.domain-dropdown) {
		z-index: 200;
		min-width: var(--bits-select-trigger-width);
		max-height: 320px;
		overflow-y: auto;
	}

	:global(.menu-item.domain-item) {
		gap: 10px;
		margin: 0;
	}

	:global(.domain-item[data-selected]) {
		background: var(--accent-weak);
		color: var(--accent-ink);
		font-weight: 600;
	}

	:global(.domain-item .dot) {
		width: 8px;
		height: 8px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex: none;
	}

	.domain-item-label {
		flex: 1;
		white-space: nowrap;
	}

	.domain-item-count {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	/* ── Nav search (button + floating popover) ───────────── */
	:global(.navsearch-btn) {
		margin: 0 12px 6px;
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 7px 10px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface-2);
		color: var(--text-3);
		font: inherit;
		font-size: 12.5px;
		cursor: pointer;
		width: calc(100% - 24px);
	}

	:global(.navsearch-btn:hover) {
		border-color: var(--border-strong);
		color: var(--text-2);
	}

	.rail-collapsed :global(.navsearch-btn) {
		justify-content: center;
		padding: 9px 0;
		margin-inline: auto;
		width: 36px;
	}

	:global(.navsearch-pop) {
		z-index: 200;
		min-width: 220px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-2);
		padding: 6px;
	}

	.navsearch-field {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 4px 6px;
		color: var(--text-3);
		font-size: 12.5px;
	}

	.navsearch-input {
		flex: 1;
		min-width: 0;
		border: none;
		background: none;
		outline: none;
		font: inherit;
		font-size: 12.5px;
		color: var(--text);
	}

	.navsearch-input::placeholder {
		color: var(--text-3);
	}

	.navsearch-results {
		list-style: none;
		margin: 4px 0 0;
		padding: 4px 0 0;
		border-top: 1px solid var(--border);
		max-height: 260px;
		overflow-y: auto;
	}

	.navsearch-results a {
		display: block;
		padding: 6px 8px;
		border-radius: var(--r-sm);
		color: var(--text-2);
		text-decoration: none;
		font-size: 12.5px;
	}

	.navsearch-results a:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.navsearch-empty {
		padding: 6px 8px;
		font-size: 11.5px;
		color: var(--text-3);
	}

	.navsearch-inline-empty {
		padding: 6px 10px;
		font-size: 11.5px;
		color: var(--text-3);
	}

	/* ── Nav ──────────────────────────────────────────────── */
	.nav {
		flex: 1;
		overflow: auto;
		padding: 6px 12px 12px;
	}

	:global(.nav .grp) {
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.08em;
		text-transform: uppercase;
		color: var(--text-3);
		padding: 13px 10px 6px;
		display: flex;
		align-items: center;
		gap: 6px;
	}

	:global(.nav .grp .gl) {
		width: 5px;
		height: 5px;
		border-radius: 1px;
		transform: rotate(45deg);
		background: var(--text-3);
		opacity: 0.6;
	}

	:global(.nav .nav-btn) {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		padding: 7px 10px;
		border-radius: var(--r-sm);
		border: none;
		background: none;
		color: var(--text-2);
		text-decoration: none;
		font: inherit;
		font-size: 13px;
		font-weight: 500;
		position: relative;
		cursor: pointer;
		text-align: left;
	}

	:global(.nav .nav-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.nav .nav-btn.on) {
		background: var(--accent-weak);
		color: var(--accent-ink);
		font-weight: 600;
	}

	:global(.nav .nav-btn.on::before) {
		content: '';
		position: absolute;
		left: -12px;
		top: 7px;
		bottom: 7px;
		width: 3px;
		border-radius: 0 3px 3px 0;
		background: var(--accent);
	}

	:global(.nav .nav-btn .dt) {
		width: 8px;
		height: 8px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex: none;
	}

	:global(.nav .nav-btn .ic) {
		width: 16px;
		height: 16px;
		flex: none;
		opacity: 0.85;
	}

	:global(.nav .nav-btn .lbl) {
		flex: 1;
		min-width: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	:global(.nav .nav-btn .ct) {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		font-weight: 500;
		flex: none;
		transition: margin-right 0.12s;
	}

	/* Make room for the pin icon, which appears on hover. Rows without a pin
	   slot (nested children, search rows) keep their badge steady. */
	:global(.nav .nav-btn.has-pin:hover .ct) {
		margin-right: 17px;
	}

	:global(.nav .nav-btn .pin) {
		color: var(--accent);
		opacity: 0.8;
		flex: none;
	}

	:global(.nav .nav-btn .pin-btn) {
		position: absolute;
		right: 10px;
		top: 50%;
		transform: translateY(-50%);
		background: none;
		border: none;
		padding: 0;
		margin: 0;
		display: flex;
		align-items: center;
		cursor: pointer;
		color: var(--text-3);
		opacity: 0;
		transition: opacity 0.12s;
	}

	:global(.nav .nav-btn:hover .pin-btn) {
		opacity: 1;
	}

	:global(.nav .nav-btn .pin-btn:hover) {
		color: var(--accent);
	}

	:global(.nav .nav-btn .pin-btn .pin-ic) {
		color: inherit;
	}

	/* ── Tree caret + subtree indent ─────────────────────── */
	/* The caret toggles a doctype's composition subtree; childless rows render
	   an invisible spacer so every icon column stays aligned. */
	:global(.nav .nav-btn .tw) {
		flex: none;
		width: 14px;
		height: 14px;
		margin-left: -4px;
		padding: 0;
		border: none;
		background: none;
		display: flex;
		align-items: center;
		justify-content: center;
		border-radius: 3px;
		color: var(--text-3);
		cursor: pointer;
	}

	:global(.nav .nav-btn .tw:hover) {
		color: var(--text);
		background: var(--sunken);
	}

	:global(.nav .nav-btn .tw svg) {
		transition: transform 0.12s;
	}

	:global(.nav .nav-btn .tw.open svg) {
		transform: rotate(90deg);
	}

	:global(.nav .nav-btn .tw-none) {
		visibility: hidden;
	}

	:global(.nav .configrow) {
		margin-top: 6px;
		border-top: 1px solid var(--border);
		padding-top: 8px;
	}

	/* ── Tooltip (collapsed rail doctype labels) ────────────── */
	/* Tooltip content — the shared tooltip shape. */
</style>
