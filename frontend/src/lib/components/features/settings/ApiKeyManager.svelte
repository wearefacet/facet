<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { KeyRound, Plus, Trash2, AlertTriangle } from '@lucide/svelte';
	import Panel from '$lib/components/primitives/surfaces/Panel.svelte';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import NewApiKeyDialog from './NewApiKeyDialog.svelte';
	import ApiKeyRevealDialog from './ApiKeyRevealDialog.svelte';
	import { confirm } from '$lib/confirm.svelte';
	import { getActiveRole, getAvailableRoles } from '$lib/role.svelte.js';
	import { roleDocIdToName, humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import {
		listApiKeys,
		createApiKey,
		revokeApiKey,
		type ApiKeyRecord,
		type CreatedApiKey,
		type CreateApiKeyInput
	} from '$lib/iam/apiKeys.js';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Assignable role ids; defaults to the session's available roles. */
		roles = undefined as string[] | undefined,
		/** Injectable API surface — stories and tests pass mocks here. */
		listKeys = listApiKeys,
		createKey = createApiKey,
		revokeKey = revokeApiKey
	}: {
		roles?: string[];
		listKeys?: typeof listApiKeys;
		createKey?: typeof createApiKey;
		revokeKey?: typeof revokeApiKey;
	} = $props();

	const roleOptions = $derived(
		(roles ?? getAvailableRoles() ?? []).map((r) => ({
			value: r,
			label: humanizeRoleName(roleDocIdToName(r))
		}))
	);

	function keyStatus(k: ApiKeyRecord): 'revoked' | 'expired' | 'active' {
		if (k.revoked_at) return 'revoked';
		if (k.expires_at && new Date(k.expires_at).getTime() <= Date.now()) return 'expired';
		return 'active';
	}

	let keys = $state<ApiKeyRecord[] | null>(null);
	let loadError = $state<string | undefined>(undefined);
	let actionError = $state<string | undefined>(undefined);
	let revokingId = $state<string | null>(null);
	let createOpen = $state(false);
	let revealOpen = $state(false);
	let revealed = $state<CreatedApiKey | null>(null);

	// Initial load — `keys` / `loadError` are not read inside, so the effect
	// cannot loop.
	$effect(() => {
		void refresh();
	});

	async function refresh() {
		loadError = undefined;
		try {
			keys = await listKeys();
		} catch (e) {
			loadError = errorMessage(e, m.apikeys_load_error());
		}
	}

	async function handleCreate(input: CreateApiKeyInput): Promise<string | null> {
		try {
			revealed = await createKey(input);
			revealOpen = true;
			await refresh();
			return null;
		} catch (e) {
			return errorMessage(e, m.apikeys_create_error());
		}
	}

	async function handleRevoke(key: ApiKeyRecord) {
		if (revokingId) return;
		const ok = await confirm({
			title: m.apikeys_revoke_confirm_title({ name: key.name }),
			message: m.apikeys_revoke_confirm_body(),
			confirmLabel: m.apikeys_revoke_confirm_button(),
			variant: 'danger'
		});
		if (!ok) return;
		revokingId = key.id;
		actionError = undefined;
		try {
			await revokeKey(key.id);
			await refresh();
		} catch (e) {
			actionError = errorMessage(e, m.apikeys_revoke_error());
		} finally {
			revokingId = null;
		}
	}
</script>

<div class="keys-wrap">
	<Panel>
		<div class="head">
			<div class="head-tx">
				<h2 class="title">{m.apikeys_manager_title()}</h2>
				<p class="sub">
					{m.apikeys_manager_helper()}
				</p>
			</div>
			<button class="create-btn" onclick={() => (createOpen = true)}>
				<Plus size={15} stroke-width={2} />
				<span>{m.apikeys_create_button()}</span>
			</button>
		</div>

		{#if loadError}
			<p class="alert" role="alert">{loadError}</p>
		{:else if keys === null}
			<p class="muted">{m.apikeys_loading()}</p>
		{:else if keys.length === 0}
			<div class="empty">
				<KeyRound size={20} stroke-width={1.8} />
				<p>{m.apikeys_empty()}</p>
			</div>
		{:else}
			<ul class="key-list">
				{#each keys as key (key.id)}
					{@const status = keyStatus(key)}
					<li class="key-row" class:revoked={status === 'revoked'}>
						<div class="id-block">
							<span class="key-name">{key.name}</span>
							<code class="key-prefix">{key.display_prefix}…</code>
						</div>
						<span class="role-chip">{humanizeRoleName(roleDocIdToName(key.role_id))}</span>
						<div class="times">
							<span class="time"
								><span class="time-label">{m.common_created()}</span>
								<RelativeTime date={key.created_at} /></span
							>
							<span class="time">
								<span class="time-label">{m.apikeys_last_used_label()}</span>
								{#if key.last_used_at}
									<RelativeTime date={key.last_used_at} />
								{:else}
									<span class="never">{m.apikeys_never_label()}</span>
								{/if}
							</span>
							<span class="time">
								<span class="time-label">{m.apikeys_expires_label()}</span>
								{#if key.expires_at}
									<RelativeTime date={key.expires_at} />
								{:else}
									<span class="never">{m.apikeys_never_label()}</span>
								{/if}
							</span>
						</div>
						<span class="status-badge badge-{status}">
							{status === 'revoked'
								? m.apikeys_status_revoked()
								: status === 'expired'
									? m.apikeys_status_expired()
									: m.apikeys_status_active()}
						</span>
						{#if status !== 'revoked'}
							<button
								class="revoke-btn"
								disabled={revokingId === key.id}
								onclick={() => handleRevoke(key)}
								title={m.apikeys_revoke_aria()}
							>
								{#if revokingId === key.id}
									<AlertTriangle size={14} stroke-width={1.8} />
									<span>{m.apikeys_revoking_button()}</span>
								{:else}
									<Trash2 size={14} stroke-width={1.8} />
									<span>{m.apikeys_revoke_button()}</span>
								{/if}
							</button>
						{:else}
							<span class="revoke-placeholder"></span>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}

		{#if actionError}
			<p class="alert" role="alert">{actionError}</p>
		{/if}
	</Panel>
</div>

<NewApiKeyDialog
	bind:open={createOpen}
	roles={roleOptions.map((o) => o.value)}
	role={getActiveRole() ?? ''}
	oncreate={handleCreate}
/>
<ApiKeyRevealDialog
	open={revealOpen}
	created={revealed}
	onclose={() => {
		revealOpen = false;
		revealed = null;
	}}
/>

<style>
	.keys-wrap {
		padding: 0 32px 32px;
	}

	.head {
		display: flex;
		align-items: flex-start;
		gap: 16px;
		margin-bottom: 18px;
	}

	.head-tx {
		flex: 1;
		min-width: 0;
	}

	.title {
		font-family: var(--font-display);
		font-size: 15px;
		font-weight: 600;
		margin: 0;
	}

	.sub {
		font-size: 12.5px;
		color: var(--text-3);
		margin: 4px 0 0;
		line-height: 1.5;
	}

	.create-btn {
		flex: none;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 7px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` is gold-on-light and
		   invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
	}

	.create-btn:hover {
		background: var(--accent-press);
	}

	.create-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.key-list {
		list-style: none;
		margin: 0;
		padding: 0;
		border-top: 1px solid var(--border);
	}

	.key-row {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 12px 0;
		border-bottom: 1px solid var(--border);
	}

	.key-row.revoked .id-block,
	.key-row.revoked .times {
		opacity: 0.55;
	}

	.id-block {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.key-name {
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.key-prefix {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}

	.role-chip {
		flex: none;
		font-size: 11px;
		font-weight: 600;
		color: var(--text-2);
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		padding: 2px 10px;
		white-space: nowrap;
	}

	.times {
		flex: none;
		display: flex;
		gap: 18px;
	}

	.time {
		display: flex;
		flex-direction: column;
		gap: 1px;
		min-width: 72px;
	}

	.time-label {
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.never {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
	}

	.status-badge {
		flex: none;
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		border-radius: var(--r-pill);
		padding: 2px 9px;
	}

	.badge-active {
		color: var(--ok);
		background: var(--ok-weak);
	}

	.badge-expired {
		color: var(--warn);
		background: var(--warn-weak);
	}

	.badge-revoked {
		color: var(--danger);
		background: var(--danger-weak);
	}

	.revoke-btn {
		flex: none;
		width: 96px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 6px;
		padding: 5px 10px;
		border-radius: var(--r);
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text-2);
	}

	.revoke-btn:hover:not(:disabled) {
		border-color: var(--danger);
		color: var(--danger);
		background: var(--danger-weak);
	}

	.revoke-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.revoke-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.revoke-placeholder {
		flex: none;
		width: 96px;
	}

	.empty {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 18px 0 6px;
		color: var(--text-3);
		font-size: 13px;
	}

	.empty p {
		margin: 0;
	}

	.muted,
	.alert {
		font-size: 13px;
		margin: 14px 0 0;
	}

	.muted {
		color: var(--text-3);
	}

	.alert {
		color: var(--danger);
		background: var(--danger-weak);
		border: 1px solid var(--danger);
		border-radius: var(--r);
		padding: 10px 12px;
	}

	@media (max-width: 900px) {
		.times {
			display: none;
		}
	}
</style>
