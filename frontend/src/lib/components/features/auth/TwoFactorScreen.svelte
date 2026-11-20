<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	TwoFactorScreen — full-screen 2FA challenge.
	Six mono OTP boxes with auto-advance + paste handling, plus recovery link.
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { ShieldCheck, ArrowLeft } from '@lucide/svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import AuthShell from './AuthShell.svelte';
	import OtpInput from './OtpInput.svelte';

	let {
		product = 'Facet',
		length = 6,
		loading = false,
		error,
		onverify,
		onCancel,
		onUseBackupCode
	}: {
		product?: string;
		length?: number;
		loading?: boolean;
		error?: string;
		onverify?: (code: string) => void;
		onCancel?: () => void;
		onUseBackupCode?: () => void;
	} = $props();

	let code = $state('');

	const complete = $derived(code.length === length);

	function handleVerify(e: SubmitEvent) {
		e.preventDefault();
		if (!complete) return;
		onverify?.(code);
	}
</script>

<AuthShell
	maxWidth={420}
	{error}
	title={m.auth_2fa_title()}
	sub={m.auth_2fa_sub({ length, product })}
>
	{#snippet icon()}
		<ShieldCheck size={22} />
	{/snippet}

	{#snippet footer()}
		<button class="link-btn" type="button" onclick={onUseBackupCode}>
			{m.auth_2fa_backup_button()}
		</button>
		<span class="dot-sep" aria-hidden="true">•</span>
		{#if onCancel}
			<button class="link-btn link-back" type="button" onclick={onCancel}>
				<ArrowLeft size={13} />
				{m.auth_back_signin()}
			</button>
		{/if}
	{/snippet}

	<form class="twofa-form" onsubmit={handleVerify}>
		<OtpInput bind:code {length} onEnter={(c) => onverify?.(c)} />

		<Button type="submit" variant="primary" size="lg" disabled={!complete} {loading}>
			{m.auth_2fa_verify()}
		</Button>
	</form>
</AuthShell>

<style>
	.twofa-form {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.twofa-form :global(.btn) {
		width: 100%;
	}

	.dot-sep {
		color: var(--text-3);
		opacity: 0.5;
	}
</style>
