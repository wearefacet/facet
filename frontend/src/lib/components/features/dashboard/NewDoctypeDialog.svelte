<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import { resetOnOpen } from '$lib/utils/resetOnOpen.svelte.js';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/**
		 * Called when the user confirms with a non-empty, CamelCase name.
		 * Returns `null` on success (the dialog closes) or an error message
		 * string (shown inline).
		 */
		oncreate = (_name: string) => Promise.resolve(null)
	}: {
		open?: boolean;
		oncreate?: (name: string) => Promise<string | null>;
	} = $props();

	let name = $state('');
	let error = $state<string | undefined>(undefined);
	let submitting = $state(false);

	// CamelCase alphanumeric, cannot start with a digit. Mirrors the backend
	// DoctypeDefinition::DOCTYPE_RE so the client rejects bad names before the
	// round-trip (the backend re-validates authoritatively).
	const NAME_RE = /^[A-Z][a-zA-Z0-9]*$/;

	function reset() {
		name = '';
		error = undefined;
		submitting = false;
	}

	// Reset whenever the dialog opens, so every open shows a fresh form. A
	// programmatic `open = false` (a successful create, or Cancel) does not fire
	// Bits UI's `onOpenChange`, so a close-time reset would miss those paths and
	// leak the previous entry into the next open.
	resetOnOpen(() => open, reset);

	function validate(value: string): string | undefined {
		const trimmed = value.trim();
		if (!trimmed) return undefined;
		if (!NAME_RE.test(trimmed)) {
			return m.dashboard_new_doctype_name_error();
		}
		return undefined;
	}

	const nameError = $derived(validate(name));

	async function handleSubmit() {
		const trimmed = name.trim();
		if (!trimmed || submitting || nameError) return;
		submitting = true;
		error = undefined;
		const err = await oncreate(trimmed);
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
		<Dialog.Overlay class="new-doctype-overlay" />
		<Dialog.Content class="new-doctype-content">
			<Dialog.Title class="new-doctype-title">{m.dashboard_new_doctype_title()}</Dialog.Title>
			<Dialog.Description class="new-doctype-desc">
				{m.dashboard_new_doctype_helper()}
			</Dialog.Description>

			<form
				onsubmit={(e) => {
					e.preventDefault();
					handleSubmit();
				}}
			>
				<input
					class="name-input"
					class:invalid={!!nameError}
					bind:value={name}
					placeholder={m.dashboard_new_doctype_placeholder()}
					autocomplete="off"
				/>
				{#if nameError}
					<p class="field-hint" role="status">{nameError}</p>
				{/if}
				<div class="actions">
					<button class="cancel-btn" type="button" onclick={() => (open = false)}>
						{m.common_cancel()}
					</button>
					<button
						class="create-btn"
						type="submit"
						disabled={!name.trim() || !!nameError || submitting}
					>
						{submitting ? m.common_creating() : m.dashboard_new_doctype_button()}
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
	:global(.new-doctype-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.new-doctype-content) {
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

	:global(.new-doctype-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.new-doctype-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.name-input {
		width: 100%;
		padding: 9px 11px;
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 13.5px;
		font-family: inherit;
	}

	.name-input:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.name-input.invalid {
		border-color: var(--danger, #dc2626);
	}

	.field-hint {
		margin: 0;
		font-size: 12px;
		color: var(--danger, #dc2626);
		line-height: 1.4;
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
