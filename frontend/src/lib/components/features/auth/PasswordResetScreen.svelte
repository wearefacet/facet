<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	PasswordResetScreen — full-screen password reset request surface.
	Mirrors the LoginScreen visual language: gold-tinted background, single card
	centered on the viewport. Used to request a reset link by email/identifier.
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { AtSign, ArrowLeft, MailCheck, KeyRound } from '@lucide/svelte';
	import Input from '../../primitives/forms/Input.svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import AuthShell from './AuthShell.svelte';

	let {
		product = 'Facet',
		loading = false,
		error,
		success = false,
		submittedIdentifier,
		validityText,
		onsubmit,
		onCancel
	}: {
		product?: string;
		loading?: boolean;
		error?: string;
		/** When true, renders the success state instead of the form. */
		success?: boolean;
		/** Echoed back in the success state ("If you@x exists, a link was sent"). */
		submittedIdentifier?: string;
		/** Localized validity phrase (e.g. "1 day") stated in the success copy —
		 * derived from the backend's `link_ttl_seconds`, never hardcoded. */
		validityText: string;
		onsubmit?: (identifier: string) => void;
		onCancel?: () => void;
	} = $props();

	let identifier = $state('');

	const handleSubmit = (e: SubmitEvent) => {
		e.preventDefault();
		onsubmit?.(identifier);
	};
</script>

<AuthShell maxWidth={420} gap={20} {error}>
	{#snippet icon()}
		<KeyRound size={22} />
	{/snippet}

	{#snippet title()}
		{m.auth_reset_title()}
	{/snippet}

	{#snippet sub()}
		{#if success}
			{m.auth_reset_success_sub({
				identifier: submittedIdentifier || m.auth_reset_fallback_identifier(),
				product
			})}
		{:else}
			{m.auth_reset_sub({ product })}
		{/if}
	{/snippet}

	{#if success}
		<div class="reset-success" role="status">
			<span class="reset-success-mark" aria-hidden="true">
				<MailCheck size={18} />
			</span>
			<div>
				<p class="reset-success-title">{m.auth_reset_check_inbox()}</p>
				<p class="reset-success-body">
					{m.auth_reset_link_validity({ validity: validityText })}
				</p>
			</div>
		</div>

		<div class="reset-actions">
			{#if onCancel}
				<Button variant="secondary" size="lg" onclick={onCancel} iconLeft={BackIcon}>
					{m.auth_back_signin()}
				</Button>
			{/if}
		</div>
	{:else}
		<form class="reset-form" onsubmit={handleSubmit}>
			<Input
				label={m.auth_login_identifier_label()}
				type="text"
				placeholder={m.auth_login_identifier_placeholder()}
				bind:value={identifier}
				iconLeft={AtSignIcon}
				autocomplete="username"
				required
			/>

			<div class="reset-actions">
				<Button type="submit" variant="primary" size="lg" {loading} iconLeft={KeyIcon}>
					{m.auth_reset_send_button()}
				</Button>
			</div>
		</form>
	{/if}

	{#snippet footer()}
		{#if !success && onCancel}
			<button class="link-btn" type="button" onclick={onCancel}>
				<ArrowLeft size={13} />
				{m.auth_back_signin()}
			</button>
		{/if}
	{/snippet}
</AuthShell>

{#snippet AtSignIcon()}<AtSign size={14} />{/snippet}
{#snippet KeyIcon()}<KeyRound size={15} />{/snippet}
{#snippet BackIcon()}<ArrowLeft size={14} />{/snippet}

<style>
	.reset-form {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.reset-actions {
		margin-top: 6px;
	}

	.reset-actions :global(.btn) {
		width: 100%;
	}

	.reset-success {
		display: flex;
		align-items: flex-start;
		gap: 12px;
		padding: 14px;
		border-radius: var(--r);
		background: var(--ok-weak);
		border: 1px solid color-mix(in srgb, var(--ok) 30%, transparent);
	}

	.reset-success-mark {
		display: grid;
		place-items: center;
		width: 32px;
		height: 32px;
		border-radius: 50%;
		background: var(--ok);
		color: #fff;
		flex: none;
	}

	.reset-success-title {
		margin: 0 0 4px;
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
	}

	.reset-success-body {
		margin: 0;
		font-size: 12px;
		color: var(--text-2);
		line-height: 1.5;
	}
</style>
