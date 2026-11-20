<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Dialog } from 'bits-ui';
	import Button from '../actions/Button.svelte';
	import Input from '../forms/Input.svelte';
	import { getPendingConfirm, settleConfirm } from '$lib/confirm.svelte';

	/**
	 * ConfirmDialog — the single global host that backs `confirm()` and
	 * `confirmWithText()` from `$lib/confirm.svelte`. Mounted once in the
	 * root layout; renders nothing while no confirmation is pending. When
	 * the pending options carry a `prompt`, one optional free-text input
	 * is rendered and its value rides back through `settleConfirm`.
	 */

	const pending = $derived(getPendingConfirm());
	let promptText = $state('');

	// Reset the captured text whenever a new request opens (the host stays
	// mounted; only the dialog inside the `{#if}` unmounts).
	$effect(() => {
		void pending;
		promptText = '';
	});
</script>

{#if pending}
	<Dialog.Root
		open
		onOpenChange={(v) => {
			if (!v) settleConfirm(false);
		}}
	>
		<Dialog.Portal>
			<Dialog.Overlay class="confirm-overlay" />
			<Dialog.Content class="confirm-content">
				<Dialog.Title class="confirm-title">{pending.title}</Dialog.Title>
				{#if pending.message}
					<Dialog.Description class="confirm-desc">{pending.message}</Dialog.Description>
				{/if}

				{#if pending.prompt}
					<Input
						label={pending.prompt.label}
						placeholder={pending.prompt.placeholder}
						value={promptText}
						oninput={(e) => (promptText = (e.target as HTMLInputElement).value)}
					/>
				{/if}

				<div class="confirm-actions">
					<Button variant="secondary" size="sm" onclick={() => settleConfirm(false)}>
						{pending.cancelLabel ?? m.common_cancel()}
					</Button>
					<Button
						variant={pending.variant === 'danger' ? 'danger' : 'primary'}
						size="sm"
						onclick={() => settleConfirm(true, promptText)}
					>
						{pending.confirmLabel ?? m.common_confirm()}
					</Button>
				</div>
			</Dialog.Content>
		</Dialog.Portal>
	</Dialog.Root>
{/if}

<style>
	:global(.confirm-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 120;
	}

	:global(.confirm-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(400px, 90vw);
		display: flex;
		flex-direction: column;
		gap: 10px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		padding: 20px;
		z-index: 121;
	}

	:global(.confirm-title) {
		font-family: var(--font-display);
		font-size: 15px;
		font-weight: 600;
		margin: 0;
	}

	:global(.confirm-desc) {
		font-size: 13px;
		color: var(--text-2);
		line-height: 1.5;
		margin: 0;
	}

	.confirm-actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 8px;
	}
	/* The action buttons are the shared `Button` primitive now. */
</style>
