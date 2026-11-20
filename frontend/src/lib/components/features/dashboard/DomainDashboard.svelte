<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { untrack } from 'svelte';
	import type { CollectionView, CollectionSurface } from '$lib/collectionView/types.js';
	import { flattenNavDoctypes, type NavDomain, type NavDoctype } from '$lib/navTypes';
	import DoctypeIcon from '$lib/components/primitives/data/DoctypeIcon.svelte';
	import { collectionViewsCache } from '$lib/datasource/clientCache.js';
	import { collectionViewDeepLinkSlugs } from '$lib/collectionView/slug.js';
	import { getCount, loadForDomain } from '$lib/navCounts.svelte';
	import { getPinnedCollectionViews } from '$lib/settings.svelte';
	import {
		getRecentDocuments,
		removeRecentDocument,
		type RecentDocument
	} from '$lib/recentDocuments.svelte';
	import { DataSourceError } from '$lib/datasource/types';
	import { resolve } from '$app/paths';
	import { SvelteSet } from 'svelte/reactivity';
	import * as m from '$lib/paraglide/messages';

	/**
	 * DomainDashboard — the landing page shown at `/{domain}`.
	 *
	 * Composes four sections that mirror the
	 * `example/root_view_domain/` mockups: a header, pinned collection views,
	 * recently-viewed documents, and the doctype list with per-doctype record
	 * counts and saved-view quick links.
	 *
	 * The pinned-view cards and the doctype saved-view sub-links both read the
	 * same per-doctype `core.CollectionView` children list (cached 60s by the
	 * shared `collectionViewsCache`), so a doctype listing visit and a dashboard
	 * view share one round-trip. Doctype counts reuse the sidebar's
	 * `navCounts.svelte` store so the dashboard and the sidebar badges stay in
	 * sync. Recently-viewed entries come from the browser-only
	 * `recentDocuments.svelte` localStorage store.
	 */

	let {
		driver,
		domain,
		/**
		 * CollectionView projection ids the user pinned. When omitted, the live
		 * settings store (`getPinnedCollectionViews`) is the source of truth;
		 * inject it together with `recentDocuments` to control the dashboard's
		 * display from stories and tests without touching localStorage/settings.
		 */
		pinnedViewIds,
		/**
		 * Recently-viewed entries for the active domain. When omitted, the
		 * localStorage-backed `getRecentDocuments(domain.id)` store is read.
		 */
		recentDocuments
	}: {
		driver: DataDriver;
		domain: NavDomain;
		pinnedViewIds?: string[];
		recentDocuments?: RecentDocument[];
	} = $props();

	// The nav model nests composition children under their parent; the
	// dashboard browses every doctype flat, so children get their own card,
	// count and saved-view links here.
	const doctypes = $derived<NavDoctype[]>(flattenNavDoctypes(domain.doctypes));

	// ── Per-doctype saved collection views ────────────────────────────────
	//
	// One fetch per doctype (cached by `collectionViewsCache`, keyed by the
	// parent `core.DocType` projection id = the qualified doctype name). The
	// result feeds BOTH the pinned-view cards (filtered by the pinned-id set)
	// and the doctype saved-view sub-links. Errors are swallowed per-doctype —
	// a failed fetch leaves that doctype's sub-links empty without breaking
	// the rest of the dashboard.

	let viewsByDoctype = $state<Record<string, { id: string; data: CollectionView }[]>>({});
	let viewsLoading = $state(true);

	$effect(() => {
		void doctypes;
		const d = driver;
		viewsLoading = true;
		let cancelled = false;
		const entries = doctypes.map(async (dt) => {
			try {
				const items = await collectionViewsCache.get(dt.qualified, async () => {
					const res = await d
						.domain('core')
						.doctype('DocType')
						.doc(dt.qualified)
						.children<CollectionView>('collection_view')
						.list({ items: 500 });
					return res.data.map((item) => ({
						id: item.meta.id,
						data: item.data as CollectionView
					}));
				});
				if (cancelled) return null;
				return [dt.qualified, items] as const;
			} catch {
				return null;
			}
		});
		Promise.all(entries).then((results) => {
			if (cancelled) return;
			const next: Record<string, { id: string; data: CollectionView }[]> = {};
			for (const r of results) {
				if (!r) continue;
				const [qualified, views] = r as [string, { id: string; data: CollectionView }[]];
				next[qualified] = views;
			}
			viewsByDoctype = next;
			viewsLoading = false;
		});
		return () => {
			cancelled = true;
		};
	});

	// ── Doctype record counts ─────────────────────────────────────────────
	//
	// Reuse the sidebar's lazy count loader so the dashboard and the sidebar
	// badges share one `aggregate=count` wave per doctype and the live store.
	// Call once the doctype list is known. This is best-effort; counts surface
	// as `—` until they resolve.
	$effect(() => {
		void doctypes;
		loadForDomain(driver, doctypes).catch(() => {
			/* per-doctype count failures render `—` */
		});
	});

	// ── Pinned views (subset of the saved views above) ────────────────────
	const pinnedIds = $derived<Set<string>>(new Set(pinnedViewIds ?? getPinnedCollectionViews()));

	interface PinnedViewCard {
		viewId: string;
		name: string;
		surface: CollectionSurface;
		qualifiedDoctype: string;
		doctypeLabel: string;
		doctypeIcon: string | null;
		doctypeColor: string;
		count: number | undefined;
	}

	/**
	 * The pinned cards are derived from the per-doctype views already fetched:
	 * intersect the pinned id set with the views whose parent doctype is in
	 * this domain. Pinned views belonging to other domains are not shown here
	 * (the dashboard is domain-scoped).
	 */
	const pinnedCards = $derived.by<PinnedViewCard[]>(() => {
		const out: PinnedViewCard[] = [];
		for (const dt of doctypes) {
			const views = viewsByDoctype[dt.qualified];
			if (!views) continue;
			for (const v of views) {
				if (!pinnedIds.has(v.id)) continue;
				out.push({
					viewId: v.id,
					name: v.data.name,
					surface: v.data.surface,
					qualifiedDoctype: dt.qualified,
					doctypeLabel: dt.label,
					doctypeIcon: dt.icon ?? null,
					doctypeColor: dt.color,
					count: getCount(dt.qualified)
				});
			}
		}
		return out;
	});

	// ── Recently viewed (localStorage, domain-filtered) ────────────────────
	const recent = $derived<RecentDocument[]>(recentDocuments ?? getRecentDocuments(domain.id));

	/** Qualified doctype name for a recent entry (`"crm.Contact"`). */
	function qualifiedFor(entry: RecentDocument): string {
		return `${entry.domain}.${entry.doctype}`;
	}

	interface RecentChip {
		entry: RecentDocument;
		color: string | null;
		icon: string | null;
	}

	/**
	 * Chip view-models. Color and icon come from the domain's `NavDoctype`
	 * list (already in memory); unknown doctypes fall back to no mark.
	 */
	const recentChips = $derived.by<RecentChip[]>(() => {
		const byQualified = new Map(doctypes.map((dt) => [dt.qualified, dt]));
		return recent.map((entry) => {
			const dt = byQualified.get(qualifiedFor(entry));
			return {
				entry,
				color: dt?.color ?? null,
				icon: dt?.icon ?? null
			};
		});
	});

	let recentLabels = $state<Record<string, string>>({});

	/**
	 * Live display labels. The store persists only the document id — display
	 * names can change with document state, so each chip's label is resolved
	 * via `show()` (deduped and cached 60s by `documentShowCache`) and falls
	 * back to the id until it resolves or when the fetch fails (e.g. deleted).
	 * A resolve that answers a definitive "gone" (404 past retention, 410
	 * tombstone) prunes the entry from the store — the same rule the command
	 * palette applies (B-392). The stale chip would otherwise render a raw id
	 * and 404 on activation.
	 */
	// Track which ids already have a fetch in flight. Reads and writes stay
	// inside `untrack`: a tracked read followed by the `add` write would re-run
	// this very effect, the cleanup would flip `cancelled`, and the in-flight
	// `show().then()` would discard its result — chips stay frozen at the id
	// fallback. See `doc/frontend/workflow.md` → "The equality-guard trap in
	// writeback effects". Verified with a runtime probe: a tracked read + write
	// on a `SvelteSet` inside `$effect` re-runs the effect and cancels the work.
	const inFlight = new SvelteSet<string>();
	$effect(() => {
		void recent;
		const d = driver;
		let cancelled = false;
		for (const entry of recent) {
			if (untrack(() => inFlight.has(entry.id))) continue;
			untrack(() => inFlight.add(entry.id));
			recentLabels[entry.id] = entry.id;
			d.domain(entry.domain)
				.doctype(entry.doctype)
				.doc(entry.id)
				.show()
				.then((res) => {
					if (!cancelled) recentLabels[entry.id] = res.meta.display_name ?? entry.id;
				})
				.catch((e: unknown) => {
					// A "gone" answer (404 past retention, 410 tombstone) means the
					// document no longer exists. Prune the entry, like the command
					// palette does (B-392). Other failures keep the entry and the id
					// fallback. The prune ignores `cancelled` on purpose: a document
					// that is gone stays gone, even when the effect re-ran.
					if (e instanceof DataSourceError && (e.status === 404 || e.status === 410)) {
						removeRecentDocument(entry.id);
					}
				});
		}
		return () => {
			cancelled = true;
		};
	});

	// ── Doctype list "show more" collapse ─────────────────────────────────
	/** How many doctype rows are initially expanded before the "show more" gate. */
	const COLLAPSE_AFTER = 6;
	let expanded = $state(false);
	const visibleDoctypes = $derived(
		expanded || doctypes.length <= COLLAPSE_AFTER ? doctypes : doctypes.slice(0, COLLAPSE_AFTER)
	);
	const hiddenDoctypeCount = $derived(Math.max(0, doctypes.length - COLLAPSE_AFTER));

	// ── Pure formatting helpers ───────────────────────────────────────────
	/**
	 * The caption shown under a pinned-view card name: `{Doctype} · {count or 1000+}`.
	 * The surface is conveyed by the card's surface icon, so the bare word is
	 * not repeated here (it was previously the source of the "user types Open,
	 * sees open" confusion). When `count` is undefined, renders `—`.
	 */
	function viewCaption(count: number | undefined, doctypeLabel: string): string {
		const countStr = count === undefined ? '—' : formatCount(count);
		return `${doctypeLabel} · ${countStr}`;
	}

	/**
	 * Format a doctype record count for display. The backend caps list totals
	 * at 1000 (the `more` flag signals the true total exceeds the cap), so a
	 * count at the cap renders as `1000+` to match the mockup.
	 */
	function formatCount(count: number | undefined): string {
		if (count === undefined) return '—';
		// The backend caps list totals at 1000; a count at the cap means the true
		// total is at least that large (the `more` flag), so render `1000+`.
		if (count >= 1000) return '1000+';
		return String(count);
	}

	/**
	 * Route params for the live listing route `/{domain}/{doctype}`, split from
	 * a qualified name. Values are encoded — `resolve` substitutes verbatim.
	 */
	function navParamsDoctype(qualified: string): { domain: string; doctype: string } {
		const dot = qualified.indexOf('.');
		return {
			domain: encodeURIComponent(qualified.slice(0, dot)),
			doctype: encodeURIComponent(qualified.slice(dot + 1))
		};
	}

	/**
	 * Listing route id for a saved view — carries the `?view=` search param so
	 * the listing lands on that view's tab. The slug comes from the view's
	 * name (runtime view ids are opaque ULIDs — see
	 * `$lib/collectionView/slug.ts`); a view whose id still follows the
	 * `<qualified>.collection_view.<slug>` authoring convention answers to its
	 * id slug first. Without any slug the bare listing route id is returned.
	 */
	function navIdForView(
		viewId: string,
		viewName: string
	): '/[domain=notApi]/[doctype]' | `/[domain=notApi]/[doctype]?view=${string}` {
		const slug = collectionViewDeepLinkSlugs(viewId, viewName)[0];
		return slug
			? `/[domain=notApi]/[doctype]?view=${encodeURIComponent(slug)}`
			: '/[domain=notApi]/[doctype]';
	}

	/** Aria label for the surface icon of a pinned-view card. */
	/** Relative-time label (`10m`, `1h`, `yest`) for a timestamp. */
	function relativeTime(ts: number): string {
		const now = Date.now();
		const diff = Math.max(0, now - ts);
		const min = Math.floor(diff / 60_000);
		if (min < 1) return m.common_time_now();
		if (min < 60) return `${min}m`;
		const hours = Math.floor(min / 60);
		if (hours < 24) return `${hours}h`;
		const days = Math.floor(hours / 24);
		if (days === 1) return m.common_time_yesterday_short();
		if (days < 7) return `${days}d`;
		const weeks = Math.floor(days / 7);
		return `${weeks}w`;
	}

	/** Aria label for the surface icon of a pinned-view card. */
	function surfaceLabel(surface: string): string {
		return m.dashboard_surface_aria({ surface });
	}

	// ── Domain totals for the subtitle ────────────────────────────────────
	const totalRecords = $derived.by<number | string>(() => {
		let sum = 0;
		let anyUnknown = false;
		for (const dt of doctypes) {
			const c = getCount(dt.qualified);
			if (c === undefined) {
				anyUnknown = true;
			} else {
				sum += c;
			}
		}
		if (anyUnknown && sum === 0) return '—';
		return sum >= 1000 ? '1000+' : String(sum);
	});
</script>

<svelte:head>
	<title>{m.dashboard_domain_page_title({ name: domain.label })}</title>
</svelte:head>

<div class="domain-dashboard">
	<header class="dash-header">
		<span class="dt-mark" style={`background:${domain.color}`}></span>
		<h1>{domain.label}</h1>
		<p class="dash-sub">
			{m.dashboard_domain_summary({ doctypes: doctypes.length, records: totalRecords })}
		</p>
	</header>

	{#if pinnedCards.length > 0}
		<section class="section pinned-section">
			<h2 class="section-title">{m.dashboard_pinned_title()}</h2>
			<div class="pinned-grid">
				{#each pinnedCards as card (card.viewId)}
					<a
						class="pinned-card"
						href={resolve(
							navIdForView(card.viewId, card.name),
							navParamsDoctype(card.qualifiedDoctype)
						)}
					>
						<span class="pinned-card-head">
							<span class="doctype-mark" style={`--tint:${card.doctypeColor}`} aria-hidden="true">
								<DoctypeIcon icon={card.doctypeIcon} color={card.doctypeColor} size={12} />
							</span>
							<span class="pinned-card-name">{card.name}</span>
							<span class="surface-icon" aria-label={surfaceLabel(card.surface)} role="img">
								{#if card.surface === 'calendar'}
									<svg
										viewBox="0 0 24 24"
										width="14"
										height="14"
										fill="none"
										stroke="currentColor"
										stroke-width="2"
										aria-hidden="true"
									>
										<rect x="3" y="4" width="18" height="18" rx="2" />
										<path d="M16 2v4M8 2v4M3 10h18" />
									</svg>
								{:else if card.surface === 'kanban'}
									<svg
										viewBox="0 0 24 24"
										width="14"
										height="14"
										fill="none"
										stroke="currentColor"
										stroke-width="2"
										aria-hidden="true"
									>
										<rect x="3" y="4" width="6" height="16" rx="1" />
										<rect x="10" y="4" width="6" height="11" rx="1" />
										<rect x="17" y="4" width="4" height="8" rx="1" />
									</svg>
								{:else}
									<svg
										viewBox="0 0 24 24"
										width="14"
										height="14"
										fill="none"
										stroke="currentColor"
										stroke-width="2"
										aria-hidden="true"
									>
										<path d="M3 6h18M3 12h18M3 18h18" />
									</svg>
								{/if}
							</span>
						</span>
						<span class="pinned-card-caption">{viewCaption(card.count, card.doctypeLabel)}</span>
					</a>
				{/each}
			</div>
		</section>
	{:else if !viewsLoading}
		<section class="section pinned-section">
			<div class="pin-empty" role="note">
				<div class="pin-empty-inner">
					<svg
						viewBox="0 0 24 24"
						width="16"
						height="16"
						fill="none"
						stroke="currentColor"
						stroke-width="2"
						aria-hidden="true"
					>
						<path d="M12 17v5" />
						<path
							d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6a1 1 0 0 0 0-2 1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1 1 1 0 0 0 0 2Z"
						/>
					</svg>
					<span>{m.dashboard_pinned_empty()}</span>
				</div>
			</div>
		</section>
	{/if}

	<section class="section recent-section">
		<h2 class="section-title">{m.dashboard_recent_title()}</h2>
		{#if recent.length > 0}
			<div class="chip-row">
				{#each recentChips as chip (chip.entry.id)}
					<a
						class="recent-chip"
						href={resolve('/[domain=notApi]/[doctype]/[id]', {
							domain: encodeURIComponent(chip.entry.domain),
							doctype: encodeURIComponent(chip.entry.doctype),
							id: encodeURIComponent(chip.entry.id)
						})}
						style={chip.color ? `--tint:${chip.color}` : ''}
					>
						{#if chip.color}
							<span class="chip-mark" aria-hidden="true">
								<DoctypeIcon icon={chip.icon} color={chip.color} size={11} />
							</span>
						{/if}
						<span class="chip-label" title={recentLabels[chip.entry.id] ?? chip.entry.id}>
							{recentLabels[chip.entry.id] ?? chip.entry.id}
						</span>
						<span class="chip-time">{relativeTime(chip.entry.ts)}</span>
					</a>
				{/each}
			</div>
		{:else}
			<p class="empty-hint">{m.dashboard_recent_empty()}</p>
		{/if}
	</section>

	<section class="section doctypes-section">
		<h2 class="section-title">{m.nav_group_doctypes()}</h2>
		<ul class="doctype-list">
			{#each visibleDoctypes as dt (dt.qualified)}
				{@const count = getCount(dt.qualified)}
				{@const views = viewsByDoctype[dt.qualified] ?? []}
				<li class="doctype-row">
					<div class="doctype-row-head">
						<a
							class="doctype-name"
							href={resolve('/[domain=notApi]/[doctype]', navParamsDoctype(dt.qualified))}
						>
							<span class="doctype-name-icon" aria-hidden="true">
								<DoctypeIcon icon={dt.icon} color={dt.color} size={12} />
							</span>
							<span class="doctype-name-label">{dt.label}</span>
						</a>
						<span class="doctype-count">{formatCount(count)}</span>
					</div>
					{#if views.length > 0}
						<div class="view-links">
							{#each views as v (v.id)}
								<a
									class="view-link"
									href={resolve(navIdForView(v.id, v.data.name), navParamsDoctype(dt.qualified))}
									>{v.data.name}</a
								>
							{/each}
						</div>
					{/if}
				</li>
			{/each}
		</ul>
		{#if hiddenDoctypeCount > 0}
			<button class="show-more" onclick={() => (expanded = true)}>
				{m.dashboard_show_more({ count: hiddenDoctypeCount })}
			</button>
		{/if}
	</section>
</div>

<style>
	.domain-dashboard {
		padding: 0 0 2rem;
	}

	/* ── Header ──────────────────────────────────────────────────────── */
	.dash-header {
		display: flex;
		align-items: center;
		gap: 9px;
		flex-wrap: wrap;
		margin-bottom: 1.5rem;
	}

	.dt-mark {
		width: 12px;
		height: 12px;
		border-radius: 3px;
		transform: rotate(45deg);
		flex: none;
	}

	.dash-header h1 {
		font-family: var(--font-display);
		font-size: 22px;
		font-weight: 500;
		letter-spacing: -0.01em;
		margin: 0;
	}

	.dash-sub {
		width: 100%;
		margin: 0 0 0 21px;
		font-size: 13px;
		color: var(--text-3);
	}

	/* ── Section shells ─────────────────────────────────────────────── */
	.section {
		margin-bottom: 1.75rem;
	}

	.section-title {
		font-size: 12px;
		color: var(--text-3);
		letter-spacing: 0.06em;
		text-transform: uppercase;
		margin: 0 0 10px;
		font-weight: 600;
	}

	/* ── Pinned views ────────────────────────────────────────────────── */
	.pinned-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
		gap: 8px;
	}

	.pinned-card {
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg);
		padding: 11px 14px;
		text-decoration: none;
		color: inherit;
		display: flex;
		flex-direction: column;
		gap: 4px;
		transition:
			border-color 0.12s,
			background 0.12s;
	}

	.pinned-card:hover {
		border-color: var(--border-strong);
		background: var(--sunken);
	}

	.pinned-card-head {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.pinned-card-head .doctype-mark {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		flex: none;
	}

	.pinned-card-head .surface-icon {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		color: var(--text-3);
		flex: none;
		margin-left: auto;
	}

	.pinned-card-name {
		font-size: 14px;
		font-weight: 500;
		color: var(--text);
	}

	.pinned-card-caption {
		font-size: 12px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.pin-empty {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 11px;
		border: 1px dashed var(--border-strong);
		border-radius: var(--r-lg);
		padding: 22px 16px;
		color: var(--text-3);
		font-size: 13px;
		opacity: 0.85;
	}

	.pin-empty-inner {
		display: inline-flex;
		align-items: center;
		gap: 9px;
		padding: 9px 14px;
		border: 0.5px dashed var(--border);
		border-radius: var(--r);
		color: var(--text-3);
	}

	/* ── Recently viewed ────────────────────────────────────────────── */
	.chip-row {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
	}

	.recent-chip {
		display: inline-flex;
		align-items: baseline;
		gap: 6px;
		font-size: 13px;
		padding: 6px 12px;
		border-radius: var(--r);
		background: var(--surface-2);
		color: var(--text-2);
		text-decoration: none;
		transition:
			background 0.12s,
			color 0.12s;
	}

	.recent-chip:hover {
		background: var(--sunken);
		color: var(--text);
	}

	/* A long display label must not stretch the chip row — cap and ellipsize. */
	.chip-label {
		min-width: 0;
		max-width: 32ch;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.chip-mark {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		flex: none;
		align-self: center;
	}

	.chip-time {
		color: var(--text-3);
		font-size: 12px;
		font-family: var(--font-mono);
	}

	.empty-hint {
		font-size: 13px;
		color: var(--text-3);
	}

	/* ── Doctypes ────────────────────────────────────────────────────── */
	.doctype-list {
		list-style: none;
		margin: 0;
		padding: 0;
	}

	.doctype-row {
		padding: 11px 2px;
		border-bottom: 0.5px solid var(--border);
	}

	.doctype-row:last-child {
		border-bottom: none;
	}

	.doctype-row-head {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.doctype-name {
		flex: 1;
		font-size: 14px;
		font-weight: 500;
		color: var(--text);
		text-decoration: none;
		display: inline-flex;
		align-items: center;
		gap: 8px;
	}

	.doctype-name-icon {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		flex: none;
	}

	.doctype-name-label {
		line-height: 1;
	}

	.doctype-name:hover {
		color: var(--accent-ink);
		text-decoration: underline;
	}

	.doctype-count {
		font-size: 13px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.view-links {
		display: flex;
		gap: 12px;
		margin-top: 5px;
		flex-wrap: wrap;
	}

	.view-link {
		font-size: 12px;
		color: var(--accent-ink);
		text-decoration: none;
	}

	.view-link:hover {
		text-decoration: underline;
	}

	.show-more {
		margin-top: 4px;
		padding: 11px 2px 0;
		background: none;
		border: none;
		font: inherit;
		font-size: 13px;
		color: var(--text-3);
		cursor: pointer;
		text-align: left;
	}

	.show-more:hover {
		color: var(--accent-ink);
	}

	@media (max-width: 640px) {
		.pinned-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
