<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { ShieldCheck } from '@lucide/svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Logo from '$lib/components/primitives/content/Logo.svelte';
	import TwoFactorScreen from '$lib/components/features/auth/TwoFactorScreen.svelte';
	import BackupCodeScreen from '$lib/components/features/auth/BackupCodeScreen.svelte';
	import TotpRegistrationScreen from '$lib/components/features/auth/TotpRegistrationScreen.svelte';
	import ForcedChangeScreen from '$lib/components/features/auth/ForcedChangeScreen.svelte';
	import LoginAttemptsWarning from '$lib/components/features/auth/LoginAttemptsWarning.svelte';
	import { apiFetch } from '$lib/session.svelte';
	import { LoginRejected } from '$lib/auth.svelte';
	import {
		login,
		changePassword,
		verifyChallenge,
		verifyEnroll,
		getMfaState,
		mfaSetup,
		verifyMfa
	} from '$lib/auth.svelte';
	import {
		clearEnrollContext,
		isEnrollContextExpired,
		loadEnrollContext,
		saveEnrollContext,
		shouldPromptEnrollment
	} from '$lib/loginFlow';

	/**
	 * Held-login state machine.
	 *
	 * `login()` resolves to one branch and this page renders the matching
	 * step:
	 *
	 *   credentials ── tokens ──┬─ (preferred, not enrolled) ─ mfa_interstitial ─ app
	 *                           └─ app
	 *               ── must_change_password ─ change ─ re-login ─ ↑
	 *               ── mfa_challenge ─┬─ code ─ tokens ─ ↑
	 *                                 └─ backup_code (single-use code)
	 *               ── mfa_enroll ─ code ─ mfa_enroll_done (backup codes) ─ app
	 */
	type Step =
		| 'credentials'
		| 'must_change_password'
		| 'mfa_challenge'
		| 'mfa_backup'
		| 'mfa_enroll'
		| 'mfa_enroll_done'
		| 'mfa_interstitial';

	let step = $state<Step>('credentials');
	// No credential prefill. A prefill ships the seeded admin password in the
	// SSR HTML, and a fill that races hydration can corrupt the field value
	// (the SSR value and the typed value interleave).
	let email = $state('');
	let password = $state('');
	let error = $state<string | null>(null);
	// Remaining brute-force attempts from the last rejected login (B-139
	// parity with the MFA challenge path). `null` hides the warning.
	let remainingAttempts = $state<number | null>(null);
	let loading = $state(false);

	let changeToken = $state<string | null>(null);
	let challengeId = $state<string | null>(null);
	let enroll = $state<{ enrollToken: string; secret: string; otpauthUri: string } | null>(null);
	// Client TTL mirror for the persisted enroll context (F05-07). Plain
	// variable — read only inside event handlers, never in the template.
	let enrollSavedAt: number | null = null;
	// One-shot mount guard for the enroll-context restore below.
	let initialized = $state(false);
	// The one-time backup codes of a completed enroll-at-login flow.
	let enrollDone = $state<{ backupCodes: string[] } | null>(null);
	let prompt = $state<{
		secret: string;
		otpauthUri: string;
		account: string;
		done: boolean;
		backupCodes: string[];
	} | null>(null);

	/** Flag from the reset-confirm redirect (`/Login?reset=ok`). */
	const passwordJustSet = $derived(page.url.searchParams.get('reset') === 'ok');

	/**
	 * Inbound OIDC. The denial redirect carries `error=oidc_denied`
	 * with no detail — the reason lives in the audit log only, so the message
	 * here stays generic.
	 */
	const oidcDenied = $derived(page.url.searchParams.get('error') === 'oidc_denied');

	/**
	 * Enabled providers and the authentication mode, read once from the
	 * public endpoint. Under `oidc_only` the password form and the reset
	 * link do not render; the SSO buttons do. Empty on failure — a broken
	 * read must never block the page: the failure shape defaults to hybrid
	 * with no providers, which renders today's layout.
	 */
	let providers = $state<{ name: string; label: string }[]>([]);
	let authMode = $state<'hybrid' | 'oidc_only'>('hybrid');
	const passwordDisabled = $derived(authMode === 'oidc_only');

	$effect(() => {
		void loadProviders();
	});

	// F05-07 — resume an interrupted enroll-at-login once on mount. Effects
	// never run during SSR, so the sessionStorage access stays client-only.
	$effect(() => {
		if (initialized) return;
		initialized = true;
		restoreEnrollContext();
	});

	async function loadProviders(): Promise<void> {
		try {
			const res = await apiFetch('/Api/iam/oidc/providers', {}, { attemptRefresh: false });
			if (!res.ok) {
				providers = [];
				return;
			}
			const body = (await res.json()) as {
				auth_mode?: unknown;
				providers?: unknown;
			};
			authMode = body.auth_mode === 'oidc_only' ? 'oidc_only' : 'hybrid';
			const list = Array.isArray(body.providers) ? body.providers : [];
			providers = list
				.filter((p) => typeof p?.name === 'string' && typeof p?.label === 'string')
				.map((p) => ({ name: p.name as string, label: p.label as string }));
		} catch {
			providers = [];
			authMode = 'hybrid';
		}
	}

	async function finish(): Promise<void> {
		// `handleAuth` embedded the page the user wanted before being sent to
		// `/Login` as a `redirectTo` query param (stateless, since the server
		// hook has no access to browser storage). Return them there now.
		const target = page.url.searchParams.get('redirectTo');
		if (target && target.startsWith('/') && !target.startsWith('/Login')) {
			// Full-page navigation on purpose: the target may be a backend-owned
			// path (the OAuth bounce lands on `/OAuth/authorize`), which no
			// SvelteKit route serves — the client-side router would request a
			// `__data.json` for it and log a 404 before falling back to a hard
			// navigation anyway. A fresh load also re-runs the server hook with
			// the new session cookie.
			window.location.assign(target);
		} else {
			await goto(resolve('/'), { invalidateAll: true });
		}
	}

	/** Common continuation after a token-emitting response: run the
	 * `preferred`-mode enrollment prompt before entering the app. A failed
	 * MFA-state lookup must never block the login, so it falls through. */
	async function afterTokens(): Promise<void> {
		try {
			const me = await getMfaState();
			if (shouldPromptEnrollment(me)) {
				const setup = await mfaSetup(me.email);
				prompt = {
					secret: setup.secret,
					otpauthUri: setup.otpauthUri,
					account: me.email,
					done: false,
					backupCodes: []
				};
				step = 'mfa_interstitial';
				return;
			}
		} catch {
			/* interstitial is best-effort */
		}
		await finish();
	}

	/** F05-07 — drops the persisted enroll context and its TTL mirror. */
	function discardEnrollContext(): void {
		enrollSavedAt = null;
		clearEnrollContext(window.sessionStorage);
	}

	function resetFlow(): void {
		discardEnrollContext();
		step = 'credentials';
		error = null;
		remainingAttempts = null;
		loading = false;
		changeToken = null;
		challengeId = null;
		enroll = null;
		enrollDone = null;
		prompt = null;
	}

	/** F05-07 — enters the enroll step and persists the context so a reload
	 * can resume the flow. The server Redis hash stays the anchor: a stale
	 * stored token fails verify, and the client TTL mirror drops dead entries. */
	function enterEnroll(branch: { enrollToken: string; secret: string; otpauthUri: string }): void {
		enroll = {
			enrollToken: branch.enrollToken,
			secret: branch.secret,
			otpauthUri: branch.otpauthUri
		};
		enrollSavedAt = Date.now();
		step = 'mfa_enroll';
		saveEnrollContext(window.sessionStorage, branch, enrollSavedAt);
	}

	/** F05-07 — resumes an interrupted enroll-at-login from sessionStorage.
	 * A dead entry (expired, corrupt) is dropped and the page stays at the
	 * credentials step. */
	function restoreEnrollContext(): void {
		const restored = loadEnrollContext(window.sessionStorage, Date.now());
		if (!restored) return;
		enroll = {
			enrollToken: restored.enrollToken,
			secret: restored.secret,
			otpauthUri: restored.otpauthUri
		};
		enrollSavedAt = restored.savedAt;
		step = 'mfa_enroll';
	}

	async function handleSubmit(e: SubmitEvent) {
		e.preventDefault();
		error = null;
		remainingAttempts = null;
		loading = true;
		try {
			const branch = await login(email, password);
			switch (branch.kind) {
				case 'tokens':
					await afterTokens();
					break;
				case 'must_change_password':
					changeToken = branch.changeToken;
					step = 'must_change_password';
					break;
				case 'mfa_challenge':
					challengeId = branch.challengeId;
					step = 'mfa_challenge';
					break;
				case 'mfa_enroll':
					enterEnroll(branch);
					break;
			}
		} catch (err) {
			if (err instanceof LoginRejected && err.remainingAttempts !== null) {
				remainingAttempts = err.remainingAttempts;
			} else {
				error = (err as Error).message;
			}
		} finally {
			loading = false;
		}
	}

	async function handleForcedChange(oldPassword: string, newPassword: string) {
		error = null;
		loading = true;
		try {
			if (!changeToken) throw new Error(m.auth_change_expired());
			await changePassword(changeToken, oldPassword, newPassword);
			// The one-shot token is consumed; sign in again with the new
			// password. Under `always` MFA this continues into enrollment.
			password = newPassword;
			const branch = await login(email, password);
			switch (branch.kind) {
				case 'tokens':
					await afterTokens();
					break;
				case 'mfa_challenge':
					challengeId = branch.challengeId;
					step = 'mfa_challenge';
					break;
				case 'mfa_enroll':
					enterEnroll(branch);
					break;
				case 'must_change_password':
					throw new Error(m.auth_change_incomplete());
			}
		} catch (err) {
			error = (err as Error).message;
			loading = false;
		}
	}

	async function handleChallenge(code: string) {
		error = null;
		loading = true;
		try {
			if (!challengeId) throw new Error(m.auth_challenge_expired());
			await verifyChallenge(challengeId, code);
			await afterTokens();
		} catch (err) {
			error = (err as Error).message;
			loading = false;
		}
	}

	async function handleEnroll(code: string) {
		error = null;
		loading = true;
		try {
			if (!enroll) throw new Error(m.auth_enroll_expired());
			if (enrollSavedAt !== null && isEnrollContextExpired(enrollSavedAt, Date.now())) {
				// F05-07 — the client TTL mirror is past the server TTL: the
				// one-shot token is dead, so drop to a clean credentials state
				// instead of a guaranteed 401 with no way back.
				resetFlow();
				error = m.auth_enroll_expired();
				return;
			}
			const { backupCodes } = await verifyEnroll(enroll.enrollToken, code);
			// Just enrolled — show the one-time backup codes before entering
			// the app. The challenge path accepts them when the phone is lost.
			// The token is consumed server-side; drop the stored copy now.
			discardEnrollContext();
			enrollDone = { backupCodes };
			step = 'mfa_enroll_done';
		} catch (err) {
			error = (err as Error).message;
			loading = false;
		}
	}

	function startBackupChallenge(): void {
		error = null;
		step = 'mfa_backup';
	}

	function backToChallenge(): void {
		error = null;
		step = 'mfa_challenge';
	}

	async function handleBackupChallenge(code: string) {
		error = null;
		loading = true;
		try {
			if (!challengeId) throw new Error(m.auth_challenge_expired());
			await verifyChallenge(challengeId, code, 'backup_code');
			await afterTokens();
		} catch (err) {
			error = (err as Error).message;
			loading = false;
		}
	}

	async function handlePromptVerify(code: string) {
		if (!prompt) return;
		prompt.done = false;
		error = null;
		loading = true;
		try {
			const backupCodes = await verifyMfa(code);
			prompt.backupCodes = backupCodes;
			prompt.done = true;
		} catch (err) {
			error = (err as Error).message;
		} finally {
			loading = false;
		}
	}
</script>

<svelte:head>
	<title>{m.auth_login_page_title()}</title>
</svelte:head>

{#if step === 'must_change_password'}
	<ForcedChangeScreen {loading} error={error ?? undefined} onsubmit={handleForcedChange} />
{:else if step === 'mfa_challenge'}
	<TwoFactorScreen
		{loading}
		error={error ?? undefined}
		onverify={handleChallenge}
		onCancel={resetFlow}
		onUseBackupCode={startBackupChallenge}
	/>
{:else if step === 'mfa_backup'}
	<BackupCodeScreen
		{loading}
		error={error ?? undefined}
		onverify={handleBackupChallenge}
		onBack={backToChallenge}
	/>
{:else if step === 'mfa_enroll' && enroll}
	<TotpRegistrationScreen
		secret={enroll.secret}
		otpauthUri={enroll.otpauthUri}
		status={loading ? 'verifying' : 'setup'}
		error={error ?? undefined}
		onverify={handleEnroll}
	/>
{:else if step === 'mfa_enroll_done' && enrollDone}
	<TotpRegistrationScreen
		secret={enroll?.secret ?? ''}
		status="verified"
		backupCodes={enrollDone.backupCodes}
		error={error ?? undefined}
		onDone={finish}
		onCancel={finish}
		cancelLabel={m.auth_totp_skip_now()}
		cancelArrow="right"
	/>
{:else if step === 'mfa_interstitial' && prompt}
	<TotpRegistrationScreen
		secret={prompt.secret}
		otpauthUri={prompt.otpauthUri}
		account={prompt.account}
		status={prompt.done ? 'verified' : loading ? 'verifying' : 'setup'}
		error={error ?? undefined}
		backupCodes={prompt.backupCodes}
		onverify={handlePromptVerify}
		onDone={finish}
		onCancel={finish}
		cancelLabel={m.auth_totp_skip_now()}
		cancelArrow="right"
	/>
{:else}
	<div class="login-page">
		<form class="login-card" onsubmit={handleSubmit}>
			<div class="brand">
				<Logo variant="lockup" size="lg" />
			</div>

			<div class="form-body">
				{#if oidcDenied}
					<div class="err-msg" role="alert">
						{m.auth_oidc_denied()}
					</div>
				{/if}
				{#if passwordJustSet}
					<div class="ok-msg" role="status">{m.auth_password_updated()}</div>
				{/if}
				{#if passwordDisabled}
					<div class="mode-msg" role="status">{m.auth_login_sso_only()}</div>
				{:else}
					<Input
						type="email"
						label={m.auth_login_email_label()}
						placeholder={m.auth_login_email_placeholder()}
						bind:value={email}
						required
						autocomplete="username"
						disabled={loading}
					/>
					<Input
						type="password"
						label={m.auth_login_password_label()}
						placeholder="••••••••"
						bind:value={password}
						required
						autocomplete="current-password"
						disabled={loading}
					/>

					{#if error}
						<div class="err-msg" role="alert">{error}</div>
					{/if}
					{#if remainingAttempts !== null}
						<LoginAttemptsWarning attempts={remainingAttempts} />
					{/if}
				{/if}
			</div>

			{#if !passwordDisabled}
				<div class="form-foot">
					<Button
						type="submit"
						variant="primary"
						size="lg"
						{loading}
						label={m.auth_login_button()}
					/>
				</div>
			{/if}

			{#if providers.length > 0}
				<div class="sso-section">
					{#if !passwordDisabled}
						<div class="sso-divider" role="separator" aria-label={m.auth_login_or()}>
							<span class="sso-divider-text">{m.auth_login_or()}</span>
						</div>
					{/if}
					<div class="sso-list">
						{#each providers as provider (provider.name)}
							<a class="sso-btn" href={`/auth/oidc/${provider.name}`} rel="external">
								<ShieldCheck size={16} aria-hidden="true" />
								<span>{m.auth_login_sso({ provider: provider.label })}</span>
							</a>
						{/each}
					</div>
				</div>
			{:else if passwordDisabled}
				<div class="sso-section">
					<p class="sso-fallback" role="status">{m.auth_login_sso_unavailable()}</p>
				</div>
			{/if}

			{#if !passwordDisabled}
				<div class="form-links">
					<a class="link-btn" href={resolve('/ResetPassword')}>{m.auth_login_forgot()}</a>
				</div>
			{/if}
		</form>
	</div>
{/if}

<style>
	.login-page {
		display: grid;
		place-items: center;
		min-height: 100vh;
		background: var(--ground);
		padding: 24px;
	}

	.login-card {
		width: 380px;
		max-width: 100%;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-2);
		padding: 32px 28px;
	}

	.brand {
		margin-bottom: 28px;
	}

	.form-body {
		display: flex;
		flex-direction: column;
		gap: 16px;
		margin-bottom: 24px;
	}

	.err-msg {
		font-size: 12.5px;
		color: var(--danger);
		background: var(--danger-weak);
		border-radius: var(--r-sm);
		padding: 8px 10px;
	}

	.ok-msg {
		font-size: 12.5px;
		color: var(--ok);
		background: var(--ok-weak);
		border-radius: var(--r-sm);
		padding: 8px 10px;
	}

	.mode-msg {
		font-size: 12.5px;
		color: var(--text-2);
		background: var(--surface-2);
		border-radius: var(--r-sm);
		padding: 8px 10px;
	}

	.sso-fallback {
		font-size: 12.5px;
		color: var(--text-3);
		text-align: center;
		margin: 0;
	}

	.form-foot {
		display: flex;
		justify-content: stretch;
	}

	.form-foot :global(.btn) {
		width: 100%;
	}

	.form-links {
		display: flex;
		justify-content: center;
		margin-top: 14px;
	}

	.sso-section {
		margin-top: 16px;
	}

	.sso-divider {
		position: relative;
		height: 1px;
		background: var(--border);
		margin-bottom: 14px;
	}

	.sso-divider-text {
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

	.sso-btn {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		width: 100%;
		padding: 10px 14px;
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

	.sso-btn:hover {
		background: var(--surface-2);
		border-color: var(--border-strong);
	}

	.sso-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.sso-btn :global(svg) {
		color: var(--text-2);
	}

	.link-btn {
		font-size: 12.5px;
		color: var(--accent-ink);
		text-decoration: none;
		transition: opacity 0.12s;
	}

	.link-btn:hover {
		opacity: 0.7;
	}

	.link-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
		border-radius: var(--r-sm);
	}
</style>
