<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Dialog } from 'bits-ui';
	import { X, UploadCloud, CheckCircle2, AlertTriangle } from '@lucide/svelte';
	import { apiFetch } from '$lib/session.svelte.js';
	import {
		enqueueImport,
		pollJob,
		ImportError,
		importReportOf,
		importRowErrorOf,
		detectFormat,
		previewHeader,
		type FetchImpl,
		type ImportReport,
		type ImportRowError
	} from '$lib/importExport/importExportClient.js';

	/**
	 * ImportDialog — the table toolbar's import affordance. A Bits UI
	 * dialog: file pick, a client-side header preview (never authoritative —
	 * the server parses at enqueue), submit, then the job's outcome driven
	 * by the status poll: the upsert report on success, the failing row's
	 * `{row, field, message}` on an all-or-nothing failure.
	 */
	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/** The doctype being imported (e.g. `crm.Company`). */
		domain,
		doctype,
		/** Called after a job imports — the host refreshes its lists. */
		onimported,
		/** Injectable fetch — defaults to `apiFetch` (token refresh + 401 recovery). Stories stub it. */
		fetchImpl = apiFetch as unknown as FetchImpl
	}: {
		open?: boolean;
		domain: string;
		doctype: string;
		onimported?: () => void;
		fetchImpl?: FetchImpl;
	} = $props();

	type Phase =
		| { step: 'pick' }
		| { step: 'uploading' }
		| { step: 'running'; jobId: string; rowCount: number }
		| { step: 'succeeded'; report: ImportReport }
		| { step: 'failed'; error: ImportRowError | string };

	let phase = $state<Phase>({ step: 'pick' });
	let file: File | null = $state(null);
	let fileText = $state('');
	let errorMessage = $state<string | undefined>(undefined);
	let fileInput: HTMLInputElement | null = $state(null);

	const deadline = { pollMs: 500, timeoutMs: 30_000 };

	function reset() {
		phase = { step: 'pick' };
		file = null;
		fileText = '';
		errorMessage = undefined;
		if (fileInput) fileInput.value = '';
	}

	function close() {
		open = false;
	}

	function handleOpenChange(v: boolean) {
		if (!v) {
			// Closed mid-run: keep the surface dismissible — the job keeps
			// running server-side and its notification reports the outcome.
			if (phase.step !== 'uploading') reset();
			// Bits UI closes through this callback from every path (Close
			// button, Escape, outside click). Sync the bindable state here too,
			// so the host's open flag always matches the dialog (B-221).
			open = false;
		}
	}

	async function handleFileChange(event: Event) {
		const input = event.target as HTMLInputElement;
		const picked = input.files?.[0] ?? null;
		errorMessage = undefined;
		if (!picked) {
			file = null;
			fileText = '';
			return;
		}
		file = picked;
		try {
			fileText = await picked.text();
		} catch {
			fileText = '';
			errorMessage = m.impex_file_read_failed();
		}
	}

	const format = $derived(file ? detectFormat(file) : null);
	const preview = $derived(
		file && format ? previewHeader(fileText, format) : { columns: [], rowCount: null }
	);
	const pickable = $derived(file !== null && format !== null && fileText.length > 0);

	const submitting = $derived(phase.step === 'uploading');

	async function handleSubmit() {
		if (!pickable || !format || submitting) return;
		phase = { step: 'uploading' };

		try {
			const enqueued = await enqueueImport(fetchImpl, domain, doctype, fileText, format);
			phase = {
				step: 'running',
				jobId: enqueued.jobId,
				rowCount: enqueued.rowCount ?? preview.rowCount ?? 0
			};
			const outcome = await pollJob(fetchImpl, domain, doctype, enqueued.jobId, deadline);

			if (outcome.mode === 'timeout') {
				// Same contract as the API's wait mode: the job keeps running,
				// the dialog reports the enqueue-mode surface.
				phase = { step: 'running', jobId: enqueued.jobId, rowCount: enqueued.rowCount ?? 0 };
				close();
				return;
			}
			if (outcome.status.status === 'succeeded') {
				const report = importReportOf(outcome.status.result);
				if (report) {
					phase = { step: 'succeeded', report };
					// The rows are in — the host listing still shows the pre-import
					// page until it refetches.
					onimported?.();
					return;
				}
				close();
				return;
			}

			const rowError =
				importRowErrorOf(outcome.status.result) ??
				({
					row: 0,
					field: null,
					message: outcome.status.error ?? m.impex_import_failed()
				} as ImportRowError);
			phase = { step: 'failed', error: rowError };
		} catch (e) {
			phase = { step: 'pick' };
			errorMessage = e instanceof ImportError ? e.message : m.impex_import_start_failed();
		}
	}
</script>

<Dialog.Root bind:open onOpenChange={handleOpenChange}>
	<Dialog.Portal>
		<Dialog.Overlay class="import-overlay" />
		<Dialog.Content class="import-content">
			<Dialog.Title class="import-title">{m.impex_import_title({ doctype })}</Dialog.Title>
			<Dialog.Description class="import-desc">
				{m.impex_import_desc()}
			</Dialog.Description>

			{#if phase.step === 'pick'}
				<div class="pick">
					<label class="dropzone">
						<input
							class="file-input"
							type="file"
							accept=".csv,.json,text/csv,application/json"
							onchange={handleFileChange}
							bind:this={fileInput}
						/>
						<UploadCloud size={20} strokeWidth={1.8} aria-hidden="true" />
						<span class="dropzone-text">
							{file ? file.name : m.impex_choose_file()}
						</span>
					</label>

					{#if file && format}
						<div class="preview">
							<p class="preview-label">
								<span class="preview-count"
									>{m.impex_row_count({ count: preview.rowCount ?? '?' })}</span
								>
								<span class="preview-cols"
									>{preview.columns.slice(0, 6).join(' · ')}{preview.columns.length > 6
										? ' …'
										: ''}</span
								>
							</p>
						</div>
					{/if}

					{#if errorMessage}
						<div class="err" role="alert">{errorMessage}</div>
					{/if}
				</div>

				<div class="actions">
					<button class="cancel-btn" type="button" onclick={close}>{m.common_cancel()}</button>
					<button
						class="primary-btn"
						type="button"
						disabled={!pickable || submitting}
						onclick={handleSubmit}
					>
						{m.impex_import()}
					</button>
				</div>
			{:else if phase.step === 'uploading'}
				<p class="phase-note" role="status">{m.common_uploading()}</p>
			{:else if phase.step === 'running'}
				<p class="phase-note" role="status">
					{m.impex_importing({ count: phase.rowCount })}
				</p>
			{:else if phase.step === 'succeeded'}
				<div class="report">
					<CheckCircle2 size={18} strokeWidth={1.8} aria-hidden="true" />
					<span class="report-line">
						{m.impex_report_line({
							created: phase.report.created,
							updated: phase.report.updated,
							skipped: phase.report.skipped
						})}
					</span>
				</div>
				<div class="actions">
					<button class="primary-btn" type="button" onclick={reset}
						>{m.impex_import_another()}</button
					>
					<button class="cancel-btn" type="button" onclick={close}>{m.common_done()}</button>
				</div>
			{:else if phase.step === 'failed'}
				<div class="failure" role="alert">
					<AlertTriangle size={18} strokeWidth={1.8} aria-hidden="true" />
					<div class="failure-text">
						<p class="failure-head">{m.impex_nothing_imported()}</p>
						{#if typeof phase.error === 'string'}
							<p class="failure-row">{phase.error}</p>
						{:else if phase.error.field}
							<p class="failure-row">
								{m.impex_row_field_error({
									row: phase.error.row,
									field: phase.error.field,
									message: phase.error.message
								})}
							</p>
						{:else}
							<p class="failure-row">
								{m.impex_row_error({ row: phase.error.row, message: phase.error.message })}
							</p>
						{/if}
						<p class="failure-hint">{m.impex_fix_row_hint()}</p>
					</div>
				</div>
				<div class="actions">
					<button class="cancel-btn" type="button" onclick={reset}>{m.impex_pick_another()}</button>
				</div>
			{/if}

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.import-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.import-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(480px, 90vw);
		display: flex;
		flex-direction: column;
		gap: 14px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 101;
		padding: 24px;
	}

	:global(.import-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.import-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.dropzone {
		display: flex;
		align-items: center;
		gap: 10px;
		border: 1px dashed var(--border-strong);
		border-radius: var(--r);
		padding: 14px;
		cursor: pointer;
		color: var(--text-2);
	}

	.dropzone:hover {
		background: var(--surface-2);
	}

	.dropzone:focus-within {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.file-input {
		font-size: 12px;
		color: var(--text-2);
	}

	.file-input:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.dropzone-text {
		font-size: 13px;
	}

	.preview {
		margin-top: 10px;
	}

	.preview-label {
		display: flex;
		align-items: baseline;
		gap: 10px;
		margin: 0;
		font-size: 12px;
	}

	.preview-count {
		font-family: var(--font-mono);
		color: var(--text-2);
	}

	.preview-cols {
		font-family: var(--font-mono);
		color: var(--text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.phase-note {
		font-size: 13px;
		color: var(--text-2);
		margin: 8px 0;
	}

	.report {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--ok);
		font-size: 13px;
	}

	.report-line {
		font-family: var(--font-mono);
		color: var(--text);
	}

	.failure {
		display: flex;
		gap: 10px;
		padding: 12px;
		background: var(--danger-weak);
		border-radius: var(--r);
		color: var(--danger);
	}

	.failure-text {
		display: flex;
		flex-direction: column;
		gap: 4px;
		font-size: 13px;
	}

	.failure-head {
		margin: 0;
		font-weight: 600;
	}

	.failure-row {
		margin: 0;
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.failure-hint {
		margin: 0;
		color: var(--text-2);
		font-size: 12px;
	}

	.err {
		font-size: 12.5px;
		color: var(--danger);
		padding: 8px 10px;
		background: var(--danger-weak);
		border-radius: var(--r);
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 2px;
	}

	.cancel-btn,
	.primary-btn {
		padding: 6px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.cancel-btn {
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text);
	}

	.cancel-btn:hover {
		background: var(--sunken);
	}

	.primary-btn {
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — see tokens: "Gold fill ≠ gold text". */
		color: var(--on-accent);
	}

	.primary-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	:global(.import-content .close-btn) {
		position: absolute;
		top: 14px;
		right: 14px;
		width: 28px;
		height: 28px;
		display: grid;
		place-items: center;
		border: none;
		border-radius: var(--r);
		background: none;
		color: var(--text-3);
		cursor: pointer;
	}

	:global(.import-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}
</style>
