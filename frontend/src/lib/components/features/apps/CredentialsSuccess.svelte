<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import {
		buildClientSnippet,
		buildCurlSnippet,
		deriveSignInAddress,
		discoveryPath
	} from '$lib/app/appValidation';
	import type { AppContent } from '$lib/app/appTypes';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';
	import { useAppKeyStatus } from '$lib/app/appKeyStatus.svelte.js';
	import SecretRevealPanel from '$lib/components/features/settings/SecretRevealPanel.svelte';
	import { CircleCheck, KeyRound, ArrowUpRight } from '@lucide/svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * CredentialsSuccess — the wizard's credentials success screen, reached
	 * only by publishing from the review step. Shows the `client_id`, the
	 * sign-in deep link (the shared `/OAuth/authorize` endpoint that
	 * discovery advertises, addressed to this app's client id — B-200), the
	 * discovery document URL, and a copy-pasteable snippet so the developer
	 * has everything they need before writing a line of code.
	 *
	 * For a `public` app there is no client secret — the screen explains
	 * PKCE + DPoP-bound tokens instead, with the TypeScript client snippet.
	 * For a `confidential` (backend) app the screen issues the app's API
	 * key: a one-time reveal of the raw bearer token, a curl example, and
	 * an "I stored it" hand-off to the app page.
	 */

	let {
		app,
		appId,
		issuerBase,
		onGoToApp
	}: {
		/** The published app's content. */
		app: AppContent;
		/** The app document id — the API-key hook targets this app. */
		appId: string;
		/** The instance's public base URL, from the OAuth discovery document. */
		issuerBase: string;
		/** Hands the "go to the app page" hand-off to the host page. */
		onGoToApp: () => void;
	} = $props();

	const signInAddress = $derived(
		issuerBase && app.client_id ? deriveSignInAddress(issuerBase, app.client_id) : ''
	);
	const discoveryUrl = $derived(issuerBase ? `${issuerBase}${discoveryPath()}` : '');
	const snippet = $derived(buildClientSnippet(app, issuerBase));
	const isPublic = $derived(app.client_type !== 'confidential');

	// ── API key issuance (backend apps) ──────────────────────────────────
	// The raw key lives only in this local $state. Nothing persists it — the
	// backend stores a hash and never repeats the value.
	let issuedKey = $state<string | null>(null);
	const appKey = useAppKeyStatus(() => appId);

	async function issueKey(): Promise<void> {
		const issued = await appKey.issue();
		if (issued) issuedKey = issued.key;
	}
</script>

<div class="page">
	<div class="header">
		<CircleCheck size={22} strokeWidth={2} class="header-icon" aria-hidden="true" />
		<div>
			<h1>{m.configure_apps_live_title({ name: app.name })}</h1>
			<p class="header-sub">
				{#if isPublic}
					{m.configure_apps_live_public_sub()}
				{:else}
					{m.configure_apps_live_backend_sub()}
				{/if}
			</p>
		</div>
	</div>

	<div class="credentials-card">
		<div class="cred-row">
			<div class="cred-label">{m.configure_apps_client_id_label()}</div>
			<div class="cred-value">
				<code>{app.client_id ?? '—'}</code>
				<CopyButton
					value={app.client_id ?? ''}
					variant="ghost"
					size="sm"
					title={m.configure_apps_copy_client_id_aria()}
				/>
			</div>
		</div>

		{#if signInAddress}
			<div class="cred-row">
				<div class="cred-label">{m.configure_apps_signin_label()}</div>
				<div class="cred-value">
					<code>{signInAddress}</code>
					<CopyButton
						value={signInAddress}
						variant="ghost"
						size="sm"
						title={m.configure_apps_copy_signin_aria()}
					/>
				</div>
			</div>
		{/if}

		{#if discoveryUrl}
			<div class="cred-row cred-row-last">
				<div class="cred-label">{m.configure_apps_discovery_label()}</div>
				<div class="cred-value">
					<code>{discoveryPath()}</code>
					<CopyButton
						value={discoveryUrl}
						variant="ghost"
						size="sm"
						title={m.configure_apps_copy_discovery_aria()}
					/>
				</div>
			</div>
		{/if}
	</div>

	{#if appKey.error}
		<AlertBanner message={appKey.error} dismissable onDismiss={appKey.dismissError} />
	{/if}

	{#if isPublic}
		<div class="secret-panel">
			<KeyRound size={17} strokeWidth={2} class="secret-icon" aria-hidden="true" />
			<div>
				<div class="secret-title">{m.configure_apps_no_secret_title()}</div>
				<div class="secret-body">
					{m.configure_apps_no_secret_body()}
				</div>
			</div>
		</div>
	{:else if issuedKey}
		<!-- One-time reveal. The raw key exists only in local state; once the
		     user leaves this screen it is unrecoverable. -->
		<SecretRevealPanel secret={issuedKey} title={m.configure_apps_apikey_title()}>
			<Button variant="primary" onclick={onGoToApp}>
				{m.configure_apps_stored_button()}
			</Button>
		</SecretRevealPanel>
	{:else}
		<div class="issue-panel">
			<KeyRound size={17} strokeWidth={2} class="secret-icon" aria-hidden="true" />
			<div class="issue-body">
				<div class="secret-title">{m.configure_apps_apikey_title()}</div>
				<div class="secret-body">
					{m.configure_apps_issue_body()}
				</div>
				<div class="issue-action">
					<Button variant="primary" disabled={appKey.issuing} onclick={issueKey}>
						{appKey.issuing ? m.configure_apps_generating() : m.configure_apps_generate_key()}
					</Button>
				</div>
			</div>
		</div>
	{/if}

	{#if isPublic}
		<div class="snippet-section">
			<div class="snippet-head">
				<div class="snippet-label">{m.configure_apps_snippet_label()}</div>
				<CopyButton value={snippet} variant="ghost" title={m.configure_apps_copy_snippet_aria()} />
			</div>
			<pre class="snippet">{snippet}</pre>
		</div>
	{:else if issuedKey}
		<div class="snippet-section">
			<div class="snippet-head">
				<div class="snippet-label">{m.configure_apps_first_call_label()}</div>
				<CopyButton
					value={buildCurlSnippet(issuedKey ?? '')}
					variant="ghost"
					title={m.configure_apps_copy_curl_aria()}
				/>
			</div>
			<pre class="snippet">{buildCurlSnippet(issuedKey)}</pre>
		</div>
	{/if}

	{#if isPublic}
		<div class="actions">
			{#if discoveryUrl}
				<a
					href={discoveryUrl}
					target="_blank"
					rel="noopener noreferrer external"
					class="link-button"
				>
					{m.configure_apps_discovery_label()}
					<ArrowUpRight size={14} strokeWidth={2} aria-hidden="true" />
				</a>
			{/if}
			<Button variant="primary" onclick={onGoToApp}>
				{m.configure_apps_goto_app()}
			</Button>
		</div>
		<p class="actions-note">
			{m.configure_apps_test_signin_note()}
		</p>
	{/if}
</div>

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.header {
		display: flex;
		align-items: flex-start;
		gap: 10px;
	}

	:global(.header-icon) {
		color: var(--ok, #16a34a);
	}

	.header h1 {
		font-size: 18px;
		font-weight: 500;
		margin: 0;
		color: var(--text);
	}

	.header-sub {
		font-size: 13px;
		color: var(--text-3);
		margin: 2px 0 0;
	}

	.credentials-card {
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
		overflow: hidden;
	}

	.cred-row {
		padding: 12px 14px;
		border-bottom: 0.5px solid var(--border);
	}

	.cred-row-last {
		border-bottom: none;
	}

	.cred-label {
		font-size: 12px;
		color: var(--text-3);
	}

	.cred-value {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-top: 4px;
		flex-wrap: wrap;
	}

	.cred-value code {
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
	}

	.secret-panel {
		display: flex;
		gap: 10px;
		align-items: flex-start;
		background: var(--accent-weak);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
		padding: 12px 14px;
	}

	:global(.secret-icon) {
		color: var(--text-2);
	}

	.secret-title {
		font-weight: 500;
		font-size: 13.5px;
		color: var(--text);
	}

	.secret-body {
		font-size: 12.5px;
		color: var(--text-3);
		margin-top: 3px;
		line-height: 1.55;
	}

	.issue-panel {
		display: flex;
		gap: 10px;
		align-items: flex-start;
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
		padding: 12px 14px;
	}

	.issue-body {
		min-width: 0;
	}

	.issue-action {
		margin-top: 9px;
	}

	.snippet-section {
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	.snippet-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 10px;
	}

	.snippet-label {
		font-size: 13px;
		font-weight: 500;
		color: var(--text-2);
	}

	.snippet {
		background: var(--surface);
		border-radius: var(--r);
		padding: 12px 14px;
		font-family: var(--font-mono);
		font-size: 12px;
		line-height: 1.7;
		overflow-x: auto;
		white-space: pre;
		margin: 0;
		color: var(--text);
	}

	.actions {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
		align-items: center;
	}

	.link-button {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		height: 34px;
		padding: 0 14px;
		font-size: 13px;
		color: var(--text-2);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		text-decoration: none;
		cursor: pointer;
	}

	.link-button:hover {
		border-color: var(--accent);
		color: var(--text);
	}

	.actions-note {
		font-size: 12.5px;
		color: var(--text-3);
	}
</style>
