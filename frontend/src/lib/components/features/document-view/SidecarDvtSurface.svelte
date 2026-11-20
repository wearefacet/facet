<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { SidecarSurfaceProps } from '$lib/surfaces/registry.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import type { TemplateNode } from '$lib/template-types';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import { loadDoctypeViewByKind } from '$lib/doctype/loadDocumentView.js';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { humanize, parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import { can } from '$lib/permissions.svelte';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { Plus } from '@lucide/svelte';

	/**
	 * SidecarDvtSurface — the basic DVT fallback surface for a sidecar
	 * segment. Lists the host's sidecar records (oldest first) and renders
	 * each row through the sidecar doctype's `inline` template (falling back
	 * to `quickView`, then to a plain capsule). A small inline creation form
	 * is offered when the active role holds `create` on the host doctype —
	 * nested sidecar creation is implied by that grant (backend prefix
	 * match), so the affordance hides entirely without it.
	 *
	 * Only `string` / `longtext` writable fields are rendered generically in
	 * the form; other field types (references, enums, money, …) are omitted —
	 * a custom sidecar surface should take over those doctypes via the
	 * `surface` field on the definition.
	 */
	let { driver, hostDef, hostDoc, segment, sidecarDef, onchanged }: SidecarSurfaceProps = $props();

	type Row = {
		meta: { id: string; display_name?: string | null };
		data: Record<string, unknown>;
	};

	const qualifiedHost = $derived(`${hostDef.domain}.${hostDef.doctype}`);
	const sidecarQualified = $derived(
		sidecarDef ? `${sidecarDef.domain}.${sidecarDef.doctype}` : null
	);
	// UI hint only — the backend re-checks every nested create.
	const canCreate = $derived(can(qualifiedHost, 'create'));
	// The generic form covers plain scalars only; references and typed fields
	// need their dedicated inputs and are dropped here.
	const addFields = $derived(
		(sidecarDef?.fields ?? []).filter(
			(f) => !f.read_only && (f.type === 'string' || f.type === 'longtext')
		)
	);

	let rows = $state<Row[] | null>(null);
	let loading = $state(false);
	let errorMsg = $state<string | null>(null);
	// Cancellation counters for the list/template fetches; separate so an
	// in-flight template load does not cancel an in-flight row list.
	let listSeq = 0;
	let tplSeq = 0;

	// Loaded row template. `undefined` = not loaded yet, `null` = no `inline`
	// and no `quickView` view exists → rows fall back to capsules.
	let inlineTemplate = $state<TemplateNode | null | undefined>(undefined);
	let templateDef = $state<DoctypeDef | undefined>(undefined);
	let templatesLoading = $state(false);

	async function load() {
		const my = ++listSeq;
		loading = true;
		errorMsg = null;
		try {
			const res = await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.list({ items: 200 });
			if (my !== listSeq) return;
			// ULID ids sort by creation order — oldest first for a sidecar log.
			const sorted = [...res.data].sort((a, b) =>
				a.meta.id < b.meta.id ? -1 : a.meta.id > b.meta.id ? 1 : 0
			);
			rows = sorted as unknown as Row[];
		} catch (e) {
			if (my !== listSeq) return;
			rows = null;
			errorMsg = errorMessage(e, m.doc_sidecar_load_failed());
		} finally {
			if (my === listSeq) loading = false;
		}
	}

	async function loadTemplates() {
		if (!sidecarQualified) {
			// No sidecar definition → no view lookups possible; capsules render.
			inlineTemplate = null;
			return;
		}
		const my = ++tplSeq;
		templatesLoading = true;
		try {
			// The passed `sidecarDef` wins; otherwise resolve it the way
			// `DvtRelation` does — mock drivers expose `doctypeDefinitions`
			// synchronously, HTTP drivers go through the TTL-cached registry.
			if (!templateDef) {
				if (sidecarDef) {
					templateDef = sidecarDef;
				} else {
					const md = driver as unknown as {
						doctypeDefinitions?: Map<string, Record<string, unknown>>;
					};
					if (md.doctypeDefinitions instanceof Map) {
						const raw = md.doctypeDefinitions.get(sidecarQualified);
						if (raw) templateDef = parseDoctypeDef(raw);
					} else {
						const reg = await DoctypeRegistry.cached(driver);
						const raw = reg.doctypeDefinitions.get(sidecarQualified);
						if (raw) templateDef = parseDoctypeDef(raw);
					}
					if (my !== tplSeq) return;
				}
			}
			if (inlineTemplate === undefined) {
				const inline = await loadDoctypeViewByKind(driver, sidecarQualified, 'inline');
				if (my !== tplSeq) return;
				if (inline.template) {
					inlineTemplate = inline.template;
				} else {
					const quick = await loadDoctypeViewByKind(driver, sidecarQualified, 'quickView');
					if (my !== tplSeq) return;
					inlineTemplate = quick.template ?? null;
				}
			}
		} catch {
			if (my === tplSeq) inlineTemplate = null;
		} finally {
			if (my === tplSeq) templatesLoading = false;
		}
	}

	$effect(() => {
		void hostDef;
		void hostDoc.meta.id;
		void segment;
		load();
		loadTemplates();
	});

	// ── Inline creation form ────────────────────────────────────────────────

	let addOpen = $state(false);
	let addDraft = $state<Record<string, string>>({});
	let creating = $state(false);
	let createError = $state<string | null>(null);

	function openAdd(): void {
		addDraft = Object.fromEntries(addFields.map((f) => [f.key, '']));
		addOpen = true;
	}

	function closeAdd(): void {
		addOpen = false;
		createError = null;
	}

	async function submitAdd(): Promise<void> {
		if (creating || addFields.length === 0) return;
		creating = true;
		createError = null;
		const payload: Record<string, unknown> = {};
		for (const f of addFields) payload[f.key] = addDraft[f.key] ?? '';
		try {
			await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.create(payload);
			addOpen = false;
			addDraft = {};
			await load();
			onchanged?.();
		} catch (e) {
			createError = errorMessage(e, m.common_create_failed());
		} finally {
			creating = false;
		}
	}

	const busy = $derived(loading || templatesLoading);
</script>

<div class="sidecar-dvt">
	<div class="sidecar-dvt-head">
		<span class="sidecar-dvt-label">{humanize(segment)}</span>
		{#if busy}
			<span class="sidecar-dvt-status" aria-live="polite">{m.common_loading()}</span>
		{:else if rows !== null}
			<span class="sidecar-dvt-status">{rows.length}</span>
		{/if}
		{#if canCreate && addFields.length > 0 && !addOpen}
			<button class="sidecar-dvt-add" type="button" onclick={openAdd}>
				<Plus size={13} strokeWidth={2} aria-hidden="true" />
				{m.common_add()}
			</button>
		{/if}
	</div>

	{#if addOpen}
		<div class="sidecar-dvt-form">
			{#each addFields as field (field.key)}
				{#if field.type === 'longtext'}
					<textarea
						class="sidecar-dvt-form-field"
						rows={3}
						placeholder={field.title ?? humanize(field.key)}
						bind:value={addDraft[field.key]}></textarea>
				{:else}
					<input
						class="sidecar-dvt-form-field"
						type="text"
						placeholder={field.title ?? humanize(field.key)}
						bind:value={addDraft[field.key]}
					/>
				{/if}
			{/each}
			{#if createError}
				<span class="sidecar-dvt-error" role="alert">{createError}</span>
			{/if}
			<div class="sidecar-dvt-form-actions">
				<button class="sidecar-dvt-form-cancel" type="button" onclick={closeAdd}
					>{m.common_cancel()}</button
				>
				<button
					class="sidecar-dvt-form-submit"
					type="button"
					disabled={creating}
					onclick={submitAdd}
				>
					{creating ? m.doc_sidecar_adding() : m.common_add()}
				</button>
			</div>
		</div>
	{/if}

	{#if errorMsg}
		<div class="sidecar-dvt-error">{errorMsg}</div>
	{:else if !busy && rows !== null && rows.length === 0}
		<div class="sidecar-dvt-empty">
			{m.doc_sidecar_empty({ label: humanize(segment).toLowerCase() })}
		</div>
	{:else if rows !== null}
		<div class="sidecar-dvt-rows">
			{#each rows as row (row.meta.id)}
				{#if inlineTemplate}
					<DocumentViewTemplate
						template={inlineTemplate}
						document={row as unknown as DocumentResponse}
						{driver}
						def={templateDef}
					/>
				{:else if inlineTemplate === null}
					<Capsule label={row.meta.display_name ?? row.meta.id} />
				{/if}
			{/each}
		</div>
	{/if}
</div>

<style>
	.sidecar-dvt {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 6px 0;
	}

	.sidecar-dvt-head {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 8px;
	}

	.sidecar-dvt-label {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
	}

	.sidecar-dvt-status {
		font-size: 11px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.sidecar-dvt-add {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		margin-left: auto;
		padding: 2px 8px;
		font-size: 11.5px;
		font-weight: 500;
		color: var(--accent-ink);
		background: transparent;
		border: 1px solid var(--accent-weak);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			background 0.12s,
			border-color 0.12s;
	}

	.sidecar-dvt-add:hover {
		background: var(--accent-weak);
		border-color: var(--accent);
	}

	.sidecar-dvt-add:focus-visible,
	.sidecar-dvt-form-cancel:focus-visible,
	.sidecar-dvt-form-submit:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.sidecar-dvt-form {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 10px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
	}

	.sidecar-dvt-form-field {
		width: 100%;
		font: inherit;
		font-size: 13px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		padding: 6px 9px;
		box-sizing: border-box;
	}

	.sidecar-dvt-form-field:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
		border-color: var(--accent);
	}

	.sidecar-dvt-form-actions {
		display: flex;
		justify-content: flex-end;
		gap: 6px;
	}

	.sidecar-dvt-form-cancel,
	.sidecar-dvt-form-submit {
		padding: 4px 12px;
		font-size: 12px;
		font-weight: 600;
		border-radius: var(--r);
		cursor: pointer;
	}

	.sidecar-dvt-form-cancel {
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border-strong);
	}

	.sidecar-dvt-form-cancel:hover {
		background: var(--sunken);
	}

	.sidecar-dvt-form-submit {
		color: var(--on-accent);
		background: var(--accent);
		border: 1px solid var(--accent);
	}

	.sidecar-dvt-form-submit:hover {
		background: var(--accent-press);
	}

	.sidecar-dvt-form-submit:disabled {
		opacity: 0.6;
		cursor: default;
	}

	.sidecar-dvt-rows {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.sidecar-dvt-empty {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
		padding: 12px;
		text-align: center;
		border: 1px dashed var(--border);
		border-radius: var(--r);
	}

	.sidecar-dvt-error {
		font-size: 12px;
		color: var(--danger);
		padding: 8px 10px;
		border: 1px solid var(--danger-weak);
		border-radius: var(--r);
		background: var(--danger-weak);
	}
</style>
