<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { untrack } from 'svelte';
	/**
	 * Editable money input — a decimal-amount text field with the currency
	 * selector internalized on the **left** of the input box (the same pattern
	 * `ReferencePicker` uses for its doctype selector), opened as a small
	 * dropdown menu.
	 *
	 * The bound `value` is the canonical money object `{ value: string,
	 * currency: string }` used by the backend's `MoneyType`. `value` is a
	 * decimal *string* (never a JS number; `MoneyType#validate` rejects a
	 * numeric `value` member with `invalid_type`). An empty amount clears the
	 * field: the binding yields `''`, which the form's patch builder coerces
	 * to `null` (the "field cleared" signal).
	 *
	 * The currency dropdown is combobox-style: a filter input at the top narrows
	 * the list by ticker, name, or symbol. The field's declared `currency`
	 * (passed as `preferredCurrency`) is pinned to the top of the list and used
	 * as the default seed when the bound value carries none.
	 *
	 * Used by `DvtInputMoney` (template-driven forms) and the `DocumentForm`
	 * fallback form. Currency options come from the currency store
	 * (`core.Currency` documents — favorites first, then active rows) and
	 * degrade to the current ticker alone when the store is empty.
	 */
	import Field from './Field.svelte';
	import {
		useCurrencies,
		type CurrencyPick,
		type CurrencyRecord
	} from '$lib/components/primitives/data/currencyStore.svelte.js';
	import { canonicalTicker, DEFAULT_CURRENCY } from '$lib/components/primitives/data/currencies.js';
	import { DECIMAL_RE, SEP, caretAfterFormat, formatAmount } from './moneyFormat.js';
	import { SvelteSet } from 'svelte/reactivity';

	let {
		label,
		placeholder = '0',
		helper,
		error,
		required = false,
		preferredCurrency,
		idScope,
		value = $bindable('')
	}: {
		label?: string;
		placeholder?: string;
		helper?: string;
		error?: string;
		required?: boolean;
		/** Field-declared currency ticker — pinned first in the list and seeded when the value has none. */
		preferredCurrency?: string;
		/**
		 * Unique scope for the synthesized id (B-394) — same contract as
		 * `Input`'s: inline child-row editors pass the row's draft id so the
		 * same label keeps a unique id per row.
		 */
		idScope?: string;
		/** Canonical money object `{ value, currency }`, or `''` when cleared. */
		value?: { value: string; currency: string } | string;
	} = $props();

	const currencies = useCurrencies();

	/** Preferred currency ticker (verbatim, or the default when unset). */
	const preferredTicker = $derived(canonicalTicker(preferredCurrency));

	// The synthesized id — one value shared by the label's `for` and the
	// amount input. The scope keeps ids unique when the same label renders
	// per row (B-394).
	const inputId = $derived(
		label ? (idScope ? `money-input-${idScope}-${label}` : `money-input-${label}`) : undefined
	);

	// ── Editable state — the single source of truth for the UI ───────────
	// The composite `value` prop is only ever written from explicitly-typed
	// handlers (input/choose/clear), never from a reactive effect that reads the
	// same state. This avoids the seed↔writeback equality-guard trap (see
	// `doc/frontend/workflow.md` → "The equality-guard trap in writeback effects"),
	// which clobbers user input on every keystroke when an effect round-trips a
	// fresh object through the bindable prop.
	//
	// `amountStr` holds the *raw* decimal string (no separators), the form the
	// backend receives. The displayed text adds `'` grouping between every 3
	// integer-part digits (e.g. `1234567.89` → `1'234'567.89`) via `displayStr`
	// below; the input is driven from `displayStr` (not `bind:value`), so the
	// separator never leaks into the model. This is the "bind:value vs oninput
	// sanitization" pattern documented in the workflow doc.
	let amountStr = $state('');
	// Seeded from the preferred ticker on mount (see the seeding effect below) —
	// initialised to the default until that runs.
	let currency = $state<string>(DEFAULT_CURRENCY);
	let menuOpen = $state(false);
	let filter = $state('');
	let activeIdx = $state(0);
	// When true, the amount input holds a currency *query* (alphabetic text typed
	// into the empty amount field) rather than a decimal amount. Engaged when the
	// field is empty and the first keystroke is a non-digit / non-`-`/`.` char.
	// Exited on selection, Escape, or once the text becomes a valid decimal.
	let typeahead = $state(false);
	// True once the user has explicitly chosen a currency (via the dropdown or the
	// amount-field typeahead). Distinguishes "untouched, amount empty" (show the
	// neutral "Currency" placeholder) from "user picked EUR, amount still empty"
	// (show the committed ticker `EUR`). Reset when the whole field is cleared.
	let currencyExplicit = $state(false);
	let rootEl = $state<HTMLElement | null>(null);
	let inputEl = $state<HTMLInputElement | null>(null);
	let filterEl = $state<HTMLInputElement | null>(null);

	// Plain-`let` shadow of the last composite value this component emitted to
	// the parent. Plain `let`s do not subscribe on read and do not trigger on
	// write, so the seeding effect below can compare against it without creating
	// a feedback loop. When the incoming `value` matches `lastEmitted`, the
	// change originated from our own writeback — ignore it. When it differs, it
	// is an external reset (form reset, programmatic clear, server round-trip)
	// and the editable channels must be re-seeded. Initialized to a sentinel so
	// the very first run on mount always seeds (even when the value starts empty).
	let lastEmitted: string | undefined = undefined;

	/**
	 * Compose the composite value to emit for the current editable state, or `''`
	 * when the field is cleared. While in typeahead mode `amountStr` holds a
	 * currency *query* (not a decimal) — emit `''` so a non-decimal query never
	 * reaches the backend as a money value.
	 */
	function composeEmitted(a: string, c: string): { value: string; currency: string } | '' {
		if (a === '' || typeahead) return '';
		return { value: a, currency: c };
	}

	/**
	 * Write the composite to the bindable `value` and stamp `lastEmitted` so the
	 * seeding effect recognises the value as our own. Called from user-action
	 * handlers only (input, choose, clear) — never from a reactive effect.
	 */
	function emit(a: string, c: string): void {
		const next = composeEmitted(a, c);
		value = next;
		lastEmitted = JSON.stringify(next);
	}

	// Seed from the bound value. Runs only on mount and on external resets (when
	// the incoming value differs from what we last wrote). This is the safe
	// pattern from the workflow doc: read the prop, compare against a plain-`let`
	// shadow of the last emitted value, re-seed only on a genuine external change.
	$effect(() => {
		const incoming = value;
		const key = JSON.stringify(incoming);
		if (key === lastEmitted) return; // our own writeback — ignore
		lastEmitted = key;
		if (incoming && typeof incoming === 'object') {
			amountStr =
				typeof incoming.value === 'string' ? incoming.value : String(incoming.value ?? '');
			// A stored value with an empty/missing `currency` member seeds the
			// field's preferred ticker (see the module docstring) — the default
			// only when the field declares none.
			const stored = typeof incoming.currency === 'string' ? incoming.currency.trim() : '';
			currency = stored !== '' ? incoming.currency : preferredTicker;
			currencyExplicit = amountStr !== '';
		} else {
			amountStr = '';
			currencyExplicit = false;
			typeahead = false;
			// External clear to empty — fall back to the preferred ticker so a
			// subsequent amount entry uses the field's declared currency.
			if (preferredTicker) currency = preferredTicker;
		}
	});

	// The current ticker's row — unknown only when the store lacks it (failed
	// fetch, deleted row, trimmed grant). A missing symbol degrades to the
	// bare ticker on the button.
	const currentRow = $derived(currencies.resolve(currency));

	const symbol = $derived(currentRow?.symbol ?? '');

	// Empty-amount display: when the field is cleared, the currency adornment
	// reads as chrome awaiting input, not a committed ticker — otherwise the
	// box shows "$ USD" with an empty amount, which reads as “auto-defaulted to
	// USD.” The chosen currency is still remembered internally, so re-typing an
	// amount restores it without re-selecting.
	const amountEmpty = $derived(amountStr === '');
	// Show the neutral "Currency" placeholder only when the amount is empty AND
	// the user has not explicitly chosen a currency — picking EUR via typeahead
	// or the dropdown should display EUR even with an empty amount.
	const showPlaceholder = $derived(amountEmpty && !currencyExplicit);
	const displaySymbol = $derived(showPlaceholder ? '' : symbol);
	const displayCode = $derived(showPlaceholder ? m.doc_money_currency_placeholder() : currency);

	/**
	 * Display string bound to the `<input>` `value` attribute. Mirrors `amountStr`
	 * with separators for amounts, or the raw query text while in typeahead mode.
	 */
	const displayStr = $derived(typeahead ? amountStr : formatAmount(amountStr));
	// The shape check is off in typeahead mode: the text is a currency query,
	// not an amount, so typing `EUR` does not flash a decimal error.
	const localError = $derived(
		!typeahead && amountStr !== '' && !DECIMAL_RE.test(amountStr)
			? m.doc_money_invalid()
			: undefined
	);
	// A local shape failure is more actionable than the 422's nested `{field}.value`
	// message, so it takes precedence over any forwarded server `error`.
	const effectiveError = $derived(localError ?? error);
	const hasError = $derived(Boolean(effectiveError));

	/**
	 * Picker options from the currency store: the field's preferred ticker
	 * pinned first, the favorites group, then the active rows. The stored
	 * ticker keeps an option when no selectable row holds it (an inactive row
	 * stays visible — flagged — while it is the current value; an unknown
	 * ticker keeps the stored value visible too). With an empty store (failed
	 * fetch, SSR) the list degrades to the current ticker alone.
	 */
	const baseOptions = $derived.by(() => {
		const picks: Pick<CurrencyPick, 'row' | 'flagged'>[] = [];
		// untrack: interleaved has/add on a tracked set inside a derivation
		// self-dirties it and re-runs the derivation.
		const seen = untrack(() => new SvelteSet<string>());
		const push = (row: CurrencyRecord, flagged: boolean) => {
			if (untrack(() => seen.has(row.ticker))) return;
			untrack(() => seen.add(row.ticker));
			picks.push({ row, flagged });
		};

		const preferred = currencies.resolve(preferredTicker);
		if (preferred && preferred.active) push(preferred, false);
		for (const row of currencies.favorites) push(row, false);
		for (const row of currencies.active) push(row, false);

		if (!seen.has(currency)) {
			const stored = currencies.resolve(currency);
			push(
				stored ?? {
					ticker: currency,
					symbol: '',
					name: '',
					digits: 2,
					grouping: 'standard',
					active: false,
					favorite: false
				},
				// The option only exists because the value holds it — an inactive
				// row (resolved from the store) and an unknown ticker (synthesized
				// row) are both flagged, matching the `CurrencyPick` contract.
				true
			);
		}
		return picks;
	});

	/**
	 * Filtered option list, case-insensitive against ticker / name / symbol.
	 * The query source depends on context: the dropdown's own filter input when
	 * opened via the currency button, or the amount field's text when in
	 * typeahead mode (so typing `EUR` in the amount field narrows the dropdown).
	 */
	const filteredOptions = $derived.by(() => {
		const q = (typeahead ? amountStr : filter).trim().toLowerCase();
		if (!q) return baseOptions;
		return baseOptions.filter(
			(p) =>
				p.row.ticker.toLowerCase().includes(q) ||
				p.row.name.toLowerCase().includes(q) ||
				p.row.symbol.toLowerCase().includes(q)
		);
	});

	/** Rendered options: the favorites group carries its header (after the
	 *  filtering, so a narrowed favorites row still shows the header). */
	const pickerOptions = $derived.by(() => {
		const isFavoritePick = (p: { row: CurrencyRecord; flagged: boolean }) =>
			p.row.favorite && !p.flagged;
		return filteredOptions.map((p, i, arr) => ({
			...p,
			groupLabel:
				isFavoritePick(p) && (i === 0 || !isFavoritePick(arr[i - 1]))
					? m.doc_money_favorites()
					: undefined
		})) satisfies CurrencyPick[];
	});

	function toggleMenu(): void {
		menuOpen = !menuOpen;
		if (menuOpen) {
			// Opening via the currency button: the amount field keeps its text; the
			// dropdown's own filter input handles narrowing (focused by the effect below).
			filter = '';
			typeahead = false;
			activeIdx = Math.max(
				0,
				pickerOptions.findIndex((c) => c.row.ticker === currency)
			);
		} else {
			inputEl?.focus();
		}
	}

	function closeMenu(): void {
		menuOpen = false;
		// If the user abandoned a typeahead query (clicked away), drop the query
		// text so the field returns to a clean empty state rather than leaving an
		// uncommitted "EUR" sitting in the amount input.
		if (typeahead) {
			typeahead = false;
			amountStr = '';
			emit('', currency);
		}
	}

	function choose(ticker: string): void {
		currency = ticker;
		currencyExplicit = true;
		const wasTypeahead = typeahead;
		typeahead = false;
		closeMenu();
		// When the currency was chosen from a typeahead query typed in the amount
		// field, clear the query so the user types the amount next.
		if (wasTypeahead) {
			amountStr = '';
			emit('', ticker);
		} else {
			emit(amountStr, ticker);
		}
		inputEl?.focus();
	}

	function endTypeahead(clearText: boolean): void {
		typeahead = false;
		menuOpen = false;
		if (clearText) {
			amountStr = '';
			emit('', currency);
		}
		inputEl?.focus();
	}

	/**
	 * Amount-input handler. The displayed text may carry `'` separators (or be a
	 * typeahead currency query). This handler:
	 *  1. Reads the raw DOM value typed by the user.
	 *  2. Strips `'` separators to recover the canonical decimal (or keeps the
	 *     text as-is for a currency query).
	 *  3. Re-derives the formatted display, writes it back to `target.value` so the
	 *     separator stays grouped as the user types/edits, and re-applies the caret
	 *     using a significant-character offset so mid-string edits don't jump the
	 *     cursor to the end.
	 *  4. Stores the raw decimal in `amountStr` and emits.
	 */
	function onAmountInput(e: Event): void {
		const target = e.target as HTMLInputElement;
		const typed = target.value;
		const caret = target.selectionStart ?? typed.length;
		// The raw model strips separators. While in typeahead mode the field holds a
		// currency query (letters) — pass it through unchanged.
		const raw = typeahead ? typed : typed.split(SEP).join('');
		amountStr = raw;
		if (!typeahead && raw !== '' && /^[^0-9.'-]/.test(raw)) {
			// A non-digit / non-`.` / non-`-` / non-`'` leading char starts currency
			// typeahead (digit/`.`/`-`/`'` stay in amount-entry mode).
			typeahead = true;
			menuOpen = true;
			activeIdx = 0;
		}
		const display = typeahead ? raw : formatAmount(raw);
		// Force the DOM display to the formatted string (the `value` attribute
		// alone would not re-render when Svelte sees the model unchanged).
		target.value = display;
		// Re-apply the caret after the same count of significant (non-separator)
		// characters it had before the re-format.
		const placed = caretAfterFormat(typed, caret, display);
		target.setSelectionRange(placed, placed);
		if (typeahead) {
			activeIdx = 0;
			// In typeahead mode the amount field holds a currency query, not a
			// decimal — emit `''` (cleared) so the query never reaches the backend.
			emit('', currency);
		} else {
			emit(raw, currency);
		}
	}

	/** Amount-field keyboard handler — mirrors the dropdown filter input while in typeahead mode. */
	function onAmountKeyDown(e: KeyboardEvent): void {
		if (!typeahead) return;
		const n = pickerOptions.length;
		if (e.key === 'Escape') {
			e.stopPropagation();
			endTypeahead(true);
			return;
		}
		if (e.key === 'ArrowDown' && n > 0) {
			e.preventDefault();
			activeIdx = (activeIdx + 1) % n;
		} else if (e.key === 'ArrowUp' && n > 0) {
			e.preventDefault();
			activeIdx = (activeIdx - 1 + n) % n;
		} else if ((e.key === 'Enter' || e.key === ' ') && n > 0) {
			// Enter or Space selects the active currency (mirrors Enter): the user
			// types a ticker prefix and presses Space to commit it, then continues
			// typing the amount (e.g. `EUR ` → selects EUR → `1000` = `EUR 1000`).
			// `preventDefault` stops a literal space being inserted into the query.
			e.preventDefault();
			choose(pickerOptions[activeIdx].row.ticker);
		} else if (e.key === 'Tab' && n === 1) {
			choose(pickerOptions[0].row.ticker);
		}
	}

	function onFilterInput(e: Event): void {
		filter = (e.target as HTMLInputElement).value;
		activeIdx = 0;
	}

	function onFilterKeyDown(e: KeyboardEvent): void {
		const n = pickerOptions.length;
		if (e.key === 'Escape') {
			e.stopPropagation();
			closeMenu();
			inputEl?.focus();
			return;
		}
		if (e.key === 'ArrowDown' && n > 0) {
			e.preventDefault();
			activeIdx = (activeIdx + 1) % n;
		} else if (e.key === 'ArrowUp' && n > 0) {
			e.preventDefault();
			activeIdx = (activeIdx - 1 + n) % n;
		} else if (e.key === 'Enter' && n > 0) {
			e.preventDefault();
			choose(pickerOptions[activeIdx].row.ticker);
		} else if (e.key === 'Tab' && n === 1) {
			// A single remaining match: Tab accepts it (common combobox affordance).
			choose(pickerOptions[0].row.ticker);
		}
	}

	function onDocClick(e: MouseEvent): void {
		if (!menuOpen) return;
		if (rootEl && e.composedPath().includes(rootEl)) return;
		closeMenu();
	}

	// When the menu opens via the currency button, focus the dropdown filter
	// input so typing narrows the list. NOT when opening via amount-field
	// typeahead — there the amount input is the query source and must keep focus.
	$effect(() => {
		if (menuOpen && !typeahead && filterEl) filterEl.focus();
	});
</script>

<svelte:window onclick={onDocClick} />

<div class="money-input-wrap" class:money-input-error={hasError} bind:this={rootEl}>
	<Field {label} {required} {helper} error={effectiveError} id={inputId} forId={inputId}>
		{#snippet children(meta)}
			<div
				class="money-input-box"
				class:money-input-focus={menuOpen}
				role="group"
				aria-label={label ?? m.doc_money_group_aria()}
				aria-describedby={meta.describedBy}
			>
				<!-- ── Currency selector (left, internal) ─────────────────────────── -->
				<button
					class="money-currency"
					class:money-currency-open={menuOpen}
					type="button"
					onclick={toggleMenu}
					aria-haspopup="listbox"
					aria-expanded={menuOpen}
					aria-controls="money-currency-listbox"
					aria-label={m.doc_money_currency_aria()}
				>
					{#if displaySymbol}
						<span class="money-currency-symbol" aria-hidden="true">{displaySymbol}</span>
					{/if}
					<span class="money-currency-code" class:money-currency-code-ph={showPlaceholder}
						>{displayCode}</span
					>
					<svg
						class="money-currency-caret"
						width="12"
						height="12"
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="2"
						aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg
					>
				</button>

				<!-- ── Amount input (right, fills the rest) ──────────────────────── -->
				<!-- No `bind:value`: the displayed text carries `'` separators while the
		     raw model (`amountStr`) does not, so the input is driven from
		     `displayStr` and reconciled in `onAmountInput` (workflow doc →
		     "bind:value vs oninput sanitization"). -->
				<input
					id={inputId}
					class="money-amount"
					type="text"
					inputmode="decimal"
					{placeholder}
					{required}
					value={displayStr}
					bind:this={inputEl}
					oninput={onAmountInput}
					onkeydown={onAmountKeyDown}
					aria-invalid={hasError || undefined}
				/>

				<!-- ── Currency dropdown ──────────────────────────────────────────── -->
				{#if menuOpen}
					<div
						id="money-currency-listbox"
						class="money-menu"
						role="listbox"
						aria-label={m.doc_money_currency_aria()}
					>
						<div class="money-menu-search">
							<input
								class="money-menu-filter"
								placeholder={m.doc_money_filter_placeholder()}
								autocomplete="off"
								bind:this={filterEl}
								bind:value={filter}
								oninput={onFilterInput}
								onkeydown={onFilterKeyDown}
							/>
						</div>
						<div class="money-menu-list">
							{#if pickerOptions.length === 0}
								<div class="money-menu-empty">{m.doc_money_no_match({ filter })}</div>
							{:else}
								{#each pickerOptions as opt, i (opt.row.ticker)}
									{#if opt.groupLabel}
										<div class="money-menu-group" role="presentation">{opt.groupLabel}</div>
									{/if}
									<button
										class="money-opt"
										class:money-opt-active={opt.row.ticker === currency}
										class:money-opt-focus={i === activeIdx}
										type="button"
										role="option"
										aria-selected={opt.row.ticker === currency}
										onclick={() => choose(opt.row.ticker)}
										onmouseenter={() => (activeIdx = i)}
									>
										<span class="money-opt-symbol" aria-hidden="true">{opt.row.symbol}</span>
										<span class="money-opt-code">{opt.row.ticker}</span>
										{#if opt.flagged}
											<span class="money-opt-flag">{m.doc_money_inactive()}</span>
										{:else if opt.row.name !== ''}
											<span class="money-opt-name">{opt.row.name}</span>
										{/if}
									</button>
								{/each}
							{/if}
						</div>
					</div>
				{/if}
			</div>
		{/snippet}
	</Field>
</div>

<style>
	.money-input-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
		position: relative;
	}

	/* Label, helper and error text render through the shared Field component.
	   Field gets the effective error (local shape check wins over the prop). */

	/* ── Box (one element, border + focus ring) ─────────────────────────── */
	.money-input-box {
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
		position: relative;
	}

	.money-input-box:focus-within,
	.money-input-focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.money-input-error .money-input-box {
		border-color: var(--danger);
	}

	.money-input-error .money-input-box:focus-within,
	.money-input-error .money-input-focus {
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	/* ── Currency button (left adornment) ───────────────────────────────── */
	.money-currency {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 0 10px;
		border: none;
		border-right: 1px solid var(--border);
		background: var(--surface-2);
		border-radius: calc(var(--r) - 1px) 0 0 calc(var(--r) - 1px);
		font: inherit;
		color: var(--text);
		white-space: nowrap;
		cursor: pointer;
	}

	.money-currency:hover {
		background: color-mix(in srgb, var(--accent) 10%, var(--surface-2));
	}

	.money-currency-open {
		background: color-mix(in srgb, var(--accent) 10%, var(--surface-2));
	}

	.money-currency-open .money-currency-caret {
		transform: rotate(180deg);
	}

	.money-currency-symbol {
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text-2);
	}

	.money-currency-code {
		font-family: var(--font-mono);
		font-weight: 500;
		font-size: 12px;
		color: var(--text-2);
	}

	/* Placeholder look when the amount is empty — reads as chrome, not a value. */
	.money-currency-code-ph {
		color: var(--text-3);
		font-weight: 400;
	}

	.money-currency-caret {
		color: var(--text-3);
		flex: none;
		transition: transform 0.15s;
	}

	/* ── Amount input (fills the rest of the box) ───────────────────────── */
	.money-amount {
		flex: 1;
		min-width: 0;
		border: none;
		background: transparent;
		font: inherit;
		font-size: 13px;
		line-height: 1.5;
		color: var(--text);
		padding: 9px 11px;
		outline: none;
		border-radius: 0 calc(var(--r) - 1px) calc(var(--r) - 1px) 0;
	}

	.money-amount::placeholder {
		color: var(--text-3);
	}

	/* ── Currency dropdown ──────────────────────────────────────────────── */
	.money-menu {
		position: absolute;
		top: 100%;
		left: 0;
		z-index: 30;
		margin-top: 6px;
		min-width: 200px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-2);
		overflow: hidden;
		animation: money-pop 0.14s ease-out;
	}

	@keyframes money-pop {
		from {
			opacity: 0;
			transform: translateY(-4px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	.money-menu-list {
		max-height: 280px;
		overflow: auto;
		padding: 6px;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.money-menu-search {
		display: flex;
		align-items: center;
		padding: 9px 12px;
		border-bottom: 1px solid var(--border);
	}

	.money-menu-filter {
		flex: 1;
		border: none;
		background: transparent;
		font: inherit;
		font-size: 13px;
		color: var(--text);
		outline: none;
	}

	.money-menu-filter::placeholder {
		color: var(--text-3);
	}

	.money-menu-empty {
		padding: 18px 16px;
		text-align: center;
		color: var(--text-3);
		font-size: 12.5px;
	}

	/* Group header — the favorites group renders its label; other groups
	   (preferred pin, active rows, the stored ticker) stay unlabeled. */
	.money-menu-group {
		padding: 6px 10px 2px;
		font-size: 10px;
		font-weight: 600;
		letter-spacing: 0.07em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.money-opt {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		padding: 7px 10px;
		border: none;
		background: transparent;
		border-radius: var(--r-sm);
		cursor: pointer;
		font: inherit;
		text-align: left;
		color: var(--text);
	}

	.money-opt:hover,
	.money-opt-focus {
		background: var(--surface-2);
	}

	.money-opt-active {
		background: color-mix(in srgb, var(--accent) 12%, var(--surface));
	}

	.money-opt-symbol {
		flex: none;
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text-2);
		width: 14px;
		text-align: center;
	}

	.money-opt-code {
		flex: none;
		font-family: var(--font-mono);
		font-weight: 500;
		font-size: 12.5px;
		width: 32px;
	}

	.money-opt-name {
		font-size: 12.5px;
		color: var(--text-3);
		margin-left: auto;
	}

	/* The stored-but-inactive (or unknown) ticker keeps its option — flagged,
	   so the user sees why the row looks different from the selectable ones. */
	.money-opt-flag {
		font-size: 10.5px;
		font-weight: 500;
		color: var(--warn);
		margin-left: auto;
		white-space: nowrap;
	}

	/* Helper and error text render through the shared Field component. */
</style>
