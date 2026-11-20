<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import ColorInput from '../../primitives/forms/ColorInput.svelte';
	import Select from '../../primitives/forms/Select.svelte';
	import DangerZone from '../../primitives/surfaces/DangerZone.svelte';
	import type { IconPicker } from '$lib/doctype/iconPicker.svelte.js';
	import type { ExportedFn } from '$lib/doctype/lua-symbols.js';
	import * as m from '$lib/paraglide/messages';

	let {
		name,
		label = $bindable(''),
		pluralLabel = $bindable(''),
		domain,
		qualifiedName,
		schemaVersion = $bindable(),
		migrations = $bindable(),
		exportedSymbols = [],
		color = $bindable(''),
		icon = $bindable(''),
		description = $bindable(),
		picker,
		metadataEditable = false,
		readonly = false,
		deleting = false,
		deleteError,
		ondelete
	}: {
		/** Doctype machine name — identity, shown read-only. */
		name: string;
		/** Human display label; empty falls back to `name` everywhere. */
		label?: string;
		/** Human plural noun for consent screens; empty falls back to a naive
		 *  pluraliser on the doctype name. */
		pluralLabel?: string;
		/** Domain id — shown read-only. */
		domain: string;
		/** Qualified name the danger zone's type-to-confirm gate checks. */
		qualifiedName: string;
		schemaVersion?: number;
		/** Schema migration map (source version → Lua function name); the parent
		 *  owns the working copy and coalesces it to `{}`. */
		migrations?: Record<string, string>;
		/** Functions the Lua script exports — the client-side mirror of the
		 *  backend `ScriptValidator` rule for migration entries. */
		exportedSymbols?: ExportedFn[];
		/** Accent color; the parent coerces the working copy to '' so the
		 *  `$bindable` fallback of `ColorInput` never sees undefined. */
		color?: string;
		/** Stored Lucide icon name (parent coerces to ''). */
		icon?: string;
		description?: string;
		/** Icon-picker state machine from the parent's `createIconPicker()`. */
		picker: IconPicker;
		/** When true, the presentation fields (label, plural label, color, icon,
		 *  description) are editable. Shape fields (schema version, migrations,
		 *  danger zone) follow `readonly` — they always need a draft. */
		metadataEditable?: boolean;
		readonly?: boolean;
		/** Set while the delete request is in flight. */
		deleting?: boolean;
		/** Failure message from the last delete attempt. */
		deleteError?: string;
		ondelete: () => void;
	} = $props();

	// ── Migrations ────────────────────────────────────────────────────
	// The map keys are source schema versions: a document at version N runs
	// `migrations[N]` to reach N+1, so the entries must be functions the
	// script exports. Rows sort by numeric version — string order puts `10`
	// before `2`.
	const migrationRows = $derived(
		Object.entries(migrations ?? {}).sort(([a], [b]) => Number(a) - Number(b))
	);

	const exportedNames = $derived(new Set(exportedSymbols.map((s) => s.name)));

	/** The backend `ScriptValidator` rule, client-side: an entry must name a
	 *  function the script exports. */
	function migrationExported(fn: string): boolean {
		return fn !== '' && exportedNames.has(fn);
	}

	function setMigrationFn(version: string, value: string) {
		if (readonly || !migrations) return;
		migrations[version] = value;
	}

	/** First free source version below the schema version; when all are
	 *  taken, continue above the highest declared one. */
	function nextMigrationVersion(): string {
		const sv = Math.trunc(schemaVersion ?? 1);
		for (let v = sv - 1; v >= 1; v -= 1) {
			if (migrations?.[String(v)] === undefined) return String(v);
		}
		const declared = Object.keys(migrations ?? {})
			.map(Number)
			.filter((n) => Number.isFinite(n));
		return declared.length > 0 ? String(Math.max(...declared) + 1) : String(sv);
	}

	function addMigration() {
		if (readonly || !migrations) return;
		migrations[nextMigrationVersion()] = '';
	}

	function deleteMigration(version: string) {
		if (readonly || !migrations) return;
		delete migrations[version];
	}

	/** Commit a renamed source version on change. A non-numeric, empty, or
	 *  already-taken name resets the field to the old version. */
	function renameMigration(e: Event, oldVersion: string) {
		if (readonly || !migrations) return;
		const input = e.currentTarget as HTMLInputElement;
		const next = input.value.replace(/[^0-9]/g, '');
		if (next === '' || next === oldVersion || migrations[next] !== undefined) {
			input.value = oldVersion;
			return;
		}
		migrations[next] = migrations[oldVersion] ?? '';
		delete migrations[oldVersion];
	}
</script>

<div class="scrollpane">
	<div class="maxw">
		<div class="fsec" style="max-width:none">
			<h4>{m.configure_identity_title()}</h4>
			<div class="grid2">
				<div class="f">
					<label for="dt-name">{m.common_name()}</label><input
						id="dt-name"
						class="inp mono"
						value={name}
						readonly
					/>
				</div>
				<div class="f">
					<label for="dt-label">{m.configure_label_label()}</label><input
						id="dt-label"
						class="inp"
						bind:value={label}
						placeholder={name}
						disabled={!metadataEditable}
					/>
					{#if !label.trim()}
						<span class="lbl-hint">{m.configure_label_helper({ name })}</span>
					{/if}
				</div>
				<div class="f">
					<label for="dt-plural">{m.configure_plural_label_label()}</label><input
						id="dt-plural"
						class="inp"
						bind:value={pluralLabel}
						placeholder={name}
						disabled={!metadataEditable}
					/>
					{#if !pluralLabel.trim()}
						<span class="lbl-hint">{m.configure_plural_label_helper()}</span>
					{/if}
				</div>
				<div class="f">
					<label for="dt-domain">{m.configure_doctypes_domain_label()}</label><input
						id="dt-domain"
						class="inp mono"
						value={domain}
						readonly
					/>
				</div>
				<div class="f">
					<label for="dt-schema">{m.configure_doctypes_schema_label()}</label><input
						id="dt-schema"
						class="inp mono"
						type="number"
						bind:value={schemaVersion}
						disabled={readonly}
					/>
				</div>
				<div class="f">
					<ColorInput
						label={m.configure_color_label()}
						bind:value={color}
						placeholder="#c89329"
						disabled={!metadataEditable}
					/>
				</div>
				<div class="f">
					<Select
						label={m.configure_doctypes_icon_label()}
						placeholder={m.configure_doctypes_icon_placeholder()}
						bind:value={icon}
						results={picker.results}
						onsearch={picker.search}
						onviewportscroll={picker.onMenuScroll}
						disabled={!metadataEditable}
						helper={icon ? '' : m.configure_doctypes_icon_helper()}
					/>
				</div>
				<div class="f wide">
					<label for="dt-desc">{m.common_description()}</label>
					<textarea
						id="dt-desc"
						class="inp textarea"
						rows="2"
						bind:value={description}
						disabled={!metadataEditable}></textarea>
				</div>
			</div>
		</div>
		<div class="fsec" style="max-width:none">
			<h4>{m.configure_doctypes_migrations_title()}</h4>
			{#each migrationRows as [version, fn] (version)}
				<div class="mig-row">
					<div class="f">
						<label for="mig-v-{version}">{m.configure_doctypes_migration_version_label()}</label>
						<input
							id="mig-v-{version}"
							class="inp mono"
							value={version}
							onchange={(e) => renameMigration(e, version)}
							disabled={readonly}
							inputmode="numeric"
						/>
					</div>
					<div class="f">
						<label for="mig-fn-{version}">{m.configure_doctypes_migration_function_label()}</label>
						<input
							id="mig-fn-{version}"
							class="inp mono"
							value={fn}
							oninput={(e) => setMigrationFn(version, (e.currentTarget as HTMLInputElement).value)}
							disabled={readonly}
						/>
						{#if !migrationExported(fn)}
							<span class="mig-err">{m.configure_doctypes_migration_not_exported()}</span>
						{/if}
					</div>
					{#if !readonly}
						<button
							class="btn sm ghost del-btn"
							aria-label={m.configure_doctypes_migration_delete_aria()}
							onclick={() => deleteMigration(version)}
						>
							<svg
								width="15"
								height="15"
								viewBox="0 0 24 24"
								fill="none"
								stroke="currentColor"
								stroke-width="1.8"
							>
								<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6" />
							</svg>
						</button>
					{/if}
				</div>
			{/each}
			{#if !readonly}
				<button class="addbtn" onclick={addMigration}>
					<svg
						width="15"
						height="15"
						fill="none"
						stroke="currentColor"
						stroke-width="2"
						viewBox="0 0 24 24"
					>
						<path d="M12 5v14M5 12h14" />
					</svg>
					{m.configure_doctypes_migration_add()}
				</button>
			{/if}
			<p class="mig-note">{m.configure_doctypes_migrations_helper()}</p>
		</div>
		{#if !readonly}
			<DangerZone
				title={m.configure_danger_zone_title()}
				warning={m.configure_doctypes_danger_helper({ doctype: name })}
				confirmTarget={qualifiedName}
				confirmLabel={m.configure_doctypes_delete_button()}
				busy={deleting}
				error={deleteError}
				onconfirm={ondelete}
			/>
		{/if}
	</div>
</div>

<style>
	.scrollpane {
		overflow: auto;
		height: 100%;
	}

	.maxw {
		max-width: 720px;
		padding: 20px 24px;
	}

	.fsec {
		margin-bottom: 24px;
		max-width: 620px;
	}
	.fsec h4 {
		font-size: 11px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
		margin: 0 0 13px;
		padding-bottom: 7px;
		border-bottom: 1px solid var(--border);
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.grid2 {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 15px 18px;
	}
	.f {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}
	.lbl-hint {
		font-size: 11.5px;
		color: var(--text-3);
	}
	.f.wide {
		grid-column: 1 / -1;
	}
	.f label {
		font-size: 12.5px;
		font-weight: 600;
	}
	.inp {
		padding: 8px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		font: inherit;
		font-size: 13px;
		color: var(--text);
		width: 100%;
	}
	.inp.mono {
		font-family: var(--font-mono);
	}
	.inp:disabled {
		opacity: 0.55;
		cursor: not-allowed;
	}
	.textarea {
		resize: vertical;
		font-family: var(--font-sans);
		line-height: 1.5;
	}

	.mig-row {
		display: flex;
		align-items: flex-start;
		gap: 12px;
		padding: 10px 0;
		border-bottom: 1px solid var(--border);
	}
	.mig-row:last-of-type {
		border-bottom: none;
	}
	.mig-row .f {
		flex: 1;
	}
	.mig-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	.btn {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 8px 13px;
		border-radius: var(--r);
		font-size: 13px;
		font-weight: 600;
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		cursor: pointer;
		font: inherit;
	}
	.btn.ghost {
		border-color: transparent;
		color: var(--text-2);
	}
	.btn.ghost:hover {
		background: var(--sunken);
		color: var(--text);
	}
	.btn.sm {
		padding: 6px 10px;
		font-size: 12.5px;
	}
	.del-btn {
		color: var(--danger);
	}
	.del-btn:hover {
		background: var(--danger-weak);
		border-color: transparent;
		color: var(--danger);
	}

	.addbtn {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		width: 100%;
		padding: 10px;
		border: 1px dashed var(--border-strong);
		border-radius: var(--r);
		color: var(--text-2);
		font-size: 12.5px;
		font-weight: 600;
		margin-top: 8px;
		background: transparent;
		font: inherit;
		cursor: pointer;
	}
	.addbtn:hover {
		border-color: var(--accent);
		color: var(--accent-ink);
	}

	.mig-note {
		font-size: 12.5px;
		color: var(--text-3);
		line-height: 1.5;
		margin: 14px 0 0;
	}
</style>
