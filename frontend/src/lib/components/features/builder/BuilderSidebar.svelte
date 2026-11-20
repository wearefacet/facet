<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { untrack } from 'svelte';
	import { PencilRuler, ArrowLeft, Plus, Pencil, ChevronRight } from '@lucide/svelte';
	import { Tooltip } from 'bits-ui';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { flattenNavDoctypes, type NavDomain, type NavDoctype } from '$lib/navTypes';
	import SidebarShell from '../../primitives/surfaces/SidebarShell.svelte';
	import Can from '../../primitives/surfaces/Can.svelte';
	import NewDoctypeDialog from '../dashboard/NewDoctypeDialog.svelte';
	import NewDomainDialog from '../dashboard/NewDomainDialog.svelte';
	import EditDomainDialog from '../dashboard/EditDomainDialog.svelte';
	import { createDoctype } from '$lib/builderDraft.svelte';
	import { getBuilderDraft } from '$lib/builderDraft.svelte';

	/**
	 * Builder sidebar — the canonical sidebar for the entire /Builder/* subtree.
	 *
	 * Two states derived from the URL:
	 *   Landing   — /Builder              (no draft selected)
	 *   Draft     — /Builder/[draft]/*    (a specific draft is open)
	 *
	 * Per the configure UX brief, this replaces the live NavPanel when in
	 * builder mode, providing either a draft-gallery landing or a flat nav list
	 * pinned to the active draft.
	 */

	let {
		collapsed = false,
		ontoggle = (_c: boolean) => {},
		/** Drafts the user has access to. */
		domains = [] as NavDomain[],
		/** Active draft domain id (URL-derived). */
		activeDomainId = '',
		/** Qualified name of the highlighted doctype, if a doctype route is open. */
		activeDoctype = undefined,
		/** Authenticated account. */
		account = undefined,
		/** Active role label from the session. */
		activeRole = undefined,
		/** Roles the account is assigned; forwarded to the sidebar shell. */
		availableRoles = [] as string[],
		/** Called when the user picks a target role in the sidebar shell. */
		onSwitchRole = async (_role: string) => {},
		/** Live domains for the EditDomainDialog — fetched by the parent. */
		liveDomains = [] as NavDomain[],
		/** Creates a new empty draft with a chosen name; returns null on success or an error message. */
		onnewdomain = (_input: { name: string; label?: string }) =>
			Promise.resolve(null as string | null),
		/** Called when the user drafts from a live domain (Edit existing). */
		oneditdomain = (_domainId: string) => {},
		/** Error to surface inside the EditDomainDialog (e.g. 409). */
		editError = undefined,
		/** Called when the user exits builder mode. */
		onexitbuilder = () => {},
		children
	}: {
		collapsed?: boolean;
		ontoggle?: (collapsed: boolean) => void;
		domains?: NavDomain[];
		activeDomainId?: string;
		activeDoctype?: string;
		account?: { id: string; display_name: string } | null;
		activeRole?: string | null;
		availableRoles?: string[];
		onSwitchRole?: (role: string) => Promise<void>;
		liveDomains?: NavDomain[];
		onnewdomain?: (input: { name: string; label?: string }) => Promise<string | null>;
		oneditdomain?: (domainId: string) => void;
		editError?: string | undefined;
		onexitbuilder?: () => void;
		children?: import('svelte').Snippet;
	} = $props();

	function handleConfigure() {
		// Exit builder mode — go back to main dashboard.
		onexitbuilder();
	}

	// ── URL-derived state ──────────────────────────────────────────────────

	/** True when on /Builder (no draft selected yet). */
	const isLanding = $derived(!page.params.draftDomain);

	/** Active draft id (only set when NOT on landing). */
	const draftId = $derived(page.params.draftDomain ?? '');
	const draftTab = $derived.by(() => {
		const segs = page.url.pathname.split('/').filter(Boolean);
		if (segs[0] !== 'Builder' || !segs[1]) return 'overview';
		return segs[2] ?? 'overview';
	});
	const onDoctypeEditor = $derived(
		!['overview', 'doctypes', 'grants', 'check', 'preview'].includes(draftTab) &&
			draftTab !== 'overview'
	);
	const activeDoctypeQualified = $derived.by(() => {
		if (!onDoctypeEditor || !activeDomain) return undefined;
		const segs = page.url.pathname.split('/').filter(Boolean);
		const dtName = segs[2];
		// The URL segment is the machine doctype name; the nav entry's `label`
		// is the display label and may differ once a doctype sets `label`. The
		// match walks the whole tree — composition children nest under their
		// parent in the doctype list.
		const walk = (list: NavDoctype[]): NavDoctype | undefined => {
			for (const dt of list) {
				if (dt.qualified.split('.').pop() === dtName) return dt;
				if (dt.children?.length) {
					const hit = walk(dt.children);
					if (hit) return hit;
				}
			}
			return undefined;
		};
		return walk(activeDomain.doctypes)?.qualified;
	});

	const overviewActive = $derived(!isLanding && draftTab === 'overview' && draftId);
	const grantsActive = $derived(!isLanding && draftTab === 'grants');
	const checkActive = $derived(!isLanding && draftTab === 'check');

	// ── Active domain derivation ───────────────────────────────────────────

	const activeDomain = $derived(
		!isLanding && domains.length > 0
			? (domains.find((d) => d.id === activeDomainId) ?? domains[0])
			: undefined
	);

	// ── Builder-draft store (for check counts and draft status) ────────────
	const draftSnapshot = $derived(getBuilderDraft());
	const checkIssueCount = $derived(
		!isLanding && draftSnapshot.id === draftId ? draftSnapshot.checkIssueCount : 0
	);
	const isDraft = $derived(
		!isLanding && draftSnapshot.id === draftId ? draftSnapshot.isDraft : false
	);

	// ── Dialogs ────────────────────────────────────────────────────────
	let newDoctypeOpen = $state(false);
	let newDomainDialogOpen = $state(false);
	let editDomainDialogOpen = $state(false);

	// ── Tree expansion ─────────────────────────────────────────────────
	// Subtrees start expanded — the builder checks child doctypes without an
	// extra click — and the caret collapses a branch. Keyed by qualified name;
	// an absent key means "expanded". Children render only when the rail is
	// expanded, so the collapsed rail keeps showing roots only.
	let subtreeCollapsed = $state<Record<string, boolean>>({});

	function toggleSubtree(e: MouseEvent, qualified: string) {
		e.preventDefault();
		e.stopPropagation();
		subtreeCollapsed[qualified] = !subtreeCollapsed[qualified];
	}

	// Keep the active doctype's branch visible: when the highlight moves into
	// a collapsed subtree (e.g. from the doctypes tab), re-expand its
	// ancestors. The write is untracked so the effect never re-runs on its own
	// mutation (workflow.md → "The equality-guard trap in writeback effects").
	$effect(() => {
		const active = activeDoctypeQualified;
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

	// ── Navigation helpers ─────────────────────────────────────────────────
	function navToOverview() {
		if (draftId)
			goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: draftId }));
	}
	function navToGrants() {
		if (draftId) goto(resolve('/Builder/[draftDomain]/(editor)/grants', { draftDomain: draftId }));
	}
	function navToCheck() {
		if (draftId) goto(resolve('/Builder/[draftDomain]/(editor)/check', { draftDomain: draftId }));
	}
	function navToDoctype(dt: NavDoctype) {
		if (draftId)
			goto(
				resolve('/Builder/[draftDomain]/[doctype]/[[tab]]', {
					draftDomain: draftId,
					doctype: dt.label,
					tab: 'fields'
				})
			);
	}
	function navBackToDomains() {
		goto(resolve('/Builder'));
	}
	function navToDraft(id: string) {
		goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: id }));
	}
</script>

<!-- Collapsed rail: rows show only their mark, so the label moves to a
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

<SidebarShell
	{collapsed}
	{ontoggle}
	{account}
	{activeRole}
	{availableRoles}
	{onSwitchRole}
	variant="lockup"
	title="Facet"
>
	{#snippet nav()}
		{#if isLanding}
			<!-- ═══════════════════════════════════════════════════════════════
			     LANDING STATE — /Builder (no draft selected)
			     ═══════════════════════════════════════════════════════════════ -->
			<div class="landing-hint">{m.builder_landing_hint()}</div>

			{#if domains.length > 0}
				<nav class="nav landing-nav">
					{#each domains as d (d.id)}
						{#snippet row()}
							<button
								class="nav-btn"
								onclick={() => navToDraft(d.id)}
								type="button"
								aria-label={d.label}
							>
								<span class="dt" style={`background:${d.color}`}></span>
								<span class="lbl">{d.label}</span>
								<span class="ct">{flattenNavDoctypes(d.doctypes).length}</span>
							</button>
						{/snippet}
						{@render tip(d.label, row)}
					{/each}
				</nav>
			{/if}

			<div class="configrow">
				<Can doctype="core.Domain" action="create">
					<button
						class="nav-btn"
						onclick={() => (newDomainDialogOpen = true)}
						title={m.builder_new_domain_hint()}
						aria-label={m.dashboard_new_domain_title()}
					>
						<Plus class="ic" size={16} stroke-width={1.8} />
						<span class="lbl">{m.dashboard_new_domain_title()}</span>
					</button>
				</Can>
				<button
					class="nav-btn"
					onclick={() => (editDomainDialogOpen = true)}
					title={m.builder_edit_existing_hint()}
					aria-label={m.builder_edit_existing()}
				>
					<Pencil class="ic" size={16} stroke-width={1.8} />
					<span class="lbl">{m.builder_edit_existing()}</span>
				</button>
				<button
					class="nav-btn"
					onclick={handleConfigure}
					title={m.builder_exit_mode_hint()}
					aria-label={m.builder_exit_builder()}
				>
					<PencilRuler class="ic" size={16} stroke-width={1.8} />
					<span class="lbl">{m.builder_exit_builder()}</span>
					<span class="ct cnm">{m.builder_live_chip()}</span>
				</button>
			</div>
			<NewDomainDialog bind:open={newDomainDialogOpen} oncreate={onnewdomain} />
			<EditDomainDialog
				bind:open={editDomainDialogOpen}
				{liveDomains}
				error={editError}
				onselect={oneditdomain}
			/>
		{:else}
			<!-- ═══════════════════════════════════════════════════════════════
			     DRAFT STATE — /Builder/[draft]/*
			     ═══════════════════════════════════════════════════════════════ -->

			<!-- ── Back-link ──────────────────────────────────────── -->
			<button
				class="back"
				type="button"
				onclick={navBackToDomains}
				title={m.builder_back_domains_aria()}
				aria-label={m.builder_back_domains_aria()}
			>
				<ArrowLeft size={14} stroke-width={1.9} />
				<span>{m.builder_all_domains()}</span>
			</button>

			{#if activeDomain}
				<div class="draft-tag" title={activeDomain.label}>
					<span class="dot" style={`background:${activeDomain.color}`}></span>
					<span class="id" class:draft={isDraft}>{activeDomain.label}</span>
				</div>
			{/if}

			<!-- ── Navigation ───────────────────────────────────── -->
			<nav class="nav">
				<button
					class="nav-btn"
					class:on={overviewActive}
					onclick={navToOverview}
					type="button"
					aria-current={overviewActive ? 'page' : undefined}
				>
					<span class="lbl">{m.builder_tab_overview()}</span>
				</button>

				<div class="grp">
					<span class="gl"></span>
					<span class="gh">{m.nav_group_doctypes()}</span>
					<span class="count"
						>{activeDomain ? flattenNavDoctypes(activeDomain.doctypes).length : 0}</span
					>
				</div>
				{#if activeDomain}
					{#snippet dtRow(dt: NavDoctype, depth: number)}
						{#snippet btn()}
							<button
								class="nav-btn dt-main"
								class:on={dt.qualified === activeDoctype || dt.qualified === activeDoctypeQualified}
								onclick={() => navToDoctype(dt)}
								type="button"
								aria-label={dt.label}
								aria-current={dt.qualified === activeDoctype ||
								dt.qualified === activeDoctypeQualified
									? 'page'
									: undefined}
								style:padding-left={dt.children?.length
									? `${24 + depth * 16}px`
									: `${10 + depth * 16}px`}
							>
								<span class="dt" style={`background:${dt.color}`}></span>
								<span class="lbl">{dt.label}</span>
								<span class="ct">{dt.count}</span>
							</button>
							{#if !collapsed && dt.children?.length}
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
									style:left={`${6 + depth * 16}px`}
									onclick={(e) => toggleSubtree(e, dt.qualified)}
								>
									<ChevronRight size={12} stroke-width={2} />
								</button>
							{/if}
						{/snippet}
						<div class="dt-row">
							{@render tip(dt.label, btn)}
						</div>
						{#if !collapsed && dt.children?.length && !subtreeCollapsed[dt.qualified]}
							{#each dt.children as child (child.qualified)}
								{@render dtRow(child, depth + 1)}
							{/each}
						{/if}
					{/snippet}
					{#each activeDomain.doctypes as dt (dt.qualified)}
						{@render dtRow(dt, 0)}
					{:else}
						<div class="empty-list">
							{m.builder_doctypes_empty()}
							{#if isDraft}{m.builder_doctypes_empty_add()}{/if}
						</div>
					{/each}
					{#if isDraft}
						<button
							class="nav-btn add-doctype"
							onclick={() => (newDoctypeOpen = true)}
							type="button"
							aria-label={m.builder_add_doctype()}
						>
							<Plus class="ic" size={14} stroke-width={1.9} />
							<span class="lbl">{m.builder_add_doctype()}</span>
						</button>
					{/if}
				{/if}

				<button
					class="nav-btn"
					class:on={grantsActive}
					onclick={navToGrants}
					type="button"
					aria-current={grantsActive ? 'page' : undefined}
				>
					<span class="lbl">{m.builder_tab_grants()}</span>
				</button>

				{#if isDraft}
					<button
						class="nav-btn"
						class:on={checkActive}
						onclick={navToCheck}
						type="button"
						aria-current={checkActive ? 'page' : undefined}
					>
						<span class="lbl">{m.builder_tab_check()}</span>
						{#if checkIssueCount > 0}
							<span class="ct warn">{checkIssueCount}</span>
						{/if}
					</button>
				{/if}

				<div class="configrow">
					<button
						class="nav-btn"
						onclick={handleConfigure}
						title={m.builder_exit_config_hint()}
						aria-label={m.builder_exit_builder()}
						type="button"
					>
						<PencilRuler class="ic" size={16} stroke-width={1.8} />
						<span class="lbl">{m.builder_exit_builder()}</span>
						<span class="ct cnm">{m.builder_live_chip()}</span>
					</button>
				</div>
			</nav>
		{/if}
	{/snippet}

	{@render children?.()}
</SidebarShell>

<NewDoctypeDialog bind:open={newDoctypeOpen} oncreate={createDoctype} />

<style>
	/* Landing state: hint text. */
	.landing-hint {
		padding: 12px 12px 4px;
		font-size: 11.5px;
		color: var(--text-3);
		font-family: var(--font-mono);
		line-height: 1.45;
	}

	/* Landing state: nav list of drafts. */
	.landing-nav {
		flex: 1;
		overflow-y: auto;
		padding: 8px 8px 4px;
		display: flex;
		flex-direction: column;
		gap: 1px;
		min-height: 0;
	}

	/* Back-link button */
	.back {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 8px 12px;
		margin: 8px 8px 0;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text-2);
		font: inherit;
		font-size: 12.5px;
		cursor: pointer;
		white-space: nowrap;
		overflow: hidden;
		text-decoration: none;
		transition:
			border-color 0.12s ease,
			color 0.12s ease,
			background 0.12s ease;
	}

	.back:hover {
		border-color: var(--accent);
		color: var(--text);
		background: var(--sunken);
	}

	/* Draft-color tag bar (visible only when the active domain has a color). */
	.draft-tag {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 4px 12px;
		margin: 6px 8px 0;
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
	}

	.draft-tag .dot {
		width: 7px;
		height: 7px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex: none;
	}

	.draft-tag .id.draft {
		color: var(--warn, #d97706);
	}

	/* Navigation */
	.nav {
		flex: 1;
		overflow-y: auto;
		padding: 10px 8px 12px;
		display: flex;
		flex-direction: column;
		gap: 1px;
		min-height: 0;
	}

	.nav-btn {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 6px 10px;
		border: none;
		border-radius: var(--r-sm);
		background: transparent;
		color: var(--text-2);
		font: inherit;
		font-size: 12.5px;
		cursor: pointer;
		width: 100%;
		text-align: left;
		transition:
			background 0.12s ease,
			color 0.12s ease;
	}

	.nav-btn:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.nav-btn.on {
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	.nav-btn.on::before {
		content: '';
		position: absolute;
		left: -8px;
		top: 6px;
		bottom: 6px;
		width: 3px;
		border-radius: var(--r-pill);
		background: var(--accent);
	}

	.nav-btn {
		position: relative;
	}

	.nav-btn .dt {
		width: 8px;
		height: 8px;
		border-radius: 2px;
		flex: none;
	}

	.nav-btn .lbl {
		flex: 1;
	}

	.nav-btn .ct {
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
		min-width: 18px;
		text-align: right;
	}

	.nav-btn .ct.warn {
		color: var(--warn, #d97706);
		font-weight: 600;
	}

	.nav-btn .ct.cnm {
		font-size: 9.5px;
		letter-spacing: 0.04em;
		text-transform: uppercase;
	}

	/* ── Doctype tree ─────────────────────────────────────── */
	/* Each row is a relative wrapper: the main button spans the full width
	   (the .on accent bar stays pinned to the rail edge), and the expand caret
	   floats at the row's left, one step per depth. */
	.dt-row {
		position: relative;
	}

	.dt-row .tw {
		position: absolute;
		top: 50%;
		transform: translateY(-50%);
		width: 14px;
		height: 14px;
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

	.dt-row .tw:hover {
		color: var(--text);
		background: var(--sunken);
	}

	.dt-row .tw :global(svg) {
		transition: transform 0.12s;
	}

	.dt-row .tw.open :global(svg) {
		transform: rotate(90deg);
	}

	:global(.nav-btn .ic) {
		flex: none;
		color: var(--text-3);
	}

	:global(.nav-btn.on .ic) {
		color: var(--accent-ink);
	}

	/* Add-doctype action — rendered at the end of the doctype list (draft-only).
	   Ghost-styled to read as an action, not a doctype entry. */
	.nav-btn.add-doctype {
		padding: 6px 10px;
		margin-top: 4px;
		color: var(--text-3);
		font-size: 12px;
		border: 1px dashed var(--border-strong, var(--border));
		border-radius: var(--r-sm);
		background: transparent;
	}

	.nav-btn.add-doctype :global(.ic) {
		color: var(--text-3);
	}

	.nav-btn.add-doctype:hover {
		border-color: var(--accent);
		color: var(--accent-ink);
		background: var(--accent-weak, transparent);
	}

	.nav-btn.add-doctype:hover :global(.ic) {
		color: var(--accent-ink);
	}

	.grp {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 14px 10px 4px;
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.06em;
		color: var(--text-3);
		text-transform: uppercase;
	}

	.grp .gl {
		width: 5px;
		height: 5px;
		border-radius: 1px;
		transform: rotate(45deg);
		background: var(--text-3);
		opacity: 0.6;
		flex: none;
	}

	.grp .count {
		margin-left: auto;
		min-width: 18px;
		text-align: right;
		font-variant-numeric: tabular-nums;
	}

	.empty-list {
		padding: 6px 12px 8px;
		font-size: 11.5px;
		color: var(--text-3);
		font-family: var(--font-mono);
		line-height: 1.45;
	}

	.configrow {
		margin-top: 8px;
		border-top: 1px solid var(--border);
		padding-top: 8px;
		display: flex;
		flex-direction: column;
		gap: 1px;
	}

	/* Collapsed rail: hide chrome that needs horizontal space. */
	:global(.rail-collapsed .back span),
	:global(.rail-collapsed .draft-tag),
	:global(.rail-collapsed .nav-btn .lbl),
	:global(.rail-collapsed .nav-btn .ct),
	:global(.rail-collapsed .grp),
	:global(.rail-collapsed .empty-list) {
		display: none;
	}

	:global(.rail-collapsed .back) {
		justify-content: center;
		padding-inline: 0;
	}

	:global(.rail-collapsed .nav-btn) {
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
</style>
