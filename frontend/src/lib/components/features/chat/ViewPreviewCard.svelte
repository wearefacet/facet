<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Eye, Maximize2, X, AlertTriangle, LoaderCircle } from '@lucide/svelte';
	import DocumentViewTemplate from '../document-view/DocumentViewTemplate.svelte';
	import MonthGrid from '$lib/calendar/MonthGrid.svelte';
	import { calendarDiscriminatorKind } from '$lib/calendar/discriminator.js';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { FieldDef, FieldType } from '$lib/doctype/types.js';
	import type { DocumentMeta } from '$lib/datasource/types';
	import type { ViewPreview } from '$lib/assistant/tool-call-helpers.js';
	import {
		buildPreviewDocument,
		fakeFieldValue,
		type ViewPreviewSpec
	} from '$lib/assistant/ui-tools.js';

	/**
	 * Inline preview card for `preview_view` UI-tool calls — the card *is*
	 * the tool-call UI (no ToolCallBar). Renders the document view template
	 * engine or a collection surface against fake data generated from the
	 * model's arguments (see `ui-tools.ts`).
	 *
	 * The heavy preview body mounts only while the card intersects the
	 * viewport (`ViewPreviewCard` mounts lazily), so a long chat session
	 * never pays for dozens of rendered DVT trees at once. The expanded
	 * overlay renders the same body at full size.
	 */
	let { preview }: { preview: ViewPreview } = $props();

	const spec = $derived(preview.spec);
	const heading = $derived.by(() => {
		if (!spec) return m.assistant_preview_title();
		if (spec.title) return spec.title;
		if (spec.kind === 'collection')
			return spec.surface === 'calendar'
				? m.assistant_preview_calendar()
				: m.assistant_preview_table();
		return m.assistant_preview_document();
	});

	// ── Lazy visibility (under-render when scrolled out of view) ───────────
	let visible = $state(false);
	let expanded = $state(false);
	let rootEl = $state<HTMLElement | undefined>(undefined);

	$effect(() => {
		const el = rootEl;
		if (!el) return;
		// No observer (old browser / test env) — always render.
		if (typeof IntersectionObserver === 'undefined') {
			visible = true;
			return;
		}
		const obs = new IntersectionObserver(
			(entries) => {
				visible = entries.some((e) => e.isIntersecting);
			},
			// Slightly over-eager: start rendering just before the card scrolls in.
			{ rootMargin: '200px 0px' }
		);
		obs.observe(el);
		return () => obs.disconnect();
	});

	function closeExpanded() {
		expanded = false;
	}

	// ── Fake document (document kind) ──────────────────────────────────────
	const fakeDoc = $derived.by<DocumentResponse | null>(() => {
		if (!spec) return null;
		const { data } = buildPreviewDocument(spec);
		const meta: DocumentMeta = {
			id: 'preview-doc',
			mid: 'preview-doc',
			domain: 'preview',
			doc_type: 'Preview',
			version: 1,
			schema_version: 1,
			display_name: spec.title ?? 'Preview document',
			created_at: '2026-03-17T09:00:00Z',
			updated_at: '2026-03-17T09:00:00Z'
		};
		return { data, meta };
	});

	// ── Collection table (static fake rows) ────────────────────────────────
	// ── Collection table (static fake rows) ─────────────────────────────
	type PreviewColumn = { key: string; label?: string; width?: string };

	const tableColumns = $derived.by<PreviewColumn[]>(() => {
		const cols = spec?.config?.columns;
		if (cols && cols.length > 0) return cols;
		// No columns declared — fall back to the sample fields, or nothing.
		return Object.keys(spec?.sample_data ?? {}).map((key) => ({ key }));
	});

	const tableRows = $derived.by(() => {
		const rows: Record<string, unknown>[] = [];
		for (let i = 0; i < 5; i++) {
			const row: Record<string, unknown> = {};
			for (const col of tableColumns) {
				row[col.key] =
					i === 0 && spec?.sample_data?.[col.key] !== undefined
						? spec.sample_data[col.key]
						: fakeFieldValue(col.key);
			}
			rows.push(row);
		}
		return rows;
	});

	// ── Calendar ───────────────────────────────────────────────────────────
	const discriminatorField = $derived.by<FieldDef | undefined>(() => {
		const cfg = spec?.config;
		if (!cfg?.discriminator) return undefined;
		return { key: cfg.discriminator, type: 'date' as FieldType };
	});
	const endField = $derived.by<FieldDef | undefined>(() => {
		const end = spec?.config?.end_field;
		return end ? { key: end, type: 'date' as FieldType } : undefined;
	});
	const colorByField = $derived.by<FieldDef | undefined>(() => {
		const color = spec?.config?.color_by;
		if (!color) return undefined;
		return {
			key: color,
			type: 'enum' as FieldType,
			values: [{ key: 'active', title: 'Active', color: 'green' }]
		};
	});
	const calendarKind = $derived(
		calendarDiscriminatorKind(discriminatorField?.type, spec?.config?.end_field ?? null)
	);
	const calendarItems = $derived.by(() => {
		if (!spec) return [];
		const items: DocumentResponse<Record<string, unknown>>[] = [];
		const today = new Date();
		for (let i = 0; i < 6; i++) {
			const d = new Date(
				Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() + (i - 2))
			);
			const data: Record<string, unknown> = { ...fakeRowForCalendar(spec) };
			data[spec.config?.discriminator ?? 'date'] = d.toISOString();
			items.push({
				data,
				meta: {
					id: `preview-${i}`,
					mid: `preview-${i}`,
					domain: 'preview',
					doc_type: 'Preview',
					version: 1,
					schema_version: 1,
					created_at: d.toISOString(),
					updated_at: d.toISOString()
				}
			});
		}
		return items;
	});

	/** One fake calendar entry: title-ish fields from sample data or the fake generator. */
	function fakeRowForCalendar(spec: ViewPreviewSpec): Record<string, unknown> {
		const out: Record<string, unknown> = {};
		const keys = spec.config?.columns?.map((c) => c.key) ?? Object.keys(spec.sample_data ?? {});
		for (const key of keys.slice(0, 3)) {
			out[key] =
				spec.sample_data?.[key] !== undefined ? spec.sample_data[key] : fakeFieldValue(key);
		}
		if (spec.config?.color_by) {
			out[spec.config.color_by] = 'active';
		}
		return out;
	}

	const bodyReady = $derived(preview.status === 'ok' && spec !== null && (visible || expanded));
</script>

<div class="preview-card" bind:this={rootEl}>
	<header class="preview-head">
		<span class="preview-icon"><Eye size={13} stroke-width={1.9} /></span>
		<span class="preview-title">{heading}</span>
		<span class="preview-status" data-status={preview.status}>
			{#if preview.status === 'running'}
				<LoaderCircle size={11} stroke-width={2} class="spin" />
			{:else if preview.status === 'error' || spec === null}
				<AlertTriangle size={11} stroke-width={2} />
			{/if}
		</span>
		{#if preview.status === 'ok' && spec !== null}
			<button
				class="expand-btn"
				type="button"
				onclick={() => (expanded = !expanded)}
				aria-label={expanded
					? m.assistant_preview_collapse_aria()
					: m.assistant_preview_expand_aria()}
				aria-pressed={expanded}
				title={expanded ? m.assistant_preview_collapse() : m.assistant_preview_expand()}
			>
				<Maximize2 size={12} stroke-width={1.9} />
			</button>
		{/if}
	</header>

	{#if preview.status === 'ok' && spec === null}
		<div class="preview-note error-note" role="alert">{m.assistant_preview_invalid()}</div>
	{:else if preview.status === 'error'}
		<div class="preview-note error-note" role="alert">{m.assistant_preview_failed()}</div>
	{:else if bodyReady && spec}
		<div class="preview-body" class:expanded>
			{#if spec.kind === 'document' && fakeDoc}
				<DocumentViewTemplate template={spec.template!} document={fakeDoc} />
			{:else if spec.kind === 'collection' && spec.surface === 'table'}
				<div class="table-wrap">
					<table>
						<thead>
							<tr>
								{#each tableColumns as col (col.key)}
									<th style:width={col.width}>{col.label ?? col.key}</th>
								{/each}
							</tr>
						</thead>
						<tbody>
							{#each tableRows as row, i (i)}
								<tr>
									{#each tableColumns as col (col.key)}
										<td>{String(row[col.key] ?? '—')}</td>
									{/each}
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{:else if spec.kind === 'collection' && spec.surface === 'calendar' && calendarItems && discriminatorField && calendarKind}
				<MonthGrid
					items={calendarItems}
					discriminator={spec.config?.discriminator ?? ''}
					kind={calendarKind}
					{discriminatorField}
					{endField}
					{colorByField}
					titleTemplate={spec.config?.title_template ?? null}
					fallbackFields={tableColumns.map((c) => ({ key: c.key }))}
					year={new Date().getUTCFullYear()}
					month={new Date().getUTCMonth() + 1}
					weekStart={spec.config?.week_start ?? 'monday'}
				/>
			{:else if spec.kind === 'collection'}
				<div class="preview-note">{m.assistant_preview_needs_discriminator()}</div>
			{/if}
		</div>
	{:else}
		<div class="preview-skeleton" aria-hidden="true"></div>
	{/if}
</div>

{#if expanded && spec}
	<div class="preview-overlay" role="dialog" aria-label={heading}>
		<button
			class="overlay-backdrop"
			type="button"
			aria-label={m.assistant_preview_backdrop_aria()}
			onclick={closeExpanded}
		></button>
		<div class="overlay-panel">
			<header class="preview-head overlay-head">
				<span class="preview-title">{heading}</span>
				<button
					class="expand-btn"
					type="button"
					onclick={closeExpanded}
					aria-label={m.assistant_preview_close_aria()}
					title={m.common_close()}
				>
					<X size={13} stroke-width={1.9} />
				</button>
			</header>
			<div class="overlay-body">
				{#if spec.kind === 'document' && fakeDoc}
					<DocumentViewTemplate template={spec.template!} document={fakeDoc} />
				{:else if spec.kind === 'collection' && spec.surface === 'table'}
					<div class="table-wrap">
						<table>
							<thead>
								<tr>
									{#each tableColumns as col (col.key)}
										<th>{col.label ?? col.key}</th>
									{/each}
								</tr>
							</thead>
							<tbody>
								{#each tableRows as row, i (i)}
									<tr>
										{#each tableColumns as col (col.key)}
											<td>{String(row[col.key] ?? '—')}</td>
										{/each}
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				{:else if spec.kind === 'collection' && spec.surface === 'calendar' && calendarKind}
					<MonthGrid
						items={calendarItems}
						discriminator={spec.config?.discriminator ?? ''}
						kind={calendarKind}
						discriminatorField={discriminatorField!}
						{endField}
						{colorByField}
						titleTemplate={spec.config?.title_template ?? null}
						fallbackFields={tableColumns.map((c) => ({ key: c.key }))}
						year={new Date().getUTCFullYear()}
						month={new Date().getUTCMonth() + 1}
						weekStart={spec.config?.week_start ?? 'monday'}
					/>
				{:else}
					<div class="preview-note">{m.assistant_preview_needs_discriminator()}</div>
				{/if}
			</div>
		</div>
	</div>
{/if}

<style>
	.preview-card {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		overflow: hidden;
	}

	.preview-head {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 5px 9px;
		background: var(--surface-2, var(--sunken));
		border-bottom: 1px solid var(--border);
		min-height: 28px;
	}

	.preview-head > .preview-title {
		font-family: var(--font-display);
		font-size: 12px;
		font-weight: 600;
		color: var(--text);
	}

	.preview-status {
		display: inline-flex;
		color: var(--text-3);
	}
	.preview-status[data-status='running'] {
		color: var(--accent);
	}
	.preview-status[data-status='error'] {
		color: var(--danger);
	}

	.preview-icon {
		color: var(--text-3);
		display: inline-flex;
	}

	.expand-btn {
		margin-left: auto;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		border-radius: var(--r-sm);
		border: none;
		background: transparent;
		color: var(--text-3);
		cursor: pointer;
	}
	.expand-btn:hover {
		background: var(--surface-3, var(--sunken));
		color: var(--text);
	}

	.preview-body {
		max-height: 320px;
		overflow: auto;
		padding: 8px;
	}
	.preview-body.expanded {
		max-height: none;
	}

	.preview-note {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		padding: 8px 9px;
	}
	.error-note {
		color: var(--danger);
	}

	.preview-skeleton {
		height: 96px;
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
		.preview-skeleton {
			animation: none;
		}
		.preview-status :global(.spin) {
			animation: none;
		}
	}

	/* .spin lands on the lucide <svg>, outside this component's scope. */
	.preview-status :global(.spin) {
		animation: spin 0.9s linear infinite;
	}
	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}

	/* Collection table (static fake rows) */
	.table-wrap {
		overflow: auto;
	}
	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 11.5px;
	}
	th,
	td {
		text-align: left;
		padding: 4px 8px;
		border-bottom: 1px solid var(--border);
		white-space: nowrap;
		color: var(--text);
	}
	th {
		font-family: var(--font-mono);
		font-size: 10px;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--text-3);
		background: var(--surface-2, var(--sunken));
	}

	/* ── Expanded overlay ─────────────────────────────────────────────── */
	.preview-overlay {
		position: fixed;
		inset: 0;
		z-index: 1100;
		display: flex;
		align-items: center;
		justify-content: center;
	}
	.overlay-backdrop {
		position: absolute;
		inset: 0;
		border: none;
		background: rgba(0, 0, 0, 0.45);
		cursor: pointer;
		padding: 0;
	}
	.overlay-panel {
		position: relative;
		width: min(1100px, calc(100vw - 48px));
		max-height: calc(100vh - 48px);
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		box-shadow: 0 18px 48px rgba(0, 0, 0, 0.25);
		overflow: hidden;
	}
	.overlay-head {
		border-bottom: 1px solid var(--border);
	}
	.overlay-body {
		overflow: auto;
		padding: 12px;
		flex: 1;
	}
</style>
