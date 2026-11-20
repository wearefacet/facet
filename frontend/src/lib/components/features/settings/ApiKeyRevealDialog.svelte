<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import SecretRevealPanel from './SecretRevealPanel.svelte';
	import { formatFullDate } from '$lib/utils/relativeTime.js';
	import { displayTimezone } from '$lib/settings.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		open = $bindable(false),
		/** The create response — `null` renders nothing. The raw `key` is shown once. */
		created = null as { key: string; display_prefix: string; expires_at?: string | null } | null,
		/** Called when the dialog closes; the host clears the raw key from memory. */
		onclose = () => {}
	}: {
		open?: boolean;
		created?: { key: string; display_prefix: string; expires_at?: string | null } | null;
		onclose?: () => void;
	} = $props();

	function handleClose() {
		open = false;
		onclose();
	}
</script>

<Dialog.Root {open} onOpenChange={(v) => (v ? undefined : handleClose())}>
	<Dialog.Portal>
		<Dialog.Overlay class="reveal-overlay" />
		<Dialog.Content class="reveal-content">
			<Dialog.Title class="reveal-title">{m.apikeys_reveal_title()}</Dialog.Title>
			<Dialog.Description class="reveal-desc">
				{m.apikeys_reveal_helper()}
			</Dialog.Description>

			{#if created}
				<SecretRevealPanel secret={created.key} hint={null} />

				{#if created?.expires_at}
					<p class="expiry-note">
						{m.apikeys_reveal_expiry({
							date: formatFullDate(created.expires_at, displayTimezone())
						})}
					</p>
				{/if}
			{/if}

			<div class="actions">
				<button class="done-btn" type="button" onclick={handleClose}>{m.common_done()}</button>
			</div>

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.reveal-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.reveal-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(520px, 90vw);
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 101;
		padding: 24px;
		gap: 14px;
	}

	:global(.reveal-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.reveal-desc) {
		font-size: 13px;
		color: var(--text-2);
		margin: 0;
		line-height: 1.5;
	}

	.expiry-note {
		font-size: 12px;
		color: var(--text-3);
		margin: 0;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		margin-top: 4px;
	}

	.done-btn {
		padding: 6px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` is gold-on-light and
		   invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
	}

	.done-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	:global(.reveal-content .close-btn) {
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

	:global(.reveal-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.reveal-content .close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
