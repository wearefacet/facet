<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { AlertTriangle, LogOut, MonitorSmartphone } from '@lucide/svelte';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import { confirm } from '$lib/confirm.svelte';
	import { roleDocIdToName, humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import {
		listSessions as fetchSessions,
		revokeSession as revokeSessionRequest,
		revokeAllSessions as revokeAllSessionsRequest,
		type AccountSession
	} from './SessionsSource.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Sessions (B-140) — the caller's own browser and app sessions, with
	 * single revoke and the bulk revoke-others action. Renders the body
	 * only: the host surface (the personal settings page) owns the section
	 * chrome. The bulk route keeps the caller's current session alive
	 * server-side; the list carries no current-session marker (the access
	 * token lives in an HttpOnly cookie the page cannot read), so a revoked
	 * current session simply disappears from the refreshed list and its
	 * client signs out at the next refresh.
	 */

	let {
		/** Injectable API surface — stories and tests pass mocks here. */
		listSessions = fetchSessions,
		revokeSession = revokeSessionRequest,
		revokeAllSessions = revokeAllSessionsRequest
	}: {
		listSessions?: typeof fetchSessions;
		revokeSession?: typeof revokeSessionRequest;
		revokeAllSessions?: typeof revokeAllSessionsRequest;
	} = $props();

	let sessions = $state<AccountSession[] | null>(null);
	let loadError = $state<string | undefined>(undefined);
	let actionError = $state<string | undefined>(undefined);
	let revokingId = $state<string | null>(null);
	let bulkBusy = $state(false);
	/** Transient result line after a bulk revoke; cleared by the next action. */
	let bulkInfo = $state<string | null>(null);

	// Initial load — `sessions` / `loadError` are not read inside, so the
	// effect cannot loop.
	$effect(() => {
		void refresh();
	});

	async function refresh() {
		loadError = undefined;
		try {
			sessions = await listSessions();
		} catch (e) {
			loadError = errorMessage(e, m.errors_sessions_load());
		}
	}

	// The backend returns the session set unordered; newest creation first
	// reads as recent activity.
	const ordered = $derived.by(() => {
		if (!sessions) return null;
		return [...sessions].sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
	});

	async function handleRevoke(session: AccountSession) {
		if (revokingId || bulkBusy) return;
		const ok = await confirm({
			title: m.sessions_revoke_confirm_title(),
			message: m.sessions_revoke_confirm_body(),
			confirmLabel: m.sessions_revoke_confirm_button(),
			variant: 'danger'
		});
		if (!ok) return;
		revokingId = session.session_id;
		actionError = undefined;
		bulkInfo = null;
		try {
			await revokeSession(session.session_id);
			await refresh();
		} catch (e) {
			actionError = errorMessage(e, m.errors_session_revoke());
		} finally {
			revokingId = null;
		}
	}

	async function handleRevokeAll() {
		if (bulkBusy || revokingId) return;
		const ok = await confirm({
			title: m.sessions_bulk_confirm_title(),
			message: m.sessions_bulk_confirm_body(),
			confirmLabel: m.sessions_bulk_confirm_button(),
			variant: 'danger'
		});
		if (!ok) return;
		bulkBusy = true;
		actionError = undefined;
		try {
			const count = await revokeAllSessions();
			bulkInfo = m.sessions_bulk_done({ count });
			await refresh();
		} catch (e) {
			actionError = errorMessage(e, m.errors_sessions_revoke_all());
		} finally {
			bulkBusy = false;
		}
	}
</script>

<div class="toolbar">
	<button
		class="bulk-btn"
		disabled={bulkBusy || sessions === null || sessions.length === 0}
		onclick={() => handleRevokeAll()}
	>
		{#if bulkBusy}
			<AlertTriangle size={14} stroke-width={1.8} />
			<span>{m.sessions_revoking_button()}</span>
		{:else}
			<LogOut size={14} stroke-width={1.8} />
			<span>{m.sessions_bulk_button()}</span>
		{/if}
	</button>
</div>

{#if loadError}
	<p class="alert" role="alert">{loadError}</p>
{:else if ordered === null}
	<p class="muted">{m.common_loading()}</p>
{:else if ordered.length === 0}
	<div class="empty">
		<MonitorSmartphone size={20} stroke-width={1.8} />
		<p>{m.sessions_empty()}</p>
	</div>
{:else}
	<ul class="session-list">
		{#each ordered as s (s.session_id)}
			<li class="session-row">
				<div class="id-block">
					<span class="ua" title={s.user_agent ?? undefined}>
						{s.user_agent ?? m.sessions_no_ua()}
					</span>
					<span class="meta-line">
						<code class="ip">{s.ip ?? '—'}</code>
						{#if s.app}
							<code class="app-id" title={s.app}>{s.app}</code>
						{/if}
					</span>
				</div>
				<span class="role-chip">{humanizeRoleName(roleDocIdToName(s.role))}</span>
				<div class="times">
					<span class="time">
						<span class="time-label">{m.common_created()}</span>
						<RelativeTime date={s.created_at} />
					</span>
					<span class="time">
						<span class="time-label">{m.sessions_last_used_label()}</span>
						<RelativeTime date={s.last_used} />
					</span>
				</div>
				<button
					class="revoke-btn"
					disabled={revokingId === s.session_id || bulkBusy}
					onclick={() => handleRevoke(s)}
					title={m.sessions_revoke_aria()}
				>
					{#if revokingId === s.session_id}
						<AlertTriangle size={14} stroke-width={1.8} />
						<span>{m.sessions_revoking_button()}</span>
					{:else}
						<span>{m.sessions_revoke_button()}</span>
					{/if}
				</button>
			</li>
		{/each}
	</ul>
{/if}

{#if bulkInfo}
	<p class="bulk-info" role="status">{bulkInfo}</p>
{/if}
{#if actionError}
	<p class="alert" role="alert">{actionError}</p>
{/if}

<style>
	.toolbar {
		display: flex;
		justify-content: flex-end;
		margin-bottom: 10px;
	}

	.bulk-btn {
		flex: none;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 7px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--border-strong);
		background: var(--surface-2);
		color: var(--text-2);
	}

	.bulk-btn:hover:not(:disabled) {
		border-color: var(--danger);
		color: var(--danger);
		background: var(--danger-weak);
	}

	.bulk-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.bulk-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.session-list {
		list-style: none;
		margin: 0;
		padding: 0;
		border-top: 1px solid var(--border);
	}

	.session-row {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 12px 0;
		border-bottom: 1px solid var(--border);
	}

	.id-block {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.ua {
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.meta-line {
		display: flex;
		align-items: baseline;
		gap: 10px;
		min-width: 0;
	}

	.ip,
	.app-id {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.app-id {
		flex: none;
		max-width: 160px;
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
	.bulk-info,
	.alert {
		font-size: 13px;
		margin: 14px 0 0;
	}

	.muted {
		color: var(--text-3);
	}

	.bulk-info {
		color: var(--ok);
		font-weight: 600;
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
