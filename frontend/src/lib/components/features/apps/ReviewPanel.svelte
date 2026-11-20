<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolve } from '$app/paths';
	import { summarizeGrants, anySensitiveGranted } from '$lib/app/appGrantsMapping';
	import type { AppContent, DoctypeCatalogueEntry } from '$lib/app/appTypes';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import { Check, CircleAlert } from '@lucide/svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * ReviewPanel — the review step of the new-app wizard. A two-tier
	 * checklist: blocking items must pass before publish; optional items
	 * show but do not block. Each row carries the step that sets it, and
	 * its Edit link goes to that step with the `?app=` thread. The consent
	 * preview renders the grouped grant summary — one verb line per group,
	 * with the plural nouns the verb applies to — instead of a folded
	 * string.
	 *
	 * The page owns the save and the navigation: `onFinish` receives the
	 * chosen status, the page writes it, and the page shows the error
	 * banner. The component emits a status only when no blocking item is
	 * open, so the Publish button shows the open item instead of firing.
	 */

	let {
		app,
		appId,
		catalogue = [],
		busy = undefined,
		onBack,
		onFinish
	}: {
		/** The draft document content. */
		app: AppContent;
		/** The draft document id. Threads the `?app=` parameter on the Edit links. */
		appId: string;
		/** Doctype catalogue for the consent summary. */
		catalogue?: DoctypeCatalogueEntry[];
		/** Set while the page writes a status change. */
		busy?: 'draft' | 'publish';
		/** Moves back to the permissions step. The page owns the navigation. */
		onBack: () => Promise<void> | void;
		/** Writes the chosen status. The page owns the save and the navigation. */
		onFinish: (status: 'draft' | 'active') => Promise<void> | void;
	} = $props();

	const summaryGroups = $derived(summarizeGrants(app.grants ?? [], catalogue));
	const hasSensitive = $derived(anySensitiveGranted(app.grants ?? [], catalogue));

	// Identity initials for the consent card avatar, fallback to the first
	// two characters of the display name.
	const initials = $derived(
		(app.name ?? '')
			.split(/\s+/)
			.filter(Boolean)
			.slice(0, 2)
			.map((w) => w[0]?.toUpperCase() ?? '')
			.join('') || (app.name ?? '').slice(0, 2).toUpperCase()
	);

	// ── Checklist ────────────────────────────────────────────────────────
	// Two tiers: blocking items gate the Publish button; optional items
	// show for awareness but never block. Each row carries the wizard step
	// that sets it, so the user can fix a gap in one click — the Edit link
	// resolves the step route (with the `?app=` thread) at render time.
	type ChecklistItem = {
		label: string;
		detail: string;
		done: boolean;
		blocking: boolean;
		editStep?: 'setup' | 'permissions';
		editLabel: string;
	};

	const isConfidential = $derived(app.client_type === 'confidential');

	const checklist = $derived.by<ChecklistItem[]>(() => {
		const items: ChecklistItem[] = [
			{
				label: m.configure_identity_title(),
				detail: `${app.name ?? '—'} · ${app.slug ?? '—'}${
					app.owner_id ? ` · ${m.configure_apps_owned_by({ id: app.owner_id })}` : ''
				}`,
				done: Boolean(app.slug && app.name),
				blocking: true,
				editStep: 'setup',
				editLabel: m.common_edit()
			}
		];
		// Both client types sign in through a browser, so the origin and
		// redirect rows always apply; a `confidential` app adds the
		// service-role row on top.
		items.push(
			{
				label: m.configure_apps_allowed_origins_label(),
				detail: m.configure_apps_origins_count({ count: app.allowed_origins?.length ?? 0 }),
				done: Array.isArray(app.allowed_origins) && app.allowed_origins.length > 0,
				blocking: true,
				editStep: 'setup',
				editLabel: m.common_edit()
			},
			{
				label: m.configure_apps_redirect_uris_label(),
				detail: m.configure_apps_uris_count({ count: app.redirect_uris?.length ?? 0 }),
				done: Array.isArray(app.redirect_uris) && app.redirect_uris.length > 0,
				blocking: true,
				editStep: 'setup',
				editLabel: m.common_edit()
			}
		);
		if (isConfidential) {
			items.push({
				label: m.configure_apps_service_role_label(),
				detail: app.service_role_id ?? '—',
				done: Boolean(app.service_role_id),
				blocking: true,
				editStep: 'permissions',
				editLabel: m.common_edit()
			});
		}
		items.push(
			{
				label: m.configure_apps_wizard_permissions(),
				detail: hasSensitive
					? `${m.configure_apps_grants_count({ count: app.grants?.length ?? 0 })} ${m.configure_apps_includes_sensitive()}`
					: m.configure_apps_grants_count({ count: app.grants?.length ?? 0 }),
				done: Array.isArray(app.grants) && app.grants.length > 0,
				blocking: true,
				editStep: 'permissions',
				editLabel: m.common_edit()
			},
			{
				label: m.configure_apps_logo_missing(),
				detail: m.configure_apps_logo_missing_detail(),
				done: false,
				blocking: false,
				editLabel: m.common_add()
			}
		);
		return items;
	});

	const blocking = $derived(checklist.filter((i) => i.blocking));
	const optional = $derived(checklist.filter((i) => !i.blocking));
	const firstBlocking = $derived(blocking.find((i) => !i.done));
	const canPublish = $derived(!firstBlocking);

	// The page used to hold this guard on its save path. It now sits next
	// to the buttons: no publish reaches the page while a blocking item is
	// open.
	function requestFinish(status: 'draft' | 'active'): void {
		if (status === 'active' && !canPublish) return;
		void onFinish(status);
	}
</script>

<section class="block">
	<h2>{m.configure_apps_review_title({ name: app.name })}</h2>
	<p class="muted">{m.configure_apps_review_sub()}</p>
</section>

<section class="block">
	<h3 class="tier-label">{m.configure_apps_required_tier()}</h3>
	<div class="checklist">
		{#each blocking as item (item.label)}
			<div class="checklist-row" class:done={item.done}>
				{#if item.done}
					<Check size={17} strokeWidth={2} class="check-icon" aria-hidden="true" />
				{:else}
					<CircleAlert size={17} strokeWidth={2} class="warn-icon" aria-hidden="true" />
				{/if}
				<div class="checklist-meta">
					<div class="checklist-label">{item.label}</div>
					<div class="checklist-detail">{item.detail}</div>
				</div>
				{#if item.editStep}
					<a
						href={resolve(`/Configure/apps/new/${item.editStep}?app=${appId}`)}
						class="checklist-edit">{item.editLabel}</a
					>
				{/if}
			</div>
		{/each}
	</div>

	{#if optional.length > 0}
		<h3 class="tier-label tier-optional">{m.configure_apps_optional_tier()}</h3>
		<div class="checklist">
			{#each optional as item (item.label)}
				<div class="checklist-row" class:done={item.done}>
					{#if item.done}
						<Check size={17} strokeWidth={2} class="check-icon" aria-hidden="true" />
					{:else}
						<CircleAlert size={17} strokeWidth={2} class="muted-icon" aria-hidden="true" />
					{/if}
					<div class="checklist-meta">
						<div class="checklist-label">{item.label}</div>
						<div class="checklist-detail">{item.detail}</div>
					</div>
					{#if item.editStep}
						<a
							href={resolve(`/Configure/apps/new/${item.editStep}?app=${appId}`)}
							class="checklist-edit">{item.editLabel}</a
						>
					{/if}
				</div>
			{/each}
		</div>
	{/if}
</section>

<section class="block">
	<h3 class="tier-label">{m.configure_apps_consent_tier()}</h3>
	<div class="consent-card">
		<div class="consent-head">
			<div class="consent-avatar" aria-hidden="true">{initials}</div>
			<div>
				<div class="consent-app-name">{app.name}</div>
				{#if app.description}
					<div class="consent-app-desc">{app.description}</div>
				{/if}
			</div>
		</div>

		{#if summaryGroups.length > 0}
			<div class="consent-intro">{m.configure_apps_consent_intro()}</div>
			<div class="consent-groups">
				{#each summaryGroups as group (group.kind + ':' + group.verb)}
					<div class="consent-group">
						<strong>{group.verb}</strong>
						{#if group.kind === 'core' && group.targets.length > 0}
							<span class="consent-nouns">
								{group.targets[0]}
								{#if group.targets.length > 1}
									{#each group.targets.slice(1, -1) as noun (noun)}<span>, {noun}</span>{/each}
									<span> and {group.targets[group.targets.length - 1]}</span>
								{/if}
							</span>
						{/if}
						{#if group.optional}
							<span class="consent-optional">{m.configure_apps_consent_optional()}</span>
						{/if}
					</div>
				{/each}
			</div>
			<div class="consent-footer">
				{m.configure_apps_consent_footer()}
				{#if hasSensitive}
					{m.configure_apps_consent_sensitive()}
				{/if}
			</div>
		{:else}
			<div class="consent-empty">{m.configure_apps_consent_empty()}</div>
		{/if}
	</div>
</section>

<footer class="step-footer">
	<Button variant="ghost" onclick={onBack}>{m.common_back()}</Button>
	<div class="footer-right">
		<Button
			variant="secondary"
			disabled={busy !== undefined}
			onclick={() => requestFinish('draft')}
		>
			{busy === 'draft' ? m.common_saving() : m.configure_apps_keep_draft()}
		</Button>
		{#if canPublish}
			<Button
				variant="primary"
				disabled={busy !== undefined}
				onclick={() => requestFinish('active')}
			>
				{busy === 'publish' ? m.configure_publishing_button() : m.configure_publish_button()}
			</Button>
		{:else}
			<div class="publish-blocked">
				<Button variant="primary" disabled>{m.configure_publish_button()}</Button>
				<span class="publish-blocked-reason">
					{m.configure_apps_complete({ name: firstBlocking?.label ?? '' })}
				</span>
			</div>
		{/if}
	</div>
</footer>

<style>
	.block {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.block h2 {
		font-size: 18px;
		font-weight: 500;
		margin: 0;
		color: var(--text);
	}

	.muted {
		font-size: 13.5px;
		color: var(--text-3);
		margin: 2px 0 0;
	}

	.tier-label {
		font-size: 13px;
		font-weight: 500;
		margin: 8px 0 4px;
		color: var(--text-2);
	}

	.tier-optional {
		margin-top: 14px;
	}

	.checklist {
		display: flex;
		flex-direction: column;
		gap: 2px;
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
		overflow: hidden;
	}

	.checklist-row {
		display: flex;
		gap: 12px;
		align-items: center;
		padding: 12px 14px;
		border-bottom: 0.5px solid var(--border);
	}

	.checklist-row:last-child {
		border-bottom: none;
	}

	:global(.check-icon) {
		color: var(--ok, #16a34a);
	}

	:global(.warn-icon) {
		color: var(--warn, #d97706);
	}

	:global(.muted-icon) {
		color: var(--text-3);
	}

	.checklist-meta {
		flex: 1;
		min-width: 0;
	}

	.checklist-label {
		font-size: 13.5px;
		font-weight: 500;
		color: var(--text);
	}

	.checklist-detail {
		font-size: 12.5px;
		color: var(--text-3);
		margin-top: 1px;
	}

	.checklist-edit {
		font-size: 12.5px;
		color: var(--accent-ink);
		flex-shrink: 0;
	}

	.consent-card {
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
		padding: 16px 18px;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.consent-head {
		display: flex;
		align-items: center;
		gap: 11px;
	}

	.consent-avatar {
		width: 34px;
		height: 34px;
		border-radius: var(--r);
		background: var(--accent-weak);
		color: var(--accent-ink);
		display: flex;
		align-items: center;
		justify-content: center;
		font-weight: 500;
		font-size: 13px;
		flex-shrink: 0;
	}

	.consent-app-name {
		font-weight: 500;
		font-size: 14px;
		color: var(--text);
	}

	.consent-app-desc {
		font-size: 12.5px;
		color: var(--text-3);
		margin-top: 1px;
	}

	.consent-intro {
		margin-top: 6px;
		font-size: 13.5px;
		color: var(--text-2);
	}

	.consent-groups {
		margin-top: 4px;
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	.consent-group {
		font-size: 13.5px;
		color: var(--text);
	}

	.consent-group strong {
		font-weight: 500;
		margin-right: 4px;
	}

	.consent-optional {
		margin-left: 6px;
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
	}

	.consent-footer {
		margin-top: 6px;
		padding-top: 10px;
		border-top: 0.5px solid var(--border);
		font-size: 12.5px;
		color: var(--text-3);
	}

	.consent-empty {
		font-size: 13px;
		color: var(--text-3);
		font-style: italic;
	}

	.step-footer {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
		padding-top: 16px;
		border-top: 1px solid var(--border);
	}

	.footer-right {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.publish-blocked {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.publish-blocked-reason {
		font-size: 12.5px;
		color: var(--warn, #d97706);
	}
</style>
