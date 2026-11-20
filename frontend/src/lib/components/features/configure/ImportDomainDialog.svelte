<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Dialog } from 'bits-ui';
	import { X, UploadCloud, CheckCircle2, AlertTriangle } from '@lucide/svelte';
	import { apiFetch } from '$lib/session.svelte.js';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import {
		enqueueDomainImport,
		pollJob,
		isBundleFile,
		importReportOf,
		PortableDomainError,
		type FetchImpl,
		type DomainImportReport
	} from '$lib/portableDomains/portableDomainsClient.js';

	/**
	 * ImportDomainDialog — the domain list's bundle import affordance. A
	 * Bits UI dialog: bundle pick (.zip / .tar.gz), an optional target
	 * rename (`into`) and merge toggle, submit, then the job's outcome
	 * driven by the status poll: the doctype counters report on success,
	 * the backend's rejection message on an expected failure. A wait-mode
	 * timeout closes the dialog while the job keeps running — the
	 * notification reports it.
	 */
	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/** Called after a bundle imports with the import report — the target
		 *  domain id is `report.domain`, so hosts can drop per-domain caches
		 *  (the sidebar's counts) alongside their list refreshes. */
		onimported,
		/** Injectable fetch — defaults to `apiFetch` (token refresh + 401 recovery). Stories stub it. */
		fetchImpl = apiFetch as unknown as FetchImpl
	}: {
		open?: boolean;
		onimported?: (report: DomainImportReport) => void;
		fetchImpl?: FetchImpl;
	} = $props();

	type Phase =
		| { step: 'pick' }
		| { step: 'uploading' }
		| { step: 'running'; jobId: string }
		| { step: 'succeeded'; report: DomainImportReport }
		| { step: 'failed'; message: string };

	let phase = $state<Phase>({ step: 'pick' });
	let file: File | null = $state(null);
	let into = $state('');
	let merge = $state(false);
	let errorMessage = $state<string | undefined>(undefined);
	let fileInput: HTMLInputElement | null = $state(null);

	const deadline = { pollMs: 500, timeoutMs: 30_000 };

	function reset() {
		phase = { step: 'pick' };
		file = null;
		into = '';
		merge = false;
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
		}
	}

	function handleFileChange(event: Event) {
		const input = event.target as HTMLInputElement;
		const picked = input.files?.[0] ?? null;
		errorMessage = undefined;
		if (!picked) {
			file = null;
			return;
		}
		// Client-side guard only — the backend sniffs the magic bytes.
		if (!isBundleFile(picked)) {
			file = null;
			errorMessage = m.configure_domains_bundle_invalid();
			return;
		}
		file = picked;
	}

	const submitting = $derived(phase.step === 'uploading');
	const pickable = $derived(file !== null && !submitting);

	async function handleSubmit() {
		if (!file || submitting) return;
		phase = { step: 'uploading' };

		try {
			const enqueued = await enqueueDomainImport(fetchImpl, file, {
				into: into.trim() || undefined,
				merge
			});
			phase = { step: 'running', jobId: enqueued.jobId };
			const outcome = await pollJob(fetchImpl, enqueued.jobId, deadline);

			if (outcome.mode === 'timeout') {
				// Same contract as the API's wait mode: the job keeps running,
				// the dialog reports the enqueue-mode surface.
				phase = { step: 'running', jobId: enqueued.jobId };
				close();
				return;
			}
			if (outcome.status.status === 'succeeded') {
				const report = importReportOf(outcome.status.result);
				if (report) {
					phase = { step: 'succeeded', report };
					onimported?.(report);
					return;
				}
				close();
				return;
			}

			phase = {
				step: 'failed',
				message: outcome.status.error ?? m.configure_domains_bundle_failed()
			};
		} catch (e) {
			phase = { step: 'pick' };
			errorMessage = e instanceof PortableDomainError ? e.message : m.impex_import_start_failed();
		}
	}
</script>

<Dialog.Root {open} onOpenChange={handleOpenChange}>
	<Dialog.Portal>
		<Dialog.Overlay class="dimp-overlay" />
		<Dialog.Content class="dimp-content">
			<Dialog.Title class="dimp-title">{m.configure_domains_import_title()}</Dialog.Title>
			<Dialog.Description class="dimp-desc">
				{m.configure_domains_import_desc()}
			</Dialog.Description>

			{#if phase.step === 'pick'}
				<div class="pick">
					<label class="dropzone">
						<input
							class="file-input"
							type="file"
							accept=".zip,.tar.gz,.tgz"
							onchange={handleFileChange}
							bind:this={fileInput}
						/>
						<UploadCloud size={20} strokeWidth={1.8} aria-hidden="true" />
						<span class="dropzone-text">
							{file ? file.name : m.configure_domains_bundle_choose()}
						</span>
					</label>

					<Input
						type="text"
						label={m.configure_domains_bundle_into_label()}
						helper={m.configure_domains_bundle_into_helper()}
						placeholder={m.configure_domains_bundle_into_placeholder()}
						bind:value={into}
					/>

					<label class="merge">
						<input type="checkbox" bind:checked={merge} />
						<span class="merge-label">{m.configure_domains_bundle_merge_label()}</span>
					</label>
					<p class="merge-helper">{m.configure_domains_bundle_merge_helper()}</p>

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
				<p class="phase-note" role="status">{m.configure_domains_bundle_importing()}</p>
			{:else if phase.step === 'succeeded'}
				<div class="report">
					<CheckCircle2 size={18} strokeWidth={1.8} aria-hidden="true" />
					<div class="report-text">
						<p class="report-domain">{phase.report.domain}</p>
						<span class="report-line">
							{m.configure_domains_bundle_report_line({
								created: phase.report.doctypes_created,
								updated: phase.report.doctypes_updated,
								unchanged: phase.report.doctypes_unchanged
							})}
						</span>
					</div>
				</div>
				<div class="actions">
					<button class="cancel-btn" type="button" onclick={reset}
						>{m.configure_domains_bundle_import_another()}</button
					>
					<button class="primary-btn" type="button" onclick={close}>{m.common_done()}</button>
				</div>
			{:else if phase.step === 'failed'}
				<div class="failure" role="alert">
					<AlertTriangle size={18} strokeWidth={1.8} aria-hidden="true" />
					<div class="failure-text">
						<p class="failure-head">{m.configure_domains_bundle_failed()}</p>
						<p class="failure-row">{phase.message}</p>
					</div>
				</div>
				<div class="actions">
					<button class="cancel-btn" type="button" onclick={reset}
						>{m.configure_domains_bundle_pick_another()}</button
					>
				</div>
			{/if}

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.dimp-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.dimp-content) {
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

	:global(.dimp-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.dimp-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.pick {
		display: flex;
		flex-direction: column;
		gap: 12px;
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
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.merge {
		display: flex;
		align-items: center;
		gap: 8px;
		cursor: pointer;
		font-size: 13px;
		color: var(--text);
	}

	.merge input {
		accent-color: var(--accent);
	}

	.merge input:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.merge-label {
		font-weight: 600;
	}

	.merge-helper {
		margin: -6px 0 0;
		font-size: 12px;
		color: var(--text-3);
		line-height: 1.45;
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

	.report-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.report-domain {
		margin: 0;
		font-weight: 600;
		color: var(--text);
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
		overflow-wrap: anywhere;
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

	:global(.dimp-content .close-btn) {
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

	:global(.dimp-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}
</style>
