<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	ConsentScreen — full-screen OAuth authorization surface.
	Shows a list of grants (effective scope per role) in a user-friendly way,
	lets the user elect a role when more than one is available, surfaces the
	"no eligible role" message, and renders error branches
	(invalid_client, invalid_redirect, unauthorized_client, invalid_request,
	access_denied).
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { untrack } from 'svelte';
	import { SvelteMap } from 'svelte/reactivity';
	import {
		CheckCircle2,
		ShieldAlert,
		ShieldQuestion,
		ArrowLeft,
		AppWindow,
		MonitorSmartphone
	} from '@lucide/svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import AuthShell from './AuthShell.svelte';
	import { humanizeRoleName, roleDocIdToName } from '$lib/authorization/roleMembership';
	import type {
		ConsentError,
		ConsentScreen,
		EffectiveScopeEntry,
		MCPScreen,
		UsableRole
	} from './oauthTypes';

	let {
		product = 'Facet',
		consent = null,
		mcp = null,
		error = null,
		loading = false,
		/** Pre-selects a role on first render (single-role apps auto-elect this). */
		preselectedRoleId,
		/** The redirect URI the route will use. Shown to the user for verification. */
		redirectUri,
		onconsent,
		oncancel,
		onretry
	}: {
		product?: string;
		consent?: ConsentScreen | null;
		mcp?: MCPScreen | null;
		error?: ConsentError | null;
		loading?: boolean;
		preselectedRoleId?: string;
		redirectUri?: string;
		onconsent?: (choice: { role_id: string }) => void;
		oncancel?: () => void;
		onretry?: () => void;
	} = $props();

	// The roles come from whichever shape is active — the app screen or the
	// MCP screen. Exactly one of `consent` / `mcp` is set by the route.
	const roles = $derived(mcp?.roles ?? consent?.roles ?? []);
	const hasMultipleRoles = $derived(roles.length > 1);

	// Resolve which role should be selected given the current props:
	// prefer an explicit preselection, otherwise auto-elect the single role
	// so Authorize is a one-click action.
	function desiredRoleId(): string | undefined {
		return preselectedRoleId ?? (roles.length === 1 ? roles[0].role_id : undefined);
	}

	// Local selection state. A writable derived: reads `desiredRoleId()` (which
	// is derived from `consent` / `preselectedRoleId` props) until the radio
	// `onchange` assigns an override; a prop change drops the override, so
	// re-election always wins. (The old `$state` + sync `$effect` pair tripped
	// `svelte/prefer-writable-derived`.)
	let selectedRoleId = $derived<string | undefined>(desiredRoleId());

	const selectedRole = $derived(
		selectedRoleId ? roles.find((r) => r.role_id === selectedRoleId) : undefined
	);

	const canSubmit = $derived(Boolean(selectedRoleId) && !loading);

	function handleSubmit(e: SubmitEvent) {
		e.preventDefault();
		if (!selectedRoleId || loading) return;
		onconsent?.({ role_id: selectedRoleId });
	}

	// Display the verified redirect target: prefer the explicit prop (the
	// authoritative one the route will use), then fall back to the first
	// registered URI on the app card. On the MCP screen the backend sends the
	// redirect *origin* (scheme+host+port) — exactly what the user approves.
	const verifiedRedirect = $derived(
		redirectUri ??
			(consent?.app.redirect_uris.length ? consent.app.redirect_uris[0] : undefined) ??
			mcp?.redirect_origin
	);

	// Header identity. The app screen names the application. The MCP screen
	// names the role the user will act as — the humanized role label, not the
	// full resource URL (which is already shown in the redirect disclosure).
	const mcpRoleLabel = $derived(
		mcp
			? mcp.pinned_role
				? roleLabel(roles.find((r) => r.role_id === mcp.pinned_role))
				: roles.length === 1
					? roleLabel(roles[0])
					: ''
			: ''
	);
	const appName = $derived(
		consent?.app.display_name ?? (mcp ? mcpRoleLabel || m.apps_mcp_name() : m.apps_request_name())
	);
	const appDescription = $derived(
		consent?.app.description ??
			(mcp
				? mcpRoleLabel
					? m.apps_mcp_desc_role({ role: mcpRoleLabel })
					: m.apps_mcp_desc()
				: undefined)
	);
	const appSlug = $derived(consent?.app.slug ?? mcp?.resource ?? '');

	// Human-friendly label for a role: the humanized role name (e.g.
	// `iam.Roles.admin` → `Admin`). `display_name` is the role's description,
	// shown separately as the `.role-desc` line.
	function roleLabel(role: UsableRole | undefined): string {
		if (!role) return '';
		return humanizeRoleName(roleDocIdToName(role.role_id));
	}

	// Single, human-friendly slug for an effective scope entry's target.
	// Wildcard paths (`crm.*`) collapse to the domain name with an "all"
	// marker; the global `*.*` admin permission reads as "All domains";
	// concrete paths join their segments with dots.
	function targetLabel(entry: EffectiveScopeEntry): string {
		if (entry.domain === '*') return m.apps_all_domains();
		if (entry.path.length === 0 || entry.path.includes('*')) {
			return m.apps_all_doctypes({ domain: entry.domain });
		}
		return `${entry.domain}.${entry.path.join('.')}`;
	}

	// Human-friendly label for a grant group's domain heading.
	function domainLabel(domain: string): string {
		return domain === '*' ? m.apps_all_domains() : domain;
	}

	// Human-friendly label for an action chip. The `*` action (admin wildcard)
	// reads as "All actions"; concrete actions pass through.
	function actionLabel(action: string): string {
		return action === '*' ? m.apps_all_actions() : action;
	}

	// Group effective scope by domain so the grants list shows a tidy
	// per-domain block instead of a long flat list.
	const groupedScope = $derived.by(() => {
		if (!selectedRole) return [];
		// untrack: interleaved get/set on a tracked map inside a derivation
		// self-dirties it and re-runs the derivation.
		return untrack(() => {
			const map = new SvelteMap<string, EffectiveScopeEntry[]>();
			for (const entry of selectedRole.effective_scope) {
				const bucket = map.get(entry.domain) ?? [];
				bucket.push(entry);
				map.set(entry.domain, bucket);
			}
			return Array.from(map, ([domain, entries]) => ({ domain, entries }));
		});
	});
</script>

<AuthShell maxWidth={hasMultipleRoles ? 520 : 460} gap={18} subMaxWidth={360}>
	{#snippet icon()}
		<ShieldQuestion size={22} />
	{/snippet}

	{#snippet title()}
		{#if consent || mcp}
			{m.apps_consent_title({ name: appName })}
		{:else if error}
			{m.apps_blocked_title()}
		{:else}
			{m.apps_loading_title()}
		{/if}
	{/snippet}

	{#snippet sub()}
		{#if consent || mcp}
			{#if appDescription}
				{appDescription}
			{:else}
				{m.apps_consent_sub({ name: appName, product })}
			{/if}
		{:else if error}
			{m.apps_error_sub()}
		{:else}
			{m.apps_verifying_sub()}
		{/if}
	{/snippet}

	{#snippet footer()}
		<footer class="consent-foot">
			<AppWindow size={12} aria-hidden="true" />
			<span>{m.apps_footer({ product })}</span>
		</footer>
	{/snippet}

	{#if loading && !consent && !error}
		<!-- Initial fetch loading state -->
		<div class="consent-loading" role="status" aria-live="polite">
			<span class="consent-spinner" aria-hidden="true"></span>
			<span class="consent-loading-text">{m.apps_checking()}</span>
		</div>
	{:else if (consent || mcp) && roles.length === 0}
		<!-- No eligible role branch -->
		<div class="consent-blocked" role="alert">
			<span class="consent-blocked-mark" aria-hidden="true">
				<ShieldAlert size={20} />
			</span>
			<div>
				<p class="consent-blocked-title">
					{#if consent}{m.apps_no_role_app()}{:else}{m.apps_no_role_request()}{/if}
				</p>
				<p class="consent-blocked-body">
					{#if consent}
						{m.apps_body_app({ name: consent.app.display_name, product })}
					{:else}
						{m.apps_body_request({ product })}
					{/if}
				</p>
			</div>
		</div>

		<div class="consent-meta">
			<div class="meta-row">
				<span class="meta-label">{m.apps_app_label()}</span>
				<span class="meta-value" title={appSlug}>{appSlug}</span>
			</div>
			{#if verifiedRedirect}
				<div class="meta-row">
					<span class="meta-label">{m.apps_redirect_label()}</span>
					<span class="meta-value meta-value-mono" title={verifiedRedirect}>{verifiedRedirect}</span
					>
				</div>
			{/if}
		</div>

		{#if oncancel}
			<div class="consent-actions">
				<Button variant="secondary" size="lg" onclick={oncancel} iconLeft={BackIcon}
					>{m.auth_back_signin()}</Button
				>
			</div>
		{/if}
	{:else if (consent || mcp) && roles.length > 0}
		<!-- Consent form -->
		{#if hasMultipleRoles}
			<fieldset class="role-fieldset">
				<legend class="role-legend">{m.apps_role_legend()}</legend>
				<p class="role-helper">
					{m.apps_role_helper()}
				</p>
				{#each roles as role (role.role_id)}
					{@const checked = selectedRoleId === role.role_id}
					<label
						class="role-option"
						class:role-option-checked={checked}
						for={`role-${role.role_id}`}
					>
						<input
							id={`role-${role.role_id}`}
							type="radio"
							name="role"
							value={role.role_id}
							{checked}
							disabled={loading}
							onchange={(e) => (selectedRoleId = (e.target as HTMLInputElement).value)}
						/>
						<span class="role-radio" aria-hidden="true"></span>
						<span class="role-meta">
							<span class="role-id" aria-hidden="true">{roleLabel(role)}</span>
							{#if role.display_name}
								<span class="role-desc" aria-hidden="true">{role.display_name}</span>
							{/if}
						</span>
					</label>
				{/each}
			</fieldset>
		{:else}
			<div class="role-single" role="status">
				<span class="role-single-mark" aria-hidden="true"><CheckCircle2 size={15} /></span>
				<span class="role-single-text">
					{#if roles[0].display_name}
						{m.apps_acting_as_desc({
							role: roleLabel(roles[0]),
							description: roles[0].display_name
						})}
					{:else}
						{m.apps_acting_as({ role: roleLabel(roles[0]) })}
					{/if}
				</span>
			</div>
		{/if}

		<!-- Grants list -->
		<section class="grants">
			<header class="grants-head">
				<h2 class="grants-title">{m.apps_grants_title()}</h2>
			</header>

			<ul class="grants-list">
				{#each groupedScope as group (group.domain)}
					<li class="grant-group">
						<div class="grant-domain" aria-hidden="true">{domainLabel(group.domain)}</div>
						<ul class="grant-entries">
							{#each group.entries as entry (`${entry.domain}.${entry.path.join('.')}`)}
								{@const isWildcard =
									entry.domain === '*' || entry.path.length === 0 || entry.path.includes('*')}
								<li class="grant-entry" class:grant-entry-wide={isWildcard}>
									<span class="grant-cap" class:grant-cap-wide={isWildcard}>
										<span class="grant-cap-diamond" aria-hidden="true"></span>
										{targetLabel(entry)}
									</span>
									<span class="grant-actions">
										{#each entry.actions as action (action)}
											<span class="grant-action" class:grant-action-passthrough={action === 'read'}
												>{actionLabel(action)}</span
											>
										{/each}
									</span>
								</li>
							{/each}
						</ul>
					</li>
				{/each}
			</ul>
		</section>

		<!-- Redirect disclosure -->
		{#if verifiedRedirect}
			<div class="consent-redirect" title={verifiedRedirect}>
				<MonitorSmartphone size={13} aria-hidden="true" />
				<span class="consent-redirect-text">
					{m.apps_redirect_text({ uri: verifiedRedirect })}
				</span>
			</div>
		{/if}

		<form class="consent-form" onsubmit={handleSubmit}>
			<div class="consent-actions">
				{#if oncancel}
					<Button
						type="button"
						variant="secondary"
						size="lg"
						onclick={oncancel}
						disabled={loading}
						iconLeft={BackIcon}
					>
						{m.common_cancel()}
					</Button>
				{/if}
				<Button type="submit" variant="primary" size="lg" disabled={!canSubmit} {loading}>
					{m.apps_authorize()}
				</Button>
			</div>
		</form>
	{:else if error}
		<!-- Structural error branch -->
		<div class="consent-blocked" role="alert">
			<span class="consent-blocked-mark" aria-hidden="true">
				<ShieldAlert size={20} />
			</span>
			<div>
				<p class="consent-blocked-title">
					{#if error.error === 'invalid_client'}{m.apps_unknown_client()}{:else if error.error === 'invalid_request'}{m.apps_invalid_request()}{:else if error.error === 'unauthorized_client'}{m.apps_app_disabled()}{:else if error.error === 'access_denied'}{m.apps_access_denied()}{:else}{m.apps_blocked_title()}{/if}
				</p>
				<p class="consent-blocked-body">{error.error_description}</p>
			</div>
		</div>

		<div class="consent-actions">
			{#if oncancel}
				<Button variant="secondary" size="lg" onclick={oncancel} iconLeft={BackIcon}
					>{m.auth_back_signin()}</Button
				>
			{/if}
			{#if onretry && (error.error === 'access_denied' || error.error === 'invalid_client')}
				<Button variant="primary" size="lg" onclick={onretry}>{m.apps_try_again()}</Button>
			{/if}
		</div>
	{/if}
</AuthShell>

{#snippet BackIcon()}<ArrowLeft size={14} />{/snippet}

<style>
	/* ── Loading ─────────────────────────────────────────────────────── */
	.consent-loading {
		display: flex;
		align-items: center;
		gap: 10px;
		justify-content: center;
		padding: 24px 0;
		color: var(--text-2);
		font-size: 13px;
	}

	.consent-spinner {
		width: 16px;
		height: 16px;
		border: 2px solid var(--border-strong);
		border-top-color: var(--accent-ink);
		border-radius: 50%;
		animation: consent-spin 0.65s linear infinite;
		flex-shrink: 0;
	}

	@keyframes consent-spin {
		to {
			transform: rotate(360deg);
		}
	}

	/* ── Blocked / error block ───────────────────────────────────────── */
	.consent-blocked {
		display: flex;
		align-items: flex-start;
		gap: 12px;
		padding: 14px;
		border-radius: var(--r);
		background: var(--danger-weak);
		border: 1px solid color-mix(in srgb, var(--danger) 30%, transparent);
	}

	.consent-blocked-mark {
		display: grid;
		place-items: center;
		width: 32px;
		height: 32px;
		border-radius: 50%;
		background: var(--danger);
		color: #fff;
		flex: none;
	}

	.consent-blocked-title {
		margin: 0 0 4px;
		font-size: 13px;
		font-weight: 600;
		color: var(--danger);
	}

	.consent-blocked-body {
		margin: 0;
		font-size: 12.5px;
		color: var(--text-2);
		line-height: 1.5;
	}

	/* ── Meta block (no-role / app identity) ─────────────────────────── */
	.consent-meta {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 12px 14px;
		background: var(--sunken);
		border-radius: var(--r);
		border: 1px solid var(--border);
	}

	.meta-row {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.meta-label {
		font-size: 10.5px;
		text-transform: uppercase;
		letter-spacing: 0.08em;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.meta-value {
		font-size: 12.5px;
		color: var(--text);
		word-break: break-all;
	}

	.meta-value-mono {
		font-family: var(--font-mono);
		font-size: 11.5px;
	}

	/* ── Role selector ───────────────────────────────────────────────── */
	.role-fieldset {
		border: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.role-legend {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text);
		padding: 0;
		margin-bottom: 2px;
	}

	.role-helper {
		margin: 0 0 4px;
		font-size: 11.5px;
		color: var(--text-3);
		line-height: 1.45;
	}

	.role-option {
		display: flex;
		align-items: flex-start;
		gap: 10px;
		padding: 10px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color 0.12s,
			background 0.12s;
	}

	.role-option:hover {
		border-color: var(--border-strong);
		background: var(--surface-2);
	}

	.role-option-checked {
		border-color: var(--accent-ink);
		background: var(--accent-weak);
	}

	.role-option input {
		position: absolute;
		opacity: 0;
		width: 0;
		height: 0;
	}

	.role-radio {
		width: 16px;
		height: 16px;
		border-radius: 50%;
		border: 1.5px solid var(--border-strong);
		background: var(--surface);
		flex-shrink: 0;
		margin-top: 1px;
		position: relative;
		transition: border-color 0.12s;
	}

	.role-option-checked .role-radio {
		border-color: var(--accent-ink);
	}

	.role-option-checked .role-radio::after {
		content: '';
		position: absolute;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--accent-ink);
	}

	.role-option:focus-within .role-radio {
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.role-meta {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.role-id {
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		font-weight: 600;
	}

	.role-desc {
		font-size: 11.5px;
		color: var(--text-2);
		line-height: 1.4;
	}

	/* ── Single-role summary ─────────────────────────────────────────── */
	.role-single {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 9px 12px;
		border-radius: var(--r);
		background: var(--ok-weak);
		border: 1px solid color-mix(in srgb, var(--ok) 28%, transparent);
		font-size: 12.5px;
		color: var(--text);
	}

	.role-single-mark {
		color: var(--ok);
		display: flex;
		flex-shrink: 0;
	}

	.role-single-text {
		line-height: 1.4;
	}

	/* ── Grants list ──────────────────────────────────────────────────── */
	.grants {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.grants-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	.grants-title {
		margin: 0;
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text);
	}

	.grants-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.grant-group {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 10px 12px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
	}

	.grant-domain {
		font-family: var(--font-mono);
		font-size: 10.5px;
		text-transform: uppercase;
		letter-spacing: 0.08em;
		color: var(--text-3);
	}

	.grant-entries {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.grant-entry {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
	}

	.grant-entry-wide {
		align-items: flex-start;
	}

	.grant-cap {
		--tint: var(--dt-document);
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 1px 8px 1px 7px;
		border-radius: var(--r-sm);
		border: 1px solid color-mix(in srgb, var(--tint) 34%, transparent);
		background: color-mix(in srgb, var(--tint) 9%, var(--surface));
		font-family: var(--font-mono);
		font-size: 11.5px;
		font-weight: 500;
		line-height: 18px;
		color: color-mix(in srgb, var(--tint) 70%, var(--text));
		white-space: nowrap;
		flex-shrink: 0;
	}

	.grant-cap-wide {
		--tint: var(--dt-document);
	}

	.grant-cap-diamond {
		width: 8px;
		height: 8px;
		transform: rotate(45deg);
		border-radius: 1.5px;
		background: color-mix(in srgb, var(--tint) 22%, transparent);
		border: 1.4px solid var(--tint);
		flex-shrink: 0;
	}

	.grant-actions {
		display: inline-flex;
		flex-wrap: wrap;
		gap: 4px;
	}

	.grant-action {
		display: inline-flex;
		align-items: center;
		padding: 2px 8px;
		border-radius: var(--r-pill);
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		line-height: 1.4;
		background: var(--sunken);
		color: var(--text-2);
		text-transform: lowercase;
	}

	.grant-action-passthrough {
		background: var(--info-weak);
		color: var(--info);
	}

	/* ── Redirect disclosure ─────────────────────────────────────────── */
	.consent-redirect {
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 8px 11px;
		border-radius: var(--r);
		background: var(--sunken);
		border: 1px solid var(--border);
		font-size: 11.5px;
		color: var(--text-2);
		line-height: 1.4;
	}

	.consent-redirect :global(svg) {
		color: var(--text-3);
		flex-shrink: 0;
	}

	.consent-redirect-text {
		min-width: 0;
	}

	/* ── Actions footer ───────────────────────────────────────────────── */
	.consent-form {
		margin: 0;
	}

	.consent-actions {
		display: flex;
		gap: 8px;
		justify-content: flex-end;
		flex-wrap: wrap;
	}

	.consent-actions :global(.btn) {
		flex: 1;
		min-width: 0;
	}

	.consent-foot {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 6px;
		padding-top: 10px;
		border-top: 1px solid var(--border);
		font-size: 11px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.consent-foot :global(svg) {
		color: var(--text-3);
	}

	@media (prefers-reduced-motion: reduce) {
		* {
			animation: none !important;
			transition: none !important;
		}
	}
</style>
