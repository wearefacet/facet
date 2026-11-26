<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { tick } from 'svelte';
	import * as m from '$lib/paraglide/messages';
	import DoctypeIcon from '../data/DoctypeIcon.svelte';
	import Field from './Field.svelte';
	import { splitQualifiedDoctype, splitQualifiedRef } from '$lib/datasource/qualifiedRef.js';
	/**
	 * ReferencePicker — two-part composite control for selecting a referenced document.
	 *
	 * ## Modes (inferred from props)
	 * | `doctype` set | **forced** | Type is locked; record search is live immediately |
	 * | `doctypes` set | **constrained** | Pick type from list; record search enables after |
	 * | neither | **open** | Filterable type list from `core.DocType`; then record search |
	 *
	 * In all modes, doctype metadata (label, tint) and record search are resolved
	 * through the provided `driver` — no static map needed.
	 */

	let {
		label,
		placeholder = m.doc_ref_search_placeholder(),
		value = $bindable(''),
		doctype,
		doctypes,
		driver,
		loading = false,
		required = false,
		disabled = false,
		error,
		helper,
		filter,
		recordMeta,
		onpick,
		hideType = false,
		...rest
	}: {
		label?: string;
		placeholder?: string;
		/**
		 * Bindable value. A pick writes the bare record id; form load seeds the
		 * stored qualified token (`"crm.Invoice.1"`). `""` is empty. The backend
		 * qualifies a bare id with the field's declared doctype on write.
		 */
		value?: string;
		/** Forced mode: single qualified doctype (e.g. `"crm.Invoice"`). */
		doctype?: string;
		/** Constrained mode: list of allowed qualified doctypes. */
		doctypes?: string[];
		/** DataDriver — provides doctype metadata via `core.DocType` and record search. */
		driver: import('$lib/datasource/driver.js').DataDriver;
		loading?: boolean;
		required?: boolean;
		disabled?: boolean;
		error?: string;
		helper?: string;
		/**
		 * Declarative `field__op: value` filter merged into the `list()` query so
		 * the picker only shows documents matching the doctype definition.
		 * Undefined / empty means "no filter".
		 */
		filter?: Record<string, unknown>;
		/**
		 * Per-record display overrides, keyed by record id. Lets a picker
		 * surface the records' own identity — a doctype's tint, icon, and
		 * qualified label — instead of the declared target type's mark.
		 * Unkeyed ids fall back to the driver label and the declared tint.
		 */
		recordMeta?: Record<string, { label?: string; icon?: string | null; color?: string | null }>;
		/**
		 * Multi-select hook (`ReferenceListEditor`). When set, a record pick
		 * calls this instead of adopting the record: `selectedRec` stays null,
		 * the `value` binding is never written, and the dropdown stays open so
		 * the parent can append target after target. The pick carries the bare
		 * record id, the display label, and the qualified doctype the record
		 * was picked under (`selectedType` — the authoritative target for the
		 * parent's token qualification).
		 */
		onpick?: (pick: { id: string; label: string; doctype: string | null }) => void;
		/**
		 * Hide the locked doctype prefix in forced mode — for embedding surfaces
		 * that already name the doctype (the grid cell editor's column header),
		 * where the prefix would eat the width the search input needs.
		 */
		hideType?: boolean;
	} = $props();

	const mode = $derived(doctype ? 'forced' : doctypes?.length ? 'constrained' : 'open');

	// Unique per-instance suffix so multiple ReferencePickers sharing the same
	// label (e.g. DomainEditor grants) don't produce duplicate DOM IDs.
	const uid = Math.random().toString(36).slice(2, 10);

	// ── State ─────────────────────────────────────────────────────────────────
	// svelte-ignore state_referenced_locally — seeded from the initial prop;
	// the forced-sync effect below owns all subsequent updates.
	let selectedType: string | null = $state(doctype ?? null);
	let selectedRec: { id: string; label: string } | null = $state(null);
	let query = $state('');
	let results: { id: string; label: string }[] = $state([]);
	let typeOpen = $state(false);
	let recOpen = $state(false);
	let active = $state(0);
	let typeFilter = $state('');
	let seq = 0;
	let debounce: ReturnType<typeof setTimeout> | undefined;
	let hydratingSeq = 0;
	/** Shadow of the last `value` we hydrated from, so the value→selectedRec
	 *  effect can skip redundant `hydrateLabel` calls WITHOUT subscribing to
	 *  `selectedRec` (which would clobber user picks from search results). */
	let lastHydratedValue: string | null = null;

	// Follow a `doctype` prop that changes under a mounted picker (builder
	// preview: retargeting a reference field re-derives the forced doctype).
	// In forced mode the type menu is closed, so `selectedType` is never
	// user-mutable — the unconditional write cannot clobber a user pick.
	$effect(() => {
		if (mode === 'forced') selectedType = doctype ?? null;
	});

	// ── Load doctype definitions from core.DocType ─────────────────────────
	// `labelled` records whether the target declares a `display_name` or
	// `search` template. A template-less doctype has a NULL search corpus, so
	// the bare `search` filter matches only the row id — the picker falls back
	// to an id-oriented label and hint for such targets (B-296).
	let docTypes: {
		qualified: string;
		label: string;
		tint: string;
		icon?: string | null;
		labelled: boolean;
	}[] = $state([]);

	$effect(() => {
		// Driver is `$props()` — reading it subscribes this effect so a new
		// driver identity re-fetches. No cancellation: if the driver is unstable
		// across parent re-renders, racing fetches still resolve to the
		// latest version (and `docTypes` is content-equal to itself anyway).
		driver
			.domain('core')
			.doctype('DocType')
			.list()
			.then((resp) => {
				const types = resp.data.map((item) => ({
					qualified: `${item.data.domain}.${item.data.doctype}`,
					label: item.data.doctype as string,
					tint: (item.data.color as string) ?? 'var(--text-2)',
					icon: (item.data.icon as string | undefined) ?? null,
					labelled: hasTemplate(item.data.display_name) || hasTemplate(item.data.search)
				}));
				types.sort((a, b) => a.qualified.localeCompare(b.qualified));
				docTypes = types;
			})
			.catch(() => {
				// core.DocType may not exist yet — leave docTypes empty
			});
	});

	// ── Search via driver ──────────────────────────────────────────────────
	// `$derived` keeps the closure in step with the driver identity (same
	// contract as the `docTypes` effect above). `filter` is read through a
	// getter at call time so definition changes apply without rebuilding.
	const searchFn = $derived(createDriverSearch(driver, () => filter));

	/** Display override for a record, if the parent supplied one. */
	const metaFor = (id: string) => recordMeta?.[id];
	/** The record's label — the parent override wins over the driver label. */
	const displayLabel = (rec: { id: string; label: string }) =>
		recordMeta?.[rec.id]?.label ?? rec.label;

	// ── Derived ───────────────────────────────────────────────────────────────
	const typeInfo = $derived(
		selectedType ? (docTypes.find((t) => t.qualified === selectedType) ?? null) : null
	);
	const typeLabel = $derived(
		typeInfo?.label ?? (selectedType ? (selectedType.split('.').pop() ?? '') : '')
	);
	// A template-less target (no `display_name`/`search`) has no search corpus,
	// so the bare `search` filter matches only the row id. The picker then
	// labels results by id and steers the user to search by id (B-296).
	const selectedLabelled = $derived(typeInfo ? typeInfo.labelled : true);
	const hasError = $derived(Boolean(error));
	const fieldId = $derived(label ? `ref-${label.replace(/\s+/g, '-')}-${uid}` : undefined);
	const labelId = $derived(fieldId ? `${fieldId}-label` : undefined);
	const inputId = $derived(fieldId ? `${fieldId}-input` : undefined);
	const listboxTypeId = $derived(fieldId ? `${fieldId}-type-list` : undefined);
	const listboxRecId = $derived(fieldId ? `${fieldId}-rec-list` : undefined);

	const typeList = $derived.by(() => {
		if (mode === 'forced' && doctype) {
			const found = docTypes.find((t) => t.qualified === doctype);
			return found ? [found] : [];
		}
		if (mode === 'constrained' && doctypes) {
			return docTypes.filter((t) => doctypes.includes(t.qualified));
		}
		return docTypes;
	});

	const filteredTypes = $derived.by(() => {
		if (!typeFilter) return typeList;
		const q = typeFilter.toLowerCase();
		return typeList.filter(
			(t) => t.label.toLowerCase().includes(q) || t.qualified.toLowerCase().includes(q)
		);
	});

	// ── Sync value ↔ selection ───────────────────────────────────────────────
	// When `value` is set externally (form load, edit, etc.), we derive the
	// qualified doctype from it and asynchronously hydrate the chip label via
	// `driver.show()`. Until that resolves, the chip shows the raw id as a
	// provisional label — much better than a permanent UUID once the fetch
	// completes.
	$effect(() => {
		if (!value) {
			selectedRec = null;
			query = '';
			results = [];
			lastHydratedValue = null;
			return;
		}
		const parts = splitQualifiedRef(value);
		if (parts) {
			// Hydrate the chip label from a bare `value`. Skip the work when the
			// provisional record we'd write is identical to the one already in
			// place — this avoids re-issuing the fetch when `value` re-evaluates
			// to the same id after an unrelated prop change. IMPORTANT: do NOT
			// read `selectedRec` or `selectedType` here to compare — doing so
			// would subscribe this effect to those signals, causing it to re-run
			// when the user picks a doctype/record from the dropdowns and
			// clobber the user's choice with the stale provisional. Use the
			// `lastHydratedValue` shadow for the dedup check instead.
			const qualifiedDoctype = `${parts.domain}.${parts.doctype}`;
			selectedType = qualifiedDoctype;
			if (value !== lastHydratedValue) {
				lastHydratedValue = value;
				selectedRec = { id: value, label: parts.id };
				hydrateLabel(qualifiedDoctype, value, parts.id);
			}
		}
	});

	async function hydrateLabel(qualifiedDoctype: string, fullValue: string, fallbackLabel: string) {
		const parts = splitQualifiedDoctype(qualifiedDoctype);
		if (!parts) return;
		const my = ++hydratingSeq;
		try {
			// `value` is the stored reference — a fully qualified token
			// (`"crm.Deal.1"`) or a bare id. The backend resolves the id shape
			// at the route layer (see `doc/backend/http-layer.md` → Document id
			// forms), so one fetch covers both shapes.
			const ds = driver.domain(parts.domain).doctype(parts.doctype);
			const res = await ds.doc(fullValue).show();
			if (my !== hydratingSeq) return; // superseded by a newer value
			const label = res.meta.display_name ?? fallbackLabel;
			selectedRec = { id: value, label };
		} catch {
			if (my !== hydratingSeq) return;
			// Leave the provisional label in place — the id falls back to itself.
		}
	}

	$effect(() => {
		if (selectedRec && selectedType) {
			value = selectedRec.id;
		} else if (!selectedRec) {
			value = '';
		}
	});

	// ── Driver-based search factory ─────────────────────────────────────────
	/**
	 * Create a search function from a DataDriver.
	 * Delegates to the backend `?search=<query>` trigram filter so the
	 * database does the heavy lifting; falls back to listing 25 records
	 * when the query is empty.
	 */
	function createDriverSearch(
		driver: import('$lib/datasource/driver.js').DataDriver,
		getFilter: () => Record<string, unknown> | undefined
	): (dt: string, q: string) => Promise<{ id: string; label: string }[]> {
		return async (qualifiedDoctype: string, query: string) => {
			const parts = splitQualifiedDoctype(qualifiedDoctype);
			if (!parts) return [];
			const ds = driver.domain(parts.domain).doctype(parts.doctype);
			// Merge the declarative filter (from the doctype definition) with the
			// user's text search. The filter is read at call time so reactive
			// updates to the prop take effect without rebuilding the closure.
			const activeFilter = getFilter();
			const filters: Record<string, unknown> = { ...(activeFilter ?? {}) };
			if (query) filters.search = query;
			const response = await ds.list({
				filters,
				items: 25
			});
			// A template-less target has no display_name corpus; label by id
			// so the picker never shows a blank row (B-296).
			const labelled = docTypes.find((t) => t.qualified === qualifiedDoctype)?.labelled ?? true;
			return response.data.map((item) => ({
				// `item.meta.id` is the bare projection id. The backend qualifies
				// a bare id with the field's declared doctype, so the stored form
				// stays canonical. A self-qualified id (`iam.Roles.editor`) already
				// starts with the target prefix and passes through unchanged — a
				// prefixed token here would double the prefix.
				id: item.meta.id,
				label: labelled ? (item.meta.display_name ?? item.meta.id) : item.meta.id
			}));
		};
	}

	// ── Helpers ───────────────────────────────────────────────────────────────
	/** True when a template field is declared (non-empty, non-whitespace). */
	function hasTemplate(value: unknown): boolean {
		return typeof value === 'string' && value.trim().length > 0;
	}

	function tint(qualified: string): string {
		return docTypes.find((t) => t.qualified === qualified)?.tint ?? 'var(--text-2)';
	}

	function iconOf(qualified: string | null): string | null | undefined {
		return qualified ? docTypes.find((t) => t.qualified === qualified)?.icon : null;
	}

	function openTypeMenu(): void {
		if (mode === 'forced') return;
		typeOpen = true;
		recOpen = false;
	}

	function openRecMenu(): void {
		if (!selectedType || selectedRec) return;
		recOpen = true;
		typeOpen = false;
		if (!query) runSearch('');
	}

	function closeMenus(): void {
		typeOpen = false;
		recOpen = false;
	}

	function chooseType(q: string): void {
		if (q !== selectedType) {
			selectedRec = null;
			query = '';
			results = [];
			active = 0;
		}
		selectedType = q;
		typeOpen = false;
		const input = document.getElementById(inputId ?? '') as HTMLInputElement | null;
		input?.focus();
		recOpen = true;
		runSearch('');
	}

	function selectRecord(i: number): void {
		const rec = results[i];
		if (!rec) return;
		if (onpick) {
			// Add-mode: the parent owns the outcome. Keep the dropdown open and
			// the query intact so several targets can be added in a row.
			onpick({ id: rec.id, label: displayLabel(rec), doctype: selectedType });
			active = 0;
			return;
		}
		selectedRec = rec;
		recOpen = false;
		// The chip replaces the input — carry the focus with it so the
		// keyboard flow survives the pick (Enter re-opens, Tab moves on)
		// instead of dropping to `body`.
		void tick().then(() => {
			(rootEl?.querySelector('.ref-rec') as HTMLElement | null)?.focus();
		});
	}

	function startEdit(): void {
		selectedRec = null;
		query = '';
		results = [];
		active = 0;
		const input = document.getElementById(inputId ?? '') as HTMLInputElement | null;
		input?.focus();
		recOpen = true;
	}

	// ── Search (debounced + seq guard to drop stale responses) ───────────────
	/**
	 * Run a search. When `q` is empty, lists all documents for the selected type
	 * (unfiltered browsing). The debounce is skipped for empty queries so the list
	 * appears immediately when the dropdown opens.
	 */
	function runSearch(q: string): void {
		clearTimeout(debounce);
		query = q;
		if (!selectedType || !searchFn) return;
		if (!q) {
			// Empty query → list all documents for the selected doctype
			const my = ++seq;
			searchFn(selectedType!, '').then((rows) => {
				if (my !== seq) return;
				results = rows;
				active = 0;
			});
			return;
		}
		debounce = setTimeout(async () => {
			const my = ++seq;
			const rows = await searchFn(selectedType!, q);
			if (my !== seq) return;
			results = rows;
			active = 0;
		}, 220);
	}

	// ── Keyboard ──────────────────────────────────────────────────────────────
	function onKeyDown(e: KeyboardEvent): void {
		if (e.key === 'ArrowDown') {
			e.preventDefault();
			if (!recOpen && selectedType && !selectedRec) openRecMenu();
			move(1);
		} else if (e.key === 'ArrowUp') {
			e.preventDefault();
			move(-1);
		} else if (e.key === 'Enter') {
			e.preventDefault();
			if (results[active]) selectRecord(active);
		} else if (e.key === 'Escape') {
			closeMenus();
		} else if (e.key === 'Backspace' && !query && mode !== 'forced') {
			openTypeMenu();
		}
	}

	function move(d: number): void {
		if (!results.length) return;
		active = (active + d + results.length) % results.length;
	}

	// ── Outside click — uses composedPath to survive DOM mutation ────────────
	let rootEl: HTMLElement | null = null;
	function onDocClick(e: MouseEvent): void {
		if (!(typeOpen || recOpen)) return;
		if (!rootEl || e.composedPath().includes(rootEl)) return;
		closeMenus();
	}
</script>

<svelte:window onclick={onDocClick} />

<!-- Shared capsule renderer — one markup source for the selected chip and the
		dropdown result rows. `meta` carries a per-record mark override (see the
		`recordMeta` prop); without it the capsule wears the declared type's mark. -->
{#snippet refCapsule(labelText: string, meta?: { icon?: string | null; color?: string | null })}
	<span
		class="ref-capsule"
		style={`--ref-tint: ${meta?.color ?? (selectedType ? tint(selectedType) : 'var(--text-2)')}`}
	>
		<DoctypeIcon
			icon={meta?.icon ?? iconOf(selectedType)}
			color={meta?.color ?? (selectedType ? tint(selectedType) : null)}
			shadow
			active
		/>
		<span class="ref-capsule-label">{labelText}</span>
	</span>
{/snippet}

<div class="ref-wrap" class:ref-error={hasError} id={fieldId} bind:this={rootEl} {...rest}>
	<Field
		{label}
		{required}
		{helper}
		{error}
		id={fieldId ?? undefined}
		forId={inputId ?? undefined}
		labelId={labelId ?? undefined}
	>
		{#snippet children(meta)}
			<!-- No Field label (embedded hosts pass none) — the aria-label
				fallback keeps the combobox named for assistive tech. -->
			<div
				class="ref"
				class:ref-has-sel={!!selectedRec}
				class:ref-focus={typeOpen || recOpen}
				class:ref-disabled={disabled}
				role="combobox"
				aria-labelledby={labelId}
				aria-label={labelId ? undefined : placeholder}
				aria-expanded={recOpen || typeOpen}
				aria-haspopup="listbox"
				aria-controls={typeOpen ? listboxTypeId : recOpen ? listboxRecId : undefined}
			>
				<!-- ── Type selector (left part) ─────────────────────────────────── -->
				{#if mode === 'forced'}
					{#if !hideType}
						<div class="ref-type ref-type-locked" aria-label={typeLabel}>
							<DoctypeIcon
								icon={iconOf(doctype ?? null)}
								color={tint(doctype ?? '')}
								shadow
								active
							/>
							<span class="ref-tlabel">{typeLabel}</span>
							<svg
								class="ref-lock"
								width="12"
								height="12"
								viewBox="0 0 24 24"
								fill="none"
								stroke="currentColor"
								stroke-width="2"
								aria-hidden="true"
								><rect x="5" y="11" width="14" height="9" rx="2" /><path
									d="M8 11V8a4 4 0 0 1 8 0v3"
								/></svg
							>
						</div>
					{/if}
				{:else}
					<button
						class="ref-type"
						class:ref-type-open={typeOpen}
						onclick={() => {
							if (typeOpen) {
								closeMenus();
							} else {
								openTypeMenu();
							}
						}}
						type="button"
						aria-haspopup="listbox"
						aria-expanded={typeOpen}
						aria-controls={listboxTypeId}
					>
						<DoctypeIcon
							icon={iconOf(selectedType)}
							color={selectedType ? tint(selectedType) : 'var(--text-3)'}
							shadow
							active
						/>
						<span class="ref-tlabel" class:ref-tlabel-ph={!selectedType}>
							{selectedType ? typeLabel : m.doc_ref_select_type()}
						</span>
						<svg
							class="ref-caret"
							width="13"
							height="13"
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="2"
							aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg
						>
					</button>
				{/if}

				<!-- ── Record area (right part) ─────────────────────────────────────── -->
				<div
					class="ref-rec"
					role="button"
					tabindex={selectedRec ? 0 : undefined}
					onclick={() => {
						if (selectedRec && !disabled) startEdit();
					}}
					onkeydown={(e) => {
						// Own-keyboard only. Keydowns from the search input bubble
						// through here; the Enter that picks a record has already set
						// `selectedRec` (state writes land before the batched DOM
						// update), so an ungated startEdit() would undo the pick.
						if (e.target !== e.currentTarget) return;
						if (e.key === 'Enter' && selectedRec && !disabled) startEdit();
					}}
					aria-label={selectedRec ? m.doc_ref_edit_aria() : undefined}
				>
					{#if selectedRec}
						{@render refCapsule(displayLabel(selectedRec), metaFor(selectedRec.id))}
						<button
							class="ref-clear"
							type="button"
							title={m.common_clear()}
							onclick={(e) => {
								e.stopPropagation();
								startEdit();
							}}
							aria-label={m.doc_ref_clear_aria()}>✕</button
						>
					{:else}
						<input
							id={inputId}
							class="ref-input"
							type="text"
							autocomplete="off"
							{placeholder}
							value={query}
							disabled={!selectedType || disabled}
							aria-describedby={meta.describedBy}
							oninput={(e) => {
								runSearch((e.target as HTMLInputElement).value);
							}}
							onfocus={() => {
								if (selectedType && !selectedRec) openRecMenu();
							}}
							onkeydown={onKeyDown}
							aria-invalid={hasError || undefined}
							role="searchbox"
							aria-controls={listboxRecId}
							aria-activedescendant={results[active] ? `${fieldId}-opt-${active}` : undefined}
						/>
					{/if}
				</div>
			</div>

			<!-- ── Type dropdown ────────────────────────────────────────────────── -->
			<div
				id={listboxTypeId}
				class="ref-menu ref-menu-type"
				class:ref-menu-show={typeOpen}
				role="listbox"
				aria-label={m.doc_ref_doctype_aria()}
			>
				{#if mode === 'open'}
					<div class="ref-search">
						<svg
							width="16"
							height="16"
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="2"
							aria-hidden="true"><circle cx="11" cy="11" r="7" /><path d="M21 21l-4.3-4.3" /></svg
						>
						<input
							class="ref-tfilter"
							placeholder={m.doc_ref_filter_placeholder()}
							autocomplete="off"
							oninput={(e) => {
								typeFilter = (e.target as HTMLInputElement).value;
							}}
							onkeydown={(e) => {
								if (e.key === 'Escape') closeMenus();
							}}
						/>
					</div>
				{/if}
				<div class="ref-list">
					{#each filteredTypes as t (t.qualified)}
						<button
							class="ref-opt"
							class:ref-opt-active={t.qualified === selectedType}
							onclick={() => chooseType(t.qualified)}
							role="option"
							aria-selected={t.qualified === selectedType}
							type="button"
						>
							<DoctypeIcon icon={t.icon} color={t.tint} shadow active />
							<span class="ref-tname">{t.label}</span>
							{#if mode !== 'forced'}
								<span class="ref-tqualified">{t.qualified}</span>
							{/if}
						</button>
					{:else}
						<div class="ref-empty">{m.doc_ref_no_doctypes()}</div>
					{/each}
				</div>
			</div>

			<!-- ── Record dropdown ──────────────────────────────────────────────── -->
			<div
				id={listboxRecId}
				class="ref-menu ref-menu-rec"
				class:ref-menu-show={recOpen}
				role="listbox"
				aria-label={m.doc_ref_results_aria()}
			>
				<div class="ref-mhead">
					{typeLabel || m.doc_ref_records()}
					{#if loading}
						<span class="ref-spin" aria-hidden="true"></span>
					{/if}
				</div>
				<div class="ref-list">
					{#if loading}
						<div class="ref-skel" aria-hidden="true">
							<div class="ref-skrow"></div>
							<div class="ref-skrow"></div>
							<div class="ref-skrow"></div>
							<div class="ref-skrow"></div>
						</div>
					{:else if !query && !results.length}
						<div class="ref-hint">
							{selectedType && !selectedLabelled
								? m.doc_ref_search_hint_id({ type: typeLabel.toLowerCase() })
								: typeLabel
									? m.doc_ref_search_hint_type({ type: typeLabel.toLowerCase() })
									: m.doc_ref_search_hint()}
						</div>
					{:else if !results.length}
						<div class="ref-empty">
							{selectedLabelled
								? m.doc_ref_no_matches({ type: typeLabel.toLowerCase(), query })
								: m.doc_ref_no_matches_id({ type: typeLabel.toLowerCase(), query })}
						</div>
					{:else}
						{#each results as r, i (r.id)}
							<button
								class="ref-opt"
								class:ref-opt-active={i === active}
								onclick={() => selectRecord(i)}
								role="option"
								aria-selected={i === active}
								type="button"
								id={`${fieldId}-opt-${i}`}
							>
								{@render refCapsule(displayLabel(r), metaFor(r.id))}
							</button>
						{/each}
					{/if}
				</div>
			</div>
		{/snippet}
	</Field>
</div>

<style>
	.ref-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
		position: relative;
	}

	/* Label, helper and error text render through the shared Field component. */

	.ref {
		display: flex;
		align-items: stretch;
		width: 100%;
		min-height: 42px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.ref-focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.ref-disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.ref-error .ref {
		border-color: var(--danger);
	}

	.ref-error .ref-focus {
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	.ref-type {
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 0 11px;
		border: none;
		border-right: 1px solid var(--border);
		background: var(--surface-2);
		border-radius: calc(var(--r) - 1px) 0 0 calc(var(--r) - 1px);
		font: inherit;
		color: var(--text);
		min-width: 142px;
		white-space: nowrap;
		cursor: pointer;
	}

	.ref-type:hover {
		background: color-mix(in srgb, var(--accent) 10%, var(--surface-2));
	}

	.ref-type-locked {
		cursor: default;
		color: var(--text-2);
	}

	.ref-type-locked:hover {
		background: var(--surface-2);
	}

	.ref-type-open .ref-caret {
		transform: rotate(180deg);
	}

	/* The doctype mark is the shared DoctypeIcon diamond/glyph. */

	.ref-tlabel {
		font-family: var(--font-display);
		font-weight: 500;
		font-size: 13px;
	}

	.ref-tlabel-ph {
		color: var(--text-3);
		font-weight: 400;
	}

	.ref-caret {
		margin-left: auto;
		color: var(--text-3);
		flex: none;
		transition: transform 0.15s;
	}

	.ref-lock {
		margin-left: auto;
		color: var(--text-3);
		flex: none;
	}

	.ref-rec {
		flex: 1;
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 0 6px 0 12px;
		min-width: 0;
	}

	.ref-input {
		flex: 1;
		border: none;
		background: transparent;
		font: inherit;
		font-size: 13.5px;
		color: var(--text);
		outline: none;
		min-width: 0;
		height: 100%;
	}

	.ref-input::placeholder {
		color: var(--text-3);
	}

	.ref-input:disabled {
		cursor: not-allowed;
	}

	.ref-has-sel .ref-rec {
		cursor: pointer;
	}

	.ref-clear {
		display: grid;
		flex: none;
		border: none;
		background: transparent;
		color: var(--text-3);
		cursor: pointer;
		width: 24px;
		height: 24px;
		border-radius: 6px;
		place-items: center;
		font-size: 14px;
		line-height: 1;
	}

	.ref-clear:hover {
		background: var(--surface-2);
		color: var(--danger);
	}

	.ref-capsule {
		--tint: var(--ref-tint, var(--text-2));
		display: inline-flex;
		align-items: center;
		gap: 6px;
		min-width: 0;
		padding: 1px 8px 1px 7px;
		border-radius: var(--r-pill);
		background: color-mix(in srgb, var(--tint) 12%, var(--surface));
		border: 1px solid color-mix(in srgb, var(--tint) 38%, transparent);
		line-height: 1;
	}

	.ref-capsule-label {
		font-size: 12.5px;
		color: var(--text);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		min-width: 0;
	}

	.ref-menu {
		position: absolute;
		top: 100%;
		z-index: 30;
		margin-top: 6px;
		left: 0;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-2);
		overflow: hidden;
		display: none;
	}

	.ref-menu-show {
		display: block;
		animation: ref-pop 0.14s ease-out;
	}

	@keyframes ref-pop {
		from {
			opacity: 0;
			transform: translateY(-4px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	.ref-menu-type {
		min-width: 230px;
	}

	.ref-menu-rec {
		left: 0;
		right: 0;
	}

	.ref-mhead {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 8px 12px;
		border-bottom: 1px solid var(--border);
		font-family: var(--font-mono);
		font-size: 10.5px;
		letter-spacing: 0.08em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.ref-spin {
		width: 13px;
		height: 13px;
		border: 2px solid var(--border);
		border-top-color: var(--accent-ink);
		border-radius: 50%;
		animation: ref-sp 0.7s linear infinite;
		flex: none;
		margin-left: auto;
	}

	@keyframes ref-sp {
		to {
			transform: rotate(360deg);
		}
	}

	.ref-search {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 9px 12px;
		border-bottom: 1px solid var(--border);
	}

	.ref-search svg {
		color: var(--text-3);
		flex: none;
	}

	.ref-tfilter {
		flex: 1;
		border: none;
		background: transparent;
		font: inherit;
		font-size: 13px;
		color: var(--text);
		outline: none;
	}

	.ref-tfilter::placeholder {
		color: var(--text-3);
	}

	.ref-list {
		max-height: 280px;
		overflow: auto;
		padding: 6px;
	}

	.ref-opt {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		padding: 8px 10px;
		border: none;
		background: transparent;
		border-radius: var(--r-sm);
		cursor: pointer;
		font: inherit;
		text-align: left;
		color: var(--text);
	}

	.ref-opt:hover,
	.ref-opt-active {
		background: var(--surface-2);
	}

	.ref-tname {
		font-family: var(--font-display);
		font-weight: 500;
		font-size: 13.5px;
	}

	.ref-tqualified {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		margin-left: auto;
	}

	.ref-hint,
	.ref-empty {
		padding: 22px 16px;
		text-align: center;
		color: var(--text-3);
		font-size: 12.5px;
	}

	.ref-skel {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 6px;
	}

	.ref-skrow {
		height: 34px;
		border-radius: var(--r-sm);
		background: linear-gradient(
			90deg,
			var(--surface-2) 25%,
			var(--border) 37%,
			var(--surface-2) 63%
		);
		background-size: 400% 100%;
		animation: ref-shm 1.3s ease infinite;
	}

	@keyframes ref-shm {
		0% {
			background-position: 100% 0;
		}
		100% {
			background-position: -100% 0;
		}
	}
</style>
