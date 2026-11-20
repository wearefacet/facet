<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { AlertTriangle, LoaderCircle } from '@lucide/svelte';
	import DoctypeIcon from '$lib/components/primitives/data/DoctypeIcon.svelte';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import Badge from '$lib/components/primitives/data/Badge.svelte';
	import DocumentViewTemplate from '$lib/components/features/document-view/DocumentViewTemplate.svelte';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { type DocumentResponse } from '$lib/datasource/types.js';
	import { loadDoctypeViewByKind, type LoadedView } from '$lib/doctype/loadDocumentView.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import type { DocumentRow } from '$lib/assistant/tool-call-helpers.js';

	/**
	 * One document rendered inside the chat — a compact row or a card — for
	 * the workspace tool seams (`rows` part from `list_documents`,
	 * `documents` part from `show_documents`).
	 *
	 * The payload only carries document identity; every display value
	 * resolves here from the data source: the record via
	 * `driver.…doc(id).show()` (60s client cache), the doctype definition via
	 * `DoctypeRegistry`, and — card mode — the doctype's `card` view
	 * template, rendered through `DocumentViewTemplate` in a bounded
	 * container (the `ViewPreviewCard` precedent, with a real document).
	 * Card mode loads no other kind: the full-page `view` template never
	 * mounts in a chat card. Without a `card` template the body falls back
	 * to display name + updated time.
	 *
	 * Click opens the document: `onopen` when a host (peek drawer) is
	 * present, else `goto` on the app's own show route.
	 */
	let {
		ref,
		display,
		driver,
		onopen = undefined
	}: {
		/** Document identity from the tool payload. */
		ref: DocumentRow;
		/** `inline` — one compact row; `card` — an inspectable card. */
		display: 'card' | 'inline';
		/** Data driver — `MockDataDriver` in stories, `DocumentDataDriver` in the app. */
		driver: DataDriver;
		/** Host hook (peek drawer). When absent, click navigates. */
		onopen?: (r: DocumentRow) => void;
	} = $props();

	type Load =
		| { state: 'loading' }
		| { state: 'ok'; doc: DocumentResponse; def: DoctypeDef | null; view: LoadedView | null }
		| { state: 'error'; message: string };

	let load = $state<Load>({ state: 'loading' });
	/** Resolved doctype icon for the identity glyphs. */
	let iconName = $state<string | null>(null);
	// Cancellation counter — only the latest request may settle state.
	let seq = 0;

	$effect(() => {
		const target = `${ref.domain}.${ref.doctype}`;
		const my = ++seq;
		load = { state: 'loading' };

		(async () => {
			try {
				const ds = driver.domain(ref.domain).doctype(ref.doctype);
				// The payload id may be the qualified reference token or the bare
				// projection id — the backend resolves the id shape at the route
				// layer (see `doc/backend/http-layer.md` → Document id forms).
				const doc = await ds.doc(ref.id).show();
				if (my !== seq) return;

				// Doctype definition + view template (card mode). Mock drivers
				// expose definitions natively — a fresh registry is free; HTTP
				// drivers share the 60s TTL snapshot (the DvtRelation rule).
				let def: DoctypeDef | null = null;
				let icon: string | null = null;
				const mockDefs = (
					driver as unknown as { doctypeDefinitions?: Map<string, Record<string, unknown>> }
				).doctypeDefinitions;
				if (mockDefs instanceof Map) {
					const raw = mockDefs.get(target);
					if (raw) {
						def = parseDoctypeDef(raw);
						icon = typeof raw['icon'] === 'string' ? raw['icon'] : null;
					}
				} else {
					try {
						const reg = await DoctypeRegistry.cached(driver);
						const raw = reg.doctypeDefinitions.get(target);
						if (raw) {
							def = parseDoctypeDef(raw);
							icon = typeof raw['icon'] === 'string' ? raw['icon'] : null;
						}
					} catch {
						/* Definition lookup is best-effort — badges degrade. */
					}
				}
				if (my !== seq) return;

				let view: LoadedView | null = null;
				if (display === 'card') {
					// Card kind only — never the full-page `view`/`quickView` chain.
					// `template: null` keeps the identity body (name + time).
					view = await loadDoctypeViewByKind(driver, target, 'card');
					if (my !== seq) return;
				}

				load = { state: 'ok', doc, def, view: view && view.template ? view : null };
				iconName = icon;
			} catch (err) {
				if (my !== seq) return;
				// DataSourceError extends Error — the helper covers both branches.
				load = { state: 'error', message: errorMessage(err, m.assistant_doc_unavailable()) };
			}
		})();
	});

	const displayName = $derived.by(() => {
		if (load.state !== 'ok') return null;
		const meta = load.doc.meta.display_name;
		if (meta && meta.length > 0) return meta;
		const content = load.doc.data as Record<string, unknown> | undefined;
		for (const k of ['display_name', 'name', 'title', 'label'] as const) {
			const v = content?.[k];
			if (typeof v === 'string' && v.length > 0) return v;
		}
		return ref.id;
	});

	/** Hover title — the resolved label, or the failure reason while in
	 * error state. */
	const headTitle = $derived(load.state === 'error' ? load.message : (displayName ?? ref.id));

	function open(): void {
		if (onopen) {
			onopen({ ...ref });
			return;
		}
		if (!ref.domain || !ref.doctype || !ref.id) return;
		void goto(
			resolve('/[domain=notApi]/[doctype]/[id]', {
				domain: encodeURIComponent(ref.domain),
				doctype: encodeURIComponent(ref.doctype),
				id: encodeURIComponent(ref.id)
			})
		);
	}
</script>

{#snippet badges()}
	{#if load.state === 'ok'}
		<Badge size="sm" label={ref.doctype} />
		<RelativeTime date={load.doc.meta.updated_at} />
	{/if}
{/snippet}

{#if display === 'inline'}
	<button type="button" class="row" data-state={load.state} onclick={open} title={headTitle}>
		<DoctypeIcon icon={iconName} shadow active />
		{#if load.state === 'loading'}
			<span class="row-name loading-name">{ref.id}</span>
			<span class="row-note"><LoaderCircle size={11} stroke-width={2} class="spin" /></span>
		{:else if load.state === 'error'}
			<span class="row-name">{ref.id}</span>
			<span class="row-note error-note"><AlertTriangle size={11} stroke-width={2} /></span>
		{:else}
			<span class="row-name">{displayName}</span>
			{@render badges()}
		{/if}
	</button>
{:else}
	<div class="card" data-state={load.state}>
		<button type="button" class="card-head" onclick={open} title={headTitle}>
			<DoctypeIcon icon={iconName} shadow active />
			{#if load.state === 'loading'}
				<span class="card-title loading-name">{ref.id}</span>
				<span class="card-note"><LoaderCircle size={11} stroke-width={2} class="spin" /></span>
			{:else if load.state === 'error'}
				<span class="card-title">{ref.id}</span>
				<span class="card-note error-note"><AlertTriangle size={11} stroke-width={2} /></span>
			{:else}
				<span class="card-title">{displayName}</span>
				{@render badges()}
			{/if}
		</button>
		{#if load.state === 'ok'}
			{#if load.view?.template}
				<div class="card-body">
					<DocumentViewTemplate
						template={load.view.template}
						document={load.doc}
						{driver}
						def={load.def ?? undefined}
					/>
				</div>
			{:else}
				<div class="card-body card-fallback">
					<span class="fallback-name" title={displayName ?? ref.id}>{displayName}</span>
					<RelativeTime date={load.doc.meta.updated_at} />
				</div>
			{/if}
		{:else if load.state === 'loading'}
			<div class="card-skeleton" aria-hidden="true"></div>
		{/if}
	</div>
{/if}

<style>
	/* ── Inline row ─────────────────────────────────────────────────────── */
	.row {
		display: flex;
		align-items: center;
		gap: 7px;
		width: 100%;
		padding: 5px 8px;
		border: none;
		border-bottom: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		text-align: left;
		cursor: pointer;
		font-size: 12px;
		min-width: 0;
		transition: background 0.12s ease;
	}
	.row:hover,
	.row:focus-visible {
		background: var(--sunken);
	}
	.row:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: -2px;
	}

	.row-name {
		font-family: var(--font-display);
		font-weight: 600;
		font-size: 12px;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.row-note {
		margin-left: auto;
		display: inline-flex;
		align-items: center;
		color: var(--text-3);
		flex-shrink: 0;
	}

	/* ── Card ───────────────────────────────────────────────────────────── */
	.card {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		overflow: hidden;
		min-width: 0;
		display: flex;
		flex-direction: column;
	}

	.card-head {
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 5px 9px;
		border: none;
		border-bottom: 1px solid var(--border);
		background: var(--surface-2, var(--sunken));
		color: var(--text);
		text-align: left;
		cursor: pointer;
		min-height: 28px;
		min-width: 0;
		transition: background 0.12s ease;
	}
	.card-head:hover,
	.card-head:focus-visible {
		background: var(--sunken);
	}
	.card-head:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: -2px;
	}

	.card-title {
		font-family: var(--font-display);
		font-size: 12px;
		font-weight: 600;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.card-note {
		margin-left: auto;
		display: inline-flex;
		align-items: center;
		color: var(--text-3);
		flex-shrink: 0;
	}

	.card-body {
		max-height: 260px;
		/* Vertical scroll only. Wide template content clips instead of
		   pushing the card wider than the chat grid. */
		overflow-x: hidden;
		overflow-y: auto;
		padding: 8px;
	}

	/* The DVT renders its own chrome; pull the first rule out of the gutter. */
	.card-body :global(.dvt-root:first-child) {
		margin-top: 0;
	}

	.card-fallback {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 6px;
	}

	.fallback-name {
		font-family: var(--font-display);
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
		max-width: 100%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	/* ── Shared bits ─────────────────────────────────────────────────── */
	/* The class lands on the child component's own element, so the parent
	   must style it through a scoped :global hook. */
	.row-note :global(.spin),
	.card-note :global(.spin) {
		animation: spin 0.9s linear infinite;
	}
	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}

	.loading-name {
		color: var(--text-3);
		font-weight: 500;
	}

	.error-note {
		color: var(--danger);
	}

	.card-skeleton {
		height: 72px;
		background: linear-gradient(
			90deg,
			var(--sunken) 25%,
			var(--surface-2, var(--sunken)) 50%,
			var(--sunken) 75%
		);
		background-size: 200% 100%;
		animation: skeleton-slide 1.4s ease infinite;
	}

	@keyframes skeleton-slide {
		from {
			background-position: 200% 0;
		}
		to {
			background-position: -200% 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.card-skeleton {
			animation: none;
		}
		.row-note :global(.spin),
		.card-note :global(.spin) {
			animation: none;
			opacity: 0.6;
		}
	}
</style>
