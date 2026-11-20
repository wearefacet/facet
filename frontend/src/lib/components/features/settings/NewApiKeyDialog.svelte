<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import type { SelectOption } from '$lib/components/primitives/forms/Select.svelte';
	import DatetimePicker from '$lib/components/primitives/forms/DatetimePicker.svelte';
	import { roleDocIdToName, humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import type { CreateApiKeyInput } from '$lib/iam/apiKeys.js';
	import { resetOnOpen } from '$lib/utils/resetOnOpen.svelte.js';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/** Role document ids the caller is assigned — one of these is required. */
		roles = [] as string[],
		/** Selected role id; bindable so a host can preselect a role. */
		role = $bindable(''),
		/**
		 * Called when the user confirms with a valid name + role. Returns `null`
		 * on success (the dialog closes) or an error message string (shown inline).
		 */
		oncreate = (_input: CreateApiKeyInput) => Promise.resolve(null)
	}: {
		open?: boolean;
		roles?: string[];
		role?: string;
		oncreate?: (input: CreateApiKeyInput) => Promise<string | null>;
	} = $props();

	// Mirrors `IAM::ApiKey::NAME_MAX_LENGTH` in `src/iam/api_key.cr`.
	const NAME_MAX_LENGTH = 100;

	let name = $state('');
	/** UTC RFC-3339 expiry from the picker; '' means "no expiry". */
	let expires = $state('');
	let errorMessage = $state<string | undefined>(undefined);
	let submitting = $state(false);

	function reset() {
		name = '';
		expires = '';
		errorMessage = undefined;
		submitting = false;
		// `role` is host-owned preselection (the bindable `role` prop): the host
		// re-applies the active role on every open, so clearing it here would drop
		// that preselection instead of resetting a user entry.
	}

	// Reset whenever the dialog opens, so every open shows a fresh form. A
	// programmatic `open = false` (a successful create, or Cancel) does not fire
	// Bits UI's `onOpenChange`, so a close-time reset would miss those paths and
	// leak the previous entry into the next open.
	resetOnOpen(() => open, reset);

	const roleOptions = $derived(
		roles.map<SelectOption>((r) => ({
			value: r,
			label: humanizeRoleName(roleDocIdToName(r))
		}))
	);

	/** The picker emits UTC RFC-3339 directly; `''` maps to "no expiry". */
	const expiresIso = $derived(expires || undefined);

	// Courtesy check — the backend re-validates and rejects past dates.
	const expiresValid = $derived(!expiresIso || new Date(expiresIso).getTime() > Date.now());

	const valid = $derived(name.trim().length > 0 && role !== '' && expiresValid);

	async function handleSubmit() {
		if (!valid || submitting) return;
		submitting = true;
		errorMessage = undefined;
		const err = await oncreate({
			name: name.trim(),
			role,
			expires_at: expiresIso
		});
		submitting = false;
		if (err) {
			errorMessage = err;
			return;
		}
		open = false;
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="new-key-overlay" />
		<Dialog.Content class="new-key-content">
			<Dialog.Title class="new-key-title">{m.apikeys_new_title()}</Dialog.Title>
			<Dialog.Description class="new-key-desc">
				{m.apikeys_new_helper()}
			</Dialog.Description>

			<form
				class="new-key-form"
				onsubmit={(e) => {
					e.preventDefault();
					handleSubmit();
				}}
			>
				<div class="field">
					<label class="field-label" for="new-key-name">{m.common_name()}</label>
					<input
						id="new-key-name"
						class="name-input"
						maxlength={NAME_MAX_LENGTH}
						bind:value={name}
						placeholder={m.apikeys_new_name_placeholder()}
						autocomplete="off"
					/>
					<p class="hint">{m.apikeys_new_name_helper({ max: NAME_MAX_LENGTH })}</p>
				</div>

				<div class="field">
					<Select
						label={m.common_role()}
						placeholder={m.apikeys_new_role_placeholder()}
						options={roleOptions}
						searchable={false}
						bind:value={role}
						helper={m.apikeys_new_role_helper()}
					/>
				</div>

				<div class="field">
					<DatetimePicker
						label={m.apikeys_expires_label()}
						bind:value={expires}
						helper={m.apikeys_new_expires_helper()}
						error={expires && !expiresValid ? m.apikeys_new_expires_error() : undefined}
					/>
				</div>

				<div class="actions">
					<button class="cancel-btn" type="button" onclick={() => (open = false)}
						>{m.common_cancel()}</button
					>
					<button class="create-btn" type="submit" disabled={!valid || submitting}>
						{submitting ? m.common_creating() : m.apikeys_create_button()}
					</button>
				</div>
			</form>

			{#if errorMessage}
				<div class="err" role="alert">
					<p class="err-head">{errorMessage}</p>
				</div>
			{/if}

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.new-key-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.new-key-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(480px, 90vw);
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 101;
		padding: 24px;
		gap: 16px;
	}

	:global(.new-key-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.new-key-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.new-key-form {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.field {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.field-label {
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
	}

	.name-input {
		width: 100%;
		padding: 9px 11px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 13.5px;
		font-family: var(--font-mono);
	}

	.name-input:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.hint {
		font-size: 11.5px;
		color: var(--text-3);
		margin: 0;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 4px;
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
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text);
	}

	.cancel-btn:hover {
		background: var(--sunken);
	}

	.create-btn {
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` is gold-on-light and
		   invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
	}

	.create-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.err {
		display: flex;
		flex-direction: column;
		gap: 6px;
		font-size: 13px;
		color: var(--danger);
		margin: 0;
		padding: 8px 10px;
		background: var(--danger-weak);
		border-radius: var(--r);
	}

	.err-head {
		margin: 0;
		font-weight: 600;
	}

	:global(.new-key-content .close-btn) {
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

	:global(.new-key-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.new-key-content .close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
