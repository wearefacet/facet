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
		/** The domain to delete. `undefined` keeps the dialog closed/reset. */
		domain,
		/**
		 * Performs the delete. Returns `null` on success or an error message
		 * string (shown inline, dialog stays open).
		 */
		ondeleted = (_id: string) => Promise.resolve(null)
	}: {
		open?: boolean;
		domain?: { id: string; label: string };
		ondeleted?: (id: string) => Promise<string | null>;
	} = $props();

	let confirmText = $state('');
	let error = $state<string | undefined>(undefined);
	let deleting = $state(false);

	function reset() {
		confirmText = '';
		error = undefined;
		deleting = false;
	}

	// Reset whenever the dialog opens, so every open shows a fresh form. A
	// programmatic `open = false` (a successful delete, or Cancel) does not fire
	// Bits UI's `onOpenChange`, so a close-time reset would miss those paths and
	// leak the previous entry into the next open.
	resetOnOpen(() => open, reset);

	async function handleSubmit() {
		if (!domain || confirmText !== domain.id || deleting) return;
		deleting = true;
		error = undefined;
		const err = await ondeleted(domain.id);
		deleting = false;
		if (err) {
			error = err;
			return;
		}
		open = false;
	}
</script>

{#if domain}
	<Dialog.Root bind:open>
		<Dialog.Portal>
			<Dialog.Overlay class="del-domain-overlay" />
			<Dialog.Content class="del-domain-content">
				<Dialog.Title class="del-domain-title"
					>{m.configure_domains_delete_dialog_title({ name: domain.label })}</Dialog.Title
				>
				<Dialog.Description class="del-domain-desc">
					{m.configure_domains_delete_dialog_desc({ id: domain.id })}
				</Dialog.Description>

				<form
					onsubmit={(e) => {
						e.preventDefault();
						handleSubmit();
					}}
				>
					<input
						class="confirm-input mono"
						bind:value={confirmText}
						placeholder={m.configure_confirm_placeholder({ name: domain.id })}
						autocomplete="off"
					/>
					<div class="actions">
						<button class="cancel-btn" type="button" onclick={() => (open = false)}>
							{m.common_cancel()}
						</button>
						<button
							class="delete-btn"
							type="submit"
							disabled={confirmText !== domain.id || deleting}
						>
							{deleting ? m.common_deleting() : m.configure_domains_delete_button()}
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
{/if}

<style>
	:global(.del-domain-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.del-domain-content) {
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

	:global(.del-domain-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.del-domain-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	:global(.del-domain-desc .mono) {
		font-family: var(--font-mono, monospace);
	}

	.confirm-input {
		width: 100%;
		padding: 9px 11px;
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 13.5px;
		font-family: inherit;
	}

	.confirm-input:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}

	.cancel-btn,
	.delete-btn {
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

	.delete-btn {
		border: 1px solid var(--danger);
		background: var(--danger);
		color: var(--danger-ink);
	}

	.delete-btn:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}

	.err {
		font-size: 13px;
		color: var(--danger);
		margin: 0;
		padding: 8px 10px;
		background: var(--danger-weak);
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
