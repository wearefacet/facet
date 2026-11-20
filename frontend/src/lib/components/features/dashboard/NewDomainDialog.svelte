<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import { resetOnOpen } from '$lib/utils/resetOnOpen.svelte.js';
	import { slugifyDomainLabel } from '$lib/utils/slugify.js';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/**
		 * Called when the user confirms with a valid id. `label` is absent when
		 * left empty. Returns `null` on success (the dialog closes) or an error
		 * message string (shown inline).
		 */
		oncreate = (_input: { name: string; label?: string }) => Promise.resolve(null)
	}: {
		open?: boolean;
		oncreate?: (input: { name: string; label?: string }) => Promise<string | null>;
	} = $props();

	// Mirrors the backend `core.Domain.name` pattern and
	// `Domain::Publish.validate_target_name`.
	const DOMAIN_ID_RE = /^[a-z][a-z0-9-]*$/;

	let label = $state('');
	let id = $state('');
	// The id stops inferring once the user types their own value; clearing it
	// resumes inference from the label.
	let idDirty = $state(false);
	let error = $state<string | undefined>(undefined);
	let submitting = $state(false);

	const trimmedId = $derived(id.trim());
	const idValid = $derived(DOMAIN_ID_RE.test(trimmedId));

	function handleLabelInput(value: string) {
		label = value;
		if (!idDirty) id = slugifyDomainLabel(value);
	}

	function handleIdInput(value: string) {
		id = value;
		idDirty = value.trim().length > 0;
	}

	function reset() {
		label = '';
		id = '';
		idDirty = false;
		error = undefined;
		submitting = false;
	}

	// Reset whenever the dialog opens, so every open shows a fresh form. A
	// programmatic `open = false` (a successful create, or Cancel) does not fire
	// Bits UI's `onOpenChange`, so a close-time reset would miss those paths and
	// leak the previous entry into the next open.
	resetOnOpen(() => open, reset);

	async function handleSubmit() {
		if (!trimmedId || !idValid || submitting) return;
		submitting = true;
		error = undefined;
		const err = await oncreate({ name: trimmedId, label: label.trim() || undefined });
		submitting = false;
		if (err) {
			error = err;
			return;
		}
		open = false;
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="new-domain-overlay" />
		<Dialog.Content class="new-domain-content">
			<Dialog.Title class="new-domain-title">{m.dashboard_new_domain_title()}</Dialog.Title>
			<Dialog.Description class="new-domain-desc">
				{m.dashboard_new_domain_helper()}
			</Dialog.Description>

			<form
				onsubmit={(e) => {
					e.preventDefault();
					handleSubmit();
				}}
			>
				<div class="field">
					<label class="field-label" for="new-domain-label">
						{m.dashboard_new_domain_label_label()}
					</label>
					<input
						id="new-domain-label"
						class="field-input"
						value={label}
						oninput={(e) => handleLabelInput((e.target as HTMLInputElement).value)}
						placeholder={m.dashboard_new_domain_label_placeholder()}
						maxlength={64}
						autocomplete="off"
					/>
				</div>
				<div class="field">
					<label class="field-label" for="new-domain-id">
						{m.dashboard_new_domain_id_label()}
					</label>
					<input
						id="new-domain-id"
						class="field-input mono"
						class:invalid={trimmedId.length > 0 && !idValid}
						value={id}
						oninput={(e) => handleIdInput((e.target as HTMLInputElement).value)}
						placeholder={m.dashboard_new_domain_id_placeholder()}
						maxlength={64}
						autocomplete="off"
						spellcheck="false"
					/>
					{#if trimmedId.length > 0 && !idValid}
						<p class="hint err" role="alert">{m.configure_publish_invalid_error()}</p>
					{:else}
						<p class="hint">{m.dashboard_new_domain_id_helper()}</p>
					{/if}
				</div>
				<div class="actions">
					<button class="cancel-btn" type="button" onclick={() => (open = false)}>
						{m.common_cancel()}
					</button>
					<button class="create-btn" type="submit" disabled={!trimmedId || !idValid || submitting}>
						{submitting ? m.common_creating() : m.dashboard_new_domain_button()}
					</button>
				</div>
			</form>

			{#if error}
				<p class="err" role="alert">{error}</p>
			{/if}

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.new-domain-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.new-domain-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(460px, 90vw);
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg, 12px);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 101;
		padding: 20px;
		gap: 12px;
	}

	:global(.new-domain-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.new-domain-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.field {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	.field-label {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
	}

	.field-input {
		width: 100%;
		padding: 9px 11px;
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 13.5px;
		font-family: inherit;
	}

	.field-input.mono {
		font-family: var(--font-mono);
	}

	.field-input:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.field-input.invalid {
		border-color: var(--danger);
	}

	.hint {
		margin: 0;
		font-size: 12px;
		color: var(--text-3);
		line-height: 1.45;
	}

	.hint.err {
		color: var(--danger);
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}

	.cancel-btn,
	.create-btn {
		padding: 6px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.cancel-btn {
		border: 1px solid var(--border-strong, var(--border));
		background: var(--surface);
		color: var(--text);
	}

	.cancel-btn:hover {
		background: var(--sunken, var(--surface));
	}

	.create-btn {
		border: 1px solid var(--accent);
		background: var(--accent);
		/* `--on-accent` (dark) sits on the gold fill. `--accent-ink` is gold-on-light
	   and renders near-invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
	}

	.create-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.err {
		font-size: 13px;
		color: var(--danger);
		margin: 0;
		padding: 8px 10px;
		background: var(--danger-weak, rgba(220, 38, 38, 0.08));
		border-radius: var(--r);
	}

	:global(.close-btn) {
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

	:global(.close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
