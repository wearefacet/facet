<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import { matchesMime } from '$lib/doctype/mimeMatcher.js';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputFileNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import FileArtifact from '$lib/components/primitives/data/FileArtifact.svelte';
	import { errorMessage } from '$lib/datasource/bannerError.js';

	let {
		template,
		document,
		values,
		fieldErrors,
		def,
		onreferenceclick: _onreferenceclick,
		uploadFile,
		fetchArtifact,
		...rest
	}: {
		/** The input-file template node. */
		template: InputFileNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		/** Mutable form values bag — the artifact id is written here on upload. */
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment. */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — for consistency with other input components. */
		def?: DoctypeDef;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
		/**
		 * Injectable uploader — receives a `File` and returns `{ id, filename }`.
		 *  Defaults to a `POST /Api/core/artifacts` call via `apiFetch`. Stories
		 *  pass a synthetic uploader so the play function can assert the field
		 *  value without a live backend. */
		uploadFile?: (file: File) => Promise<{ id: string; filename: string }>;
		/**
		 * Injectable artifact metadata fetcher — receives an artifact id and
		 *  returns `{ id, filename, url, ... }`. Defaults to
		 *  `GET /Api/core/artifacts/:id` via `apiFetch`. Used to resolve the
		 *  filename of an already-stored artifact so the edit surface shows the
		 *  human filename rather than the raw ULID. */
		fetchArtifact?: (id: string) => Promise<{ id: string; filename: string; url: string }>;
	} = $props();

	const content = $derived(getDocContent(document));
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	const error = $derived(joinFieldErrors(fieldErrors, fieldTop));

	// The field's MIME allow-list, resolved from the doctype definition. A
	// missing `accept` means any MIME is allowed. `acceptAttr` is the
	// comma-joined form the HTML <input type="file"> expects; `acceptList`
	// is the typed list used by the rejection check.
	const fieldDef = $derived(fieldDefFor(def, fieldTop));
	const acceptList = $derived(fieldDef?.accept);
	const acceptAttr = $derived(acceptList?.join(','));

	// Eagerly initialise so values[field] is never undefined at render time.
	// Skipped in display context (no `values` bag) — input nodes require a
	// form owner.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		values[template.field] = (content[template.field] as string | undefined) ?? '';
	}

	// Upload state — surfaced in the UI while the bytes are in flight and on
	// failure. The artifact id is the only persisted value (written into the
	// values bag); the filename is shown next to it as a hint.
	let uploading = $state(false);
	let uploadError = $state<string | null>(null);
	let attachedName = $state<string | null>(null);

	// Mirror the stored artifact id back into a display label when the field
	// already carries a value (e.g. an edit form loading an existing document).
	// In read-only mode (`values` absent), the id is read straight from the
	// document content — the form values bag is the source of truth only when
	// an input owner is present.
	const storedId = $derived(
		values
			? ((values[template.field] as string | undefined) ?? '')
			: ((content[template.field] as string | undefined) ?? '')
	);
	$effect(() => {
		// When the stored id changes externally (form reset, programmatic
		// upload), reset the attached name so the display does not lie about
		// a value that no longer applies, then refetch metadata so the label
		// matches the (possibly different) artifact now stored. A freshly-
		// uploaded artifact already has its filename on hand (set in `upload`),
		// so skip the refetch in that case to avoid a redundant round-trip.
		const id = storedId;
		if (!id) {
			attachedName = null;
			return;
		}
		if (attachedName && values?.[template.field] === id) return;
		let cancelled = false;
		void (async () => {
			try {
				const grant = await fetchArtifactMetadata(id);
				if (cancelled) return;
				attachedName = grant.filename;
			} catch {
				// Best-effort — leave attachedName as-is; the id remains visible.
			}
		})();
		return () => {
			cancelled = true;
		};
	});

	let inputEl: HTMLInputElement | null = $state(null);

	async function upload(file: File): Promise<void> {
		if (!values) return;
		// Reject before any byte leaves the browser. The server runs the same
		// check (`Document::FileMimeCheck`); failing client-side first avoids a
		// useless round-trip and keeps the error text adjacent to the field.
		if (acceptList && (file.type === '' || !matchesMime(file.type, acceptList))) {
			uploadError = m.doc_file_type_not_allowed({
				type: file.type || 'unknown',
				accepted: acceptList.join(', ')
			});
			return;
		}
		uploading = true;
		uploadError = null;
		try {
			const result = await uploadArtifact(file);
			values[template.field] = result.id;
			attachedName = result.filename;
		} catch (err) {
			uploadError = errorMessage(err, m.common_upload_failed());
		} finally {
			uploading = false;
		}
	}

	async function uploadArtifact(file: File): Promise<{ id: string; filename: string }> {
		if (uploadFile) return uploadFile(file);
		const { apiFetch } = await import('$lib/session.svelte');
		const form = new FormData();
		form.append('file', file, file.name);
		const res = await apiFetch('/Api/core/artifacts', {
			method: 'POST',
			body: form
		});
		if (!res.ok) {
			const body = await res.json().catch(() => ({}) as { error?: string });
			throw new Error((body as { error?: string }).error ?? `Upload failed (${res.status})`);
		}
		return (await res.json()) as { id: string; filename: string };
	}

	async function fetchArtifactMetadata(
		id: string
	): Promise<{ id: string; filename: string; url: string }> {
		if (fetchArtifact) return fetchArtifact(id);
		const { apiFetch } = await import('$lib/session.svelte');
		const res = await apiFetch(`/Api/core/artifacts/${id}`);
		if (!res.ok) {
			throw new Error(`Fetch failed (${res.status})`);
		}
		const body = (await res.json()) as { id: string; filename: string; url: string };
		return { id: body.id, filename: body.filename, url: body.url };
	}

	function onDrop(event: DragEvent): void {
		// Only honour drops carrying files. The event may also fire on text
		// drops from elsewhere in the page (drag a reference capsule, etc.) —
		// those are not file uploads.
		const file = event.dataTransfer?.files?.[0];
		if (!file) return;
		event.preventDefault();
		void upload(file);
	}

	function onInputChange(event: Event): void {
		const target = event.target as HTMLInputElement;
		const file = target.files?.[0];
		if (file) void upload(file);
		// Reset the input so selecting the same file twice fires `change`
		// again (re-uploads are idempotent on the server via dedup).
		target.value = '';
	}
</script>

<div class="dvt-input-file" {...rest}>
	{#if values}
		{#if template.label}
			<label class="dvt-input-file-label" for="file-{template.field}">
				{template.label}{template.required ? ' *' : ''}
			</label>
		{/if}
		<div
			class="dvt-input-file-drop"
			class:dragging={false}
			class:dvt-input-file-drop-err={error}
			role="button"
			tabindex="0"
			aria-label={template.placeholder ?? m.doc_file_attach_aria()}
			onclick={(e) => {
				// Let clicks on the hidden input itself bubble; otherwise clicking
				// the drop zone (the only visible target) would never reach the
				// file picker — the input is clipped to 1px via the sr-only style.
				if (e.target === inputEl) return;
				if (uploading) return;
				inputEl?.click();
			}}
			onkeydown={(e) => {
				if (e.key === 'Enter' || e.key === ' ') {
					e.preventDefault();
					inputEl?.click();
				}
			}}
			ondrop={onDrop}
			ondragover={(e) => e.preventDefault()}
		>
			<input
				bind:this={inputEl}
				id="file-{template.field}"
				class="dvt-input-file-input"
				type="file"
				accept={acceptAttr}
				onchange={onInputChange}
				aria-invalid={error ? true : undefined}
				disabled={uploading}
			/>
			{#if uploading}
				<span class="dvt-input-file-status">{m.common_uploading()}</span>
			{:else if storedId}
				<span class="dvt-input-file-attached" title={attachedName ?? storedId}>
					{attachedName ?? storedId}
					<span class="dvt-input-file-id">{storedId}</span>
				</span>
			{:else}
				<span class="dvt-input-file-hint">
					{template.placeholder ?? m.doc_file_drop_hint()}
				</span>
			{/if}
		</div>
		{#if template.helper && !error}
			<span class="dvt-input-file-helper">{template.helper}</span>
		{/if}
		{#if error}
			<span class="dvt-input-file-err" role="alert">{error}</span>
		{:else if uploadError}
			<span class="dvt-input-file-err" role="alert">{uploadError}</span>
		{/if}
	{:else}
		{#if template.label}
			<span class="dvt-input-file-label">{template.label}</span>
		{/if}
		<div class="dvt-input-file-readonly">
			{#if storedId}
				<FileArtifact artifactId={storedId} {fetchArtifact} />
			{:else}
				<span>—</span>
			{/if}
		</div>
	{/if}
</div>

<style>
	.dvt-input-file {
		display: flex;
		flex-direction: column;
		gap: 5px;
		padding: 4px 0;
	}

	.dvt-input-file-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.dvt-input-file-drop {
		display: flex;
		align-items: center;
		gap: 10px;
		min-height: 40px;
		padding: 9px 11px;
		font-size: 13px;
		color: var(--text-2);
		background: var(--surface);
		border: 1px dashed var(--border);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color 0.12s,
			box-shadow 0.12s,
			background 0.12s;
	}

	.dvt-input-file-drop:hover {
		border-color: var(--accent);
		color: var(--text);
	}

	.dvt-input-file-drop:focus-visible {
		outline: none;
		border-color: var(--accent-ink);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.dvt-input-file-drop-err {
		border-color: var(--danger);
	}

	.dvt-input-file-input {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		margin: -1px;
		overflow: hidden;
		clip: rect(0, 0, 0, 0);
		white-space: nowrap;
		border: 0;
	}

	.dvt-input-file-hint {
		color: var(--text-3);
	}

	.dvt-input-file-attached {
		display: flex;
		flex-direction: column;
		gap: 1px;
		color: var(--text);
	}

	.dvt-input-file-id {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		max-width: 240px;
	}

	.dvt-input-file-status {
		color: var(--text-2);
	}

	.dvt-input-file-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.dvt-input-file-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	.dvt-input-file-readonly {
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		padding: 6px 0;
	}
</style>
