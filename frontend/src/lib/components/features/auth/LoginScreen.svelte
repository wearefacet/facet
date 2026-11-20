<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	LoginScreen — full-screen authentication surface.
	Username + password form primary, one SSO button per configured OIDC
	provider (the backend starts the flow with a 302 on `/auth/oidc/:name`).
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { AtSign, KeyRound, LogIn, ShieldCheck } from '@lucide/svelte';
	import Input from '../../primitives/forms/Input.svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import AuthShell from './AuthShell.svelte';

	let {
		product = 'Facet',
		tagline = '',
		/** One SSO entry per enabled provider; empty or omitted hides the section. */
		providers = [],
		loading = false,
		error,
		onsubmit
	}: {
		product?: string;
		tagline?: string;
		providers?: { name: string; label: string }[];
		loading?: boolean;
		error?: string;
		onsubmit?: (creds: { identifier: string; password: string }) => void;
	} = $props();

	let identifier = $state('');
	let password = $state('');

	const handleSubmit = (e: SubmitEvent) => {
		e.preventDefault();
		onsubmit?.({ identifier, password });
	};
</script>

<AuthShell maxWidth={380} gap={20} {error} title={product}>
	{#snippet sub()}
		{#if tagline}
			<p class="login-tagline">{tagline}</p>
		{/if}
	{/snippet}

	<form class="login-form" onsubmit={handleSubmit}>
		<Input
			label={m.auth_login_identifier_label()}
			type="text"
			placeholder={m.auth_login_identifier_placeholder()}
			value={identifier}
			iconLeft={AtSignIcon}
			autocomplete="username"
			required
		/>
		<Input
			label={m.auth_login_password_label()}
			type="password"
			placeholder="••••••••"
			value={password}
			iconLeft={KeyRoundIcon}
			autocomplete="current-password"
			required
		/>

		<div class="login-actions">
			<Button type="submit" variant="primary" size="lg" {loading} iconLeft={LogInIcon}>
				{m.auth_login_button()}
			</Button>
		</div>
	</form>

	{#if providers.length > 0}
		<div class="login-divider" role="separator" aria-label={m.auth_login_or()}>
			<span class="login-divider-text">{m.auth_login_or()}</span>
		</div>
		<div class="sso-list">
			{#each providers as provider (provider.name)}
				<a class="sso-link" href={`/auth/oidc/${provider.name}`} rel="external">
					<ShieldCheck size={16} />
					<span>{m.auth_login_sso({ provider: provider.label })}</span>
				</a>
			{/each}
		</div>
	{/if}
</AuthShell>

{#snippet AtSignIcon()}<AtSign size={14} />{/snippet}
{#snippet KeyRoundIcon()}<KeyRound size={14} />{/snippet}
{#snippet LogInIcon()}<LogIn size={15} />{/snippet}

<style>
	.login-tagline {
		margin: 0;
		font-size: 12px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.login-form {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.login-actions {
		margin-top: 6px;
	}

	.login-actions :global(.btn) {
		width: 100%;
	}

	.login-divider {
		position: relative;
		height: 1px;
		background: var(--border);
		margin: 2px 0;
	}

	.login-divider-text {
		position: absolute;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		background: var(--surface);
		padding: 0 12px;
		font-size: 11px;
		color: var(--text-3);
		font-family: var(--font-mono);
		text-transform: uppercase;
		letter-spacing: 0.08em;
	}

	.sso-list {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.sso-link {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		width: 100%;
		padding: 10px 14px;
		font-family: var(--font-sans);
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		cursor: pointer;
		text-decoration: none;
		transition:
			background 0.12s,
			border-color 0.12s;
	}

	.sso-link:hover {
		background: var(--surface-2);
		border-color: var(--border-strong);
	}

	.sso-link:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.sso-link :global(svg) {
		color: var(--text-2);
	}
</style>
