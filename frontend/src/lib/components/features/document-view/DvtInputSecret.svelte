<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { FieldStageRegistrar } from './fieldStage.js';
	import type { InputSecretNode, SecretStagePayload } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import { asSecretMarker } from '$lib/doctype/types.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import Badge from '$lib/components/primitives/data/Badge.svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';

	let {
		template,
		document,
		values,
		fieldErrors,
		def,
		stageSecret,
		registerFieldStage,
		...rest
	}: {
		/** The input-secret template node. */
		template: InputSecretNode;
		/** The full document response — the existing marker is read from here. */
		document: DocumentResponse;
		/** Mutable form values bag — the stage handle is written here on staging. */
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment. */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — provides the field's declared stage mode. */
		def?: DoctypeDef;
		/**
		 * Injectable stager — receives the stage payload and returns
		 * `{ handle, token? }`. Defaults to a `POST /Api/secrets/stage` call
		 * via `apiFetch`. Stories pass a synthetic stager so the play function
		 * can assert the staged handle without a live backend.
		 */
		stageSecret?: (payload: SecretStagePayload) => Promise<{ handle: string; token?: string }>;
		/**
		 * Registration for in-flight stage work (B-191). Called once per stage
		 * attempt with the owning field path and a promise that settles when the
		 * attempt lands (resolve) or fails (reject). The form awaits every
		 * registered promise before it diffs, so a save never races the stage
		 * round-trip and a failed stage stops the save loudly.
		 */
		registerFieldStage?: FieldStageRegistrar;
	} = $props();

	const content = $derived(getDocContent(document));
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	const error = $derived(joinFieldErrors(fieldErrors, fieldTop));

	// The persisted marker, read from the document content. The plaintext is
	// never present in content — only this `{mode, version, set_at}` object.
	const existingMarker = $derived(asSecretMarker(content[template.field]));

	// The field's stage mode, resolved from the doctype definition. When the
	// definition lost it (B-124: the presenter could drop `mode`), the stored
	// marker's mode wins — it records the mode the value was staged under, so
	// the status badge and the Change/Generate behaviour stay truthful. An
	// unset `mode` everywhere means `hash` — the backend applies the same
	// default.
	const fieldDef = $derived(fieldDefFor(def, fieldTop));
	const mode = $derived(fieldDef?.mode ?? existingMarker?.mode ?? 'hash');
	const isTokenMode = $derived(mode === 'token');

	// On init, strip any existing marker object from the form values. An
	// unchanged save must send nothing for the field — resubmitting the marker
	// would make the backend treat it as new content. After the strip, the
	// field only re-enters the bag as a fresh stage handle (or `null` on clear).
	// svelte-ignore state_referenced_locally — intentional one-time strip of
	// the persisted marker from the initial bag; the bag is then owned by the
	// form session (stage / clear writes only).
	if (values && asSecretMarker(values[template.field])) {
		delete values[template.field];
	}

	// Staging state. `draft` is the only place the plaintext exists, and it is
	// cleared the moment the stage call resolves — the component never renders
	// it, logs it, or keeps it past the round-trip.
	let revealed = $state(false);
	let draft = $state('');
	let staging = $state(false);
	let stageError = $state<string | null>(null);
	let stagedNow = $state(false);
	let cleared = $state(false);
	let oneTimeToken = $state<string | null>(null);

	// The status row (badge + actions) shows for a field that already carries
	// a value in the document, or one staged during this form session. A
	// pending clear suppresses the document's stored marker — the save will
	// drop it.
	const hasValue = $derived((existingMarker !== null && !cleared) || stagedNow);

	async function sendStage(
		extra: { value?: string } = {}
	): Promise<{ handle: string; token?: string }> {
		const payload: SecretStagePayload = {
			domain: document.meta.domain,
			doctype: document.meta.doc_type,
			field_path: template.field
		};
		if (extra.value !== undefined) payload.value = extra.value;
		if (document.meta.id) payload.doc_id = document.meta.id;
		if (stageSecret) return stageSecret(payload);
		const { apiFetch } = await import('$lib/session.svelte');
		const res = await apiFetch('/Api/secrets/stage', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(payload)
		});
		if (!res.ok) {
			const body = await res.json().catch(() => ({}) as { error?: string });
			throw new Error((body as { error?: string }).error ?? `Staging failed (${res.status})`);
		}
		return (await res.json()) as { handle: string; token?: string };
	}

	/**
	 * Shared stage runner. Sets the widget state from the outcome and
	 * rethrows on failure so the promise the form registered rejects and the
	 * save fails loudly (B-191).
	 */
	async function runStage(extra: { value?: string } = {}): Promise<void> {
		if (!values) return;
		try {
			const result = await sendStage(extra);
			values[template.field] = result.handle;
			oneTimeToken = result.token ?? null;
			stagedNow = true;
			if (extra.value !== undefined) draft = '';
		} catch (err) {
			stageError = errorMessage(err, m.doc_secret_stage_failed());
			throw err;
		} finally {
			staging = false;
		}
	}

	/** Stage the typed plaintext (hash / sealed modes). Registers the
	 * in-flight promise with the form (B-191). */
	function stageDraft(): void {
		if (!values || staging || !draft) return;
		staging = true;
		stageError = null;
		stagedNow = false;
		cleared = false;
		// The stage runs whether or not a registrar is wired — optional
		// chaining would skip the argument evaluation with it.
		const stage = runStage({ value: draft });
		registerFieldStage?.(template.field, stage);
	}

	/** Ask the backend to generate a one-time token (token mode). Registers
	 * the in-flight promise with the form (B-191). */
	function stageToken(): void {
		if (!values || staging) return;
		staging = true;
		stageError = null;
		stagedNow = false;
		cleared = false;
		const stage = runStage();
		registerFieldStage?.(template.field, stage);
	}

	function onDraftChange(event: Event): void {
		draft = (event.target as HTMLInputElement).value;
		stageDraft();
	}

	function reveal(): void {
		revealed = true;
		stageError = null;
	}

	/** Clear drops the staged handle — the save sends `null` for the field. */
	function clearValue(): void {
		if (!values) return;
		values[template.field] = null;
		revealed = false;
		draft = '';
		oneTimeToken = null;
		stagedNow = false;
		cleared = true;
		stageError = null;
		// The clear is the field's latest stage state (B-191): register a
		// resolved stage so it supersedes a failed attempt and the save
		// proceeds with the cleared value. The action buttons are disabled
		// while a stage is in flight, so this never races a live stage.
		registerFieldStage?.(template.field, Promise.resolve());
	}
</script>

<div class="dvt-input-secret" {...rest}>
	{#if values}
		{#if template.label && !isTokenMode}
			<label class="dvt-input-secret-label" for="secret-{template.field}">
				{template.label}{template.required ? ' *' : ''}
			</label>
		{:else if template.label}
			<span class="dvt-input-secret-label">{template.label}</span>
		{/if}
		{#if hasValue}
			<div class="dvt-input-secret-status">
				<Badge label={m.common_marker_set_badge({ mode })} />
				{#if isTokenMode}
					<button class="dvt-input-secret-act" onclick={stageToken} disabled={staging}
						>{m.doc_secret_generate_new()}</button
					>
				{:else}
					<button class="dvt-input-secret-act" onclick={reveal} disabled={staging}
						>{m.doc_secret_change()}</button
					>
				{/if}
				<button class="dvt-input-secret-act" onclick={clearValue} disabled={staging}
					>{m.common_clear()}</button
				>
			</div>
		{:else if !isTokenMode && !revealed}
			<div class="dvt-input-secret-status">
				<button class="dvt-input-secret-act" onclick={reveal}>{m.doc_secret_set()}</button>
			</div>
		{:else if isTokenMode}
			<div class="dvt-input-secret-status">
				<button class="dvt-input-secret-act" onclick={stageToken} disabled={staging}>
					{staging ? m.doc_secret_generating() : m.doc_secret_generate()}
				</button>
			</div>
		{/if}
		{#if revealed && !isTokenMode}
			<input
				id="secret-{template.field}"
				class="dvt-input-secret-field"
				class:dvt-input-secret-field-err={error || stageError}
				type="password"
				placeholder={template.placeholder ?? m.doc_secret_enter()}
				autocomplete="new-password"
				value={draft}
				onchange={onDraftChange}
				aria-invalid={error || stageError ? true : undefined}
				disabled={staging}
			/>
			{#if template.helper && !error && !stageError}
				<span class="dvt-input-secret-helper">{template.helper}</span>
			{/if}
		{/if}
		{#if oneTimeToken}
			<div class="dvt-input-secret-token">
				<code class="dvt-input-secret-token-value">{oneTimeToken}</code>
				<CopyButton
					value={oneTimeToken}
					variant="ghost"
					size="sm"
					label={m.common_copy()}
					copiedLabel={m.common_copied()}
					title={m.doc_secret_copy_title()}
				/>
			</div>
			<span class="dvt-input-secret-helper">{m.doc_secret_once_helper()}</span>
		{/if}
		{#if staging && !isTokenMode}
			<span class="dvt-input-secret-status-text">{m.doc_secret_staging()}</span>
		{/if}
		{#if error}
			<span class="dvt-input-secret-err" role="alert">{error}</span>
		{:else if stageError}
			<span class="dvt-input-secret-err" role="alert">{stageError}</span>
		{/if}
	{:else}
		{#if template.label}
			<span class="dvt-input-secret-label">{template.label}</span>
		{/if}
		<div class="dvt-input-secret-readonly">
			{#if existingMarker}
				<Badge label={m.common_marker_set_badge({ mode: existingMarker.mode })} />
			{:else}
				<span>—</span>
			{/if}
		</div>
	{/if}
</div>

<style>
	.dvt-input-secret {
		display: flex;
		flex-direction: column;
		gap: 5px;
		padding: 4px 0;
	}

	.dvt-input-secret-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.dvt-input-secret-status {
		display: flex;
		align-items: center;
		gap: 9px;
		min-height: 30px;
	}

	.dvt-input-secret-act {
		font-size: 12px;
		font-weight: 500;
		color: var(--text-2);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 5px 10px;
		cursor: pointer;
		transition:
			border-color 0.12s,
			color 0.12s;
	}

	.dvt-input-secret-act:hover:not(:disabled) {
		border-color: var(--accent);
		color: var(--text);
	}

	.dvt-input-secret-act:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.dvt-input-secret-field {
		font-family: var(--font-mono);
		font-size: 13px;
		padding: 9px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.dvt-input-secret-field:focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.dvt-input-secret-field-err {
		border-color: var(--danger);
	}

	.dvt-input-secret-field-err:focus {
		border-color: var(--danger);
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	.dvt-input-secret-token {
		display: flex;
		align-items: center;
		gap: 9px;
	}

	.dvt-input-secret-token-value {
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		background: var(--sunken);
		border-radius: var(--r);
		padding: 5px 9px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		max-width: 320px;
	}

	.dvt-input-secret-status-text {
		font-size: 12px;
		color: var(--text-3);
	}

	.dvt-input-secret-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.dvt-input-secret-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	.dvt-input-secret-readonly {
		font-size: 13px;
		color: var(--text-3);
		padding: 2px 0;
	}
</style>
