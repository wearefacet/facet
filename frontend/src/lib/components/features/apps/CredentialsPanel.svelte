<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Power, PowerOff, Trash2, Rocket } from '@lucide/svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import EmailCapsule from '$lib/components/primitives/data/EmailCapsule.svelte';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import type { AppContent } from '$lib/app/appTypes';
	import { bareReferenceId, type DeploymentRow } from '$lib/app/deployments';
	import * as m from '$lib/paraglide/messages';

	/**
	 * CredentialsPanel — the body of the app detail Overview tab: the
	 * registration and credential surface. It shows the read-only identity
	 * (client id, client type, owner), the origins and redirect URIs (both
	 * client types sign in through a browser), the service identity for a
	 * backend (`confidential`) app, the deployment panel for a managed app,
	 * and the lifecycle actions (Activate / Disable / Re-enable / Delete).
	 *
	 * The component renders from props only. The host page owns the load,
	 * the mutations, and the navigation; every action arrives here as a
	 * callback, and the in-flight flags arrive as props. Permission gating
	 * uses `can('app.App', action)` because the manifest may not grant
	 * every action to every role.
	 */

	let {
		app,
		deployments = [],
		activatingId,
		busy = false,
		onActivateDeployment,
		onSetStatus,
		onDelete,
		onDeploy
	}: {
		/** The loaded app document content. */
		app: AppContent;
		/** Deployment history, newest first. Empty when the read failed. */
		deployments?: DeploymentRow[];
		/** Id of the deployment row that activates now. Disables its button. */
		activatingId?: string;
		/** True while the host runs a lifecycle mutation. Disables the buttons. */
		busy?: boolean;
		/** Points the app's `active_deployment` at the given row. */
		onActivateDeployment: (row: DeploymentRow) => void | Promise<void>;
		/** Applies one lifecycle status transition. */
		onSetStatus: (status: 'active' | 'disabled') => void | Promise<void>;
		/** Deletes the app. The host confirms and navigates back to the list. */
		onDelete: () => void;
		/** Opens the deploy flow. The host navigates. */
		onDeploy: () => void;
	} = $props();

	/** Managed app: Facet serves it, so the deployment panel applies. */
	let managed = $derived(Boolean(app.host || app.active_deployment));

	/** The deployment currently pointed at by `active_deployment`. */
	let activeDeployment = $derived(
		app.active_deployment
			? (deployments.find(
					(row) => row.meta.id === bareReferenceId(app.active_deployment!, 'app.Deployment.')
				) ?? null)
			: null
	);

	/** History rows minus the active one (the active row shows inline above). */
	let pastDeployments = $derived(
		activeDeployment
			? deployments.filter((row) => row.meta.id !== activeDeployment?.meta.id)
			: deployments
	);
</script>

<section class="block">
	<h2>{m.configure_identity_title()}</h2>
	<dl>
		<div class="row">
			<dt>{m.configure_domains_display_name_label()}</dt>
			<dd>{app.name}</dd>
		</div>
		<div class="row">
			<dt>{m.configure_apps_slug_label()}</dt>
			<dd class="mono">{app.slug}</dd>
		</div>
		<div class="row">
			<dt>{m.configure_apps_client_id_label()}</dt>
			<dd>
				{#if app.client_id}<EmailCapsule email={app.client_id} label={app.client_id} />{:else}—{/if}
			</dd>
		</div>
		<div class="row">
			<dt>{m.configure_apps_client_type_label()}</dt>
			<dd class="mono">{app.client_type ?? 'public'}</dd>
		</div>
		<div class="row">
			<dt>{m.configure_apps_served_at_label()}</dt>
			<dd>
				{#if app.host}<span class="pill">{app.host}</span>{:else}—{/if}
			</dd>
		</div>
		<div class="row">
			<dt>{m.configure_apps_owner_label()}</dt>
			<dd class="mono">{app.owner_id ?? '—'}</dd>
		</div>
		<div class="row">
			<dt>{m.common_description()}</dt>
			<dd>{app.description ?? '—'}</dd>
		</div>
	</dl>
</section>

<section class="block">
	<h2>{m.configure_apps_origins_title()}</h2>
	<dl>
		<div class="row">
			<dt>{m.configure_apps_allowed_origins_label()}</dt>
			<dd>
				{#if app.allowed_origins && app.allowed_origins.length > 0}
					<div class="capsules">
						{#each app.allowed_origins as origin (origin)}<span class="pill">{origin}</span>{/each}
					</div>
				{:else}—{/if}
			</dd>
		</div>
		<div class="row">
			<dt>{m.configure_apps_redirect_uris_label()}</dt>
			<dd>
				{#if app.redirect_uris && app.redirect_uris.length > 0}
					<div class="capsules">
						{#each app.redirect_uris as uri (uri)}<span class="pill">{uri}</span>{/each}
					</div>
				{:else}—{/if}
			</dd>
		</div>
	</dl>
</section>

{#if app.client_type === 'confidential'}
	<section class="block">
		<h2>{m.configure_apps_service_identity_title()}</h2>
		<dl>
			<div class="row">
				<dt>{m.configure_apps_service_role_label()}</dt>
				<dd class="mono">{app.service_role_id ?? '—'}</dd>
			</div>
			<div class="row">
				<dt>{m.configure_apps_service_account_label()}</dt>
				<dd class="mono">{app.service_account_id ?? '—'}</dd>
			</div>
		</dl>
	</section>
{/if}

{#if managed}
	<section class="block">
		<h2>{m.configure_apps_deployment_title()}</h2>

		<div class="cli-note">
			<div class="cli-note-text">
				{m.configure_apps_cli_note()}
				<button type="button" class="cli-note-link">{m.configure_apps_cli_guide()}</button>
			</div>
		</div>

		<div class="deploy-head">
			{#if activeDeployment}
				<div class="deploy-current">
					<span class="rev">r{activeDeployment.data.revision ?? '?'}</span>
					<span class="deploy-note">{activeDeployment.data.note || '—'}</span>
					<RelativeTime date={activeDeployment.meta.created_at} />
					<span class="deploy-files"
						>{m.configure_apps_files_count({
							count: activeDeployment.data.files?.length ?? 0
						})}</span
					>
					{#if activeDeployment.data.spa}
						<span class="pill">SPA</span>{/if}
					<span class="pill">{app.host}</span>
				</div>
			{:else}
				<div class="deploy-current">
					<span class="deploy-note">{m.configure_apps_no_deployment()}</span>
				</div>
			{/if}
			<Can doctype="app.App" action="update">
				<Button variant="primary" size="sm" onclick={onDeploy}>
					{#snippet iconLeft()}<Rocket size={13} strokeWidth={2} aria-hidden="true" />{/snippet}
					{m.configure_apps_deploy_button()}
				</Button>
			</Can>
		</div>

		{#if pastDeployments.length > 0}
			<div class="history">
				<div class="history-title">{m.configure_apps_history_title()}</div>
				{#each pastDeployments as row (row.meta.id)}
					<div class="history-row">
						<span class="rev">r{row.data.revision ?? '?'}</span>
						<span class="deploy-note">{row.data.note || '—'}</span>
						<RelativeTime date={row.meta.created_at} />
						<span class="deploy-files"
							>{m.configure_apps_files_count({ count: row.data.files?.length ?? 0 })}</span
						>
						<div class="history-action">
							<Can doctype="app.App" action="update">
								<Button
									variant="ghost"
									size="sm"
									disabled={activatingId === row.meta.id}
									onclick={() => onActivateDeployment(row)}
								>
									{m.configure_apps_activate()}
								</Button>
							</Can>
						</div>
					</div>
				{/each}
			</div>
		{/if}
	</section>
{/if}

<section class="block">
	<h2>{m.configure_apps_lifecycle_title()}</h2>
	<div class="lifecycle">
		<span class="badge" data-state={app.status ?? 'draft'}>{app.status ?? 'draft'}</span>
		<div class="lifecycle-actions">
			{#if (app.status ?? 'draft') === 'draft'}
				<Can doctype="app.App" action="update">
					<Button variant="primary" size="sm" disabled={busy} onclick={() => onSetStatus('active')}>
						{#snippet iconLeft()}<Power size={13} strokeWidth={2} aria-hidden="true" />{/snippet}
						{m.configure_apps_activate()}
					</Button>
				</Can>
			{:else if app.status === 'active'}
				<Can doctype="app.App" action="update">
					<Button variant="ghost" size="sm" disabled={busy} onclick={() => onSetStatus('disabled')}>
						{#snippet iconLeft()}<PowerOff size={13} strokeWidth={2} aria-hidden="true" />{/snippet}
						{m.configure_apps_disable()}
					</Button>
				</Can>
			{:else}
				<Can doctype="app.App" action="update">
					<Button variant="ghost" size="sm" disabled={busy} onclick={() => onSetStatus('active')}>
						{#snippet iconLeft()}<Power size={13} strokeWidth={2} aria-hidden="true" />{/snippet}
						{m.configure_apps_reenable()}
					</Button>
				</Can>
			{/if}
			<Can doctype="app.App" action="delete">
				<Button variant="danger" size="sm" disabled={busy} onclick={onDelete}>
					{#snippet iconLeft()}<Trash2 size={13} strokeWidth={2} aria-hidden="true" />{/snippet}
					{m.configure_apps_delete_button()}
				</Button>
			</Can>
		</div>
	</div>
</section>

<style>
	.block h2 {
		font-size: 13px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--text-3);
		margin: 0 0 10px;
	}

	dl {
		display: flex;
		flex-direction: column;
		gap: 8px;
		margin: 0;
	}

	.row {
		display: grid;
		grid-template-columns: 140px minmax(0, 1fr);
		gap: 12px;
		align-items: start;
	}

	dt {
		font-size: 13px;
		color: var(--text-3);
	}

	dd {
		font-size: 13px;
		color: var(--text);
		margin: 0;
		min-width: 0;
	}

	.mono {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.capsules {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
	}

	.pill {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
		background: var(--surface-2);
		border: 1px solid var(--border-2);
		border-radius: var(--r-sm);
		padding: 1px 8px;
	}

	.lifecycle {
		display: flex;
		align-items: center;
		gap: 12px;
		flex-wrap: wrap;
	}

	.lifecycle-actions {
		display: inline-flex;
		align-items: center;
		gap: 6px;
	}

	.badge {
		padding: 2px 9px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		text-transform: lowercase;
		background: color-mix(in srgb, var(--badge-color) 12%, transparent);
		color: var(--badge-color);
	}

	.badge[data-state='draft'] {
		--badge-color: var(--warn, #d97706);
	}

	.badge[data-state='active'] {
		--badge-color: var(--ok, #16a34a);
	}

	.badge[data-state='disabled'] {
		--badge-color: var(--text-3);
	}

	/* ── Deployment panel ─────────────────────────────────────────── */

	.cli-note {
		padding: 10px 12px;
		font-size: 13px;
		line-height: 1.55;
		color: var(--text-2);
		background: var(--info-weak, rgba(59, 130, 246, 0.1));
		border: 1px solid var(--info, #3b82f6);
		border-radius: var(--r);
		margin-bottom: 14px;
	}

	.cli-note-link {
		font: inherit;
		color: var(--info);
		font-weight: 600;
		text-decoration: none;
		margin-left: 4px;
		background: none;
		border: none;
		padding: 0;
		cursor: pointer;
	}

	.cli-note-link:hover {
		text-decoration: underline;
	}

	.deploy-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		flex-wrap: wrap;
	}

	.deploy-current {
		display: flex;
		align-items: center;
		gap: 10px;
		flex-wrap: wrap;
		min-width: 0;
	}

	.rev {
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 600;
		color: var(--accent-ink);
	}

	.deploy-note {
		font-size: 13px;
		color: var(--text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		max-width: 260px;
	}

	.deploy-files {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}

	.history {
		margin-top: 14px;
		border-top: 1px solid var(--border);
		padding-top: 10px;
		display: flex;
		flex-direction: column;
	}

	.history-title {
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--text-3);
		margin-bottom: 6px;
	}

	.history-row {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 5px 0;
	}

	.history-action {
		margin-left: auto;
	}
</style>
