<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { useAppKeyStatus } from '$lib/app/appKeyStatus.svelte.js';
	import type { AppContent } from '$lib/app/appTypes';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Field from '$lib/components/primitives/forms/Field.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import StringListEditor from '$lib/components/primitives/forms/StringListEditor.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import SecretRevealPanel from '$lib/components/features/settings/SecretRevealPanel.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import { Trash2 } from '@lucide/svelte';
	import { validateRedirectUri } from '$lib/app/appValidation';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { validateHostname } from '$lib/app/appValidation';
	import * as m from '$lib/paraglide/messages';

	/**
	 * AppSettingsForm — the body of the app detail Settings tab: the
	 * advanced fields the wizard does not carry. `slug` and `client_id`
	 * render read-only (immutable after create); the rest are editable.
	 *
	 * The form owns the draft state. The host page owns the persistence:
	 * every Save sends one flat content patch through `onSave`, and the
	 * page PATCHes the document and invalidates the show cache so the next
	 * read reflects the saved state. A failed save throws out of `onSave`;
	 * the page maps it to the banner.
	 *
	 * A backend (`confidential`) app also picks its service role here — the
	 * wizard sets the field only at create time, so an app flipped to
	 * confidential after creation gets it from this tab — and manages its
	 * API key: status, regenerate (confirm + one-time reveal), and revoke.
	 * The reveal state is local `$state` only — the raw key is never
	 * persisted client-side.
	 */

	let {
		app,
		appId,
		busy = false,
		driver = new DocumentDataDriver(''),
		onSave,
		onDelete
	}: {
		/** The loaded app document content. The sync effect copies it into the draft. */
		app: AppContent;
		/** Bare app id. The API-key hook targets this app. */
		appId: string;
		/** True while the host persists a patch or runs the delete. Disables the buttons. */
		busy?: boolean;
		/** Data driver for the service-role picker — a mock in stories. */
		driver?: DataDriver;
		/** Persists one flat content patch. Throws on failure (the page maps it). */
		onSave: (patch: Record<string, unknown>) => void | Promise<void>;
		/** Deletes the app. The page confirms and navigates back to the list. */
		onDelete: () => void;
	} = $props();

	// ── Editable draft ─────────────────────────────────────────────────

	/** One draft bag for every editable field on the tab. */
	interface AppSettingsDraft {
		clientType: 'public' | 'confidential';
		serviceRoleId: string;
		redirectUris: string[];
		allowedOrigins: string[];
		compatibleRoles: string[];
		noLauncher: boolean;
		noAsset: boolean;
		/** Optional; empty clears the host (the page sends `host: null`). */
		host: string;
		assistantEnabled: boolean;
		assistantPrompt: string;
	}

	let draft = $state<AppSettingsDraft>({
		clientType: 'public',
		serviceRoleId: '',
		redirectUris: [],
		allowedOrigins: [],
		compatibleRoles: [],
		noLauncher: false,
		noAsset: false,
		host: '',
		assistantEnabled: false,
		assistantPrompt: ''
	});

	// Sync the draft when the loaded document changes (initial load and
	// after `invalidateAll()` following a save). Each editor owns its own
	// local field so user edits don't dirty the loaded document until the
	// explicit Save button PATCHes it. IMPORTANT: do NOT add equality
	// guards here — reading the local `$state`s inside this effect would
	// subscribe it to them, causing the effect to re-run on every keystroke
	// and clobber the user's input with the unchanged prop value.
	$effect(() => {
		draft.clientType = app.client_type ?? 'public';
		draft.serviceRoleId = app.service_role_id ?? '';
		draft.redirectUris = [...(app.redirect_uris ?? [])];
		draft.allowedOrigins = [...(app.allowed_origins ?? [])];
		draft.compatibleRoles = [...(app.compatible_roles ?? [])];
		draft.noLauncher = app.no_launcher ?? false;
		draft.noAsset = app.no_asset ?? false;
		draft.host = app.host ?? '';
		draft.assistantEnabled = app.assistant_enabled ?? false;
		draft.assistantPrompt = app.assistant_prompt ?? '';
	});

	// ── Field validators ───────────────────────────────────────────────

	function urlValidator(v: string): string | null {
		try {
			const u = new URL(v);
			if (u.protocol !== 'http:' && u.protocol !== 'https:') return 'Must be http(s).';
			return null;
		} catch {
			return 'Not a valid URL.';
		}
	}

	function originValidator(v: string): string | null {
		return urlValidator(v);
	}

	function roleValidator(v: string): string | null {
		if (!v.includes('.')) return 'Role ids are qualified (e.g. iam.Roles.admin).';
		return null;
	}

	/** Client-side shape error for the host input; the backend hook stays the authority. */
	let hostError = $state<string | null>(null);

	// ── Save (one flat patch per section) ──────────────────────────────

	async function saveClientType(): Promise<void> {
		await onSave({ client_type: draft.clientType });
	}

	async function saveServiceRole(): Promise<void> {
		await onSave({ service_role_id: draft.serviceRoleId });
	}

	async function saveRedirectUris(): Promise<void> {
		await onSave({ redirect_uris: draft.redirectUris });
	}

	async function saveAllowedOrigins(): Promise<void> {
		await onSave({ allowed_origins: draft.allowedOrigins });
	}

	async function saveCompatibleRoles(): Promise<void> {
		await onSave({ compatible_roles: draft.compatibleRoles });
	}

	async function saveHeadlessFlags(): Promise<void> {
		await onSave({ no_launcher: draft.noLauncher, no_asset: draft.noAsset });
	}

	async function saveHost(): Promise<void> {
		const trimmed = draft.host.trim();
		// Empty clears the field: the page PATCHes RFC 7386 style, and `null`
		// is the one way to remove a key from the merged document. Absent
		// values skip the unique check and both Lua hooks read the cleared
		// merged state as "no host".
		if (trimmed === '') {
			hostError = null;
			await onSave({ host: null });
			return;
		}
		const problem = validateHostname(trimmed);
		if (problem) {
			hostError = problem;
			return;
		}
		hostError = null;
		await onSave({ host: trimmed });
	}

	async function saveAssistant(): Promise<void> {
		await onSave({
			assistant_enabled: draft.assistantEnabled,
			assistant_prompt: draft.assistantPrompt
		});
	}

	// ── API key (backend apps) ─────────────────────────────────────────

	const isConfidential = $derived(app.client_type === 'confidential');

	// ── Service role (backend apps) ────────────────────────────────────

	// The picked role's connectivity list loads through the driver: a role
	// whose list excludes the `api` channel cannot carry a service key
	// (issuance refuses with 422). `undefined` while loading — an unknown
	// list must not raise a false alarm. The plain-`let` seq guard drops
	// results from a superseded pick without re-triggering this effect.
	let roleConnectivity = $state<string[] | undefined>(undefined);
	let roleLoadSeq = 0;
	$effect(() => {
		const roleId = draft.serviceRoleId;
		const activeDriver = driver;
		if (!roleId) {
			roleLoadSeq += 1;
			roleConnectivity = undefined;
			return;
		}
		const my = ++roleLoadSeq;
		activeDriver
			.domain('iam')
			.doctype('Roles')
			.doc(roleId)
			.show()
			.then((res) => {
				if (my !== roleLoadSeq) return; // superseded by a newer pick
				const channels = res?.data?.connectivity;
				roleConnectivity = Array.isArray(channels)
					? channels.filter((c): c is string => typeof c === 'string')
					: [];
			})
			.catch(() => {
				if (my !== roleLoadSeq) return;
				roleConnectivity = undefined;
			});
	});

	// Warning only — the operator can still save the role and fix its
	// channels; key issuance refuses with 422 until then.
	const roleMissingApi = $derived(
		Boolean(isConfidential && draft.serviceRoleId) &&
			roleConnectivity !== undefined &&
			!roleConnectivity.includes('api')
	);

	// Status, issue, revoke — one reactive hook. The raw key of the latest
	// issue stays in local state only (the panel clears it on Done).
	const appKey = useAppKeyStatus(() => appId);
	let revealedKey = $state<string | null>(null);

	// Initial status load — re-runs only if the app flips its client type;
	// the locals it writes are not read inside, so it cannot loop.
	$effect(() => {
		if (isConfidential) void appKey.refresh();
	});

	async function generateKey(): Promise<void> {
		const issued = await appKey.issue();
		if (issued) revealedKey = issued.key;
	}

	async function regenerateKey(): Promise<void> {
		if (!window.confirm(m.configure_apps_regenerate_confirm())) return;
		await generateKey();
	}

	async function revokeKey(): Promise<void> {
		if (!window.confirm(m.configure_apps_revoke_confirm())) return;
		const revoked = await appKey.revoke();
		if (revoked) revealedKey = null;
	}
</script>

<section class="block read-only">
	<h2>{m.configure_apps_readonly_title()}</h2>
	<Input
		label={m.configure_apps_slug_label()}
		value={app.slug}
		readonly
		helper={m.configure_apps_slug_helper()}
	/>
	<Input
		label={m.configure_apps_client_id_label()}
		value={app.client_id ?? ''}
		readonly
		helper={m.configure_apps_client_id_helper()}
	/>
</section>

<section class="block">
	<h2>{m.configure_apps_client_type_label()}</h2>
	<div class="field-row">
		<div class="field-grow">
			<Select
				label={m.configure_apps_client_type_label()}
				value={draft.clientType}
				searchable={false}
				options={[
					{ value: 'public', label: m.configure_apps_client_public() },
					{ value: 'confidential', label: m.configure_apps_client_confidential() }
				]}
				onValueChange={(v) => (draft.clientType = (v as AppContent['client_type']) ?? 'public')}
				helper={m.configure_apps_client_helper()}
			/>
		</div>
		<Can doctype="app.App" action="update">
			<Button variant="ghost" size="sm" disabled={busy} onclick={saveClientType}
				>{m.common_save()}</Button
			>
		</Can>
	</div>
</section>

<section class="block">
	<h2>{m.configure_apps_origins_title()}</h2>
	<div class="field-row">
		<div class="field-grow">
			<StringListEditor
				bind:values={draft.redirectUris}
				label={m.configure_apps_redirect_uris_label()}
				placeholder="https://app.example.com/oauth/callback"
				validator={validateRedirectUri}
				helper={m.configure_apps_redirect_helper()}
			/>
		</div>
		<Can doctype="app.App" action="update">
			<Button variant="ghost" size="sm" disabled={busy} onclick={saveRedirectUris}
				>{m.common_save()}</Button
			>
		</Can>
	</div>
	<div class="field-row">
		<div class="field-grow">
			<StringListEditor
				bind:values={draft.allowedOrigins}
				label={m.configure_apps_allowed_origins_label()}
				placeholder="https://app.example.com"
				validator={originValidator}
				helper={m.configure_apps_origins_helper()}
			/>
		</div>
		<Can doctype="app.App" action="update">
			<Button variant="ghost" size="sm" disabled={busy} onclick={saveAllowedOrigins}
				>{m.common_save()}</Button
			>
		</Can>
	</div>
</section>

<section class="block">
	<h2>{m.configure_apps_compatible_roles_title()}</h2>
	<div class="field-row">
		<div class="field-grow">
			<StringListEditor
				bind:values={draft.compatibleRoles}
				label={m.configure_apps_role_ids_label()}
				placeholder="iam.Roles.admin"
				validator={roleValidator}
				helper={m.configure_apps_role_ids_helper()}
			/>
		</div>
		<Can doctype="app.App" action="update">
			<Button variant="ghost" size="sm" disabled={busy} onclick={saveCompatibleRoles}
				>{m.common_save()}</Button
			>
		</Can>
	</div>
</section>

<section class="block">
	<h2>{m.configure_apps_headless_title()}</h2>
	<div class="field-row">
		<div class="field-grow flags">
			<Toggle bind:checked={draft.noLauncher} label={m.configure_apps_no_launcher_label()} />
			<Toggle bind:checked={draft.noAsset} label={m.configure_apps_no_asset_label()} />
		</div>
		<Can doctype="app.App" action="update">
			<Button variant="ghost" size="sm" disabled={busy} onclick={saveHeadlessFlags}
				>{m.common_save()}</Button
			>
		</Can>
	</div>
	<p class="flags-helper">
		{m.configure_apps_headless_helper()}
	</p>
</section>

<section class="block">
	<h2>{m.configure_apps_serving_title()}</h2>
	<div class="field-row">
		<div class="field-grow">
			<Input
				label={m.configure_apps_host_label()}
				bind:value={draft.host}
				placeholder={m.configure_apps_host_placeholder()}
				disabled={draft.noAsset}
				error={hostError ?? undefined}
				helper={draft.noAsset
					? m.configure_apps_host_helper_no_asset()
					: m.configure_apps_host_helper()}
				oninput={() => (hostError = null)}
			/>
		</div>
		<Can doctype="app.App" action="update">
			<Button
				variant="ghost"
				size="sm"
				disabled={busy || draft.noAsset || Boolean(hostError)}
				onclick={saveHost}>{m.common_save()}</Button
			>
		</Can>
	</div>
</section>

<!-- The assistant chat surface is a browser feature; both client types
	     host it — a `confidential` app signs in through a browser too. -->
<Can doctype="app.App" action="update">
	<section class="block">
		<h2>{m.configure_apps_assistant_title()}</h2>
		<div class="field-row">
			<div class="field-grow">
				<Toggle
					bind:checked={draft.assistantEnabled}
					label={m.configure_apps_assistant_enable_label()}
				/>
			</div>
			<Button variant="ghost" size="sm" disabled={busy} onclick={saveAssistant}
				>{m.common_save()}</Button
			>
		</div>
		<p class="flags-helper">{m.configure_apps_assistant_helper()}</p>
		<div class="assistant-prompt">
			<Field
				label={m.configure_apps_assistant_prompt_label()}
				helper={m.configure_apps_assistant_prompt_helper()}
				id="app-assistant-prompt"
				forId="app-assistant-prompt"
			>
				{#snippet children(meta)}
					<textarea
						id="app-assistant-prompt"
						class="assistant-prompt-field"
						bind:value={draft.assistantPrompt}
						rows="5"
						placeholder={m.configure_apps_assistant_prompt_placeholder()}
						aria-describedby={meta.describedBy}></textarea>
				{/snippet}
			</Field>
		</div>
	</section>
</Can>

{#if isConfidential}
	<section class="block">
		<h2>{m.configure_apps_service_identity_title()}</h2>
		<div class="field-row">
			<div class="field-grow">
				<ReferencePicker
					label={m.configure_apps_service_role_label()}
					bind:value={draft.serviceRoleId}
					doctype="iam.Roles"
					{driver}
					placeholder={m.configure_apps_service_role_placeholder()}
					helper={m.configure_apps_service_role_helper()}
				/>
			</div>
			<Can doctype="app.App" action="update">
				<Button
					variant="ghost"
					size="sm"
					disabled={busy || !draft.serviceRoleId}
					onclick={saveServiceRole}>{m.common_save()}</Button
				>
			</Can>
		</div>
		{#if roleMissingApi}
			<p class="role-gap" role="status">{m.configure_apps_role_no_api_channel()}</p>
		{/if}
	</section>
{/if}

{#if isConfidential}
	<section class="block">
		<h2>{m.configure_apps_apikey_title()}</h2>
		{#if revealedKey}
			<!-- One-time reveal. The raw key exists only in local state; once
			     dismissed it is unrecoverable. -->
			<SecretRevealPanel secret={revealedKey}>
				<Button variant="ghost" size="sm" onclick={() => (revealedKey = null)}
					>{m.common_done()}</Button
				>
			</SecretRevealPanel>
		{:else}
			<div class="key-row">
				<div class="key-status">
					{#if !app.service_role_id}
						<!-- The role gate comes first: with no service role the key
						     status is irrelevant — issuance would refuse anyway. -->
						<span class="key-muted">{m.configure_apps_key_needs_role()}</span>
					{:else if appKey.loading}
						<span class="key-muted">{m.common_loading()}</span>
					{:else if appKey.status?.active}
						<div class="key-line">
							<span class="key-label">{m.configure_apps_key_label()}</span>
							<code class="mono">{appKey.status.display_prefix}…</code>
						</div>
						<div class="key-line">
							<span class="key-label">{m.common_role()}</span>
							<code class="mono">{appKey.status.role_id}</code>
						</div>
						<div class="key-line">
							<span class="key-label">{m.common_created()}</span>
							<RelativeTime date={appKey.status.created_at} />
						</div>
						<div class="key-line">
							<span class="key-label">{m.apikeys_last_used_label()}</span>
							{#if appKey.status.last_used_at}
								<RelativeTime date={appKey.status.last_used_at} />
							{:else}
								<span class="key-muted">{m.apikeys_never_label()}</span>
							{/if}
						</div>
					{:else}
						<span class="key-muted">
							{m.configure_apps_no_key()}
						</span>
					{/if}
				</div>
				<Can doctype="app.App" action="update">
					<div class="key-actions">
						{#if appKey.status?.active}
							<Button
								variant="ghost"
								size="sm"
								disabled={appKey.issuing || appKey.revoking}
								onclick={regenerateKey}
							>
								{appKey.issuing ? m.configure_apps_generating() : m.configure_apps_regenerate()}
							</Button>
							<Button
								variant="danger"
								size="sm"
								disabled={appKey.issuing || appKey.revoking}
								onclick={revokeKey}
							>
								{appKey.revoking ? m.apikeys_revoking_button() : m.apikeys_revoke_button()}
							</Button>
						{:else}
							<Button
								variant="primary"
								size="sm"
								disabled={appKey.issuing || !app.service_role_id}
								onclick={generateKey}
							>
								{appKey.issuing ? m.configure_apps_generating() : m.configure_apps_generate_key()}
							</Button>
						{/if}
					</div>
				</Can>
			</div>
		{/if}
		{#if appKey.error}
			<p class="key-error" role="alert">{appKey.error}</p>
		{/if}
	</section>
{/if}

<section class="block danger">
	<h2>{m.configure_danger_zone_title()}</h2>
	<div class="danger-row">
		<span class="danger-label">{m.configure_apps_delete_label()}</span>
		<Can doctype="app.App" action="delete">
			<Button variant="danger" size="sm" disabled={busy} onclick={onDelete}>
				{#snippet iconLeft()}<Trash2 size={13} strokeWidth={2} aria-hidden="true" />{/snippet}
				{m.configure_apps_delete_button()}
			</Button>
		</Can>
	</div>
</section>

<style>
	.block h2 {
		font-size: 13px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--text-3);
		margin: 0 0 12px;
	}

	.field-row {
		display: flex;
		align-items: flex-end;
		gap: 12px;
	}

	.field-grow {
		flex: 1;
		min-width: 0;
	}

	.flags {
		display: flex;
		flex-wrap: wrap;
		gap: 18px;
	}

	.flags-helper {
		margin-top: 8px;
		font-size: 12.5px;
		color: var(--text-muted);
	}

	.role-gap {
		margin-top: 8px;
		padding: 8px 10px;
		border-radius: var(--r-sm);
		background: var(--warn-weak);
		color: var(--warn);
		font-size: 12.5px;
	}

	.assistant-prompt {
		margin-top: 14px;
	}

	.assistant-prompt-field {
		font-family: var(--font-sans);
		font-size: 13px;
		line-height: 1.5;
		padding: 9px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
		width: 100%;
		min-height: 96px;
		resize: vertical;
	}

	.assistant-prompt-field:focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.assistant-prompt-field::placeholder {
		color: var(--text-3);
	}

	.block.danger {
		border: 1px solid var(--danger);
		border-radius: var(--r);
		padding: 14px 16px;
		background: var(--danger-weak);
	}

	/* --text-3 reads AA on plain surfaces but not on the danger tint; the
	   heading follows the shared DangerZone pattern (danger ink). */
	.danger h2 {
		color: var(--danger);
	}

	.danger-row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
	}

	.danger-label {
		font-size: 13px;
		color: var(--text-2);
	}

	.key-row {
		display: flex;
		align-items: flex-start;
		gap: 12px;
	}

	.key-status {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.key-line {
		display: flex;
		align-items: baseline;
		gap: 10px;
		font-size: 13px;
		color: var(--text);
	}

	.key-label {
		flex: none;
		width: 72px;
		font-size: 12px;
		color: var(--text-3);
	}

	.mono {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.key-muted {
		font-size: 12.5px;
		color: var(--text-3);
	}

	.key-actions {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		flex: none;
	}

	.key-error {
		font-size: 12.5px;
		color: var(--danger);
		margin: 10px 0 0;
	}
</style>
