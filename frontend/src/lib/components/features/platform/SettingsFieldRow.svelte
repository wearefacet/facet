<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Badge from '$lib/components/primitives/data/Badge.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import { RotateCcw } from '@lucide/svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * SettingsFieldRow — one row of the system-settings field grid.
	 *
	 * The parent (`SystemSettingsForm`) owns the state engine: the field
	 * registry, the patch assembly, the dirty tracking, and the secret
	 * staging. This component renders one row from its descriptor and
	 * sends every edit back to the parent:
	 *
	 * - `text` and `bool` are bindable. A binding writes the new value in
	 *   the parent's scope. This component never mutates a shared state
	 *   object directly (see the reactivity quirk in
	 *   doc/frontend/workflow.md).
	 * - `onSecretInput`, `onRetentionInput`, `onKeepForever`, `onReset`,
	 *   and `onUndoClear` are intents. The parent owns those transitions.
	 *
	 * The row carries its own status cluster: the override badge with the
	 * reset-to-file control, or the pending-reset badge with undo.
	 */

	/** One settings row: the parent owns the descriptor, this component renders it. */
	export type FieldRow = {
		path: string;
		label: string;
		kind: 'string' | 'number' | 'bool' | 'text' | 'secret' | 'adapter' | 'enum' | 'retention';
		/** Helper line under the control — states what the field does and what empty means. */
		helper: string;
		/** Option list for the `enum` and `adapter` kinds (value + display label). */
		options?: { value: string; label: string }[];
		/** Wide rows span both grid columns (textarea, adapter, behavior switches). */
		wide?: boolean;
	};

	let {
		row,
		text = $bindable(''),
		bool = $bindable(false),
		cleared = false,
		staged = false,
		pinned = false,
		stageError = null as string | null,
		onSecretInput,
		onRetentionInput,
		onKeepForever,
		onReset,
		onUndoClear
	}: {
		/** The field descriptor (path, label, kind, helper, options, wide). */
		row: FieldRow;
		/** The editable text value. Two-way bound to the parent's field state. */
		text?: string;
		/** The toggle value (the `bool` kind and the retention keep-forever). Two-way bound. */
		bool?: boolean;
		/** Set when the admin reset the field this session (pending explicit null). */
		cleared?: boolean;
		/** Set after Save staged the plaintext — `text` then holds the handle. */
		staged?: boolean;
		/** Set when the document pins an override for this path. */
		pinned?: boolean;
		/** The stage-error message for this row, when Save failed to stage it. */
		stageError?: string | null;
		/** Typing into a secret cancels a staged handle and a pending reset. */
		onSecretInput?: () => void;
		/** A retention input happened — typing a 0 flips the keep-forever toggle. */
		onRetentionInput?: () => void;
		/** The keep-forever toggle flipped — the binding already wrote `bool`. */
		onKeepForever?: () => void;
		/** Reset-to-file intent. */
		onReset?: () => void;
		/** Undo a pending reset. */
		onUndoClear?: () => void;
	} = $props();
</script>

<div class="field-row" class:wide={row.wide} data-path={row.path} data-pinned={pinned}>
	{#if row.kind === 'bool'}
		<Toggle label={row.label} bind:checked={bool} disabled={cleared} />
		<p class="field-helper">{row.helper}</p>
	{:else if row.kind === 'adapter'}
		<Select
			label={row.label}
			options={row.options ?? []}
			searchable={false}
			value={text}
			onValueChange={(v) => (text = v)}
			helper={row.helper}
		/>
	{:else if row.kind === 'enum'}
		<Select
			label={row.label}
			options={row.options ?? []}
			searchable={row.path === 'localization.default_timezone'}
			value={text}
			onValueChange={(v) => (text = v)}
			helper={row.helper}
		/>
	{:else if row.kind === 'text'}
		<label class="field-label" for={'field-' + row.path}>{row.label}</label>
		<textarea
			id={'field-' + row.path}
			class="text-input"
			rows="3"
			bind:value={text}
			disabled={cleared}></textarea>
		<p class="field-helper">{row.helper}</p>
	{:else if row.kind === 'secret'}
		<Input
			label={row.label}
			type="password"
			placeholder={pinned || staged
				? m.system_settings_secret_set()
				: m.system_settings_secret_unset()}
			bind:value={text}
			oninput={() => onSecretInput?.()}
		/>
		{#if stageError}
			<span class="stage-err" role="alert">{stageError}</span>
		{/if}
		<p class="field-helper">{row.helper}</p>
	{:else if row.kind === 'retention'}
		<div class="retention-line">
			<Input
				label={row.label}
				type="number"
				bind:value={text}
				disabled={cleared || bool}
				inputmode="numeric"
				helper={row.helper}
				oninput={() => onRetentionInput?.()}
			/>
			<span class="forever-toggle">
				<!-- The toggle stays enabled during a pending reset. Clicking it
				     on cancels the reset and pins 0 again. A disabled toggle also
				     fails the accessibility contrast scan — a known backlog item
				     on the primitive. -->
				<Toggle
					label={m.system_settings_keep_forever()}
					bind:checked={bool}
					onchange={() => onKeepForever?.()}
				/>
			</span>
		</div>
	{:else}
		<Input
			label={row.label}
			type={row.kind === 'number' ? 'number' : 'text'}
			bind:value={text}
			disabled={cleared}
			inputmode={row.kind === 'number' ? 'decimal' : undefined}
			helper={row.helper}
		/>
	{/if}

	{#if cleared}
		<div class="field-status">
			<Badge label={m.system_settings_reset_pending()} variant="warn" size="sm" />
			<button class="undo-btn" type="button" onclick={() => onUndoClear?.()}>
				{m.system_settings_undo()}
			</button>
		</div>
	{:else if pinned}
		<div class="field-status">
			<Badge label={m.system_settings_override_badge()} variant="accent" size="sm" />
			<button
				class="undo-btn"
				type="button"
				title={m.system_settings_reset_title()}
				onclick={() => onReset?.()}
			>
				<RotateCcw size={13} aria-hidden="true" />
				{m.system_settings_reset_to_file()}
			</button>
		</div>
	{/if}
</div>

<style>
	/* ── Field row ────────────────────────────────────────────── */

	.field-row {
		display: flex;
		flex-direction: column;
		gap: 5px;
		min-width: 0;
	}

	.field-row.wide {
		grid-column: 1 / -1;
	}

	/* ── Shared field chrome (matches Field.svelte) ───────────────────── */

	.field-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.field-helper {
		margin: 0;
		font-size: 11.5px;
		line-height: 1.45;
		color: var(--text-3);
	}

	.text-input {
		font-family: var(--font-sans);
		font-size: 13px;
		line-height: 1.5;
		padding: 9px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		resize: vertical;
	}

	.text-input:focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.text-input:disabled {
		opacity: 0.5;
		background: var(--surface-2);
	}

	/* ── Secret fields — inline stage error ─────────────────── */

	.stage-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	/* ── Status cluster — override badge, pending states ───────────────── */

	.field-status {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.undo-btn {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 4px 8px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text-2);
		font-size: 11.5px;
		cursor: pointer;
		white-space: nowrap;
	}

	.undo-btn:hover {
		background: var(--sunken);
		color: var(--text);
	}

	/* ── Keep-forever row (retention windows) ─────────── */

	.retention-line {
		display: flex;
		align-items: flex-start;
		gap: 16px;
	}

	/* The Input block renders label, control, helper. The toggle aligns
	   with the control, below the label line. */
	.forever-toggle {
		flex: none;
		margin-top: 27px;
	}

	@media (max-width: 760px) {
		.field-row.wide {
			grid-column: auto;
		}
	}
</style>
