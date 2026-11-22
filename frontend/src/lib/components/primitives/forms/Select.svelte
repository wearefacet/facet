<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Combobox } from 'bits-ui';
	import type { Component } from 'svelte';
	import Field from './Field.svelte';
	import '../shared.css';

	/**
	 * Typeable select with grouped, featured, and icon-bearing options.
	 *
	 * One component covers three pickers that used to be separate:
	 *
	 * - **Static mode** (default): the parent gives `options: SelectOption[]`;
	 *   the component filters them client-side as the user types.
	 * - **Async mode**: the parent gives `results: SelectOption[]` and an
	 *   `onsearch` callback; the component renders whatever the server
	 *   returns and never filters locally.
	 * - **Non-searchable**: `searchable={false}` makes the trigger
	 *   read-only and opens the full list on click/focus (tiny fixed lists).
	 *
	 * Built on Bits UI `Combobox`. Per the v2.18.x connector quirk,
	 * `inputValue` is a one-way prop (not `bind:inputValue`).
	 *
	 * Typed text commits to the bound value when it names exactly one option
	 * (on Enter or blur); text that matches nothing shows a field error and
	 * never binds (B-290) — the input never holds committed-looking text
	 * without a bound value.
	 */

	/**
	 * A select option, or a non-selectable group header rendered above its
	 * `options` children. Group children are flat options only (no recursive
	 * nesting); this keeps the picker one level deep.
	 */
	export type SelectOption =
		| { value: string; label: string; icon?: Component; featured?: boolean }
		| {
				group: string;
				options: { value: string; label: string; icon?: Component; featured?: boolean }[];
		  };

	/** A flat (non-group) option — the shape the `renderItem` snippet receives. */
	type SelectItem = Extract<SelectOption, { value: string }>;

	/**
	 * Flatten grouped options into a flat list of value entries (used to
	 * resolve the selected label and for async `results` parity).
	 */
	export function flattenOptions(opts: SelectOption[]): Extract<SelectOption, { value: string }>[] {
		const out: Extract<SelectOption, { value: string }>[] = [];
		for (const opt of opts) {
			if ('value' in opt) out.push(opt);
			else if ('options' in opt) out.push(...flattenOptions(opt.options));
		}
		return out;
	}

	/**
	 * Type guard: is this select option a group (vs. a flat value entry)?
	 * Exposed so the `{#if}` blocks in the template narrow correctly.
	 */
	export function isSelectGroup(
		opt: SelectOption
	): opt is Extract<SelectOption, { group: string }> {
		return 'group' in opt;
	}

	/**
	 * Stable key for the `{#each}` over `options` — supports both flat
	 * options and grouped ones. Group entries key on their `group` label
	 * (empty string for an unnamed group); flat options key on `value`.
	 */
	export function optionKey(opt: SelectOption): string {
		return isSelectGroup(opt) ? opt.group : opt.value;
	}

	let {
		label,
		placeholder = 'Select…',
		options = [],
		results = [],
		value = $bindable(''),
		name,
		disabled = false,
		readonly = false,
		required = false,
		searchable = true,
		loading = false,
		helper,
		error,
		filter,
		onsearch,
		onviewportscroll,
		onchange,
		onblur,
		onValueChange,
		renderItem,
		...rest
	}: {
		label?: string;
		placeholder?: string;
		/** Static list (static mode). */
		options?: SelectOption[];
		/** Server-driven list (async mode). */
		results?: SelectOption[];
		value?: string;
		name?: string;
		disabled?: boolean;
		readonly?: boolean;
		required?: boolean;
		/** When `false`, the trigger is read-only and the full list opens on click. */
		searchable?: boolean;
		/** Async spinner in the trigger. */
		loading?: boolean;
		helper?: string;
		error?: string;
		/** Custom client-side match for static mode. Default: case-insensitive includes on label + value. */
		filter?: (label: string, value: string, query: string) => boolean;
		/** Fires on each keystroke (async mode). Presence enables async mode. */
		onsearch?: (query: string) => void;
		/** Fires on scroll of the dropdown viewport (used to paginate async results). */
		onviewportscroll?: (e: Event) => void;
		/** DOM-level `change` event — fires after value updates, with no payload. */
		onchange?: (e: Event) => void;
		/** DOM-level `blur` of the trigger input (used to reveal required hints). */
		onblur?: (e: Event) => void;
		/** Callback with the new value (preferred for programmatic state updates). */
		onValueChange?: (value: string) => void;
		/** Custom rendering for each item. Replaces icon+label when set. */
		renderItem?: import('svelte').Snippet<[item: SelectItem]>;
	} = $props();

	// Set when the committed text (Enter / blur) matches no option exactly
	// (B-290). The text stays visible so the user can correct it; the error
	// marks it as not committed. Cleared on any new input or selection.
	let typedError = $state(false);
	const displayError = $derived(typedError ? m.form_select_no_match() : error);

	const hasError = $derived(Boolean(displayError));
	const fieldId = $derived(label ? `select-${label}` : undefined);

	// Async mode is active when the parent performs the search server-side.
	const asyncMode = $derived(Boolean(onsearch));

	// Source list rendered in the dropdown. In async mode the parent owns it
	// (server results); in static mode `options` is the source of truth.
	const source = $derived(asyncMode ? (results as SelectOption[]) : (options as SelectOption[]));

	const flat = $derived(flattenOptions(source));
	const selectedOption = $derived(flat.find((o) => o.value === value));

	// Track the raw input value (typed text / displayed label). One-way prop
	// only: `bind:inputValue` silently fails on Bits UI v2.18.x.
	let inputValue = $state('');

	// Open state for the dropdown — open on input focus so the list is visible
	// immediately when the user tabs/clicks into the field.
	let open = $state(false);

	// In async mode, fire an initial server fetch when the dropdown opens so the
	// user sees a page of results before typing. Skipped when the user has
	// already typed a query (handled by `handleInput`).
	let lastOpen = false;
	$effect(() => {
		if (open && !lastOpen && asyncMode && !inputValue.trim()) {
			onsearch?.('');
		}
		lastOpen = open;
	});

	// Sync the input display when the value changes externally (programmatic
	// set, parent re-render), and when the resolved label for the current value
	// changes while the input still shows the previous label (a lazily loaded
	// option list, e.g. the currency registry, resolving after the first
	// render). Do NOT re-sync when `flat` recomputes while the user has typed a
	// query — that would override the typed text. `previousValue` starts as
	// `null` so the initial value also populates the input on first render.
	let previousValue = $state<string | null>(null);
	let previousLabel = $state<string | null>(null);
	$effect(() => {
		const item = flat.find((o) => o.value === value);
		const label = item?.label ?? null;
		if (value !== previousValue) {
			previousValue = value;
			previousLabel = label;
			if (item) inputValue = item.label;
		} else if (label !== previousLabel && inputValue === (previousLabel ?? '')) {
			// Same value, resolved label changed, and the user has not typed:
			// refresh the display text to the new label.
			previousLabel = label;
			if (item) inputValue = item.label;
		}
	});

	const defaultFilter = (l: string, v: string, q: string): boolean =>
		l.toLowerCase().includes(q) || v.toLowerCase().includes(q);

	// Static mode: derive the filtered list from `inputValue`. Async mode:
	// never filter locally (the parent already did).
	//
	// When the input text exactly matches the selected option's label, the
	// user is viewing the current value, not searching — show the full list.
	const filteredOptions = $derived.by(() => {
		if (asyncMode) return source;
		const all = source as SelectOption[];
		const q = inputValue.trim().toLowerCase();
		if (!q) return all;
		// If the input matches the selected label exactly, show everything.
		if (selectedOption && selectedOption.label.toLowerCase() === q) return all;
		const match = filter ?? defaultFilter;
		const out: SelectOption[] = [];
		for (const opt of all) {
			if ('value' in opt) {
				if (match(opt.label, opt.value, q)) out.push(opt);
			} else {
				const kept = opt.options.filter((sub) => match(sub.label, sub.value, q));
				if (kept.length > 0) out.push({ group: opt.group, options: kept });
			}
		}
		return out;
	});

	const SelectedIcon = $derived(selectedOption?.icon);

	function handleInput(e: Event) {
		const q = (e.target as HTMLInputElement).value;
		inputValue = q;
		typedError = false;
		onsearch?.(q);
	}

	/** Apply a committed value: bind it, show its label, notify the parent. */
	function commitValue(v: string) {
		value = v;
		const item = flat.find((o) => o.value === v);
		if (item) inputValue = item.label;
		typedError = false;
		onValueChange?.(v);
		onchange?.(new Event('change'));
	}

	function handleValueChange(v: string) {
		commitValue(v);
	}

	/**
	 * Commit typed text that names exactly one option (B-290): an exact,
	 * case-insensitive match on one option's label or value binds it to the
	 * form state. Returns `true` when committed (or already bound) — text
	 * that matches nothing, or more than one option, stays uncommitted.
	 */
	function commitTypedText(): boolean {
		const q = inputValue.trim();
		if (!q) return false;
		const ql = q.toLowerCase();
		const matches = flat.filter(
			(o) => o.label.toLowerCase() === ql || o.value.toLowerCase() === ql
		);
		if (matches.length !== 1) return false;
		const match = matches[0];
		if (match.value !== value) commitValue(match.value);
		typedError = false;
		return true;
	}

	function handleKeyDown(e: KeyboardEvent) {
		if (e.key !== 'Enter' || !searchable) return;
		// Defer past Bits UI's own Enter handling (it selects a highlighted
		// list item when one exists); commit only what survives that path.
		setTimeout(() => {
			if (commitTypedText()) return;
			if (inputValue.trim()) typedError = true;
		}, 0);
	}
</script>

<div class="select-wrap">
	<Field
		{label}
		{required}
		{helper}
		error={displayError}
		id={label ? `select-${label}` : undefined}
		forId={fieldId}
		labelClass="select-label"
	>
		{#snippet children(meta)}
			<Combobox.Root
				type="single"
				bind:value
				{name}
				{inputValue}
				bind:open
				disabled={disabled || readonly}
				{required}
				{...rest}
				onValueChange={handleValueChange}
			>
				<div class="select-field-wrap">
					<Combobox.Input
						id={fieldId}
						{placeholder}
						class="select-field-input"
						readonly={!searchable}
						aria-invalid={hasError || undefined}
						aria-describedby={meta.describedBy}
						oninput={handleInput}
						onkeydown={handleKeyDown}
						onfocus={() => (open = true)}
						onpointerdown={() => (open = !open)}
						onblur={(e) => {
							onblur?.(e);
							// Defer so selection (handleValueChange) runs first. Then
							// commit typed text that names exactly one option (B-290);
							// text matching nothing stays visible with an error, and
							// empty text falls back to the selected label or clears.
							setTimeout(() => {
								if (commitTypedText()) return;
								if (inputValue.trim()) {
									typedError = true;
									return;
								}
								if (value) {
									const item = flat.find((o) => o.value === value);
									if (item) inputValue = item.label;
								} else {
									inputValue = '';
								}
							}, 0);
						}}
					/>
					{#if SelectedIcon}
						<SelectedIcon class="select-item-icon select-item-icon-leading" />
					{/if}
					{#if loading}
						<span class="select-spinner" aria-hidden="true"></span>
					{:else}
						<span class="select-chevron" aria-hidden="true">▼</span>
					{/if}
				</div>

				<Combobox.Portal>
					<Combobox.Content class="select-dropdown menu-surface" align="start" sideOffset={4}>
						<Combobox.Viewport onscroll={onviewportscroll}>
							{#each filteredOptions as opt (optionKey(opt))}
								{#if isSelectGroup(opt)}
									<Combobox.Group>
										{#if opt.group}
											<Combobox.GroupHeading class="select-group-heading">
												{opt.group}
											</Combobox.GroupHeading>
										{/if}
										{#each opt.options as sub (sub.value)}
											{@const SubIcon = sub.icon}
											<Combobox.Item
												value={sub.value}
												label={sub.label}
												class="select-item menu-item"
												data-featured={sub.featured || undefined}
											>
												{#snippet children({ selected, highlighted })}
													{#if renderItem}
														{@render renderItem(sub)}
													{:else}
														{#if SubIcon}
															<SubIcon class="select-item-icon" />
														{/if}
														<span
															class="select-item-label"
															class:select-item-highlighted={highlighted}
															class:select-item-selected={selected}
															class:select-item-featured={sub.featured}
														>
															{sub.label}
														</span>
													{/if}
												{/snippet}
											</Combobox.Item>
										{/each}
									</Combobox.Group>
								{:else}
									{@const OptIcon = opt.icon}
									<Combobox.Item
										value={opt.value}
										label={opt.label}
										class="select-item menu-item"
										data-featured={opt.featured || undefined}
									>
										{#snippet children({ selected, highlighted })}
											{#if renderItem}
												{@render renderItem(opt)}
											{:else}
												{#if OptIcon}
													<OptIcon class="select-item-icon" />
												{/if}
												<span
													class="select-item-label"
													class:select-item-highlighted={highlighted}
													class:select-item-selected={selected}
													class:select-item-featured={opt.featured}
												>
													{opt.label}
												</span>
											{/if}
										{/snippet}
									</Combobox.Item>
								{/if}
							{:else}
								<div class="select-empty">{m.doc_select_empty()}</div>
							{/each}
						</Combobox.Viewport>
					</Combobox.Content>
				</Combobox.Portal>
			</Combobox.Root>
		{/snippet}
	</Field>
</div>

<style>
	/* ── Select wrap ─────────────────────────────────────────────────────── */
	.select-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	/* ── Trigger wrap (caret + spinner positioning) ─────────────── */
	.select-field-wrap {
		position: relative;
		width: 100%;
	}

	/* ── Input (Bits UI renders the <input> — must be :global) ─────────── */
	:global(.select-field-input) {
		width: 100%;
		font-family: var(--font-sans);
		font-size: 13px;
		line-height: 1.5;
		padding: 9px 30px 9px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
		text-align: left;
		outline: none;
		user-select: none;
		-webkit-user-select: none;
	}

	:global(.select-field-input::placeholder) {
		color: var(--text-3);
	}

	:global(.select-field-input:hover) {
		background: var(--surface-2);
	}

	:global(.select-field-input:focus),
	:global(.select-field-input[data-state='open']) {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
		background: var(--surface-2);
	}

	:global(.select-field-input:disabled),
	:global(.select-field-input[data-disabled]) {
		opacity: 0.5;
		cursor: not-allowed;
		background: var(--surface-2);
	}

	:global(.select-field-input[readonly]) {
		cursor: pointer;
	}

	:global(.select-field-input[aria-invalid='true']) {
		border-color: var(--danger);
	}

	:global(.select-field-input[aria-invalid='true']:focus) {
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	/* ── Chevron / spinner ──────────────────────────────────────────────── */
	.select-chevron {
		position: absolute;
		right: 10px;
		top: 50%;
		transform: translateY(-50%);
		font-size: 0.5em;
		color: var(--text-3);
		pointer-events: none;
		line-height: 1;
	}

	.select-spinner {
		position: absolute;
		right: 10px;
		top: 50%;
		transform: translateY(-50%);
		width: 14px;
		height: 14px;
		border: 2px solid var(--border-strong);
		border-right-color: transparent;
		border-radius: 50%;
		animation: select-spin 0.6s linear infinite;
		pointer-events: none;
	}

	@keyframes select-spin {
		to {
			transform: translateY(-50%) rotate(360deg);
		}
	}

	/* ── Dropdown (portal-rendered — :global) ───────────────────────────── */
	/* ── Dropdown (portal-rendered — surface base is shared) ───────── */
	:global(.select-dropdown) {
		max-height: 240px;
		overflow-y: auto;
		z-index: 1100;
		min-width: var(--bits-combobox-trigger-width);
	}

	/* Items share the menu-item base; the select keeps its tighter padding. */
	:global(.menu-item.select-item) {
		padding: 6px 8px;
	}

	:global(.select-item[data-selected]) {
		font-weight: 600;
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	:global(.select-item[data-selected]::before) {
		content: '✓';
		margin-right: 4px;
		font-size: 11px;
	}

	/* Featured: distinct accent marker (left border + dot) — does not
	   collide with selected (✓) or highlighted (tint) states. */
	:global(.select-item[data-featured]) {
		border-left: 2px solid var(--accent);
		padding-left: 6px;
	}

	:global(.select-item[data-featured] .select-item-featured::after) {
		content: '★';
		margin-left: auto;
		padding-left: 6px;
		font-size: 10px;
		color: var(--accent);
	}

	.select-item-label {
		display: block;
		flex: 1;
	}

	:global(.select-group-heading) {
		padding: 6px 8px 2px;
		font-size: 10.5px;
		font-weight: 700;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	/* ── Icon styling ──────────────────────────────────────────────────── */
	:global(.select-item-icon) {
		width: 16px;
		height: 16px;
		margin-right: 8px;
		flex-shrink: 0;
		color: var(--text-2);
	}

	:global(.select-item-icon-leading) {
		position: absolute;
		left: 10px;
		top: 50%;
		transform: translateY(-50%);
		pointer-events: none;
		margin-right: 0;
	}

	:global(.select-field-wrap:has(.select-item-icon-leading) .select-field-input) {
		padding-left: 32px;
	}

	:global(.select-item[data-selected] .select-item-icon) {
		color: var(--accent-ink);
	}

	:global(.select-item[data-highlighted] .select-item-icon) {
		color: var(--text);
	}

	/* ── Empty ─────────────────────────────────────────────────────────── */
	:global(.select-empty) {
		padding: 8px 10px;
		font-size: 13px;
		color: var(--text-3);
		text-align: center;
	}

	/* Helper and error text render through the shared Field component. */
</style>
