<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import PasswordResetScreen from '$lib/components/features/auth/PasswordResetScreen.svelte';
	import PasswordResetConfirmScreen from '$lib/components/features/auth/PasswordResetConfirmScreen.svelte';
	import TotpRegistrationScreen from '$lib/components/features/auth/TotpRegistrationScreen.svelte';
	import {
		confirmPasswordReset,
		requestPasswordReset,
		getMfaState,
		mfaSetup,
		verifyMfa,
		ResetLinkError
	} from '$lib/auth.svelte';
	import { shouldPromptEnrollment } from '$lib/loginFlow';
	import { formatLinkValidity } from '$lib/link-validity';

	/**
	 * Password reset / invite acceptance surface.
	 *
	 * - `?token=…`  → confirm form; a valid token sets the new password. When
	 *   the link set the account's FIRST credential (an operator invite), the
	 *   backend auto-logs-in and the response is a token body — the flow then
	 *   runs the same `preferred`-mode enrollment prompt as the login page
	 *   before entering the app. Under MFA `always` enforcement the backend
	 *   emits no session for an un-enrolled account — `{ok: true}` →
	 *   `/Login`, and the sign-in holds at enrollment (B-141). Otherwise
	 *   `{ok: true}` → back to `/Login`.
	 * - no token    → request form (`PasswordResetScreen`). Also serves as the
	 *   expired-link fallback: a dead token switches to this form with an
	 *   explanatory banner.
	 */
	type Mode = 'request' | 'confirm' | 'interstitial';

	/**
	 * The token comes from the URL at mount. Once the confirm attempt fails
	 * with a dead link we switch to the request form for this session, so the
	 * mode is state, not a pure derivation — a new visit re-reads the URL.
	 */
	let mode = $state<Mode>('confirm');
	let initialized = $state(false);

	let error = $state<string | null>(null);
	let loading = $state(false);

	let requestSuccess = $state(false);
	let submittedIdentifier = $state('');
	/** Localized validity phrase for the success panel. Set together with
	 * `requestSuccess` — the screen only renders the copy when it is set. */
	let validityText = $state('');

	let prompt = $state<{
		secret: string;
		otpauthUri: string;
		account: string;
		done: boolean;
		backupCodes: string[];
	} | null>(null);

	$effect(() => {
		// Route-driven initial mode: token present → confirm, else request.
		if (initialized) return;
		initialized = true;
		const token = page.url.searchParams.get('token');
		mode = token ? 'confirm' : 'request';
	});

	async function finish(): Promise<void> {
		await goto(resolve('/'), { invalidateAll: true });
	}

	/** Same continuation as the login page: `preferred`-mode enrollment
	 * prompt before entering the app; best-effort on lookup failure. */
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
				mode = 'interstitial';
				return;
			}
		} catch {
			/* interstitial is best-effort */
		}
		await finish();
	}

	async function handleRequest(identifier: string) {
		error = null;
		loading = true;
		submittedIdentifier = identifier;
		try {
			// Anti-enumeration: always 200 — the screen shows the same
			// confirmation whether or not the account exists.
			const { linkTtlSeconds } = await requestPasswordReset(identifier);
			validityText = formatLinkValidity(linkTtlSeconds);
			requestSuccess = true;
		} catch (err) {
			error = (err as Error).message;
		} finally {
			loading = false;
		}
	}

	async function handleConfirm(newPassword: string) {
		const token = page.url.searchParams.get('token');
		if (!token) {
			mode = 'request';
			return;
		}
		error = null;
		loading = true;
		try {
			const result = await confirmPasswordReset(token, newPassword);
			if (result.kind === 'tokens') {
				await afterTokens();
			} else {
				await goto(resolve('/Login?reset=ok'));
			}
		} catch (err) {
			loading = false;
			if (err instanceof ResetLinkError) {
				// Unknown, expired, or already-used link. Point the user at the
				// request form (with the reason as banner) instead of a dead end.
				error = (err as Error).message;
				mode = 'request';
				requestSuccess = false;
			} else {
				error = (err as Error).message;
			}
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
	<title>{m.auth_reset_page_title()}</title>
</svelte:head>

{#if mode === 'interstitial' && prompt}
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
{:else if mode === 'confirm'}
	<PasswordResetConfirmScreen {loading} error={error ?? undefined} onsubmit={handleConfirm} />
{:else}
	<PasswordResetScreen
		{loading}
		error={error ?? undefined}
		success={requestSuccess}
		{submittedIdentifier}
		{validityText}
		onsubmit={handleRequest}
	/>
{/if}
