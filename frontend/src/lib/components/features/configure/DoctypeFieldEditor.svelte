<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { FieldDef } from '$lib/doctype/types.js';
	import { defaultFilterCapabilities } from '$lib/doctype/capabilities.js';
	import { sanitizeKeyInput } from '$lib/doctype/keys.js';
	import DoctypeTypeEditor from './DoctypeTypeEditor.svelte';
	import Input from '../../primitives/forms/Input.svelte';
	import Toggle from '../../primitives/forms/Toggle.svelte';
	import Select from '../../primitives/forms/Select.svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import { FIELD_TYPE_OPTIONS as TYPE_OPTIONS } from './field-type-options.js';
	import * as m from '$lib/paraglide/messages';

	let {
		field,
		allFields = [],
		tagSuggestions = [],
		domain = '',
		readonly = false,
		ondelete,
		onchange
	}: {
		field: FieldDef | undefined;
		/** All fields in the doctype (for duplicate-key validation). */
		allFields?: FieldDef[];
		/** Tags already in use across the domain's doctypes — clicking one
		 *  appends it to the field's tags. Free-form input stays the primary
		 *  entry (producers invent their own labels); suggestions only speed
		 *  up reuse. */
		tagSuggestions?: string[];
		/** Domain of the doctype being edited. A bare reference target is
		 *  qualified into the `domain.Target` form the backend Check requires
		 *  (empty when unknown — no qualification). */
		domain?: string;
		readonly?: boolean;
		ondelete?: () => void;
		/** Reports the edited field after every edit. The parent owns the
		 *  definition; a form that passes no handler keeps the edits local to
		 *  the `field` object it handed in. */
		onchange?: (field: FieldDef) => void;
	} = $props();

	/** The working copy this editor shows. Each edit is applied to it and
	 *  reported upward — never written into the `field` prop itself, which
	 *  would mutate the parent's state from here. The local copy is the
	 *  fallback for a form that passes no `onchange` handler. */
	let draft = $derived(field);

	function edit(mutate: (d: FieldDef) => void) {
		if (!draft) return;
		const next = { ...draft };
		mutate(next);
		draft = next;
		onchange?.(next);
	}

	/** A field edited by the type section: adopt it and report it upward. */
	function adoptField(next: FieldDef) {
		draft = next;
		onchange?.(next);
	}

	// Duplicate-key error derived from the edited field. It reads the key the
	// input just committed (`typedKey`) ahead of the stored one, so the inline
	// error appears at once, before the parent has re-rendered.
	let keyError = $derived.by(() => {
		if (!draft) return undefined;
		const k = typedKey ?? draft.key;
		if (!k) return undefined;
		return allFields.some((f) => f !== draft && f.key === k)
			? m.configure_doctypes_key_duplicate_error({ key: k })
			: undefined;
	});

	/** The last text committed by the key input, so `keyError` reflects it
	 *  immediately (the parent re-renders on its own schedule). */
	let typedKey: string | undefined = $state(undefined);

	function handleTypeChange(next: string) {
		if (!draft || readonly) return;
		// The Select reports the committed value; write it before resetting the
		// type-specific fields (they belong to the previous type).
		edit((f) => {
			f.type = next as FieldDef['type'];
			f.values = undefined;
			f.properties = undefined;
			f.items = undefined;
			f.compute = undefined;
			f.compute_when = undefined;
			f.currency = undefined;
			// Capabilities re-seed to the new type's defaults: the old set may
			// carry capabilities the new type may not declare (the backend
			// validator would reject them), and a switched field starts from the
			// same filterable-by-default state as a freshly added one.
			const caps = defaultFilterCapabilities(f.type);
			f.filters = caps.length > 0 ? [...caps] : undefined;
			// secret and replicate fields reject unique server-side — drop the flag
			// so a type switch cannot leave an invalid definition behind.
			if (!uniqueSupported) {
				f.unique = undefined;
			}
		});
	}

	/** The backend rejects unique on secret fields and on replicated fields
	 *  (uniqueness there is governed by the source document). */
	const uniqueSupported = $derived(draft?.type !== 'secret' && draft?.replicate === undefined);

	function handleFieldChange(e: Event) {
		if (!draft || readonly) return;
		const target = e.target as HTMLInputElement;
		// Overwrite the DOM display too — the input is not bind:value-bound, so
		// only the handler can filter out illegal characters as the user types.
		const v = sanitizeKeyInput(target.value);
		target.value = v;
		// Duplicate keys throw `each_key_duplicate` at the keyed {#each} in
		// DoctypeFieldList. Refuse the write and keep the typed text in the
		// input, so the user can type past the collision. The inline error
		// names the key that already exists.
		typedKey = v;
		if (keyError) return;
		edit((f) => {
			f.key = v;
		});
	}

	function handleTitleChange(e: Event) {
		if (!draft || readonly) return;
		const target = e.target as HTMLInputElement;
		const title = target.value || undefined;
		edit((f) => {
			f.title = title;
		});
	}

	function handleDescChange(e: Event) {
		if (!draft || readonly) return;
		const target = e.target as HTMLTextAreaElement;
		const description = target.value || undefined;
		edit((f) => {
			f.description = description;
		});
	}

	function handleTagsChange(e: Event) {
		if (!draft || readonly) return;
		const target = e.target as HTMLInputElement;
		const tags = target.value
			? target.value
					.split(',')
					.map((s) => s.trim())
					.filter(Boolean)
			: undefined;
		edit((f) => {
			f.tags = tags;
		});
	}

	/** Appends one suggested tag (a click on an in-use chip). Already-set
	 *  tags toggle off — the chips double as removal affordances. */
	function toggleSuggestedTag(tag: string) {
		if (!draft || readonly) return;
		const current = draft.tags ?? [];
		const next = current.includes(tag) ? current.filter((t) => t !== tag) : [...current, tag];
		edit((f) => {
			f.tags = next.length > 0 ? next : undefined;
		});
	}

	const tagsValue = $derived(draft?.tags?.join(', ') ?? '');

	// Suggestion chips not already on the field — the ones that would add
	// a new label. On-field tags render as active chips below instead.
	const offSuggestions = $derived(tagSuggestions.filter((t) => !draft?.tags?.includes(t)));
	const onSuggestions = $derived((draft?.tags ?? []).filter((t) => tagSuggestions.includes(t)));
</script>

<div class="fdetail">
	{#if draft}
		<!-- Header -->
		<div class="dt-h">
			<span class="key">{draft.key}</span>
			<span class="ty-mono">{draft.type}</span>
			<span class="sp"></span>
			<Toggle
				label={m.configure_doctypes_required_label()}
				checked={draft.required ?? false}
				onchange={() => {
					const required = !draft?.required;
					edit((f) => {
						f.required = required;
					});
				}}
				{readonly}
			/>
			{#if uniqueSupported}
				<span class="unique-toggle" title={m.configure_doctypes_unique_helper()}>
					<Toggle
						label={m.configure_doctypes_unique_label()}
						checked={draft?.unique ?? false}
						onchange={() => {
							const unique = !draft?.unique;
							edit((f) => {
								f.unique = unique;
							});
						}}
						{readonly}
					/>
				</span>
			{/if}
			{#if !readonly}
				<span class="delete-slot">
					<Button
						variant="ghost"
						size="sm"
						title={m.configure_doctypes_delete_field_aria()}
						onclick={ondelete}
					>
						{#snippet iconLeft()}
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
						{/snippet}
					</Button>
				</span>
			{/if}
		</div>
		{#if draft.description}
			<div class="dt-sub">{draft.description}</div>
		{/if}

		<!-- General section -->
		<div class="fsec">
			<h4>{m.configure_doctypes_general_title()}</h4>
			<div class="grid2">
				<div class="f">
					<Input
						label={m.configure_doctypes_key_label()}
						value={draft.key}
						oninput={handleFieldChange}
						error={keyError}
						helper={keyError ? undefined : m.configure_doctypes_key_helper()}
						disabled={readonly}
					/>
				</div>
				<div class="f">
					<Select
						label={m.common_type()}
						options={TYPE_OPTIONS}
						value={draft.type ?? ''}
						onValueChange={handleTypeChange}
						{readonly}
					/>
				</div>
				<div class="f wide">
					<Input
						label={m.configure_doctypes_title_label()}
						value={draft.title ?? ''}
						oninput={handleTitleChange}
						disabled={readonly}
					/>
				</div>
				<div class="f wide">
					<label class="field-label" for="field-desc">{m.common_description()}</label>
					<textarea
						id="field-desc"
						class="textarea"
						rows="2"
						value={draft.description ?? ''}
						oninput={handleDescChange}
						disabled={readonly}></textarea>
				</div>
			</div>
		</div>

		<!-- Type-specific section -->
		<DoctypeTypeEditor field={draft} {readonly} {domain} onchange={adoptField} />

		<!-- Access section -->
		<div class="fsec">
			<h4>
				{m.configure_doctypes_access_title()}
				<span
					class="opt"
					style="font-weight:400;text-transform:none;letter-spacing:0;color:var(--text-3)"
					>{m.configure_doctypes_access_opt()}</span
				>
			</h4>
			<div class="f" style="max-width:320px">
				<Input
					label={m.configure_doctypes_tags_label()}
					value={tagsValue}
					placeholder={m.configure_doctypes_tags_placeholder()}
					oninput={handleTagsChange}
					disabled={readonly}
				/>
			</div>
			{#if (onSuggestions.length > 0 || offSuggestions.length > 0) && !readonly}
				<div class="tag-suggest">
					{#each onSuggestions as tag (tag)}
						<button
							type="button"
							class="suggest-chip on"
							aria-pressed="true"
							title={m.configure_doctypes_tags_chip_remove_title({ tag })}
							onclick={() => toggleSuggestedTag(tag)}
						>
							{tag}
						</button>
					{/each}
					{#each offSuggestions as tag (tag)}
						<button
							type="button"
							class="suggest-chip"
							aria-pressed="false"
							title={m.configure_doctypes_tags_chip_add_title({ tag })}
							onclick={() => toggleSuggestedTag(tag)}
						>
							{tag}
						</button>
					{/each}
				</div>
			{/if}
			<div class="hint" style="margin-top:7px">
				{m.configure_doctypes_tags_helper()}
			</div>
		</div>
	{:else}
		<div class="empty-state">
			<div class="empty-icon">
				<svg
					width="32"
					height="32"
					fill="none"
					stroke="currentColor"
					stroke-width="1.5"
					viewBox="0 0 24 24"
				>
					<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
					<polyline points="14 2 14 8 20 8" />
					<line x1="12" y1="18" x2="12" y2="12" />
					<line x1="9" y1="15" x2="15" y2="15" />
				</svg>
			</div>
			<p>{m.configure_doctypes_field_editor_empty()}</p>
		</div>
	{/if}
</div>

<style>
	.fdetail {
		overflow: auto;
		padding: 24px 28px;
	}

	.dt-h {
		display: flex;
		align-items: center;
		gap: 11px;
		margin-bottom: 4px;
	}
	.dt-h .key {
		font-family: var(--font-mono);
		font-size: 18px;
		font-weight: 600;
	}
	.dt-h .sp {
		flex: 1;
	}
	.unique-toggle {
		display: inline-flex;
	}
	.ty-mono {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-2);
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: 5px;
		padding: 2px 8px;
	}

	.dt-sub {
		color: var(--text-3);
		font-size: 12.5px;
		margin-bottom: 22px;
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
	.f.wide {
		grid-column: 1 / -1;
	}

	/* The description textarea is the one control without a matching
	   primitive — it keeps the field chrome itself, label included. */
	.field-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	/* The description textarea is the one control without a matching
	   primitive — it keeps the standard field chrome itself. */
	.textarea {
		padding: 8px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		font: inherit;
		font-size: 13px;
		color: var(--text);
		width: 100%;
		resize: vertical;
		font-family: var(--font-sans);
		line-height: 1.5;
	}
	.textarea:focus {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	/* Danger ghost for the delete affordance, themed on the Button primitive. */
	.delete-slot :global(.btn) {
		color: var(--danger);
	}
	.delete-slot :global(.btn:hover) {
		background: var(--danger-weak);
		border-color: transparent;
		color: var(--danger);
	}

	.hint {
		font-size: 11.5px;
		color: var(--text-3);
	}

	/* In-use tag suggestions — reuse beats retyping, and a shared label set
	   keeps grants stable across fields. */
	.tag-suggest {
		display: flex;
		flex-wrap: wrap;
		gap: 5px;
		margin-top: 7px;
		max-width: 480px;
	}
	.suggest-chip {
		padding: 2px 9px;
		border-radius: 999px;
		font: 400 11px/1.4 var(--font-mono);
		color: var(--text-2);
		background: var(--surface-2);
		border: 1px solid var(--border-2);
		cursor: pointer;
	}
	.suggest-chip:hover {
		border-color: var(--accent);
		color: var(--text-1);
	}
	.suggest-chip.on {
		background: var(--accent);
		color: var(--on-accent);
		border-color: var(--accent);
	}

	.empty-state {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		height: 100%;
		color: var(--text-3);
		gap: 12px;
	}
	.empty-icon {
		opacity: 0.4;
	}
	.empty-state p {
		font-size: 13px;
		margin: 0;
	}
</style>
