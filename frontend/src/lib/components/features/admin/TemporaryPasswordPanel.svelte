<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X, ShieldAlert } from '@lucide/svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/**
		 * The temporary password — shown exactly once. The host sets it right
		 * after the generate call resolves and clears it when the panel closes,
		 * so the component never receives the same password twice. `null`
		 * renders nothing.
		 */
		password = null as string | null,
		/** The account the password belongs to (for context in the copy). */
		email = null as string | null,
		/** `true` after a regenerate — the heading states that explicitly. */
		regenerated = false,
		/** Called when the panel closes; the host clears the password. */
		onclose = () => {}
	}: {
		open?: boolean;
		password?: string | null;
		email?: string | null;
		regenerated?: boolean;
		onclose?: () => void;
	} = $props();

	const shown = $derived(password ?? '');

	function handleClose() {
		open = false;
		onclose();
	}
</script>

{#if password}
	<Dialog.Root {open} onOpenChange={(v) => (v ? undefined : handleClose())}>
		<Dialog.Portal>
			<Dialog.Overlay class="temp-pw-overlay" />
			<Dialog.Content class="temp-pw-content">
				<Dialog.Title class="temp-pw-title">
					{regenerated ? m.admin_temp_pw_regenerated_title() : m.admin_temp_pw_generated_title()}
				</Dialog.Title>
				<Dialog.Description class="temp-pw-desc">
					{#if email}
						{m.admin_temp_pw_desc_email({ email })}
					{:else}
						{m.admin_temp_pw_desc()}
					{/if}
				</Dialog.Description>

				<div class="pw-row">
					<code class="pw-value">{shown}</code>
					<CopyButton value={shown} title={m.admin_temp_pw_copy_aria()} />
				</div>

				<div class="warn" role="alert">
					<ShieldAlert size={15} stroke-width={1.8} aria-hidden="true" />
					<p>
						{m.admin_temp_pw_warning()}
					</p>
				</div>

				<div class="actions">
					<button class="done-btn" type="button" onclick={handleClose}>{m.common_done()}</button>
				</div>

				<Dialog.Close class="close-btn" title={m.common_close()}>
					<X size={16} stroke-width={1.8} />
				</Dialog.Close>
			</Dialog.Content>
		</Dialog.Portal>
	</Dialog.Root>
{/if}

<style>
	:global(.temp-pw-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 110;
	}

	:global(.temp-pw-content) {
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
		box-shadow: var(--sh-2);
		z-index: 111;
		padding: 24px;
		gap: 14px;
	}

	:global(.temp-pw-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.temp-pw-desc) {
		font-size: 13px;
		color: var(--text-2);
		margin: 0;
		line-height: 1.45;
	}

	:global(.temp-pw-desc code) {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.pw-row {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.pw-value {
		flex: 1;
		min-width: 0;
		padding: 10px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--sunken);
		font-family: var(--font-mono);
		font-size: 14px;
		letter-spacing: 0.04em;
		color: var(--text);
		overflow-wrap: anywhere;
	}

	.warn {
		display: flex;
		align-items: flex-start;
		gap: 8px;
		padding: 10px 12px;
		border-radius: var(--r);
		background: var(--warn-weak);
		color: var(--warn);
	}

	.warn p {
		margin: 0;
		font-size: 12.5px;
		line-height: 1.5;
	}

	.warn :global(svg) {
		flex: none;
		margin-top: 2px;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		margin-top: 2px;
	}

	.done-btn {
		padding: 6px 14px;
		border-radius: var(--r);
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` is gold-on-light and
		   invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.done-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	:global(.temp-pw-content .close-btn) {
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

	:global(.temp-pw-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.temp-pw-content .close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
