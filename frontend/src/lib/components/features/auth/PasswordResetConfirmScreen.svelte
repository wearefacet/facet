<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	PasswordResetConfirmScreen — the confirm half of the reset flow.

	Rendered on `/ResetPassword?token=…` (the link emailed by the reset or
	invite flow). Collects the new password; the token stays with the caller.
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { KeyRound, Lock } from '@lucide/svelte';
	import Input from '../../primitives/forms/Input.svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import AuthShell from './AuthShell.svelte';

	let {
		product = 'Facet',
		loading = false,
		error,
		onsubmit,
		onCancel
	}: {
		product?: string;
		loading?: boolean;
		error?: string;
		onsubmit?: (newPassword: string) => void;
		onCancel?: () => void;
	} = $props();

	let newPassword = $state('');
	let confirmPassword = $state('');

	/** Client-side validation message; the backend error renders beside it. */
	let localError = $state<string | null>(null);
	const displayError = $derived(error ?? localError);
	const shellError = $derived(displayError ?? undefined);

	const handleSubmit = (e: SubmitEvent) => {
		e.preventDefault();
		localError = null;
		if (newPassword.length < 8) {
			localError = m.auth_confirm_length_error();
			return;
		}
		if (newPassword !== confirmPassword) {
			localError = m.auth_password_mismatch();
			return;
		}
		onsubmit?.(newPassword);
	};
</script>

<AuthShell
	maxWidth={420}
	gap={20}
	error={shellError}
	title={m.auth_confirm_title()}
	sub={m.auth_confirm_sub({ product })}
>
	{#snippet icon()}
		<KeyRound size={22} />
	{/snippet}

	<form class="confirm-form" onsubmit={handleSubmit}>
		<Input
			label={m.auth_new_password_label()}
			type="password"
			placeholder={m.auth_new_password_placeholder()}
			bind:value={newPassword}
			required
			autocomplete="new-password"
			disabled={loading}
		/>
		<Input
			label={m.auth_confirm_password_label()}
			type="password"
			placeholder={m.auth_confirm_password_placeholder()}
			bind:value={confirmPassword}
			required
			autocomplete="new-password"
			disabled={loading}
		/>

		<Button type="submit" variant="primary" size="lg" {loading} iconLeft={KeyIcon}>
			{m.auth_confirm_set_button()}
		</Button>
	</form>

	{#snippet footer()}
		{#if onCancel}
			<button class="link-btn" type="button" onclick={onCancel}>
				<Lock size={13} />
				{m.auth_back_signin()}
			</button>
		{/if}
	{/snippet}
</AuthShell>

{#snippet KeyIcon()}<KeyRound size={15} />{/snippet}

<style>
	.confirm-form {
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.confirm-form :global(.btn) {
		width: 100%;
	}
</style>
