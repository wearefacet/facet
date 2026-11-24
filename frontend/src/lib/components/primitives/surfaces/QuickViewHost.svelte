<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DocumentResponse } from '$lib/datasource/types';
	import { DataSourceError } from '$lib/datasource/types.js';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { parseDoctypeDef, humanize, type DoctypeDef } from '$lib/doctype/types.js';
	import { loadDoctypeViewByKind } from '$lib/doctype/loadDocumentView.js';
	import { formatFullDate } from '$lib/utils/relativeTime.js';
	import type { ReferenceClickHandler, TemplateNode } from '$lib/template-types';
	import QuickView from './QuickView.svelte';
	import QvIdentity from './QvIdentity.svelte';
	import RestoreButton from '../data/RestoreButton.svelte';
	import type { QvDeletedDoc } from './documentIdentity.js';
	import { ExternalLink, Pencil } from '@lucide/svelte';
	import { can } from '$lib/permissions.svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { insideDialog, isInteractiveTarget, isTypingTarget } from '$lib/shortcuts.svelte';
	import DocumentViewTemplate from '../../features/document-view/DocumentViewTemplate.svelte';
	import DvtValue from '../../features/document-view/DvtValue.svelte';
	import { fieldDefFor, resolveValue } from '$lib/template-resolve';

	/**
	 * API handed to the host's `trigger` snippet so the surrounding surface can
	 * ask the host to open a document in the peek drawer.
	 *
	 * - `openReference(e)` follows a reference capsule click — pushes onto the
	 *   nav stack (so the Back button returns to the previous document), and
	 *   resolves the referenced doctype's def from the `core.DocType` registry.
	 * - `openRootDoc(docId)` opens a document belonging to the host surface's
	 *   own doctype (e.g. a list row click on `crm.Contact`) — replaces the
	 *   stack with a single entry, skipping the registry round-trip since the
	 *   def is already known (passed in as `rootDef` / `rootParentDocId`).
	 */
	export type QvHostApi = {
		openReference: ReferenceClickHandler;
		openRootDoc: (docId: string) => void;
	};

	interface QvNavEntry {
		def: DoctypeDef;
		/** Qualified `core.DocType` projection id (`"crm.Contact"`). */
		parentDocId: string;
		docId: string;
	}

	let {
		driver,
		rootDef,
		rootParentDocId,
		trigger
	}: {
		/**
		 * Driver used to fetch the referenced documents, their doctype
		 * definitions (via `DoctypeRegistry`), and the matching `quickView`
		 * view template.
		 */
		driver: DataDriver;
		/**
		 * Doctype definition of the host surface's own doctype. Returned to as
		 * the fallback `def` when no nav entry is on the stack yet (e.g. while
		 * the first document is still loading on a root open).
		 */
		rootDef: DoctypeDef;
		/**
		 * Qualified projection id of the host surface's doctype
		 * (e.g. `"crm.Contact"`). Used as the fallback parent for the
		 * `quickView` template load during a root open.
		 */
		rootParentDocId: string;
		/**
		 * Hosted surface (table, document show view, …). Receives an `api`
		 * object with `openReference` and `openRootDoc` to wire into click
		 * handlers (capsules, rows, …).
		 */
		trigger: import('svelte').Snippet<[api: QvHostApi]>;
	} = $props();

	let selectedDoc = $state<DocumentResponse<Record<string, unknown>> | null>(null);
	let quickViewError = $state<string | null>(null);
	// Tombstone open — the requested document exists but is deleted (`410`)
	// with the surviving label/timestamp in the error body. Renders a deleted
	// card with a Restore affordance instead of the raw error.
	let qvDeleted = $state<QvDeletedDoc | null>(null);
	// Qualified doctype name of the request that failed — shown in the header
	// while the nav stack is still empty (otherwise the host's `rootDef` leaks
	// through, e.g. the audit page's `core.DocType` stub).
	let qvErrorName = $state<string | null>(null);
	let quickViewTemplate = $state<TemplateNode | null>(null);
	let quickViewTemplateLoading = $state(false);
	let quickViewTemplateLoaded = $state(false);
	// While true, the drawer is open but the document/template fetch is still
	// in flight (or the previous document is being shown until the new one
	// resolves). Lets the drawer stay mounted across navigations.
	let qvLoading = $state(false);
	// Cancellation counter — increments on every open/pop/reset so any
	// in-flight fetch whose sequence no longer matches the latest can no-op.
	let qvLoadSeq = 0;
	let qvNav = $state<QvNavEntry[]>([]);
	// Two-phase close. `closeQuickView()` only drops the `on` class so the
	// slide-out plays with the content intact; the state clear waits for
	// QuickView to report the transition finished (`qvClosed`).
	let qvClosing = $state(false);

	const activeNav = $derived(qvNav.length > 0 ? qvNav[qvNav.length - 1] : null);
	const activeDef = $derived(activeNav?.def ?? rootDef);
	const activeParentDocId = $derived(activeNav?.parentDocId ?? rootParentDocId);

	async function ensureQuickViewTemplate() {
		if (quickViewTemplateLoaded) return;
		quickViewTemplateLoading = true;
		const result = await loadDoctypeViewByKind(driver, activeParentDocId, 'quickView');
		quickViewTemplate = result.template;
		quickViewTemplateLoaded = true;
		quickViewTemplateLoading = false;
	}

	function clearQuickViewState() {
		selectedDoc = null;
		quickViewError = null;
		qvDeleted = null;
		qvErrorName = null;
		quickViewTemplate = null;
		quickViewTemplateLoaded = false;
		quickViewTemplateLoading = false;
		qvNav = [];
		qvLoading = false;
	}

	/** Request close: keep the content rendered while the drawer slides out. */
	function closeQuickView() {
		if (qvClosing) return;
		qvLoadSeq++;
		qvClosing = true;
	}

	/** The drawer's close transition finished — drop the kept content. */
	function qvClosed() {
		if (!qvClosing) return;
		qvClosing = false;
		clearQuickViewState();
	}

	/**
	 * Pop one entry off the nav stack — wired to the header's Back button.
	 * Loads the previous document + its doctype's `quickView` template, kept
	 * rendered during the fetch so the drawer doesn't collapse-and-reopen.
	 */
	async function popQvNav() {
		if (qvNav.length <= 1) {
			closeQuickView();
			return;
		}
		const target = qvNav[qvNav.length - 2];
		const my = ++qvLoadSeq;
		qvLoading = true;
		quickViewError = null;
		qvDeleted = null;
		qvErrorName = null;
		quickViewTemplate = null;
		quickViewTemplateLoaded = false;
		quickViewTemplateLoading = false;
		try {
			const ds = driver.domain(target.def.domain).doctype(target.def.doctype);
			const doc = await ds.doc(target.docId).show();
			if (my !== qvLoadSeq) return;
			qvNav.pop();
			selectedDoc = doc;
		} catch (e) {
			if (my !== qvLoadSeq) return;
			qvErrorName = `${target.def.domain}.${target.def.doctype}`;
			quickViewError = errorMessage(e, m.errors_document_load_failed());
		} finally {
			if (my === qvLoadSeq) qvLoading = false;
		}
		void ensureQuickViewTemplate();
	}

	/**
	 * Open a document belonging to the host surface's own doctype (e.g. a list
	 * row click on `crm.Contact`). Replaces the nav stack with a single entry
	 * — the def is already known so we skip the registry round-trip.
	 */
	function openRootDoc(docId: string) {
		if (typeof docId !== 'string' || docId.length === 0) return;
		void runOpen({
			entries: [{ def: rootDef, parentDocId: rootParentDocId, docId }],
			replace: true
		});
	}

	/**
	 * Follow a reference capsule click — pushes the referenced document onto
	 * the nav stack so Back returns to the previous document. Resolves the
	 * referenced doctype's def from `core.DocType` (cached per-driver in
	 * `DoctypeRegistry`).
	 *
	 * The referenced doctype's `core.DocType` projection id equals its
	 * qualified name (e.g. `"crm.Company"`) — the id is preserved
	 * verbatim by `domain:import` (the doctype entry's filename stem
	 * becomes `projections.id`).
	 */
	function openReference(e: { domain: string; doctype: string; id: string }) {
		const qualified = `${e.domain}.${e.doctype}`;
		void runOpen({
			entries: [{ qualified, domain: e.domain, doctype: e.doctype, docId: e.id }],
			replace: false
		});
	}

	/**
	 * Shared load pipeline. `entries` carries either a fully-resolved entry
	 * (`def` + `parentDocId` + `docId`) when the def is already known, or a
	 * pending entry (`qualified` + `domain` + `doctype` + `docId`) that needs a
	 * registry lookup.
	 */
	async function runOpen(
		opts:
			| {
					entries: { def: DoctypeDef; parentDocId: string; docId: string }[];
					replace: true;
			  }
			| {
					entries: { qualified: string; domain: string; doctype: string; docId: string }[];
					replace: false;
			  }
	) {
		const my = ++qvLoadSeq;
		// A new open cancels a pending close — the drawer slides back in.
		qvClosing = false;
		// Keep the previous document rendered while the new one loads so the
		// drawer doesn't collapse-and-reopen (scrim/drawer flicker). The push
		// + doc swap happen atomically once the fetch resolves.
		qvLoading = true;
		quickViewError = null;
		qvDeleted = null;
		qvErrorName = null;
		let def: DoctypeDef | null = null;
		try {
			const entry = opts.entries[0];
			let parentDocId: string;
			if ('def' in entry) {
				def = entry.def;
				parentDocId = entry.parentDocId;
			} else {
				const reg = await DoctypeRegistry.cached(driver);
				if (my !== qvLoadSeq) return;
				const raw = reg.doctypeDefinitions.get(entry.qualified);
				if (!raw) {
					// The registry is built from the RBAC-scoped `core.DocType`
					// list, so a doctype the caller cannot read is absent — same as
					// a doctype that does not exist. Ask the REST route for the
					// target to tell the two apart: `403` means "no access", any
					// other answer keeps the "not found in registry" verdict.
					let probeStatus: number | null = null;
					try {
						await driver.domain(entry.domain).doctype(entry.doctype).doc(entry.docId).show();
					} catch (probeErr) {
						if (probeErr instanceof DataSourceError) probeStatus = probeErr.status;
					}
					if (my !== qvLoadSeq) return;
					if (probeStatus === 403) {
						qvErrorName = entry.qualified;
						quickViewError = m.errors_reference_no_access();
						return;
					}
					throw new Error(m.errors_doctype_not_registered({ name: entry.qualified }));
				}
				def = parseDoctypeDef(raw as Record<string, unknown>);
				parentDocId = entry.qualified;
			}
			const doc = await driver.domain(def.domain).doctype(def.doctype).doc(entry.docId).show();
			if (my !== qvLoadSeq) return;
			if (opts.replace) {
				qvNav = [{ def, parentDocId, docId: entry.docId }];
			} else {
				qvNav = [...qvNav, { def, parentDocId, docId: entry.docId }];
			}
			selectedDoc = doc;
			quickViewTemplate = null;
			quickViewTemplateLoaded = false;
			quickViewTemplateLoading = false;
		} catch (err) {
			if (my !== qvLoadSeq) return;
			// Header fallback: the nav entry was never pushed, so the header's
			// `activeDef` would show the host's root def. Name the request instead.
			qvErrorName = def
				? `${def.domain}.${def.doctype}`
				: 'qualified' in opts.entries[0]
					? opts.entries[0].qualified
					: `${opts.entries[0].def.domain}.${opts.entries[0].def.doctype}`;
			if (err instanceof DataSourceError && err.status === 410 && def) {
				const meta = err.meta ?? {};
				qvDeleted = {
					def,
					docId: opts.entries[0].docId,
					displayName: typeof meta.display_name === 'string' ? meta.display_name : null,
					deletedAt: typeof meta.deleted_at === 'string' ? meta.deleted_at : null
				};
			} else {
				quickViewError = errorMessage(err, m.errors_reference_load_failed());
			}
		} finally {
			if (my === qvLoadSeq) qvLoading = false;
		}
		void ensureQuickViewTemplate();
	}

	// Reset peek drawer state when the host surface's root doctype changes.
	// SvelteKit reuses this component instance on navigation, so without this
	// reset the drawer (and its full-page link) would keep referencing a
	// document belonging to the previous doctype.
	$effect(() => {
		void rootParentDocId;
		qvLoadSeq++;
		qvClosing = false;
		clearQuickViewState();
	});

	const quickViewOpen = $derived(
		selectedDoc !== null || quickViewError !== null || qvDeleted !== null || qvLoading
	);
	const selectedId = $derived(selectedDoc?.meta.id ?? '');

	/** Reload the tombstoned document after a successful restore. */
	function reloadDeletedDoc(): void {
		const deleted = qvDeleted;
		if (!deleted) return;
		void runOpen({
			entries: [
				{
					def: deleted.def,
					parentDocId: `${deleted.def.domain}.${deleted.def.doctype}`,
					docId: deleted.docId
				}
			],
			replace: true
		});
	}

	const qvShowBack = $derived(qvNav.length > 1);
	// Qualified `domain.Doctype` key used to gate the Edit affordance on the
	// active role's `update` permission.
	const activeQualifiedName = $derived(`${activeDef.domain}.${activeDef.doctype}`);
	// Header identity name: the active nav entry's doctype, or — while an
	// error/deleted state holds the stack empty — the doctype of the failed
	// request (avoids the host's root-def stub leaking through).
	const headerQualifiedName = $derived(
		quickViewError !== null || qvDeleted !== null
			? (qvErrorName ?? activeQualifiedName)
			: activeQualifiedName
	);
	const qvCanRestore = $derived(
		qvDeleted !== null && can(`${qvDeleted.def.domain}.${qvDeleted.def.doctype}`, 'update')
	);
	// Show Edit only when a document is loaded and the active role may update it.
	const canEdit = $derived(can(activeQualifiedName, 'update'));

	/** Full show-page href for the displayed document. Shared by the header's
	 * "Open full page" link and the Enter-while-open shortcut. Null when no
	 * document is shown — the loading, error, and tombstone states. */
	const showHref = $derived.by<string | null>(() => {
		if (!selectedId) return null;
		return resolve('/[domain=notApi]/[doctype]/[id]', {
			domain: activeDef.domain,
			doctype: activeDef.doctype,
			id: selectedId
		});
	});

	/** Edit-form href — resolve() plus a `?from=` query carrying the host
	 * page's path + query, so DocumentForm returns here after a save
	 * instead of landing on the app-domain show page. */
	const editHref = $derived.by<string>(() => {
		const base = resolve('/[domain=notApi]/[doctype]/[id]/edit', {
			domain: activeDef.domain,
			doctype: activeDef.doctype,
			id: selectedId
		});
		return `${base}?from=${encodeURIComponent(page.url.pathname + page.url.search)}`;
	});

	// ── Drawer keyboard: Enter opens fully, Escape closes ───────────────
	//
	// With the drawer open, Enter means "open fully" — the same target as
	// the header's external-link affordance — and Escape means "close": pop
	// one entry off the nav stack when the drawer was reached through a
	// reference, otherwise close the drawer. A capture-phase window listener
	// is required: the shortcuts dispatcher's route scope already holds the
	// table's `Enter` (open the peek for the highlighted row) and `Escape`
	// (clear the row highlight) entries, and registration order would let
	// them consume the keys first. The listener stays out of an open
	// dialog's keyboard, and Enter only claims non-interactive, non-typing
	// targets so links, buttons, and inputs keep their native Enter (edit
	// pencil, restore, form fields). Escape is claimed from typing targets
	// too — a picker inside the drawer already stops propagation on its own
	// Escape, so only a genuinely unhandled press reaches this listener.
	$effect(() => {
		if (!quickViewOpen) return;
		const onKeydown = (e: KeyboardEvent) => {
			if (e.defaultPrevented || e.isComposing) return;
			if (e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
			if (insideDialog(e.target)) return;
			if (e.key === 'Escape') {
				// A close already in flight (a repeated key, the scrim) — swallow
				// the key without acting so the table's Escape stays out.
				if (!qvClosing) void popQvNav();
				e.preventDefault();
				e.stopPropagation();
				return;
			}
			if (e.key !== 'Enter' || !showHref) return;
			if (isInteractiveTarget(e.target) || isTypingTarget(e.target)) return;
			e.preventDefault();
			e.stopPropagation();
			// eslint-disable-next-line svelte/no-navigation-without-resolve -- showHref is a resolve() result; the rule cannot see through the derived.
			void goto(showHref);
		};
		window.addEventListener('keydown', onKeydown, true);
		return () => window.removeEventListener('keydown', onKeydown, true);
	});

	const api: QvHostApi = {
		openReference,
		openRootDoc
	};
</script>

{@render trigger(api)}

{#if quickViewOpen}
	<QuickView open={!qvClosing} onclose={closeQuickView} onclosed={qvClosed}>
		{#snippet header()}
			{#if qvShowBack}
				<button class="qv-back" type="button" title={m.doc_peek_back_aria()} onclick={popQvNav}>
					<svg
						viewBox="0 0 24 24"
						width="14"
						height="14"
						fill="none"
						stroke="currentColor"
						stroke-width="2"
					>
						<path d="M15 18l-6-6 6-6" />
					</svg>
				</button>
			{/if}
			<span class="qv-qualified">{headerQualifiedName}</span>
			{#if canEdit && selectedId}
				<!-- eslint-disable svelte/no-navigation-without-resolve -- editHref is resolve() plus the `?from` return-path query; the rule cannot see through the concatenation. -->
				<a
					class="qv-open"
					href={editHref}
					title={m.doc_peek_edit_aria()}
					aria-label={m.doc_peek_edit_aria()}
				>
					<Pencil size={15} strokeWidth={2} aria-hidden="true" />
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			{/if}
			{#if selectedId}
				<!-- eslint-disable svelte/no-navigation-without-resolve -- showHref is a resolve() result; the rule cannot see through the derived. -->
				<a
					class="qv-open"
					href={showHref}
					title={m.doc_peek_open_aria()}
					aria-label={m.doc_peek_open_aria()}
				>
					<ExternalLink size={15} strokeWidth={2} aria-hidden="true" />
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			{/if}
			<span class="qv-head-spacer"></span>
		{/snippet}

		{#snippet title()}
			<QvIdentity
				doc={selectedDoc}
				def={activeDef}
				deleted={qvDeleted}
				errorName={qvErrorName}
				error={quickViewError}
			/>
		{/snippet}

		{#if qvDeleted}
			<div class="qv-deleted">
				<p class="qv-deleted-note">
					{#if qvDeleted.deletedAt}
						{m.doc_deleted_note_dated({ date: formatFullDate(qvDeleted.deletedAt) })}
					{:else}
						{m.doc_deleted_note()}
					{/if}
				</p>
				{#if qvCanRestore}
					<RestoreButton
						doctype={`${qvDeleted.def.domain}.${qvDeleted.def.doctype}`}
						doc={driver
							.domain(qvDeleted.def.domain)
							.doctype(qvDeleted.def.doctype)
							.doc(qvDeleted.docId)}
						onRestored={reloadDeletedDoc}
					/>
				{/if}
			</div>
		{:else if quickViewError}
			<p class="qv-error">{quickViewError}</p>
		{:else if selectedDoc}
			{#if quickViewTemplate}
				<DocumentViewTemplate
					template={quickViewTemplate}
					document={selectedDoc}
					{driver}
					def={activeDef}
					onreferenceclick={openReference}
				/>
			{:else if !quickViewTemplateLoaded && quickViewTemplateLoading}
				<p class="qv-hint">{m.doc_peek_loading()}</p>
			{:else}
				<!-- Fallback (no quickView template): one row per stored field,
				     dispatched through the shared typed-value renderer so money,
				     period, and dateperiod values render instead of being dropped
				     (B-102). The driver routes reference values through Capsule so
				     they show the target's display name, not the raw id token
				     (B-132). Objects, object-item arrays, and definition-less
				     arrays fall back to JSON text. -->
				<dl class="qv-fields">
					{#each Object.entries(selectedDoc.data) as [key, value] (key)}
						{@const fd = fieldDefFor(activeDef, key)}
						<div class="qv-field">
							<dt>{humanize(key)}</dt>
							<dd>
								<DvtValue
									{value}
									fieldType={fd?.type ?? null}
									fieldDef={fd}
									fallback={value == null ? '' : resolveValue(`$${key}`, selectedDoc.data)}
									{driver}
									onreferenceclick={openReference}
								/>
							</dd>
						</div>
					{/each}
				</dl>
			{/if}
		{/if}
	</QuickView>
{/if}

<style>
	/* ── Header bar (slim mono doctype label + actions) ─────────────────── */
	.qv-back {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		padding: 0;
		margin: 0 2px 0 -4px;
		border: none;
		border-radius: var(--r-sm);
		background: transparent;
		color: var(--text-2);
		cursor: pointer;
		transition:
			background 0.12s,
			color 0.12s;
	}

	.qv-back:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.qv-qualified {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
	}

	/* Pushes the header's right-side actions flush against the drawer's close
	   button. Must come AFTER the action links so the (flex:1) spacer sits
	   between them and the close button — the QuickView appends a second
	   flex:1 spacer after this whole snippet, which would otherwise swallow
	   the slack and leave the links away from the right edge. */
	.qv-head-spacer {
		flex: 1;
	}

	.qv-open {
		display: inline-flex;
		align-items: center;
		padding: 4px;
		border-radius: var(--r-sm);
		color: var(--text-2);
		text-decoration: none;
		transition:
			background 0.12s,
			color 0.12s;
	}

	.qv-open:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.qv-open:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.qv-error {
		color: var(--danger);
		font-size: 13px;
	}

	.qv-deleted {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 12px;
		padding: 16px;
		border: 1px solid color-mix(in srgb, var(--danger) 22%, transparent);
		border-radius: var(--r);
		background: var(--sunken);
	}

	.qv-deleted-note {
		margin: 0;
		color: var(--text-2);
		font-size: 13px;
		line-height: 1.5;
	}

	.qv-hint {
		color: var(--text-3);
		font-size: 13px;
	}

	.qv-fields {
		margin: 0;
		display: grid;
		gap: 10px;
	}

	.qv-field dt {
		font-size: 11px;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: var(--text-3);
		font-weight: 600;
		margin-bottom: 2px;
	}

	.qv-field dd {
		margin: 0;
		font-size: 13px;
		color: var(--text);
		font-family: var(--font-mono);
		word-break: break-word;
	}
</style>
