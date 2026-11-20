<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DoctypeDefinitionRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import type { DoctypeRegistry } from '../../schematic/doctypeSchematic.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import DangerZone from '../../primitives/surfaces/DangerZone.svelte';
	import DomainCheck from './DomainCheck.svelte';
	import DomainEditorsTab from './DomainEditorsTab.svelte';
	import DomainEditorHeader from './DomainEditorHeader.svelte';
	import DomainOverviewTab from './DomainOverviewTab.svelte';
	import DomainDoctypesTab from './DomainDoctypesTab.svelte';
	import DomainGrantsTab from './DomainGrantsTab.svelte';
	import DomainContextSetCard from './DomainContextSetCard.svelte';
	import {
		composeContextSets,
		contextSetRowsFromMap,
		type ContextSetRow,
		type DomainDoc,
		type DomainEditorContent
	} from './domainSecurity.js';
	import type { DomainGrantContent } from './domainGrants.js';
	import { grantDomainId } from './domainGrants.js';
	import { fetchDomainCheck, type DomainCheckResult } from '$lib/datasource/domainCheck.js';
	import type { ListItem } from '$lib/datasource/types.js';
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { untrack } from 'svelte';
	import { setBuilderDraft } from '$lib/builderDraft.svelte';
	import { isSystemDomain } from '$lib/systemDomains.js';
	import { domainListCache } from '$lib/datasource/clientCache.js';
	import { documentShowCache } from '$lib/datasource/clientCache.js';
	import { createSaveFlash } from '$lib/utils/saveFlash.svelte.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import * as m from '$lib/paraglide/messages';

	/** Tab vocabulary (URL-driven): overview — identity; doctypes — list +
	 *  schematic; editors — the core.DomainEditor grant list; grants — issued
	 *  + held core.DomainGrant documents + context-set RBAC; check —
	 *  draft-only diagnostics, hidden on published configs. */
	type Tab = 'overview' | 'doctypes' | 'editors' | 'grants' | 'check';

	let {
		registry,
		domain,
		tab = 'overview',
		ondoctypeclick,
		ontabselect,
		crumb
	}: {
		/** Doctype-definition registry — `MockDataDriver` (stories) or a real
		 *  `DoctypeRegistry` (app). Drives the schematic, the doctype list, and
		 *  the core.Domain fetch for the overview + grants tabs. */
		registry: DoctypeDefinitionRegistry;
		/** Domain id, e.g. "production", "crm". */
		domain: string;
		/** Active tab — URL-driven via the Builder route. */
		tab?: Tab;
		/** Called when a doctype node is clicked in the doctypes tab, with
		 *  the qualified doctype id (e.g. "production.Project"). */
		ondoctypeclick?: (qualified: string) => void;
		/** Called when the user picks a tab, instead of the default Builder
		 *  navigation. Mounts outside the Builder pass a callback that
		 *  resolves their own tab routes. */
		ontabselect?: (tab: Tab) => void;
		/** Header crumb link — label plus resolved href. The default crumb
		 *  targets the Builder landing. */
		crumb?: { label: string; href: string };
	} = $props();

	// Doctype definitions in this domain — filtered from the registry by
	// domain prefix and parsed into typed DoctypeDef objects.

	const domainDoctypes = $derived.by<DoctypeDef[]>(() => {
		const out: DoctypeDef[] = [];
		for (const [qualified, raw] of registry.doctypeDefinitions) {
			const dot = qualified.indexOf('.');
			if (qualified.slice(0, dot) !== domain) continue;
			out.push(parseDoctypeDef(structuredClone(raw)));
		}
		out.sort((a, b) => a.doctype.localeCompare(b.doctype));
		return out;
	});

	const schematicRegistry = $derived(registry as unknown as DoctypeRegistry);

	// The core.Domain document holds the identity fields plus the security
	// fields `context_sets` and `hooks`. The `DomainDoc` type and the model
	// rules live in `./domainSecurity.ts`; the grant documents are separate
	// `core.DomainGrant` rows loaded in `loadGrants` below.

	let domainDoc = $state<DomainDoc | undefined>(undefined);
	let loadError = $state<string | undefined>(undefined);

	// Working copy of context sets as a mutable array (the document stores a
	// map keyed by name; array rows plus {key, value} `where` pairs survive
	// reorder/rename without focus loss). Rebuilt to a map on save.
	let contextSetRows = $state<ContextSetRow[]>([]);

	// Working copy of the optional `color` field. `ColorInput`'s `value` prop
	// is `$bindable('#5B8DEF')` (a fallback), and Svelte 5 rejects
	// `bind:value={undefined}` when the prop has a fallback. Since `color` is
	// optional on the domain document, we hold it in a separate `$state` string
	// (loaded from the doc, written back on save) — the bindable target is
	// always a defined string.
	let colorValue = $state('');

	async function loadDomainDoc() {
		loadError = undefined;
		try {
			const list = await registry.domain('core').doctype('Domain').list({ items: 500 });
			const match = list.data.find((item) => item.meta.id === domain);
			if (!match) {
				domainDoc = undefined;
				loadError = m.configure_domains_not_found({ name: domain });
				return;
			}
			domainDoc = structuredClone(match.data) as DomainDoc;
			colorValue = domainDoc.color ?? '';
			// Build the working-copy array of context sets from the map.
			contextSetRows = contextSetRowsFromMap(domainDoc.context_sets);
		} catch (err) {
			domainDoc = undefined;
			loadError = errorMessage(err);
		}
	}

	// Initial load + reload when the domain id changes.
	$effect(() => {
		void domain;
		loadDomainDoc();
	});

	// The active tab is URL-driven (e.g. /Builder/_abc/grants); the header
	// calls back and `selectTab` navigates via `goto` so the URL reflects the
	// user's location and browser back/forward works.
	let activeTab = $derived(tab);

	// ── Doctypes tab: selected doctype (by qualified name) ─────────────────

	let selectedDoctype = $state<string | undefined>(undefined);

	function selectTab(newTab: Tab) {
		// Mounts outside the Builder supply their own tab routes through
		// `ontabselect`; the default targets the Builder editor routes.
		if (ontabselect) {
			ontabselect(newTab);
			return;
		}
		goto(resolve(`/Builder/[draftDomain]/(editor)/${newTab}`, { draftDomain: domain }));
	}

	// ── Grants tab: issued + held core.DomainGrant documents ──────────
	// Two document lists, both in `core`: the domain's own grants read
	// through the child collection (`/Api/core/Domain/:id/grants`, the
	// producer side), and the grants filed in this domain's favour, read
	// through the `consumer_domain` equality filter (the consumer side).
	// System domains hold no grants — the create validator rejects them —
	// so the reads are skipped there.

	let issuedGrants = $state<ListItem<DomainGrantContent>[]>([]);
	let heldGrants = $state<ListItem<DomainGrantContent>[]>([]);
	let grantsLoading = $state(false);
	let grantsError = $state<string | undefined>(undefined);

	// ── Derived counts for tab badges ─────────────────────────────────────

	const doctypeCount = $derived(domainDoctypes.length);
	const grantCount = $derived(issuedGrants.length + heldGrants.length);
	const contextSetCount = $derived(contextSetRows.length);

	// ── Context set editor helpers ────────────────────────────────────────
	// On save, `composeContextSets` rebuilds the map shape the backend expects
	// and it is assigned to the domain document.

	function addContextSet() {
		contextSetRows = [...contextSetRows, { name: 'new_set', from: '', select: '', where: [] }];
	}

	function removeContextSet(index: number) {
		contextSetRows = contextSetRows.filter((_, i) => i !== index);
	}

	function addWhereEntry(row: ContextSetRow) {
		row.where = [...row.where, { key: 'field_' + row.where.length, value: '$self' }];
	}

	function removeWhereEntry(row: ContextSetRow, index: number) {
		row.where = row.where.filter((_, i) => i !== index);
	}

	// ── Save ─────────────────────────────────────────────────────────────────
	// PATCH /Api/core/Domain/:id — the backend deep-merges the patch, so only
	// the keys the editor surfaces are sent; `documentShowCache` is dropped
	// and `invalidateAll()` re-runs loaders after success.

	const flash = createSaveFlash();

	async function handleSave() {
		if (!domainDoc || !domain) return;
		if (flash.status === 'saving') return;

		// Fold the working-copy-only fields back into the document so the patch is
		// built from the same source as the editor display.
		domainDoc.color = colorValue || undefined;
		domainDoc.context_sets = composeContextSets(contextSetRows);

		flash.saving();
		try {
			const { apiFetch } = await import('$lib/session.svelte');
			const patch: Record<string, unknown> = {
				name: domainDoc.name,
				description: domainDoc.description,
				context_sets: domainDoc.context_sets ?? {}
			};
			// `color` is optional — omit it when cleared so deep-merge does not
			// override the stored value with `undefined`.
			if (domainDoc.color !== undefined) patch.color = domainDoc.color;

			const res = await apiFetch(`/Api/core/Domain/${encodeURIComponent(domain)}`, {
				method: 'PATCH',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(patch)
			});
			if (!res.ok) {
				const errBody = await res.json().catch(() => ({}));
				flash.failed(errBody.error ?? m.builder_draft_failed_status({ status: res.status }));
				return;
			}

			// Drop the cached `show()` for this domain and re-run loaders so the
			// next read reflects the saved state. The check tab refetches via its
			// own `loadCheck` effect keyed on `domainDoc?.draft`.
			documentShowCache.invalidate(`/Api/core/Domain/${encodeURIComponent(domain)}`);
			invalidateAll().catch(() => {});

			flash.saved();
		} catch (err) {
			flash.failed(errorMessage(err));
		}
	}

	// ── Editors tab: the core.DomainEditor grant list ──────────────────────
	// The rows are separate admin-managed documents (not domain content),
	// filtered by the grant's `domain` field for the tab badge and the Editors
	// pane. System domains never carry rows — the doctype's Lua create guard
	// rejects them — so the read is skipped there.

	let editorRows = $state<ListItem<DomainEditorContent>[]>([]);
	let editorsLoading = $state(false);
	let editorsError = $state<string | undefined>(undefined);
	const editorCount = $derived(editorRows.length);

	async function loadEditors() {
		if (isSystemDomain(domain)) {
			editorRows = [];
			editorsError = undefined;
			return;
		}
		editorsLoading = true;
		editorsError = undefined;
		try {
			const list = await registry
				.domain('core')
				.doctype<DomainEditorContent>('DomainEditor')
				.list({ filters: { domain__eq: domain }, items: 1000 });
			editorRows = list.data;
		} catch (err) {
			editorRows = [];
			editorsError = errorMessage(err);
		} finally {
			editorsLoading = false;
		}
	}

	// Initial load + reload when the domain id changes.
	$effect(() => {
		void domain;
		loadEditors();
	});

	// ── Grants tab: issued + held core.DomainGrant documents ──────
	// The lists are declared with the tab-badge state above (the badge
	// counts both sides); the domain's doctype names below feed the
	// resource-doctype options on the issued side.

	// The domain's doctype names — the resource-doctype options on the
	// issued side. Derived from the registry, so it needs no fetch.
	const DOMAIN_DOCTYPE_NAMES = $derived(
		domainDoctypes.map((d) => d.doctype).sort((a, b) => a.localeCompare(b))
	);

	async function loadGrants() {
		if (isSystemDomain(domain)) {
			issuedGrants = [];
			heldGrants = [];
			grantsError = undefined;
			return;
		}
		grantsLoading = true;
		grantsError = undefined;
		try {
			const issuedList = await registry
				.domain('core')
				.doctype('Domain')
				.doc(domain)
				.children<DomainGrantContent>('grants')
				.list({ items: 1000 });
			const heldList = await registry
				.domain('core')
				.doctype<DomainGrantContent>('DomainGrant')
				.list({
					// The reference equality filter accepts the bare form; the
					// qualified form is what the mock driver matches verbatim.
					filters: { consumer_domain__eq: `core.Domain.${domain}` },
					items: 1000
				});
			// A grant names one consumer — the held list must exclude grants
			// issued by this domain (a child row never names itself, but the
			// guard keeps the two lists disjoint when the filter misfires).
			const issuedIds = new Set(issuedList.data.map((g) => g.meta.id));
			issuedGrants = issuedList.data;
			heldGrants = heldList.data.filter(
				(g) => !issuedIds.has(g.meta.id) && grantDomainId(g.data.consumer_domain) === domain
			);
		} catch (err) {
			issuedGrants = [];
			heldGrants = [];
			grantsError = errorMessage(err);
		} finally {
			grantsLoading = false;
		}
	}

	// Initial load + reload when the domain id changes.
	$effect(() => {
		void domain;
		loadGrants();
	});

	// ── Draft domain check + publish state ─────────────────────────────────
	// Draft-only diagnostics from `GET /Api/core/Domain/:id/check`, re-fetched
	// when the domain changes and on Refresh. The publish dialog is hosted by
	// `(editor)/+layout.svelte`; this editor only feeds the shared
	// `builderDraft` store so the top bar has a single source of truth.

	let checkState = $state<DomainCheckResult | undefined>(undefined);
	let checkError = $state<string | undefined>(undefined);
	let checkLoading = $state(false);

	async function loadCheck() {
		if (!domainDoc?.draft) {
			checkState = undefined;
			checkError = undefined;
			return;
		}
		checkLoading = true;
		checkError = undefined;
		try {
			checkState = await fetchDomainCheck(domain);
		} catch (err) {
			checkState = undefined;
			checkError = errorMessage(err);
		} finally {
			checkLoading = false;
		}
	}

	// Initial load + reload when the domain id changes. Skipped for non-draft
	// domains so live domains don't pay the round-trip.
	$effect(() => {
		void domain;
		void domainDoc?.draft;
		loadCheck();
	});

	const checkIssueCount = $derived(checkState?.issue_count ?? 0);
	const isDraft = $derived(domainDoc?.draft === true);

	// ── Danger zone ──────────────────────────────────────────────────────
	// Deletes (or discards, for drafts) via `POST /Api/core/Domain/:id/drop`.
	// System domains never render the zone: the backend refuses them, so a
	// dead button would only confuse.

	let dropping = $state(false);
	let dropError = $state<string | undefined>(undefined);

	const canDrop = $derived(domainDoc !== undefined && !isSystemDomain(domain));

	async function handleDrop() {
		if (!canDrop || dropping) return;
		dropping = true;
		dropError = undefined;
		try {
			const { apiFetch } = await import('$lib/session.svelte');
			const res = await apiFetch(`/Api/core/Domain/${encodeURIComponent(domain)}/drop`, {
				method: 'POST'
			});
			if (!res.ok) {
				const body = await res.json().catch(() => ({}));
				dropError = body.error ?? m.builder_draft_failed_status({ status: res.status });
				return;
			}
			// The domain list, the nav model, and the cached `show()` all still
			// hold the dropped domain — drop them before navigating so neither
			// the sidebar nor the landing pages resurrect it within the TTL.
			domainListCache.invalidate();
			documentShowCache.invalidate(`/Api/core/Domain/${encodeURIComponent(domain)}`);
			await goto(isDraft ? resolve('/Builder') : resolve('/Configure/domains'));
			await invalidateAll();
		} catch (err) {
			dropError = errorMessage(err);
		} finally {
			dropping = false;
		}
	}

	// Publish this draft's state to the builderDraft store so the top bar can
	// render it and the publish dialog can prefill its input.
	//
	// `publishName` prefers the author's intended target name (the `name`
	// field, editable on Overview), then falls back to the `source_domain`
	// the draft was branched from. Empty drafts get no prefill. Note the
	// fallback chain must not use `domain` — that is the `_`-prefixed draft
	// id, which is never a valid publish target.
	//
	// `untrack` around the write keeps the effect from re-running when the
	// store's `$state` updates — the store's snapshot is a downstream sink, not
	// an upstream input of the editor, so reading it back would form a cycle.
	$effect(() => {
		const snapshot = {
			id: domain,
			name: domainDoc?.label?.trim() || domainDoc?.name || domain,
			isDraft,
			checkIssueCount,
			publishName: domainDoc?.name?.trim() || domainDoc?.source_domain || '',
			check: checkState
		};
		untrack(() => setBuilderDraft(snapshot));
	});
</script>

{#if loadError}
	<div class="not-found">
		<p>{loadError}</p>
		<span class="mono">core.Domain.{domain}</span>
	</div>
{:else if domainDoc}
	<div class="page">
		<DomainEditorHeader
			{domain}
			name={domainDoc.label?.trim() || domainDoc.name || domain}
			color={domainDoc.color}
			draft={domainDoc.draft}
			sourceDomain={domainDoc.source_domain}
			{flash}
			tab={activeTab}
			{crumb}
			{doctypeCount}
			{editorCount}
			{grantCount}
			{contextSetCount}
			{checkIssueCount}
			onsave={handleSave}
			ontabselect={selectTab}
		/>

		<div class="content">
			{#if activeTab === 'overview'}
				<div class="pane on">
					<div class="scrollpane">
						<div class="maxw">
							<DomainOverviewTab
								{domain}
								label={domainDoc.label ?? ''}
								bind:color={colorValue}
								description={domainDoc.description ?? ''}
								onlabelinput={(v) => (domainDoc!.label = v || undefined)}
								ondescriptionchange={(v) => (domainDoc!.description = v || undefined)}
							/>

							<!-- Drop decision is parent state — the zone stays here. -->
							{#if canDrop}
								<DangerZone
									title={isDraft
										? m.configure_domains_discard_title()
										: m.configure_danger_zone_title()}
									warning={isDraft
										? m.configure_domains_discard_helper()
										: m.configure_domains_danger_helper()}
									confirmTarget={domain}
									confirmLabel={isDraft
										? m.configure_domains_discard_title()
										: m.configure_domains_delete_button()}
									busyLabel={isDraft
										? m.configure_domains_discarding_button()
										: m.common_deleting()}
									busy={dropping}
									error={dropError}
									onconfirm={handleDrop}
								/>
							{/if}
						</div>
					</div>
				</div>
			{:else if activeTab === 'doctypes'}
				<div class="pane on">
					<DomainDoctypesTab
						{domain}
						doctypes={domainDoctypes}
						registry={schematicRegistry}
						bind:selectedDoctype
						{ondoctypeclick}
					/>
				</div>
			{:else if activeTab === 'editors'}
				<div class="pane on">
					<div class="scrollpane">
						<div class="maxw">
							<DomainEditorsTab
								{registry}
								{domain}
								rows={editorRows}
								loading={editorsLoading}
								error={editorsError}
								onreload={loadEditors}
							/>
						</div>
					</div>
				</div>
			{:else if activeTab === 'grants'}
				<div class="pane on">
					<div class="scrollpane">
						<div class="maxw">
							<!-- ── Domain grants: issued + held ───────────────────── -->
							<DomainGrantsTab
								{registry}
								{domain}
								issued={issuedGrants}
								held={heldGrants}
								doctypeNames={DOMAIN_DOCTYPE_NAMES}
								loading={grantsLoading}
								error={grantsError}
								onreload={loadGrants}
							/>

							<!-- ── RBAC context sets ─────────────────────────────── -->
							<div class="fsec">
								<div class="sec-head">
									<h2 class="sec-title">{m.configure_domains_context_sets_title()}</h2>
									<button class="addbtn" onclick={addContextSet}>
										{m.configure_domains_add_context_set_button()}
									</button>
								</div>
								<p class="sec-hint">
									{m.configure_domains_context_sets_helper()}
								</p>
								{#each contextSetRows as row, ridx (ridx)}
									<DomainContextSetCard
										{row}
										doctypeNames={DOMAIN_DOCTYPE_NAMES}
										onremove={() => removeContextSet(ridx)}
										onaddwhere={() => addWhereEntry(row)}
										onremovewhere={(widx) => removeWhereEntry(row, widx)}
									/>
								{:else}
									<div class="empty-card">
										{m.configure_domains_context_sets_empty()}
									</div>
								{/each}
							</div>
						</div>
					</div>
				</div>
			{:else if activeTab === 'check'}
				<div class="pane on">
					<div class="scrollpane">
						<div class="maxw">
							<DomainCheck
								check={checkState}
								loading={checkLoading}
								error={checkError}
								onrefresh={loadCheck}
							/>
						</div>
					</div>
				</div>
			{/if}
		</div>
	</div>
{:else}
	<div class="not-found">
		<p>{m.configure_domains_loading()}</p>
	</div>
{/if}

<style>
	.page {
		display: flex;
		flex-direction: column;
		height: 100vh;
		min-height: 0;
		background: var(--surface-2);
	}

	/* ── Content ───────────────────────────────────────────────────── */
	.content {
		flex: 1 1 auto;
		min-height: 0;
		overflow: hidden;
		position: relative;
	}
	.pane {
		position: absolute;
		inset: 0;
		opacity: 0;
		pointer-events: none;
		transition: opacity 0.12s;
	}
	.pane.on {
		opacity: 1;
		pointer-events: auto;
	}

	.scrollpane {
		height: 100%;
		overflow: auto;
		padding: 24px;
	}
	.maxw {
		max-width: 760px;
		margin: 0 auto;
	}

	/* ── Form sections (grants tab scaffolding) ─────────────────────────── */
	.fsec {
		margin-bottom: 28px;
	}
	.fsec h2.sec-title {
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
		margin: 0 0 13px;
		padding-bottom: 7px;
		border-bottom: 1px solid var(--border);
	}
	.sec-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding-bottom: 7px;
		border-bottom: 1px solid var(--border);
	}
	.sec-head h2.sec-title {
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
		margin: 0;
		padding: 0;
		border: none;
	}
	.sec-hint {
		font-size: 12px;
		color: var(--text-3);
		line-height: 1.5;
		margin: 8px 0 16px;
	}
	.empty-card {
		border: 1px dashed var(--border);
		border-radius: var(--r);
		padding: 18px;
		font-size: 12.5px;
		color: var(--text-3);
		text-align: center;
	}

	.addbtn {
		font: inherit;
		font-size: 12px;
		font-weight: 600;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border: 1px solid transparent;
		border-radius: var(--r);
		padding: 5px 11px;
		cursor: pointer;
		transition:
			background 0.12s,
			border-color 0.12s;
	}
	.addbtn:hover {
		border-color: var(--accent);
	}

	/* ── States ─────────────────────────────────────────────────────────── */
	.not-found {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		height: 100%;
		color: var(--text-3);
		gap: 8px;
	}
	.not-found .mono {
		font-family: var(--font-mono);
		font-size: 12px;
	}
	.not-found p {
		font-size: 13px;
		margin: 0;
	}
</style>
