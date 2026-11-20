<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { SidecarSurfaceProps } from '$lib/surfaces/registry.js';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import { can } from '$lib/permissions.svelte';
	import {
		File as FileIcon,
		FileText,
		Image as ImageIcon,
		Music,
		Film,
		Download,
		Eye,
		Pencil,
		Trash2,
		Paperclip
	} from '@lucide/svelte';
	import { postArtifact, artifactDownloadUrl, type ArtifactUploadResult } from '$lib/artifacts.js';
	import { resolveRefLabel } from '$lib/datasource/qualifiedRef.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { untrack } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';

	/**
	 * AttachmentSurface — the file-attachment sidecar for `core.Attachment`
	 * (registered under the `attachment` surface id by `surfaces.ts`).
	 *
	 * Rows render oldest first (ULID ids sort by creation order): a file
	 * icon derived from the artifact's MIME type, the user-facing `name`,
	 * and a meta line with type label, size, upload time, and the resolved
	 * `uploaded_by` identity (degrading to an unknown uploader). Download
	 * goes through the cookie-auth gateway (`/Api/core/artifacts/:id/download`)
	 * — no signed URL is ever stored in the page DOM.
	 *
	 * Image artifacts replace the icon with a 32px thumbnail loaded from the
	 * same gateway (`loading="lazy"`, decorative `alt=""`); a failed load
	 * reverts the slot to the image icon. PDF rows add a preview affordance
	 * (`Eye`) beside the download link — the gateway serves PDFs inline, so
	 * it opens the same URL in a new tab. Other types keep their icon and
	 * the download link only.
	 *
	 * The composer uploads bytes first (`POST /Api/core/artifacts`, the
	 * standalone artifact route), then creates the sidecar record with
	 * `{ name, file: <artifact id> }` through the host's nested route — the
	 * backend stamps `target` from the path and forces `uploaded_by` via
	 * Lua. The name input pre-fills from the chosen file's name; any file
	 * type is allowed (the backend `file` field declares no `accept` list).
	 *
	 * Download links open a new tab (`target="_blank"`): the gateway serves
	 * inline-renderable types (images, PDF) with no `Content-Disposition:
	 * attachment`, so a same-tab navigation would replace the app session.
	 *
	 * Edit/delete affordances are UI hints gated on `can('core.Attachment',
	 * 'update' | 'delete')`, the upload affordance on the host create grant —
	 * production roles scope edits to `$mine` and the backend re-checks
	 * every mutation.
	 *
	 * `uploadFile`, `fetchArtifactMeta` and `artifactUrl` are injectable
	 * seams (stories substitute synthetic ones — no network in storybook);
	 * all default to the real cookie-auth routes.
	 */
	let {
		driver,
		hostDef,
		hostDoc,
		segment,
		onchanged,
		uploadFile,
		fetchArtifactMeta,
		artifactUrl
	}: SidecarSurfaceProps & {
		uploadFile?: (file: File) => Promise<ArtifactUploadResult>;
		fetchArtifactMeta?: (id: string) => Promise<ArtifactMeta | null>;
		/** Gateway URL for an artifact id. Defaults to the download gateway. */
		artifactUrl?: (id: string) => string;
	} = $props();

	const urlOf = (id: string): string => (artifactUrl ?? artifactDownloadUrl)(id);

	type Attachment = {
		meta: { id: string; display_name?: string | null; created_at: string };
		data: Record<string, unknown>;
	};

	/** Subset of the artifact metadata route's response the surface renders. */
	type ArtifactMeta = { mime_type: string; size: number; filename: string };

	const doctype = 'core.Attachment';
	const qualifiedHost = $derived(`${hostDef.domain}.${hostDef.doctype}`);
	// Nested sidecar create is implied by the host's `create` grant.
	const canCreate = $derived(can(qualifiedHost, 'create'));
	const canEdit = $derived(can(doctype, 'update'));
	const canDelete = $derived(can(doctype, 'delete'));

	let rows = $state<Attachment[] | null>(null);
	let loading = $state(false);
	let errorMsg = $state<string | null>(null);
	let listSeq = 0;

	// ── Artifact metadata ───────────────────────────────────────────────────
	// Resolved on demand after each list fetch; cached per artifact id.
	// `null` = unresolvable (missing row, denied, failed lookup) — the row
	// then renders without the type/size line.

	let metas = $state<Record<string, ArtifactMeta | null>>({});
	const metasStarted = new SvelteSet<string>();

	// Artifact ids whose thumbnail request failed — the row falls back to
	// the MIME icon instead of a broken-image glyph.
	const thumbFailed = new SvelteSet<string>();

	async function defaultFetchArtifactMeta(id: string): Promise<ArtifactMeta | null> {
		const { apiFetch } = await import('$lib/session.svelte');
		const res = await apiFetch(`/Api/core/artifacts/${id}`);
		if (!res.ok) return null;
		const body = (await res.json()) as { mime_type?: string; size?: number };
		if (typeof body.mime_type !== 'string' || typeof body.size !== 'number') return null;
		return { mime_type: body.mime_type, size: body.size, filename: '' };
	}

	async function resolveMeta(artifactId: unknown): Promise<void> {
		const key = String(artifactId ?? '');
		// untrack: a tracked read + the `add` write inside the caller's effect
		// would re-run that effect and orphan this fetch (workflow.md →
		// "The equality-guard trap in writeback effects").
		if (!key || untrack(() => metasStarted.has(key))) return;
		untrack(() => metasStarted.add(key));
		const fetcher = fetchArtifactMeta ?? defaultFetchArtifactMeta;
		try {
			metas[key] = await fetcher(key);
		} catch {
			metas[key] = null;
		}
	}

	function metaOf(artifactId: unknown): ArtifactMeta | null {
		const key = String(artifactId ?? '');
		return key ? (metas[key] ?? null) : null;
	}

	// ── Icon + label derivation ────────────────────────────────────────────
	// The icon buckets on the MIME prefix; the label is the subtype uppercased
	// and truncated to four characters (PDF, PNG, DOCX, OCT when unknown).

	function mimeOf(meta: ArtifactMeta | null): string {
		return meta?.mime_type ?? '';
	}

	function typeLabelOf(meta: ArtifactMeta | null): string {
		const mime = mimeOf(meta);
		if (!mime) return '';
		const subtype = mime.split('/')[1] ?? '';
		if (!subtype || subtype === 'octet-stream') return 'OCT';
		return subtype.replace(/^x-/, '').slice(0, 4).toUpperCase();
	}

	function formatSize(bytes: number): string {
		if (bytes < 1024) return `${bytes} B`;
		if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
		return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
	}

	// ── Uploader identity ───────────────────────────────────────────────────
	// Resolved on demand after each list fetch; cached per reference value.
	// `null` = unknown uploader (unresolvable reference or failed lookup).

	type Uploader = { name: string };
	let uploaders = $state<Record<string, Uploader | null>>({});
	const uploadersStarted = new SvelteSet<string>();

	async function resolveUploader(ref: unknown): Promise<void> {
		const key = String(ref ?? '');
		// untrack: see resolveMeta.
		if (!key || untrack(() => uploadersStarted.has(key))) return;
		untrack(() => uploadersStarted.add(key));
		// Unqualified refs and failed lookups resolve to `null` — an unknown
		// uploader, never a wrong one.
		const name = await resolveRefLabel(driver, key);
		uploaders[key] = name ? { name } : null;
	}

	function uploaderOf(ref: unknown): Uploader | null {
		const key = String(ref ?? '');
		return key ? (uploaders[key] ?? null) : null;
	}

	// ── Data ────────────────────────────────────────────────────────────────

	async function load(): Promise<void> {
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
			// Oldest first — ULID ids sort by creation order.
			const sorted = [...res.data].sort((a, b) =>
				a.meta.id < b.meta.id ? -1 : a.meta.id > b.meta.id ? 1 : 0
			);
			rows = sorted as unknown as Attachment[];
			for (const row of sorted) {
				void resolveMeta(row.data['file']);
				void resolveUploader(row.data['uploaded_by']);
			}
		} catch (e) {
			if (my !== listSeq) return;
			rows = null;
			errorMsg = errorMessage(e, m.doc_attachments_load_failed());
		} finally {
			if (my === listSeq) loading = false;
		}
	}

	$effect(() => {
		void hostDef;
		void hostDoc.meta.id;
		void segment;
		void load();
	});

	// ── Upload composer ─────────────────────────────────────────────────────

	let chosenFile = $state<File | null>(null);
	let draftName = $state('');
	let submitting = $state(false);
	let submitError = $state<string | null>(null);
	let fileInput = $state<HTMLInputElement | null>(null);

	function handleFileChange(event: Event): void {
		const input = event.currentTarget as HTMLInputElement;
		const file = input.files?.[0] ?? null;
		chosenFile = file;
		// Pre-fill the label from the file name; the caller can edit it after.
		draftName = file?.name ?? '';
		submitError = null;
	}

	function clearChosen(): void {
		chosenFile = null;
		draftName = '';
		if (fileInput) fileInput.value = '';
	}

	async function submit(): Promise<void> {
		if (!chosenFile || submitting || !canCreate) return;
		const name = draftName.trim();
		if (!name) return;
		submitting = true;
		submitError = null;
		try {
			const upload = uploadFile ? await uploadFile(chosenFile) : await postArtifact(chosenFile);
			// `target` is set by the route; `uploaded_by` is forced server-side.
			await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.create({ name, file: upload.id });
			clearChosen();
			await load();
			onchanged?.();
		} catch (e) {
			submitError = errorMessage(e, m.doc_attachment_attach_failed());
		} finally {
			submitting = false;
		}
	}

	// ── Rename ──────────────────────────────────────────────────────────────

	let editingId = $state<string | null>(null);
	let editDraft = $state('');
	let mutatingId = $state<string | null>(null);
	let mutationError = $state<string | null>(null);

	function startRename(row: Attachment): void {
		editingId = row.meta.id;
		editDraft = String(row.data['name'] ?? '');
		mutationError = null;
	}

	function cancelRename(): void {
		editingId = null;
		editDraft = '';
		mutationError = null;
	}

	async function saveRename(row: Attachment): Promise<void> {
		if (mutatingId || editingId !== row.meta.id) return;
		const name = editDraft.trim();
		if (!name) return;
		mutatingId = row.meta.id;
		mutationError = null;
		try {
			await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.doc(row.meta.id)
				.update({ name });
			editingId = null;
			editDraft = '';
			await load();
			onchanged?.();
		} catch (e) {
			mutationError = errorMessage(e, m.doc_attachment_rename_failed());
		} finally {
			mutatingId = null;
		}
	}

	// ── Delete ──────────────────────────────────────────────────────────────

	async function remove(row: Attachment): Promise<void> {
		// Destructive action: confirm first, matching the show route. The
		// global ConfirmDialog host lives in the app layout (not inside
		// stories), so the promise-based `confirm()` store would hang there.
		if (!window.confirm(m.doc_attachment_delete_confirm())) return;
		mutatingId = row.meta.id;
		mutationError = null;
		try {
			await driver
				.domain(hostDef.domain)
				.doctype(hostDef.doctype)
				.doc(hostDoc.meta.id)
				.sidecars(segment)
				.doc(row.meta.id)
				.delete();
			await load();
			onchanged?.();
		} catch (e) {
			mutationError = errorMessage(e, m.doc_attachment_delete_failed());
		} finally {
			mutatingId = null;
		}
	}
</script>

<div class="attachment-surface">
	{#if errorMsg}
		<div class="at-error">{errorMsg}</div>
	{:else if loading}
		<div class="at-status" aria-live="polite">{m.doc_attachments_loading()}</div>
	{:else if rows !== null && rows.length === 0}
		<div class="at-empty">{m.doc_attachments_empty()}</div>
	{/if}

	{#if rows !== null && rows.length > 0}
		<ul class="at-list">
			{#each rows as row (row.meta.id)}
				{@const artifactId = String(row.data['file'] ?? '')}
				{@const meta = metaOf(artifactId)}
				{@const uploader = uploaderOf(row.data['uploaded_by'])}
				{@const renaming = editingId === row.meta.id}
				{@const busy = mutatingId === row.meta.id}
				<li class="at-row" data-attachment-id={row.meta.id}>
					<span class="at-icon" aria-hidden="true">
						{#if mimeOf(meta).startsWith('image/') && !thumbFailed.has(artifactId)}
							<img
								class="at-thumb"
								src={urlOf(artifactId)}
								alt=""
								loading="lazy"
								decoding="async"
								onerror={() => thumbFailed.add(artifactId)}
							/>
						{:else if mimeOf(meta).startsWith('image/')}
							<ImageIcon size={15} strokeWidth={2} />
						{:else if mimeOf(meta).startsWith('audio/')}
							<Music size={15} strokeWidth={2} />
						{:else if mimeOf(meta).startsWith('video/')}
							<Film size={15} strokeWidth={2} />
						{:else if mimeOf(meta) === 'application/pdf' || typeLabelOf(meta).startsWith('DOC') || typeLabelOf(meta).startsWith('TX')}
							<FileText size={15} strokeWidth={2} />
						{:else}
							<FileIcon size={15} strokeWidth={2} />
						{/if}
					</span>
					<div class="at-main">
						{#if renaming}
							<input
								class="at-rename"
								type="text"
								bind:value={editDraft}
								disabled={busy}
								aria-label={m.doc_attachment_name_aria()}
								onkeydown={(e) => {
									if (e.key === 'Enter') void saveRename(row);
									if (e.key === 'Escape') cancelRename();
								}}
							/>
						{:else}
							<span class="at-name" data-testid="attachment-name-{row.meta.id}"
								>{String(row.data['name'] ?? '')}</span
							>
						{/if}
						<span class="at-meta">
							{#if typeLabelOf(meta)}<span class="at-type">{typeLabelOf(meta)}</span>{/if}
							{#if meta}<span class="at-size">{formatSize(meta.size)}</span>{/if}
							<RelativeTime date={row.meta.created_at} />
							{#if uploader}
								<span class="at-uploader">{m.doc_attachment_by({ name: uploader.name })}</span>
							{/if}
						</span>
					</div>
					<span class="at-actions">
						{#if renaming}
							<button
								class="at-btn at-btn-cancel"
								type="button"
								disabled={busy}
								onclick={cancelRename}
							>
								{m.common_cancel()}
							</button>
							<button
								class="at-btn at-btn-primary"
								type="button"
								disabled={busy || editDraft.trim().length === 0}
								onclick={() => saveRename(row)}
							>
								{busy ? m.common_saving() : m.common_save()}
							</button>
						{:else}
							{#if mimeOf(meta) === 'application/pdf'}
								<a
									class="at-action"
									href={urlOf(artifactId)}
									target="_blank"
									rel="noopener noreferrer external"
									aria-label={m.doc_attachment_preview_aria()}
									data-testid="attachment-preview-{row.meta.id}"
								>
									<Eye size={12} strokeWidth={2} />
								</a>
							{/if}
							<a
								class="at-action"
								href={urlOf(artifactId)}
								target="_blank"
								rel="noopener noreferrer external"
								aria-label={m.doc_attachment_download_aria()}
								data-testid="attachment-download-{row.meta.id}"
							>
								<Download size={12} strokeWidth={2} />
							</a>
							{#if canEdit}
								<button
									class="at-action"
									type="button"
									disabled={mutatingId !== null}
									onclick={() => startRename(row)}
									aria-label={m.doc_attachment_rename_aria()}
								>
									<Pencil size={12} strokeWidth={2} aria-hidden="true" />
								</button>
							{/if}
							{#if canDelete}
								<button
									class="at-action"
									type="button"
									disabled={mutatingId !== null}
									onclick={() => remove(row)}
									aria-label={m.doc_attachment_delete_aria()}
								>
									<Trash2 size={12} strokeWidth={2} aria-hidden="true" />
								</button>
							{/if}
						{/if}
					</span>
				</li>
			{/each}
		</ul>
	{/if}

	{#if mutationError && editingId === null}
		<span class="at-mutation-error" role="alert">{mutationError}</span>
	{/if}

	<!-- Composer: locked hint when the host create grant is missing (UI hint
		only — the backend re-checks the nested-create grant). -->
	{#if canCreate}
		<div class="at-composer" data-testid="attachment-composer">
			<input
				type="file"
				class="at-file-input"
				data-testid="attachment-file-input"
				bind:this={fileInput}
				onchange={handleFileChange}
			/>
			<div class="at-composer-row">
				<button class="at-btn at-btn-cancel" type="button" onclick={() => fileInput?.click()}>
					<Paperclip size={12} strokeWidth={2} aria-hidden="true" />
					{chosenFile ? m.doc_attachment_change() : m.doc_attachment_choose()}
				</button>
				<input
					class="at-name-input"
					type="text"
					placeholder={m.doc_attachment_name_placeholder()}
					bind:value={draftName}
					disabled={!chosenFile || submitting}
					aria-label={m.doc_attachment_name_aria()}
				/>
				<button
					class="at-btn at-btn-primary"
					type="button"
					disabled={!chosenFile || submitting || draftName.trim().length === 0}
					onclick={submit}
				>
					{submitting ? m.doc_attachment_attaching() : m.doc_attachment_attach()}
				</button>
			</div>
			{#if chosenFile}
				<span class="at-chosen">{chosenFile.name}</span>
			{/if}
			{#if submitError}
				<span class="at-mutation-error" role="alert">{submitError}</span>
			{/if}
		</div>
	{:else}
		<div class="at-composer-locked">{m.doc_attachments_forbidden()}</div>
	{/if}
</div>

<style>
	.attachment-surface {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 4px 0;
	}

	.at-status,
	.at-empty {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
		padding: 12px;
		text-align: center;
		border: 1px dashed var(--border);
		border-radius: var(--r);
	}

	.at-error {
		font-size: 12px;
		color: var(--danger);
		padding: 8px 10px;
		border: 1px solid var(--danger-weak);
		border-radius: var(--r);
		background: var(--danger-weak);
	}

	.at-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.at-row {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 9px 10px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
	}

	.at-icon {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		flex: none;
		width: 28px;
		height: 28px;
		color: var(--text-2);
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
	}

	.at-thumb {
		width: 32px;
		height: 32px;
		object-fit: cover;
		border-radius: var(--r-sm);
		background: var(--sunken);
	}

	.at-main {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
		flex: 1;
	}

	.at-name {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.at-meta {
		display: flex;
		align-items: center;
		gap: 6px;
		min-width: 0;
		font-size: 11px;
		color: var(--text-3);
		white-space: nowrap;
		overflow: hidden;
	}

	/* Type label and size are data — mono per the design rule. */
	.at-type,
	.at-size {
		font-family: var(--font-mono);
		font-size: 10px;
		letter-spacing: 0.02em;
		color: var(--text-3);
		padding: 1px 5px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
	}

	.at-uploader {
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.at-actions {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		flex: none;
	}

	.at-action {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		padding: 0;
		color: var(--text-3);
		background: transparent;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		cursor: pointer;
		transition:
			color 0.12s,
			border-color 0.12s,
			background 0.12s;
	}

	a.at-action {
		text-decoration: none;
	}

	.at-action:hover:not(:disabled) {
		color: var(--text);
		background: var(--sunken);
		border-color: var(--border-strong);
	}

	.at-action:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.at-action:disabled {
		opacity: 0.5;
		cursor: default;
	}

	.at-rename {
		font: inherit;
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border-strong);
		border-radius: var(--r-sm);
		padding: 3px 7px;
		min-width: 0;
		width: 100%;
	}

	.at-rename:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.at-btn {
		padding: 4px 12px;
		font-size: 12px;
		font-weight: 600;
		border-radius: var(--r);
		cursor: pointer;
		display: inline-flex;
		align-items: center;
		gap: 5px;
	}

	.at-btn-cancel {
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border-strong);
	}

	.at-btn-cancel:hover:not(:disabled) {
		background: var(--sunken);
	}

	.at-btn-primary {
		color: var(--on-accent);
		background: var(--accent);
		border: 1px solid var(--accent);
	}

	.at-btn-primary:hover:not(:disabled) {
		background: var(--accent-press);
	}

	.at-btn:disabled {
		opacity: 0.6;
		cursor: default;
	}

	.at-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.at-mutation-error {
		font-size: 11.5px;
		color: var(--danger);
	}

	.at-composer {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 10px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
		/* Stick to the bottom of the sidecar rail's scrollport: with a long
		 * list the upload box stays reachable without scrolling to the end. */
		position: sticky;
		bottom: 0;
		z-index: 1;
	}

	.at-file-input {
		/* Hidden — the "Choose file" button proxies the native picker; play
		 * functions drive the input directly via userEvent.upload (which needs
		 * pointer events enabled, so the input hides off-screen instead). */
		position: absolute;
		left: -9999px;
		width: 1px;
		height: 1px;
		opacity: 0;
	}

	.at-composer-row {
		display: flex;
		align-items: center;
		gap: 6px;
	}

	.at-name-input {
		font: inherit;
		font-size: 12.5px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		padding: 4px 8px;
		min-width: 0;
		flex: 1;
	}

	.at-name-input:disabled {
		opacity: 0.6;
	}

	.at-name-input:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.at-chosen {
		font-size: 11px;
		color: var(--text-3);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.at-composer-locked {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
		padding: 12px;
		text-align: center;
		border: 1px dashed var(--border);
		border-radius: var(--r);
	}
</style>
