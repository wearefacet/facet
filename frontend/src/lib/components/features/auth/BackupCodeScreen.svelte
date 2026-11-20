<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	BackupCodeScreen — full-screen MFA backup-code challenge.

	Reached from the "Use a backup code" link on TwoFactorScreen when the
	authenticator is lost. One text field takes a single-use recovery code
	(the `xxxx-xxxx` form saved at enrollment; case and the dash are
	accepted), and the back link returns to the TOTP code entry.
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { KeyRound, ArrowLeft } from '@lucide/svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import Input from '../../primitives/forms/Input.svelte';
	import AuthShell from './AuthShell.svelte';

	let {
		product = 'Facet',
		loading = false,
		error,
		onverify,
		onBack
	}: {
		product?: string;
		loading?: boolean;
		error?: string;
		onverify?: (code: string) => void;
		onBack?: () => void;
	} = $props();

	let code = $state('');

	function handleVerify(e: SubmitEvent) {
		e.preventDefault();
		const trimmed = code.trim();
		if (trimmed.length === 0) return;
		onverify?.(trimmed);
	}
</script>

<AuthShell
	maxWidth={420}
	{error}
	title={m.auth_backup_title()}
	sub={m.auth_backup_sub({ product })}
>
	{#snippet icon()}
		<KeyRound size={22} />
	{/snippet}

	{#snippet footer()}
		{#if onBack}
			<button class="link-btn" type="button" onclick={onBack} data-testid="backup-back">
				<ArrowLeft size={13} />
				{m.auth_backup_back()}
			</button>
		{/if}
	{/snippet}

	<form class="backup-form" onsubmit={handleVerify}>
		<Input
			type="text"
			label={m.auth_backup_label()}
			placeholder={m.auth_backup_placeholder()}
			bind:value={code}
			required
			autocomplete="one-time-code"
			disabled={loading}
		/>

		<Button type="submit" variant="primary" size="lg" disabled={!code.trim()} {loading}>
			{m.auth_2fa_verify()}
		</Button>
	</form>
</AuthShell>

<style>
	.backup-form {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.backup-form :global(.btn) {
		width: 100%;
	}
</style>
