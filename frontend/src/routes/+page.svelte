<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { resolve } from '$app/paths';
	import { goto } from '$app/navigation';
	import {
		Sun,
		Moon,
		Plus,
		PencilRuler,
		SlidersHorizontal,
		Boxes,
		Settings2
	} from '@lucide/svelte';
	import Panel from '$lib/components/primitives/surfaces/Panel.svelte';
	import Card from '$lib/components/features/dashboard/Card.svelte';
	import AppCard from '$lib/components/features/dashboard/AppCard.svelte';
	import EmptyDomainsCard from '$lib/components/features/dashboard/EmptyDomainsCard.svelte';
	import NewDoctypeDialog from '$lib/components/features/dashboard/NewDoctypeDialog.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import { displayTimezone } from '$lib/settings.svelte';
	import { can } from '$lib/permissions.svelte';
	import { createDraft, createDraftFromSource, createDoctype } from '$lib/builderDraft.svelte';

	// The dashboard hosts no Builder draft, but `createDoctype` needs one —
	// it creates the doctype inside the active draft domain. The flow is the
	// Builder landing's two-step: branch a draft from the chosen domain, then
	// create the doctype inside it (the create call navigates to the new
	// doctype's field editor and installs the draft nav).
	let doctypeDialogOpen = $state(false);
	let doctypeSourceId = $state<string | null>(null);

	function openNewDoctype(domainId: string): void {
		doctypeSourceId = domainId;
		doctypeDialogOpen = true;
	}

	async function handleNewDoctype(name: string): Promise<string | null> {
		const sourceId = doctypeSourceId;
		doctypeSourceId = null;
		if (!sourceId) return m.builder_no_active_draft();
		const draft = await createDraftFromSource(sourceId);
		if (draft.error || !draft.draftId) return draft.error ?? m.builder_draft_network_error();
		return createDoctype(name);
	}

	let { data } = $props();

	const drafts = $derived(data.draftDomains ?? []);
	const apps = $derived(data.apps ?? []);

	/** First-name token from the session display name (e.g. "Alban Rakoto" → "Alban"). */
	const firstName = $derived(
		data.account?.display_name?.trim().split(/\s+/)[0] ?? m.dashboard_hello_fallback()
	);

	// Wall-clock tick — re-evaluated every minute so `isDaytime` re-computes
	// when the real time crosses the day/night boundary, not only when the
	// timezone store changes. SSR-safe: the interval only starts in the
	// browser and is torn down on component destroy.
	let now = $state(Date.now());
	$effect(() => {
		if (typeof window === 'undefined') return;
		const id = window.setInterval(() => (now = Date.now()), 60_000);
		return () => window.clearInterval(id);
	});

	/**
	 * Whether it is currently daytime in the user's preferred timezone.
	 * `displayTimezone()` resolves the `auto` sentinel (and a not-yet-loaded
	 * store) to the browser zone. Reads `now` so it re-runs on the wall-clock
	 * tick above; reads the settings store so it re-runs when it hydrates.
	 */
	const isDaytime = $derived.by(() => {
		const _ = now; // subscribe to the wall-clock tick
		const zone = displayTimezone();
		try {
			const hour = Number(
				new Intl.DateTimeFormat('en-US', {
					timeZone: zone,
					hour: 'numeric',
					hour12: false
				}).format(new Date())
			);
			return hour >= 6 && hour < 18;
		} catch {
			// Invalid zone name — fall back to the local hour.
			const h = new Date().getHours();
			return h >= 6 && h < 18;
		}
	});

	const roleLabel = $derived.by(() => {
		if (!data.activeRole) return '—';
		// Mirror the sidebar's humanization: `iam.Roles.production_editor` → `Production Editor`.
		const name = data.activeRole.includes('.')
			? data.activeRole.split('.').pop()!
			: data.activeRole;
		return name
			.split(/[_\s-]+/)
			.filter(Boolean)
			.map((p) => p.charAt(0).toUpperCase() + p.slice(1))
			.join(' ');
	});

	const domains = $derived(data.domains);
	const domainCount = $derived(domains.length);

	// The same gate the Configure page uses for its write affordances; the
	// backend re-checks the create, so this is a UI hint only.
	const canCreateDomain = $derived(can('core.Domain', 'create') || can('core.Domain', 'update'));

	// Key surfaces the quick-links row opens. Each entry carries the gate its
	// destination applies, so the row never offers a page that redirects away:
	// the Configure shell needs `update core.DocType` (its layout gate), and
	// the Builder creates drafts, which need `create core.Domain`. Route ids
	// resolve through the generated manifest (`pnpm check` validates them).
	const quickLinks = $derived.by(() => [
		{
			label: m.builder_title(),
			icon: PencilRuler,
			href: resolve('/Builder'),
			when: can('core.Domain', 'create')
		},
		{
			label: m.configure_domains_list_title(),
			icon: Boxes,
			href: resolve('/Configure/domains'),
			when: can('core.DocType', 'update')
		},
		{
			label: m.system_settings_nav(),
			icon: SlidersHorizontal,
			href: resolve('/Configure/platform/settings'),
			when: can('core.SystemSettings', 'read')
		},
		{
			label: m.configure_apps_title(),
			icon: Settings2,
			href: resolve('/Configure/apps'),
			when: can('core.DocType', 'update')
		}
	]);

	// The Configure page's draft flow, reused for the empty-state card:
	// `createDraft` owns the POST, the sidebar install, and the WS settle;
	// this page owns the navigation to the new draft's Builder overview.
	async function handleNewDomain(input: { name: string; label?: string }): Promise<string | null> {
		const result = await createDraft(input);
		if (result.error) return result.error;
		if (!result.draftId) return m.builder_draft_network_error();
		goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: result.draftId }));
		return null;
	}
</script>

<svelte:head>
	<title>{m.dashboard_page_title()}</title>
</svelte:head>

<div class="page">
	<div class="dash-head">
		<h1>
			<span>{m.dashboard_hello({ name: firstName })}</span>
			{#if isDaytime}
				<Sun size={20} stroke-width={1.8} aria-hidden="true" />
			{:else}
				<Moon size={20} stroke-width={1.8} aria-hidden="true" />
			{/if}
		</h1>
		<span class="head-sub">{m.dashboard_connected_as({ role: roleLabel })}</span>
	</div>

	<!-- ── Key surfaces ───────────────────────────────────────────── -->
	<nav class="quick-links" aria-label={m.dashboard_quick_links_aria()}>
		{#each quickLinks as link (link.href)}
			{#if link.when !== false}
				<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- href is a resolve()-built literal from a $derived, invisible to the rule. -->
				<a class="quick-link" href={link.href}>
					<link.icon size={14} stroke-width={1.8} aria-hidden="true" />
					{link.label}
				</a>
			{/if}
		{/each}
	</nav>

	<!-- ── Applications ──────────────────────────────────────────── -->
	{#if apps.length > 0}
		<div class="section-head">{m.dashboard_section_applications()}</div>
		<div class="domain-grid">
			{#each apps as app (app.id)}
				<AppCard name={app.display_name} slug={app.slug} usable={app.usable} />
			{/each}
		</div>
	{/if}

	<!-- ── Drafts in progress ─────────────────────────────────── -->
	{#if drafts.length > 0}
		<div class="section-head">{m.dashboard_section_drafts()}</div>
		<Panel>
			<div class="draft-list">
				{#each drafts as d (d.id)}
					<a
						class="draft-row"
						href={resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: d.id })}
					>
						<span class="dot" style={`background:${d.color}`}></span>
						<span class="draft-name">{d.label}</span>
						<span class="draft-count">{m.common_doctypes_count({ count: d.doctypes.length })}</span>
						{#if d.check}
							<span
								class="issue-chip"
								class:warn={d.check.issue_count > 0}
								class:ok={d.check.issue_count === 0}
								title={d.check.issue_count > 0
									? m.common_issues_check_title({ count: d.check.issue_count })
									: m.common_check_ready_title()}
							>
								{#if d.check.issue_count > 0}
									{d.check.issue_count}⚠
								{:else}
									✓
								{/if}
							</span>
						{/if}
					</a>
				{/each}
			</div>
		</Panel>
	{/if}

	<!-- ── Domains ────────────────────────────────────────── -->
	<div class="section-head">{m.dashboard_section_domains()}</div>
	{#if domainCount === 0}
		{#if canCreateDomain}
			<!-- The administrator sees the first-run call to action, not a
				"contact your administrator" notice (tour handoff). -->
			<EmptyDomainsCard oncreate={handleNewDomain} />
		{:else}
			<Card
				variant="notice"
				title={m.dashboard_no_domains_title()}
				description={m.dashboard_no_domains_desc()}
			/>
		{/if}
	{:else}
		<div class="domain-grid">
			{#each domains as domain (domain.id)}
				<div class="domain-card-wrap">
					<a class="domain-card" href={resolve('/[domain=notApi]', { domain: domain.id })}>
						<span class="dot" style={`background:${domain.color}`}></span>
						<span class="domain-name">{domain.label}</span>
					</a>
					<!-- Draft + edit live in the Builder; the card action opens the
					     doctype dialog once the draft branch succeeds. -->
					<Can doctype="core.DocType" action="create">
						<button
							type="button"
							class="domain-add"
							title={m.dashboard_domain_new_doctype({ domain: domain.label })}
							aria-label={m.dashboard_domain_new_doctype({ domain: domain.label })}
							onclick={() => openNewDoctype(domain.id)}
						>
							<Plus size={13} stroke-width={2} aria-hidden="true" />
						</button>
					</Can>
				</div>
			{/each}
		</div>
	{/if}
</div>

<NewDoctypeDialog bind:open={doctypeDialogOpen} oncreate={handleNewDoctype} />

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 960px;
		margin: 0 auto;
	}

	.dash-head {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 4px;
		margin-bottom: 24px;
	}

	.dash-head h1 {
		display: flex;
		align-items: center;
		gap: 8px;
		font-family: var(--font-display);
		font-size: 22px;
		font-weight: 600;
		letter-spacing: -0.01em;
		margin: 0;
		color: var(--text);
	}

	.head-sub {
		font-size: 13px;
		color: var(--text-3);
	}

	/* Quick links — the same chip language as the domain cards, denser. */
	.quick-links {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		margin-bottom: 26px;
	}

	.quick-link {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 7px 13px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
		text-decoration: none;
		transition:
			border-color 0.1s ease,
			background 0.1s ease;
	}

	.quick-link:hover {
		border-color: var(--accent);
		background: var(--sunken);
		color: var(--text);
	}

	.section-head {
		font-size: 12px;
		color: var(--text-3);
		letter-spacing: 0.06em;
		margin-bottom: 10px;
		margin-top: 8px;
	}

	.domain-grid {
		display: grid;
		grid-template-columns: repeat(4, 1fr);
		gap: 12px;
	}

	.domain-card {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 14px 16px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		text-decoration: none;
		color: inherit;
		transition:
			border-color 0.1s ease,
			background 0.1s ease;
	}

	/* Card + its add action travel together so the grid stays uniform. */
	.domain-card-wrap {
		position: relative;
		display: flex;
	}

	.domain-card-wrap .domain-card {
		flex: 1;
	}

	.domain-add {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 30px;
		flex: none;
		background: var(--surface);
		border: 1px solid var(--border);
		border-left: none;
		border-radius: 0 var(--r) var(--r) 0;
		color: var(--text-3);
		cursor: pointer;
		transition:
			border-color 0.1s ease,
			background 0.1s ease;
	}

	.domain-add:hover {
		border-color: var(--accent);
		background: var(--sunken);
		color: var(--accent-ink);
	}

	.domain-card:hover {
		border-color: var(--accent);
		background: var(--sunken);
	}

	.dot {
		width: 8px;
		height: 8px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex: none;
	}

	.domain-name {
		font-family: var(--font-display);
		font-weight: 600;
		font-size: 13px;
		color: var(--text);
	}

	.draft-list {
		display: flex;
		flex-direction: column;
	}

	.draft-row {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 9px 0;
		border-bottom: 1px solid var(--border);
		text-decoration: none;
		color: inherit;
		transition: background 0.1s ease;
	}

	.draft-row:last-child {
		border-bottom: none;
	}

	.draft-row:hover .draft-name {
		color: var(--accent-ink);
	}

	.draft-name {
		font-weight: 600;
		font-size: 13px;
		color: var(--text);
	}

	.draft-count {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}

	.issue-chip {
		flex: none;
		margin-left: auto;
		padding: 2px 7px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 600;
		border: 1px solid transparent;
		line-height: 1.4;
	}

	.issue-chip.warn {
		background: var(--warn-weak, rgba(217, 119, 6, 0.12));
		color: var(--warn);
		border-color: var(--warn);
	}

	.issue-chip.ok {
		background: var(--ok-weak, rgba(34, 197, 94, 0.08));
		color: var(--ok);
		border-color: var(--ok);
	}

	@media (max-width: 900px) {
		.domain-grid {
			grid-template-columns: repeat(2, 1fr);
		}

		.page {
			padding: 20px 20px 32px;
		}
	}

	@media (max-width: 480px) {
		.domain-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
