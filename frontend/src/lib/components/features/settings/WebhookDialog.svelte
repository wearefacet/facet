<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import StringListEditor from '$lib/components/primitives/forms/StringListEditor.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { WebhookInput } from '$lib/webhooks/webhooks.js';
	import { resetOnOpen } from '$lib/utils/resetOnOpen.svelte.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * WebhookDialog — create / edit form for a `core.Webhook` document.
	 *
	 * Editable fields: `label`, `url`, `source_doctype`, `events`,
	 * `headers`. The server-stamped fields (`secret`, `account_id`,
	 * `role_id`) are read-only and never render here. The `events` field is
	 * tri-state on the backend — *absent* means all events, *empty* means
	 * none — so an "all events" toggle carries the absent state and the
	 * string list carries the named subset.
	 *
	 * `onsave` receives the wire payload; returning an error string shows it
	 * inline (backend 422s surface verbatim — e.g. an insecure target URL).
	 * The header editor keeps key/value rows; keys are validated against the
	 * HTTP token grammar and the `X-Facet-` authoring ban as a courtesy —
	 * the backend re-validates and rejects with a 422.
	 */

	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/** The stored content subset when editing, or null on a fresh create. */
		webhook = null as WebhookInput | null,
		/** Driver for the source-doctype picker (`core.DocType` search). */
		driver,
		onsave = (_input: WebhookInput) => Promise.resolve(null)
	}: {
		open?: boolean;
		webhook?: WebhookInput | null;
		driver: DataDriver;
		onsave?: (input: WebhookInput) => Promise<string | null>;
	} = $props();

	interface HeaderRow {
		key: string;
		value: string;
	}

	let label = $state('');
	let url = $state('');
	let sourceDoctype = $state('');
	let allEvents = $state(true);
	let events = $state([] as string[]);
	let headerRows = $state([] as HeaderRow[]);
	let errorMessage = $state<string | undefined>(undefined);
	let submitting = $state(false);

	// The target the form was last seeded for — guards the re-seed effect below
	// against clobbering user edits when `webhook` changes identity.
	let seededFor: WebhookInput | null | undefined;

	function seed() {
		errorMessage = undefined;
		submitting = false;
		label = webhook?.label ?? '';
		url = webhook?.url ?? '';
		sourceDoctype = webhook?.source_doctype ?? '';
		// Absent `events` = all events; present (even empty) = a named subset.
		allEvents = webhook ? webhook.events === undefined : true;
		events = webhook?.events ? [...webhook.events] : [];
		headerRows = Object.entries(webhook?.headers ?? {}).map(([key, value]) => ({ key, value }));
	}

	function reset() {
		seededFor = webhook;
		seed();
	}

	// Reset whenever the dialog opens, so every open shows a fresh form. A
	// programmatic `open = false` (a successful save, or Cancel) does not fire
	// Bits UI's `onOpenChange`, so a close-time reset would miss those paths and
	// leak the previous entry into the next open.
	resetOnOpen(() => open, reset);

	// Re-seed if the edit target changes while the dialog stays open.
	$effect(() => {
		if (!open || seededFor === webhook) return;
		seededFor = webhook;
		seed();
	});

	function addHeaderRow() {
		headerRows = [...headerRows, { key: '', value: '' }];
	}

	function removeHeaderRow(index: number) {
		headerRows = headerRows.filter((_, i) => i !== index);
	}

	function onHeaderKeyInput(index: number, raw: string) {
		headerRows = headerRows.map((row, i) => (i === index ? { ...row, key: raw } : row));
	}

	function onHeaderValueInput(index: number, raw: string) {
		headerRows = headerRows.map((row, i) => (i === index ? { ...row, value: raw } : row));
	}

	// Courtesy checks — the backend re-validates and rejects with a 422.
	// Keys must match the RFC 7230 token grammar and must not start with
	// `X-Facet-` (case-insensitive) — the dispatcher's mandate always wins.
	function headerKeyError(key: string): string | null {
		if (key === '') return null;
		if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(key)) return m.webhooks_header_key_error();
		if (/^x-facet-/i.test(key)) return m.webhooks_header_facet_error();
		return null;
	}

	const headerError = $derived(
		headerRows.map((row) => headerKeyError(row.key.trim())).find(Boolean)
	);

	const urlValid = $derived.by(() => {
		if (url.trim() === '') return false;
		try {
			const parsed = new URL(url.trim());
			return parsed.protocol === 'https:' || parsed.protocol === 'http:';
		} catch {
			return false;
		}
	});

	const valid = $derived(
		label.trim().length > 0 && urlValid && sourceDoctype !== '' && !headerError
	);

	async function handleSubmit() {
		if (!valid || submitting) return;
		submitting = true;
		errorMessage = undefined;
		const headers: Record<string, string> = {};
		for (const row of headerRows) {
			const key = row.key.trim();
			if (key !== '') headers[key] = row.value;
		}
		const err = await onsave({
			label: label.trim(),
			url: url.trim(),
			source_doctype: sourceDoctype,
			// Absent = all events. A deliberately empty list (none) is the
			// caller's choice — the editor expresses it as an empty subset.
			events: allEvents ? undefined : [...events],
			headers: Object.keys(headers).length > 0 ? headers : undefined
		});
		submitting = false;
		if (err) {
			errorMessage = err;
			return;
		}
		open = false;
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="webhook-dlg-overlay" />
		<Dialog.Content class="webhook-dlg-content">
			<Dialog.Title class="webhook-dlg-title">
				{webhook ? m.webhooks_edit_title() : m.webhooks_new_title()}
			</Dialog.Title>
			<Dialog.Description class="webhook-dlg-desc">
				{m.webhooks_new_helper()}
			</Dialog.Description>

			<form
				class="webhook-dlg-form"
				onsubmit={(e) => {
					e.preventDefault();
					handleSubmit();
				}}
			>
				<div class="field">
					<label class="field-label" for="webhook-label">{m.common_name()}</label>
					<input
						id="webhook-label"
						class="text-input"
						bind:value={label}
						placeholder={m.webhooks_label_placeholder()}
						autocomplete="off"
					/>
				</div>

				<div class="field">
					<label class="field-label" for="webhook-url">{m.webhooks_url_label()}</label>
					<input
						id="webhook-url"
						class="text-input mono"
						type="url"
						bind:value={url}
						placeholder="https://example.test/hooks/facet"
						autocomplete="off"
					/>
					<p class="hint">{m.webhooks_url_helper()}</p>
				</div>

				<div class="field">
					<ReferencePicker
						label={m.webhooks_source_label()}
						placeholder={m.webhooks_source_placeholder()}
						doctype="core.DocType"
						{driver}
						bind:value={sourceDoctype}
						helper={m.webhooks_source_helper()}
					/>
				</div>

				<div class="field">
					<Toggle label={m.webhooks_all_events_label()} bind:checked={allEvents} />
					<p class="hint">{m.webhooks_all_events_helper()}</p>
					{#if !allEvents}
						<div class="events-editor">
							<StringListEditor
								label={m.webhooks_events_label()}
								bind:values={events}
								placeholder={m.webhooks_events_placeholder()}
							/>
						</div>
					{/if}
				</div>

				<div class="field">
					<div class="headers-head">
						<span class="field-label">{m.webhooks_headers_label()}</span>
						<button class="add-header" type="button" onclick={addHeaderRow}>
							{m.webhooks_headers_add()}
						</button>
					</div>
					<p class="hint">{m.webhooks_headers_helper()}</p>
					{#if headerRows.length > 0}
						<div class="header-rows">
							{#each headerRows as row, i (i)}
								<div class="header-row">
									<input
										class="text-input mono header-key"
										aria-label={m.webhooks_header_key_label({ n: i + 1 })}
										value={row.key}
										oninput={(e) => onHeaderKeyInput(i, e.currentTarget.value)}
										placeholder="Authorization"
										autocomplete="off"
									/>
									<input
										class="text-input mono header-value"
										aria-label={m.webhooks_header_value_label({ n: i + 1 })}
										value={row.value}
										oninput={(e) => onHeaderValueInput(i, e.currentTarget.value)}
										placeholder="Bearer …"
										autocomplete="off"
									/>
									<button
										class="remove-header"
										type="button"
										aria-label={m.webhooks_headers_remove({ n: i + 1 })}
										onclick={() => removeHeaderRow(i)}
									>
										<X size={14} stroke-width={1.8} />
									</button>
								</div>
								{#if headerKeyError(row.key.trim())}
									<p class="row-error" role="alert">{headerKeyError(row.key.trim())}</p>
								{/if}
							{/each}
						</div>
					{/if}
				</div>

				<div class="actions">
					<button class="cancel-btn" type="button" onclick={() => (open = false)}
						>{m.common_cancel()}</button
					>
					<button class="save-btn" type="submit" disabled={!valid || submitting}>
						{submitting ? m.common_saving() : m.common_save()}
					</button>
				</div>
			</form>

			{#if errorMessage}
				<div class="err" role="alert">
					<p class="err-head">{errorMessage}</p>
				</div>
			{/if}

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.webhook-dlg-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.webhook-dlg-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(560px, 92vw);
		max-height: 86vh;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 101;
		padding: 24px;
		gap: 16px;
	}

	:global(.webhook-dlg-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.webhook-dlg-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.webhook-dlg-form {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.field {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.field-label {
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
	}

	.text-input {
		width: 100%;
		padding: 9px 11px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 13.5px;
	}

	.text-input.mono {
		font-family: var(--font-mono);
		font-size: 12.5px;
	}

	.text-input:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.hint {
		font-size: 11.5px;
		color: var(--text-3);
		margin: 0;
	}

	.events-editor {
		margin-top: 8px;
	}

	.headers-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
	}

	.add-header {
		font-size: 11.5px;
		font-weight: 600;
		color: var(--accent-ink);
		background: none;
		border: none;
		cursor: pointer;
		padding: 2px 4px;
		border-radius: var(--r);
	}

	.add-header:hover {
		background: var(--sunken);
	}

	.add-header:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.header-rows {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.header-row {
		display: grid;
		grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr) auto;
		gap: 6px;
		align-items: center;
	}

	.remove-header {
		width: 28px;
		height: 28px;
		display: grid;
		place-items: center;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text-3);
		cursor: pointer;
	}

	.remove-header:hover {
		color: var(--danger);
		border-color: var(--danger);
		background: var(--danger-weak);
	}

	.remove-header:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.row-error {
		font-size: 11.5px;
		color: var(--danger);
		margin: 0;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 4px;
	}

	.cancel-btn,
	.save-btn {
		padding: 6px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.cancel-btn {
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text);
	}

	.cancel-btn:hover {
		background: var(--sunken);
	}

	.save-btn {
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` is gold-on-light and
		   invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
	}

	.save-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.err {
		display: flex;
		flex-direction: column;
		gap: 6px;
		font-size: 13px;
		color: var(--danger);
		margin: 0;
		padding: 8px 10px;
		background: var(--danger-weak);
		border-radius: var(--r);
	}

	.err-head {
		margin: 0;
		font-weight: 600;
	}

	:global(.webhook-dlg-content .close-btn) {
		position: absolute;
		top: 14px;
		right: 14px;
		width: 28px;
		height: 28px;
		display: grid;
		place-items: center;
		border: none;
		border-radius: var(--r);
		background: none;
		color: var(--text-3);
		cursor: pointer;
	}

	:global(.webhook-dlg-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.webhook-dlg-content .close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
