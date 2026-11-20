<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Panel from '$lib/components/primitives/surfaces/Panel.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Badge from '$lib/components/primitives/data/Badge.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import { confirm } from '$lib/confirm.svelte';
	import { errorMessage as toMessage } from '$lib/datasource/bannerError.js';
	import {
		buildFormError,
		groupFieldErrors,
		joinFieldErrors,
		type FormError
	} from '$lib/doctype/fieldErrors.js';
	import { OidcProvidersError, type OidcProviderRow } from './OidcProvidersSource.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * OidcProviders — the admin list and editor for the `iam.OIDCProvider`
	 * documents: the provider table, the enable / disable toggles, the
	 * delete confirm, and the create / edit dialog.
	 *
	 * The page owns loading and the backend round-trips; they arrive as
	 * callback props. Save groups the ten form fields into one state
	 * object, stages a typed plaintext out-of-band through `onStageSecret`,
	 * and sends the single-use handle to `onCreate` / `onUpdate` — the
	 * plaintext never enters a document body. A `422` maps to per-field
	 * errors; a failed save keeps the dialog open. Toggle and delete
	 * failures show on the page banner. The Create button lives in the
	 * page header; the page opens the dialog through `openCreate()` and
	 * `bind:this`.
	 */

	let {
		rows = [] as OidcProviderRow[],
		loading = false,
		onCreate,
		onUpdate,
		onStageSecret,
		onToggle,
		onDelete,
		onChanged
	}: {
		/** Provider rows as loaded by the page. */
		rows?: OidcProviderRow[];
		/** True while the page lists the providers. */
		loading?: boolean;
		/** Creates one provider. Throws on failure — the dialog maps the error. */
		onCreate: (fields: Record<string, unknown>) => Promise<void>;
		/** Sparse-updates one provider. Throws on failure — the dialog maps the error. */
		onUpdate: (id: string, fields: Record<string, unknown>) => Promise<void>;
		/** Stages one plaintext and returns the single-use handle. Throws on failure. */
		onStageSecret: (value: string) => Promise<string>;
		/** Flips one provider's enabled flag. Failure shows on the page banner. */
		onToggle: (row: OidcProviderRow) => Promise<void>;
		/** Deletes one confirmed provider. Failure shows on the page banner. */
		onDelete: (row: OidcProviderRow) => Promise<void>;
		/** Runs after a successful create or update — the page re-reads the list. */
		onChanged: () => void;
	} = $props();

	// ── Editor dialog state ─────────────────────────────────────────────
	type EditorMode =
		| { kind: 'closed' }
		| { kind: 'create' }
		| { kind: 'edit'; row: OidcProviderRow };
	let editor = $state<EditorMode>({ kind: 'closed' });
	let saving = $state(false);
	let formError = $state<FormError | undefined>(undefined);
	let fieldErrors = $state<Record<string, string>>({});
	let togglingId = $state<string | null>(null);

	/**
	 * The ten editor fields in one object. List fields (domains, scopes)
	 * hold comma-separated text and split at save. The secret holds the
	 * typed plaintext until Save stages it.
	 */
	interface OidcProviderForm {
		/** URL slug. Fixed after create. */
		name: string;
		label: string;
		issuer: string;
		clientId: string;
		secret: string;
		domains: string;
		/** Default role id. Empty = unset. */
		role: string;
		autoProvision: boolean;
		scopes: string;
		enabled: boolean;
	}

	function emptyForm(): OidcProviderForm {
		return {
			name: '',
			label: '',
			issuer: '',
			clientId: '',
			secret: '',
			domains: '',
			role: '',
			autoProvision: false,
			scopes: '',
			enabled: true
		};
	}

	let form = $state<OidcProviderForm>(emptyForm());

	/** Opens the create dialog. The page calls it through `bind:this`. */
	export function openCreate() {
		form = emptyForm();
		formError = undefined;
		fieldErrors = {};
		editor = { kind: 'create' };
	}

	function openEdit(row: OidcProviderRow) {
		form = {
			name: row.name,
			label: row.label ?? '',
			issuer: row.issuer ?? '',
			clientId: row.client_id ?? '',
			secret: '',
			domains: (row.domains ?? []).join(', '),
			role: row.default_role ?? '',
			autoProvision: row.auto_provision === true,
			scopes: (row.scopes ?? []).join(', '),
			enabled: row.enabled !== false
		};
		formError = undefined;
		fieldErrors = {};
		editor = { kind: 'edit', row };
	}

	function closeEditor() {
		if (saving) return;
		editor = { kind: 'closed' };
	}

	/** Comma-separated text → trimmed, lowercase, empty-entry-free list. */
	function splitList(raw: string): string[] {
		return raw
			.split(',')
			.map((entry) => entry.trim().toLowerCase())
			.filter((entry) => entry.length > 0);
	}

	function applyFieldErrors(e: OidcProvidersError) {
		const grouped = groupFieldErrors(e.fieldErrors);
		const map: Record<string, string> = {};
		for (const field of Object.keys(grouped.fieldErrors)) {
			const joined = joinFieldErrors(grouped.fieldErrors, field);
			if (joined) map[field] = joined;
		}
		fieldErrors = map;
		// Field-less details (e.g. the Lua issuer rule) have no input to attach
		// to — they render under the headline instead of being dropped.
		formError = buildFormError(e.message, grouped);
	}

	async function save() {
		if (!editor || editor.kind === 'closed') return;
		saving = true;
		formError = undefined;
		fieldErrors = {};
		try {
			const fields: Record<string, unknown> = {
				label: form.label.trim() || undefined,
				issuer: form.issuer.trim(),
				client_id: form.clientId.trim(),
				domains: splitList(form.domains),
				auto_provision: form.autoProvision,
				scopes: splitList(form.scopes),
				enabled: form.enabled
			};
			if (form.role.trim()) fields.default_role = form.role.trim();

			// The secret stages out-of-band; only a typed plaintext is sent
			// (as a handle). An untouched secret field stays out of the body,
			// so an edit keeps the stored slot.
			if (form.secret !== '') {
				const handle = await onStageSecret(form.secret);
				fields.client_secret = handle;
			}

			if (editor.kind === 'create') {
				fields.name = form.name.trim();
				await onCreate(fields);
			} else {
				await onUpdate(editor.row.id, fields);
			}
			editor = { kind: 'closed' };
			onChanged();
		} catch (e) {
			if (e instanceof OidcProvidersError) {
				applyFieldErrors(e);
			} else {
				formError = { message: toMessage(e, m.configure_oidc_save_fallback()), details: [] };
			}
		} finally {
			saving = false;
		}
	}

	async function toggleEnabled(row: OidcProviderRow) {
		togglingId = row.id;
		try {
			await onToggle(row);
		} finally {
			togglingId = null;
		}
	}

	async function remove(row: OidcProviderRow) {
		const ok = await confirm({
			title: m.configure_oidc_delete_title({ name: row.label || row.name }),
			message: m.configure_oidc_delete_message(),
			confirmLabel: m.common_delete()
		});
		if (!ok) return;
		await onDelete(row);
	}
</script>

<Panel>
	{#if loading}
		<p class="hint">{m.common_loading()}</p>
	{:else if rows.length === 0}
		<p class="hint">{m.configure_oidc_empty()}</p>
	{:else}
		<table class="provider-table">
			<thead>
				<tr>
					<th>{m.configure_oidc_col_provider()}</th>
					<th>{m.configure_oidc_col_issuer()}</th>
					<th>{m.configure_oidc_col_domains()}</th>
					<th>{m.configure_oidc_col_state()}</th>
					<th class="col-actions"><span class="visually-hidden">Actions</span></th>
				</tr>
			</thead>
			<tbody>
				{#each rows as row (row.id)}
					<tr>
						<td>
							<span class="p-label">{row.label || row.name}</span>
							{#if row.auto_provision}
								<Badge label={m.configure_oidc_jit_badge()} variant="accent" size="sm" />
							{/if}
							<span class="p-name">/{row.name}</span>
						</td>
						<td class="p-issuer">{row.issuer}</td>
						<td class="p-domains">{(row.domains ?? []).join(', ') || '—'}</td>
						<td>
							<Toggle
								label={m.configure_oidc_enabled()}
								checked={row.enabled !== false}
								disabled={togglingId === row.id}
								onchange={() => void toggleEnabled(row)}
							/>
						</td>
						<td class="col-actions">
							<button class="row-btn" type="button" onclick={() => openEdit(row)}>
								{m.common_edit()}
							</button>
							<button class="row-btn danger" type="button" onclick={() => void remove(row)}>
								{m.common_delete()}
							</button>
						</td>
					</tr>
				{/each}
			</tbody>
		</table>
	{/if}
</Panel>

{#if editor.kind !== 'closed'}
	<div
		class="dialog-overlay"
		role="presentation"
		onclick={closeEditor}
		onkeydown={(e) => {
			if (e.key === 'Escape') closeEditor();
		}}
		tabindex="-1"
	>
		<div
			class="dialog"
			role="dialog"
			aria-modal="true"
			tabindex="0"
			aria-label={editor.kind === 'create'
				? m.configure_oidc_create()
				: m.configure_oidc_edit_title()}
			onclick={(e) => e.stopPropagation()}
			onkeydown={(e) => e.stopPropagation()}
		>
			<h2 class="dialog-title">
				{editor.kind === 'create' ? m.configure_oidc_create() : m.configure_oidc_edit_title()}
			</h2>

			{#if formError}
				<div class="form-error" role="alert">
					<p class="form-error-headline">{formError.message}</p>
					{#if formError.details.length > 0}
						<ul class="form-error-details">
							{#each formError.details as detail (detail)}
								<li>{detail}</li>
							{/each}
						</ul>
					{/if}
				</div>
			{/if}

			<div class="form-grid">
				<Input
					label={m.configure_oidc_field_name()}
					bind:value={form.name}
					disabled={editor.kind === 'edit' || saving}
					helper={editor.kind === 'edit'
						? m.configure_oidc_name_immutable()
						: m.configure_oidc_field_name_helper()}
					error={fieldErrors['name']}
				/>
				<Input
					label={m.configure_oidc_field_label()}
					bind:value={form.label}
					disabled={saving}
					error={fieldErrors['label']}
				/>
				<Input
					label={m.configure_oidc_field_issuer()}
					bind:value={form.issuer}
					disabled={saving}
					error={fieldErrors['issuer']}
				/>
				<Input
					label={m.configure_oidc_field_client_id()}
					bind:value={form.clientId}
					disabled={saving}
					error={fieldErrors['client_id']}
				/>
				<Input
					label={m.configure_oidc_field_secret()}
					type="password"
					placeholder={editor.kind === 'edit'
						? m.configure_oidc_secret_set()
						: m.configure_oidc_secret_unset()}
					bind:value={form.secret}
					disabled={saving}
					helper={m.configure_oidc_field_secret_helper()}
					error={fieldErrors['client_secret']}
				/>
				<Input
					label={m.configure_oidc_field_domains()}
					bind:value={form.domains}
					disabled={saving}
					helper={m.configure_oidc_field_domains_helper()}
					error={fieldErrors['domains']}
				/>
				<Input
					label={m.configure_oidc_field_role()}
					bind:value={form.role}
					disabled={saving}
					helper={m.configure_oidc_field_role_helper()}
					error={fieldErrors['default_role']}
				/>
				<Input
					label={m.configure_oidc_field_scopes()}
					bind:value={form.scopes}
					disabled={saving}
					helper={m.configure_oidc_field_scopes_helper()}
					error={fieldErrors['scopes']}
				/>
				<Toggle
					label={m.configure_oidc_field_auto_provision()}
					bind:checked={form.autoProvision}
					disabled={saving}
				/>
				<Toggle label={m.configure_oidc_enabled()} bind:checked={form.enabled} disabled={saving} />
			</div>

			<div class="dialog-foot">
				<Button label={m.common_cancel()} onclick={closeEditor} disabled={saving} />
				<Button
					label={saving ? m.common_loading() : m.common_save()}
					onclick={() => void save()}
					variant="primary"
					disabled={saving}
				/>
			</div>
		</div>
	</div>
{/if}

<style>
	.hint {
		font-size: 13px;
		color: var(--text-3);
		margin: 8px 0;
	}

	.provider-table {
		width: 100%;
		border-collapse: collapse;
		font-size: 13px;
	}

	.provider-table th {
		text-align: left;
		font-size: 11px;
		font-weight: 600;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.06em;
		padding: 8px 12px;
		border-bottom: 1px solid var(--border);
	}

	.provider-table td {
		padding: 10px 12px;
		border-bottom: 1px solid var(--border);
		vertical-align: middle;
	}

	.col-actions {
		text-align: right;
		white-space: nowrap;
	}

	.p-label {
		font-weight: 600;
		margin-right: 8px;
	}

	.p-name {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
		margin-left: 8px;
	}

	.p-issuer,
	.p-domains {
		font-size: 12px;
		color: var(--text-2);
	}

	.row-btn {
		font-size: 12px;
		color: var(--accent-ink);
		background: none;
		border: none;
		cursor: pointer;
		padding: 4px 6px;
	}

	.row-btn:hover {
		text-decoration: underline;
	}

	.row-btn.danger {
		color: var(--danger);
	}

	.dialog-overlay {
		position: fixed;
		inset: 0;
		background: rgb(0 0 0 / 0.45);
		display: grid;
		place-items: center;
		z-index: 60;
		padding: 24px;
	}

	.dialog {
		width: 560px;
		max-width: 100%;
		max-height: 90vh;
		overflow-y: auto;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-3);
		padding: 24px;
	}

	.dialog-title {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0 0 16px;
	}

	.form-error {
		font-size: 12.5px;
		color: var(--danger);
		background: var(--danger-weak);
		border-radius: var(--r-sm);
		padding: 8px 10px;
		margin: 0 0 12px;
	}

	.form-error-headline {
		margin: 0;
	}

	.form-error-details {
		margin: 4px 0 0;
		padding-left: 18px;
	}

	.form-grid {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.dialog-foot {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 20px;
	}

	.visually-hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
</style>
