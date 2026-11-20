<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { untrack } from 'svelte';
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import GlobalAuditTable from '$lib/components/features/audit/GlobalAuditTable.svelte';
	import AuditDetail from '$lib/components/features/audit/AuditDetail.svelte';
	import {
		listAudit,
		rollbackMutation,
		rollbackCluster,
		AuditError
	} from '$lib/components/features/audit/AuditSource.js';
	import { can } from '$lib/permissions.svelte.js';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import QuickViewHost, {
		type QvHostApi
	} from '$lib/components/primitives/surfaces/QuickViewHost.svelte';
	import { auditFilterDoctype } from '$lib/components/features/audit/auditFilters.js';
	import type { DoctypeDef, EnumValue } from '$lib/doctype/types.js';
	import type { AppContent } from '$lib/app/appTypes.js';
	import type { HistoryResponse, MutationRecord } from '$lib/datasource/types.js';
	import { errorMessage as toMessage } from '$lib/datasource/bannerError.js';
	import { SvelteMap } from 'svelte/reactivity';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Global audit log page (/Configure/audit).
	 *
	 * The page owns the filter/pagination state and delegates rendering to
	 * `GlobalAuditTable` and inspection/rollback to `AuditDetail`. A
	 * `QuickViewHost` wraps the layout so clicking a document capsule opens
	 * the peek drawer instead of the full-page show route.
	 */

	const PAGE_SIZE = 25;

	let filters: Record<string, unknown> = $state({});
	let page: number = $state(1);
	let data = $state<HistoryResponse | null>(null);
	let loading: boolean = $state(true);
	let errorMessage: string | undefined = $state(undefined);
	let errorStatus: number | undefined = $state(undefined);

	let selected: MutationRecord | null = $state(null);
	let rollingBack: boolean = $state(false);
	let rollbackError: string | undefined = $state(undefined);

	// The selected mutation's causal cluster (all mutations sharing its
	// `cause_trace`) — drives the cause section and the whole-action rollback.
	let cluster: MutationRecord[] = $state([]);
	let clusterLoading = $state(false);
	let clusterSeq = 0;
	let rollingBackCluster = $state(false);

	// Single shared driver for the peek drawer, the doctype registry, and the
	// filter option loads. Same construction as the other Configure pages.
	const driver = new DocumentDataDriver('');

	// The audit page has no host doctype — the stub is only read by
	// `QuickViewHost` on a root open (`openRootDoc`), which this page never
	// issues; opens go through `openReference`.
	const AUDIT_ROOT_DEF: DoctypeDef = {
		domain: 'core',
		doctype: 'DocType',
		fields: [],
		children: [],
		actions: []
	};

	let domainValues: EnumValue[] = $state([]);
	let doctypeValues: EnumValue[] = $state([]);
	let appValues: EnumValue[] = $state([]);
	let appNames: Record<string, string> = $state({});

	// The `core.DocType` registry load is shared across all consumers (60s TTL
	// cache behind `DoctypeRegistry.cached`).
	let registryPromise: Promise<DoctypeRegistry> | null = null;
	function ensureRegistry(): Promise<DoctypeRegistry> {
		registryPromise ??= DoctypeRegistry.cached(driver);
		return registryPromise;
	}

	function splitQualified(
		qualified: string,
		raw: Record<string, unknown>
	): { domain: string; doctype: string } | null {
		const domain = typeof raw.domain === 'string' ? raw.domain : qualified.split('.')[0];
		const doctype = typeof raw.doctype === 'string' ? raw.doctype : qualified.split('.')[1];
		if (!domain || !doctype) return null;
		return { domain, doctype };
	}

	/** Populate the app filter values and the detail-panel app labels. */
	async function loadApps() {
		try {
			const appsRes = await driver.domain('app').doctype<AppContent>('App').list({ items: 500 });
			const namesMap: Record<string, string> = {};
			const values: EnumValue[] = [];
			for (const app of appsRes.data) {
				const label = app.data.name ?? app.data.slug ?? app.meta.id;
				namesMap[app.meta.id] = label;
				values.push({ key: app.meta.id, label });
			}
			appValues = values.sort((a, b) => (a.label ?? '').localeCompare(b.label ?? ''));
			appNames = namesMap;
		} catch {
			// App list failure only leaves the app filter empty.
		}
	}

	// Populate the filter enums on mount so the pickers carry values before the
	// first dropdown open. The registry feeds the domain and doctype enums (the
	// doctype picker carries the qualified `domain.Doctype` form, so one pick
	// pins both); the app list feeds the app enum and the detail-panel labels.
	$effect(() => {
		void ensureRegistry()
			.then((reg) => {
				const domains = new Set<string>();
				const doctypes = new Set<string>();
				for (const [qualified, raw] of reg.doctypeDefinitions) {
					const parts = splitQualified(qualified, raw);
					if (!parts) continue;
					domains.add(parts.domain);
					doctypes.add(qualified);
				}
				domainValues = [...domains].sort().map((d) => ({ key: d, label: d }));
				doctypeValues = [...doctypes].sort().map((dt) => ({ key: dt, label: dt }));
			})
			.catch(() => {
				// Registry failure leaves both enums empty — the text-style pickers
				// still render, and the list itself is unaffected.
			});
		void loadApps();
	});

	// The filter schema rebuilds when the dynamic enums land; the FilterBar
	// re-renders its pickers reactively.
	const auditDoctype: DoctypeDef = $derived(
		auditFilterDoctype({ domains: domainValues, doctypes: doctypeValues, apps: appValues })
	);

	function openInQuickView(api: QvHostApi, m: MutationRecord) {
		// `mutations.doc_id` is `projections.id` verbatim — pass it as-is.
		api.openReference({ domain: m.domain, doctype: m.doc_type, id: m.doc_id });
	}

	const items: MutationRecord[] = $derived(data?.data ?? []);

	/**
	 * For each document, the id of its newest mutation in the currently loaded
	 * items (newest-first ordering). Rolling back to the newest mutation is a
	 * no-op, so it is blocked — except for a delete, which the backend resolves
	 * to the pre-delete state (a restore, never a no-op).
	 */
	const latestMutationIds: Set<string> = $derived.by(() => {
		// untrack: interleaved get/set on a tracked map inside a derivation
		// self-dirties it and re-runs the derivation.
		return untrack(() => {
			const latest = new SvelteMap<string, { idx: number; id: string }>();
			for (const m of items) {
				const current = latest.get(m.doc_id);
				if (!current || m.idx > current.idx) {
					latest.set(m.doc_id, { idx: m.idx, id: m.id });
				}
			}
			return new Set([...latest.values()].map((v) => v.id));
		});
	});

	const rollBlockReason = $derived.by(() => {
		if (!selected) return '';
		if (selected.action === 'snapshot') {
			return m.audit_block_snapshot();
		}
		if (selected.action !== 'delete' && latestMutationIds.has(selected.id)) {
			return m.audit_block_newest();
		}
		if (!can(`${selected.domain}.${selected.doc_type}`, 'update')) {
			return m.audit_block_permission();
		}
		return '';
	});

	const selectedCanRollback = $derived(selected != null && rollBlockReason === '');

	async function load() {
		loading = true;
		errorMessage = undefined;
		errorStatus = undefined;
		try {
			data = await listAudit({ page, items: PAGE_SIZE, filters, sort: ['-emitted_at'] });
			const sel = selected;
			if (sel && !data.data.some((m) => m.id === sel.id)) {
				selected = null;
			}
		} catch (e) {
			data = null;
			if (e instanceof AuditError) {
				errorStatus = e.status;
				errorMessage = e.status === 403 ? m.audit_forbidden() : e.message;
			} else {
				errorMessage = toMessage(e, m.audit_load_error());
			}
		} finally {
			loading = false;
		}
	}

	// Reload whenever filters or page change (and on mount).
	$effect(() => {
		void filters;
		void page;
		load();
	});

	async function handleRollback(mutation: MutationRecord) {
		rollingBack = true;
		rollbackError = undefined;
		try {
			await rollbackMutation(mutation.id);
			selected = null;
			await load();
		} catch (e) {
			rollbackError = toMessage(e, m.audit_rollback_error());
		} finally {
			rollingBack = false;
		}
	}

	async function handleRollbackCluster() {
		if (!selected) return;
		rollingBackCluster = true;
		rollbackError = undefined;
		try {
			await rollbackCluster(selected.id);
			selected = null;
			await load();
		} catch (e) {
			rollbackError = toMessage(e, m.audit_rollback_error());
		} finally {
			rollingBackCluster = false;
		}
	}

	// Fetch the causal cluster whenever the selection changes. The trace
	// filter is capped at 1000 rows — the same cap the backend undo enforces.
	$effect(() => {
		const sel = selected;
		const my = ++clusterSeq;
		if (!sel) {
			cluster = [];
			clusterLoading = false;
			return;
		}
		clusterLoading = true;
		listAudit({ items: 1000, filters: { trace__eq: sel.cause_trace }, sort: ['emitted_at'] })
			.then((res) => {
				if (my !== clusterSeq) return;
				cluster = res.data;
			})
			.catch(() => {
				if (my !== clusterSeq) return;
				cluster = [];
			})
			.finally(() => {
				if (my === clusterSeq) clusterLoading = false;
			});
	});
</script>

<svelte:head>
	<title>{m.audit_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader title={m.audit_page_header()} subtitle={m.audit_page_subtitle()} />

	{#if errorMessage && errorStatus === 403}
		<div class="state state-error">
			<p>{errorMessage}</p>
		</div>
	{:else if errorMessage}
		<div class="state state-error">
			<p>{errorMessage}</p>
			<button class="retry-btn" type="button" onclick={load}>{m.common_retry()}</button>
		</div>
	{:else}
		<QuickViewHost {driver} rootDef={AUDIT_ROOT_DEF} rootParentDocId="core.DocType">
			{#snippet trigger(api)}
				<div class="layout">
					<GlobalAuditTable
						{items}
						{loading}
						error={undefined}
						meta={data?.meta ?? null}
						{page}
						pageSize={PAGE_SIZE}
						selectedId={selected?.id ?? null}
						{filters}
						doctype={auditDoctype}
						{driver}
						onFilterChange={(next) => {
							filters = next;
							page = 1;
							selected = null;
						}}
						onPageChange={(p) => (page = p)}
						onSelect={(m) => (selected = m)}
						onOpenDocument={(m) => openInQuickView(api, m)}
						onOpenActor={(e) => api.openReference(e)}
					/>
					<AuditDetail
						mutation={selected}
						canRollback={selectedCanRollback}
						{rollBlockReason}
						{rollingBack}
						{rollbackError}
						onRollback={handleRollback}
						onOpenDocument={(m) => openInQuickView(api, m)}
						onOpenSource={(e) => api.openReference(e)}
						onOpenActor={(e) => api.openReference(e)}
						{driver}
						{cluster}
						{clusterLoading}
						{rollingBackCluster}
						onRollbackCluster={handleRollbackCluster}
						{appNames}
					/>
				</div>
			{/snippet}
		</QuickViewHost>
	{/if}
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 1280px;
		margin: 0 auto;
	}

	.layout {
		display: grid;
		grid-template-columns: minmax(0, 1fr) 360px;
		gap: 16px;
		align-items: start;
	}

	@media (max-width: 1100px) {
		.layout {
			grid-template-columns: 1fr;
		}
	}

	.state {
		padding: 24px;
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		background: var(--surface);
	}

	.state p {
		margin: 0;
		font-size: 13px;
		color: var(--text-2);
	}

	.state-error p {
		color: var(--danger);
	}

	.retry-btn {
		margin-top: 12px;
		padding: 6px 14px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.retry-btn:hover {
		background: var(--sunken);
	}
</style>
