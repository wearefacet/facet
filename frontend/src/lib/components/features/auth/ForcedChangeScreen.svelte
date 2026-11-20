<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	ForcedChangeScreen — full-screen bootstrap password change.

	Rendered after a login that returned `must_change_password` (a temporary
	password issued by an operator, or an operator-set first password). The
	one-shot `change_token` stays with the caller; this surface only collects
	the old + new pair.
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { KeyRound, ShieldAlert } from '@lucide/svelte';
	import Input from '../../primitives/forms/Input.svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import AuthShell from './AuthShell.svelte';

	let {
		product = 'Facet',
		loading = false,
		error,
		onsubmit
	}: {
		product?: string;
		loading?: boolean;
		error?: string;
		onsubmit?: (oldPassword: string, newPassword: string) => void;
	} = $props();

	let oldPassword = $state('');
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
			localError = m.auth_forced_length_error();
			return;
		}
		if (newPassword !== confirmPassword) {
			localError = m.auth_password_mismatch();
			return;
		}
		onsubmit?.(oldPassword, newPassword);
	};
</script>

<AuthShell
	maxWidth={420}
	gap={20}
	error={shellError}
	title={m.auth_forced_title()}
	sub={m.auth_forced_sub({ product })}
	iconTint="warn"
>
	{#snippet icon()}
		<ShieldAlert size={22} />
	{/snippet}

	<form class="change-form" onsubmit={handleSubmit}>
		<Input
			label={m.auth_current_password_label()}
			type="password"
			placeholder="••••••••"
			bind:value={oldPassword}
			required
			autocomplete="current-password"
			disabled={loading}
		/>
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
			{m.auth_forced_save_button()}
		</Button>
	</form>
</AuthShell>

{#snippet KeyIcon()}<KeyRound size={15} />{/snippet}

<style>
	.change-form {
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.change-form :global(.btn) {
		width: 100%;
	}
</style>
