<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	let {
		title,
		warning,
		confirmTarget,
		confirmLabel,
		busyLabel = m.common_deleting(),
		busy = false,
		error,
		onconfirm
	}: {
		/** Zone heading, e.g. "Danger zone" or "Discard draft". */
		title: string;
		/** One-line explanation of what the destructive action removes. */
		warning: string;
		/** The exact name the user must type to arm the confirm button. */
		confirmTarget: string;
		/** Button label while idle. */
		confirmLabel: string;
		/** Button label while `busy` is true. Defaults to "Deleting…". */
		busyLabel?: string;
		/** Set while the destructive request is in flight. */
		busy?: boolean;
		/** Failure message from the last attempt; rendered with `role="alert"`. */
		error?: string;
		onconfirm: () => void;
	} = $props();

	let confirmText = $state('');
</script>

<div class="danger-zone">
	<h4>{title}</h4>
	<p>{warning}</p>
	<div class="danger-confirm">
		<input
			class="danger-input"
			placeholder={m.configure_confirm_placeholder({ name: confirmTarget })}
			bind:value={confirmText}
		/>
		<button class="danger-btn" disabled={confirmText !== confirmTarget || busy} onclick={onconfirm}>
			{busy ? busyLabel : confirmLabel}
		</button>
	</div>
	{#if error}
		<p class="danger-error" role="alert">{error}</p>
	{/if}
</div>

<style>
	.danger-zone {
		margin-top: 32px;
		padding-top: 20px;
		border-top: 1px solid var(--danger-weak);
	}
	.danger-zone h4 {
		font-size: 11px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--danger);
		margin: 0 0 8px;
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.danger-zone p {
		font-size: 12.5px;
		color: var(--text-3);
		margin: 0 0 13px;
	}
	.danger-confirm {
		display: flex;
		gap: 10px;
		align-items: center;
	}
	/* Full input chrome — the component does not rely on a parent-scoped
	   `.inp` rule (the editors it replaces styled their own). */
	.danger-input {
		flex: 1;
		max-width: 320px;
		padding: 8px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		font: inherit;
		font-size: 13px;
		font-family: var(--font-mono);
		color: var(--text);
	}
	.danger-input:focus {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}
	.danger-btn {
		padding: 8px 16px;
		border-radius: var(--r);
		border: 1px solid var(--danger);
		background: var(--danger);
		color: var(--danger-ink);
		font: inherit;
		font-size: 13px;
		font-weight: 600;
		cursor: pointer;
		flex: none;
		white-space: nowrap;
	}
	.danger-btn:hover:not(:disabled) {
		opacity: 0.85;
	}
	.danger-btn:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}
	.danger-error {
		margin: 8px 0 0;
		font-size: 13px;
		color: var(--danger);
	}
</style>
