<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { untrack } from 'svelte';
	import { Send, KeyRound, ShieldOff } from '@lucide/svelte';

	import Button from '$lib/components/primitives/actions/Button.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import TemporaryPasswordPanel from './TemporaryPasswordPanel.svelte';
	import { confirm } from '$lib/confirm.svelte';
	import { apiFetch } from '$lib/session.svelte';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import { DataSourceError } from '$lib/datasource/types.js';
	import { can } from '$lib/permissions.svelte';
	import { SvelteMap } from 'svelte/reactivity';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Account credential bootstrap — the action panel on the `iam.Account`
	 * show page. Replaces the row actions the accounts table used to carry:
	 * the operator opens an account (table row → quick view → show) and
	 * manages its sign-in state here.
	 *
	 * The panel renders nothing when the active role holds no relevant
	 * permission. Every action is a UI hint gated on the permission manifest
	 * through `can()`; the backend re-checks each request. All state-changing
	 * calls send `X-Requested-With: XMLHttpRequest` (the IAM CSRF rule).
	 */

	/** One entry of the `credential-states` response. */
	interface CredentialState {
		id: string;
		has_password: boolean;
		must_change_pw: boolean;
		mfa_enabled: boolean;
		invite_pending: boolean;
		/** Always `false` until the OIDC backend lands (Phase 6). */
		federated: boolean;
	}

	/** Live credential-state reader — one batched GET per call. */
	async function fetchCredentialStates(ids: string[]): Promise<Map<string, CredentialState>> {
		// untrack: called from the loadState effect — a tracked read on `out`
		// followed by its own `set` writes would re-run that effect and orphan
		// the fetch (workflow.md → "The equality-guard trap in writeback effects").
		const out = untrack(() => new SvelteMap<string, CredentialState>());
		if (ids.length === 0) return out;
		const query = ids.map((id) => `id=${encodeURIComponent(id)}`).join('&');
		const res = await apiFetch(`/Api/iam/accounts/credential-states?${query}`);
		if (!res.ok) return out;
		const body = (await res.json()) as { states?: CredentialState[] };
		for (const state of body.states ?? []) untrack(() => out.set(state.id, state));
		return out;
	}

	let {
		/** The account's document id (`iam.Account` projection id). */
		docId,
		/** The account email — shown in the reveal-once password panel. */
		email = null,
		/** Document `status` field — hides the password action when terminal. */
		status = 'active',
		/** Document `service_account` flag — service accounts hold no invite/password. */
		serviceAccount = false,
		/** Credential-state reader — inject a stub in stories. */
		fetchStates = fetchCredentialStates,
		/** Called after a successful action so the host can refresh the document. */
		onchanged
	}: {
		docId: string;
		email?: string | null;
		status?: string;
		serviceAccount?: boolean;
		fetchStates?: (ids: string[]) => Promise<Map<string, CredentialState>>;
		onchanged?: () => void | Promise<void>;
	} = $props();

	const canProvision = $derived(can('iam.Account', 'provision_credentials'));
	const canResetMfa = $derived(can('iam.Account', 'mfa_disable'));

	let credential = $state<CredentialState | null>(null);
	let busy = $state(false);
	let actionError = $state<string | undefined>(undefined);

	let reveal = $state<{ password: string; regenerated: boolean } | null>(null);
	let revealOpen = $state(false);

	// Invite: a non-expired reset token exists (`invite_pending`) → the link
	// is being re-sent. Service accounts never receive one (backend 422).
	const inviteLabel = $derived(
		credential?.invite_pending ? m.admin_resend_invite() : m.admin_send_invite()
	);
	const showInvite = $derived(canProvision && !serviceAccount);

	// Temporary password: the backend refuses service, disabled, and
	// suspended accounts — hide the action where it cannot succeed.
	const pwLabel = $derived(
		credential?.has_password ? m.admin_regenerate_password() : m.admin_generate_password()
	);
	const showPassword = $derived(
		canProvision && !serviceAccount && status !== 'suspended' && status !== 'disabled'
	);

	// Reset MFA: only for enrolled accounts. A purely federated account
	// (federated with no local password) has no local factor to
	// reset — the IdP is the factor of record. A federated account that also
	// holds a local password keeps the action.
	const showResetMfa = $derived(
		Boolean(canResetMfa) &&
			Boolean(credential?.mfa_enabled) &&
			!(credential?.federated && !credential?.has_password)
	);

	const visible = $derived(showInvite || showPassword || showResetMfa);

	// Sequence guard: a slow state read must never overwrite a newer one
	// (the fetch re-runs after every action).
	let stateSeq = 0;

	async function loadState(): Promise<void> {
		const seq = ++stateSeq;
		try {
			const states = await fetchStates([docId]);
			if (seq === stateSeq) credential = states.get(docId) ?? null;
		} catch {
			if (seq === stateSeq) credential = null;
		}
	}

	$effect(() => {
		void docId;
		void loadState();
	});

	function showError(err: unknown): void {
		const banner = toBannerError(err);
		actionError =
			banner.details.length > 0
				? `${banner.message}: ${banner.details.join('; ')}`
				: banner.message;
	}

	/** POST JSON to a non-doctype IAM endpoint, with the CSRF header. */
	async function postJson<T>(url: string, body: unknown): Promise<T> {
		const res = await apiFetch(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
			body: JSON.stringify(body)
		});
		if (!res.ok) {
			const payload = (await res.json().catch(() => ({}))) as {
				error?: string;
				details?: never;
			};
			throw new DataSourceError(res.status, payload.error ?? res.statusText, payload.details);
		}
		return (await res.json()) as T;
	}

	async function doInvite(): Promise<void> {
		busy = true;
		actionError = undefined;
		try {
			await postJson<{ ok: boolean }>(`/Api/iam/accounts/${encodeURIComponent(docId)}/invite`, {});
			await loadState();
			await onchanged?.();
		} catch (err) {
			showError(err);
		} finally {
			busy = false;
		}
	}

	async function doPassword(): Promise<void> {
		busy = true;
		actionError = undefined;
		try {
			const body = await postJson<{ temporary_password: string }>(
				`/Api/iam/accounts/${encodeURIComponent(docId)}/temporary-password`,
				{}
			);
			reveal = {
				password: body.temporary_password,
				regenerated: credential?.has_password === true
			};
			revealOpen = true;
			await loadState();
			await onchanged?.();
		} catch (err) {
			showError(err);
		} finally {
			busy = false;
		}
	}

	async function doResetMfa(): Promise<void> {
		const ok = await confirm({
			title: m.admin_reset_mfa_confirm_title(),
			message: m.admin_reset_mfa_confirm_body(),
			confirmLabel: m.admin_reset_mfa(),
			variant: 'danger'
		});
		if (!ok) return;
		busy = true;
		actionError = undefined;
		try {
			// The route reads `account_id` — the identity naming rule (the
			// account is the identity; `user_id` answered 422).
			await postJson<{ ok: boolean }>('/Api/iam/mfa/disable', { account_id: docId });
			await loadState();
			await onchanged?.();
		} catch (err) {
			showError(err);
		} finally {
			busy = false;
		}
	}
</script>

{#if visible}
	<section class="cred-panel">
		<h2 class="cred-label">{m.admin_credentials_title()}</h2>

		{#if actionError}
			<AlertBanner message={actionError} dismissable onDismiss={() => (actionError = undefined)} />
		{/if}

		<div class="cred-actions">
			{#if showInvite}
				<Button variant="secondary" size="sm" disabled={busy} onclick={doInvite}>
					{#snippet iconLeft()}
						<Send size={13} strokeWidth={1.8} aria-hidden="true" />
					{/snippet}
					{inviteLabel}
				</Button>
			{/if}
			{#if showPassword}
				<Button variant="secondary" size="sm" disabled={busy} onclick={doPassword}>
					{#snippet iconLeft()}
						<KeyRound size={13} strokeWidth={1.8} aria-hidden="true" />
					{/snippet}
					{pwLabel}
				</Button>
			{/if}
			{#if showResetMfa}
				<Button variant="secondary" size="sm" disabled={busy} onclick={doResetMfa}>
					{#snippet iconLeft()}
						<ShieldOff size={13} strokeWidth={1.8} aria-hidden="true" />
					{/snippet}
					{m.admin_reset_mfa()}
				</Button>
			{/if}
		</div>
	</section>
{/if}

<TemporaryPasswordPanel
	bind:open={revealOpen}
	password={reveal?.password ?? null}
	{email}
	regenerated={reveal?.regenerated ?? false}
	onclose={() => (reveal = null)}
/>

<style>
	.cred-panel {
		margin-top: 28px;
		padding: 18px 20px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.cred-label {
		margin: 0;
		font-size: 11px;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: var(--text-3);
		font-weight: 600;
	}

	.cred-actions {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
	}
</style>
