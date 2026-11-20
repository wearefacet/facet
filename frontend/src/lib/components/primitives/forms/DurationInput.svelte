<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import Field from './Field.svelte';
	import { UNITS, fromParts, parseDuration, toParts, type UnitKey } from './durationMath.js';

	/**
	 * Duration input — four spinbutton cells (days / hours / minutes / seconds)
	 * bound to a single integer seconds count.
	 *
	 * Interaction model (translated from the React inspiration):
	 * - Type digits: replaces/advances within a cell, auto-advances on full length
	 *   or when the next digit would overflow the unit's cap.
	 * - ↑/↓: bump by one unit (Shift = ×10); PageUp/Down = ×10.
	 * - ←/→ + Home/End: move focus across cells.
	 * - d/h/m/s letter keys jump focus to that cell.
	 * - Backspace/Delete: clear the cell (or move left if already zero).
	 * - Drag a cell vertically to scrub its unit.
	 * - Paste anywhere parses `1d 2h30m`, `26:30:00`, `90`, `1 hour 5 min`.
	 * - Optional presets render as chips; an optional `max` clamps the total.
	 */

	type Preset = { label: string; value: number };

	let {
		value = $bindable(''),
		units = ['d', 'h', 'm', 's'] as UnitKey[],
		label,
		helper,
		error,
		hint,
		disabled = false,
		required = false,
		max = Infinity,
		min = 0,
		presets,
		id
	}: {
		/** Total duration in seconds, or the `''` unset sentinel (B-310).
		 *  Negative values are clamped to 0 (or `min`). Zero is a real,
		 *  explicitly entered value — only `''` means unset. */
		value?: number | '';
		/** Ordered unit list. The first unit is uncapped at render time. */
		units?: UnitKey[];
		label?: string;
		helper?: string;
		error?: string;
		/** Hint text rendered under the field describing the keyboard shortcuts. */
		hint?: string;
		disabled?: boolean;
		required?: boolean;
		/** Upper clamp (seconds). When reached, an "at maximum" tag appears. */
		max?: number;
		/** Lower clamp (seconds). Defaults to 0 (durations are non-negative). */
		min?: number;
		/** Quick-pick chips rendered below the field. */
		presets?: Preset[];
		id?: string;
	} = $props();

	const hasError = $derived(Boolean(error));
	const inputId = $derived(id ?? (label ? `duration-${label}` : undefined));
	// Shared field chrome: hint text wins over helper text, same chain as before.
	const helperText = $derived(hint || helper);

	// Focused cell index, -1 when none.
	let focused = $state(-1);
	// In-flight digit entry: { index, digits } while a cell is being typed.
	let draft = $state<{ index: number; digits: string } | null>(null);
	// Pulse the gold focus ring briefly on paste/preset picks.
	let flash = $state(false);
	let flashTimer: ReturnType<typeof setTimeout> | null = null;

	// Cell element refs (one per unit) for focus navigation.
	let cells: (HTMLDivElement | null)[] = $state([]);
	// Active vertical drag.
	let drag: { i: number; y: number; start: number; moved: boolean } | null = null;

	// The numeric working total. The `''` unset sentinel behaves as 0 for
	// display and math; every user mutation replaces it with a real number,
	// so an untouched widget stays unset while a touched one commits.
	const total = $derived(typeof value === 'number' ? value : 0);

	const parts = $derived(toParts(total, units));

	function clamp(n: number, lo: number, hi: number): number {
		return Math.min(hi, Math.max(lo, n));
	}

	function commitTotal(next: number) {
		value = clamp(Math.round(next), min, max);
	}

	function setPart(index: number, v: number) {
		const unitKey = units[index];
		const cap = UNITS[unitKey].cap;
		const next = [...parts];
		next[index] = clamp(v, 0, cap);
		commitTotal(fromParts(next, units));
	}

	function bump(index: number, step: number) {
		commitTotal(total + step * UNITS[units[index]].mult);
	}

	function flushDraft() {
		if (!draft) return;
		setPart(draft.index, parseInt(draft.digits || '0', 10));
		draft = null;
	}

	function focusCell(i: number) {
		const next = clamp(i, 0, units.length - 1);
		cells[next]?.focus();
	}

	function pulse() {
		flash = true;
		if (flashTimer) clearTimeout(flashTimer);
		flashTimer = setTimeout(() => {
			flash = false;
		}, 320);
	}

	function onKeyDown(e: KeyboardEvent, i: number) {
		if (disabled) return;
		const unitKey = units[i];
		const cap = UNITS[unitKey].cap;

		if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
			e.preventDefault();
			flushDraft();
			const step = (e.key === 'ArrowUp' ? 1 : -1) * (e.shiftKey ? 10 : 1);
			bump(i, step);
			return;
		}
		if (e.key === 'PageUp' || e.key === 'PageDown') {
			e.preventDefault();
			flushDraft();
			bump(i, e.key === 'PageUp' ? 10 : -10);
			return;
		}
		if (e.key === 'ArrowLeft') {
			e.preventDefault();
			flushDraft();
			focusCell(i - 1);
			return;
		}
		if (e.key === 'ArrowRight') {
			e.preventDefault();
			flushDraft();
			focusCell(i + 1);
			return;
		}
		if (e.key === 'Home' || e.key === 'End') {
			e.preventDefault();
			flushDraft();
			focusCell(e.key === 'Home' ? 0 : units.length - 1);
			return;
		}
		if (e.key === 'Backspace' || e.key === 'Delete') {
			e.preventDefault();
			if (draft && draft.digits.length > 1) {
				draft = { index: i, digits: draft.digits.slice(0, -1) };
			} else if (parts[i] !== 0 || draft) {
				draft = null;
				setPart(i, 0);
			} else {
				focusCell(i - 1);
			}
			return;
		}
		if (/^[dhms]$/.test(e.key)) {
			const target = units.indexOf(e.key as UnitKey);
			if (target >= 0) {
				e.preventDefault();
				flushDraft();
				focusCell(target);
			}
			return;
		}
		if (/^[0-9]$/.test(e.key)) {
			e.preventDefault();
			const digits = (draft?.index === i ? draft.digits : '') + e.key;
			const n = parseInt(digits, 10);
			const maxLen = UNITS[unitKey].len;

			if (n > cap && i !== 0) {
				// Next digit would overflow the unit — start fresh with this digit.
				setPart(i, clamp(parseInt(e.key, 10), 0, cap));
				draft = { index: i, digits: e.key };
				return;
			}
			setPart(i, n);
			if (digits.length >= maxLen || n * 10 > cap) {
				draft = null;
				if (i < units.length - 1) focusCell(i + 1);
			} else {
				draft = { index: i, digits };
			}
			return;
		}
		if (e.key === 'Enter' || e.key === 'Escape') {
			flushDraft();
			(e.currentTarget as HTMLElement).blur();
		}
	}

	function onPaste(e: ClipboardEvent) {
		if (disabled) return;
		const text = e.clipboardData?.getData('text') ?? '';
		const parsed = parseDuration(text);
		if (parsed !== null) {
			e.preventDefault();
			draft = null;
			commitTotal(parsed);
			pulse();
		}
	}

	function onPointerDown(e: PointerEvent, i: number) {
		if (disabled || e.button !== 0) return;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		drag = { i, y: e.clientY, start: total, moved: false };
	}

	function onPointerMove(e: PointerEvent) {
		if (!drag) return;
		const steps = Math.round((drag.y - e.clientY) / 7);
		if (steps === 0 && !drag.moved) return;
		drag.moved = true;
		commitTotal(drag.start + steps * UNITS[units[drag.i]].mult);
	}

	function onPointerUp(e: PointerEvent) {
		if (drag) {
			try {
				(e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
			} catch {
				// Swallow: the pointer may already be released.
			}
			drag = null;
		}
	}

	function onClear() {
		if (disabled) return;
		draft = null;
		// Clear means unset (B-310): emit the '' sentinel, not 0.
		value = '';
		focusCell(units.length - 1);
	}

	function onPreset(p: Preset) {
		if (disabled) return;
		commitTotal(p.value);
		pulse();
	}

	// Clear the digit draft when focus leaves all cells.
	$effect(() => {
		if (focused === -1) draft = null;
	});

	function formatHuman(total: number, u: UnitKey[]): string {
		if (total <= 0) return m.doc_duration_none();
		return toParts(total, u)
			.map((v, i) => (v ? `${v} ${UNITS[u[i]].short}` : null))
			.filter(Boolean)
			.join('  ');
	}

	function formatISO(total: number): string {
		if (total <= 0) return 'PT0S';
		const [d, h, m, s] = toParts(total, ['d', 'h', 'm', 's']);
		const date = d ? `${d}D` : '';
		const time = [h && `${h}H`, m && `${m}M`, s && `${s}S`].filter(Boolean).join('');
		return `P${date}${time ? 'T' + time : ''}`;
	}

	const atMax = $derived(total >= max && max !== Infinity);
	// Dim units before the first non-zero unit (and all but the last when zero).
	const leading = $derived(parts.findIndex((v) => v > 0));
	// The clear affordance is off only while the field is already unset.
	const isCleared = $derived(value === '');

	function cellDisplay(unitKey: UnitKey, i: number, raw: number): string {
		const shown =
			draft?.index === i
				? draft.digits.padStart(UNITS[unitKey].len, '0')
				: String(raw).padStart(i === 0 ? 2 : UNITS[unitKey].len, '0');
		return shown;
	}

	function cellDimmed(i: number): boolean {
		// The unset sentinel dims every cell — a placeholder state, not a value.
		if (value === '') return true;
		if (leading === -1) return i < units.length - 1;
		return i < leading;
	}
</script>

<div class="dur-wrap" class:dur-error={hasError}>
	<Field
		{label}
		{required}
		helper={helperText}
		{error}
		id={inputId ?? undefined}
		forId={inputId ?? undefined}
	>
		{#snippet children(meta)}
			<!-- svelte-ignore a11y_no_static_element_interactions -->
			<div
				class="dur-field"
				class:is-flash={flash}
				class:dur-disabled={disabled}
				id={inputId}
				role="group"
				aria-label={label ?? m.common_duration_aria()}
				aria-describedby={meta.describedBy}
				onpaste={onPaste}
			>
				{#each units as unitKey, i (unitKey)}
					<div class="dur-cellwrap">
						{#if i > 0}
							<span class="dur-sep" aria-hidden="true">:</span>
						{/if}
						<!-- svelte-ignore a11y_no_static_element_interactions -->
						<div
							bind:this={cells[i]}
							class="dur-cell"
							class:is-focus={focused === i}
							class:is-dim={cellDimmed(i)}
							tabindex={disabled ? -1 : 0}
							role="spinbutton"
							aria-label={UNITS[unitKey].label}
							aria-invalid={hasError || undefined}
							aria-valuenow={parts[i]}
							aria-valuemin={0}
							aria-valuemax={UNITS[unitKey].cap}
							aria-valuetext={`${parts[i]} ${UNITS[unitKey].short}`}
							aria-disabled={disabled || undefined}
							onfocus={() => (focused = i)}
							onblur={() => {
								flushDraft();
								focused = focused === i ? -1 : focused;
							}}
							onkeydown={(e) => onKeyDown(e, i)}
							onpointerdown={(e) => onPointerDown(e, i)}
							onpointermove={onPointerMove}
							onpointerup={onPointerUp}
							onpointercancel={onPointerUp}
						>
							<span class="dur-digits">{cellDisplay(unitKey, i, parts[i])}</span>
							<span class="dur-unit">{UNITS[unitKey].short}</span>
							<span class="dur-stepper" aria-hidden="true">
								<button
									tabindex={-1}
									type="button"
									{disabled}
									onpointerdown={(e) => e.stopPropagation()}
									onclick={() => bump(i, 1)}
									aria-hidden="true">▲</button
								>
								<button
									tabindex={-1}
									type="button"
									{disabled}
									onpointerdown={(e) => e.stopPropagation()}
									onclick={() => bump(i, -1)}
									aria-hidden="true">▼</button
								>
							</span>
						</div>
					</div>
				{/each}

				<button
					class="dur-clear"
					type="button"
					disabled={disabled || isCleared}
					onclick={onClear}
					aria-label={m.doc_duration_clear_aria()}
					title={m.common_clear()}>✕</button
				>
			</div>

			{#if presets && presets.length > 0}
				<div class="dur-presets">
					{#each presets as p (p.label)}
						<button
							class="dur-chip"
							class:is-on={value === p.value}
							type="button"
							{disabled}
							onclick={() => onPreset(p)}>{p.label}</button
						>
					{/each}
				</div>
			{/if}

			<div class="dur-foot">
				<span class="dur-human">{formatHuman(total, units)}</span>
				<span class="dur-iso">{formatISO(total)}</span>
				{#if atMax}<span class="dur-warn">{m.doc_duration_max()}</span>{/if}
			</div>
		{/snippet}
	</Field>
</div>

<style>
	/* ── Wrap ───────────────────────────────────────────────────────── */
	.dur-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	/* Label, hint and error text render through the shared Field component. */

	.dur-field {
		display: flex;
		align-items: stretch;
		gap: 2px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 6px;
		position: relative;
		transition:
			border-color 0.18s ease,
			box-shadow 0.18s ease;
	}

	.dur-field:hover {
		border-color: var(--border-strong);
	}

	.dur-field.is-flash {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.dur-disabled {
		opacity: 0.5;
		cursor: not-allowed;
		background: var(--surface-2);
	}

	/* ── Cell + separator ────────────────────────────────────────────── */
	.dur-cellwrap {
		display: flex;
		align-items: stretch;
	}

	.dur-sep {
		align-self: center;
		color: var(--text-3);
		font-family: var(--font-mono);
		font-size: 18px;
		padding: 0 2px;
		user-select: none;
		margin-top: -6px;
	}

	/* svelte-ignore a11y_no_static_element_interactions */
	.dur-cell {
		position: relative;
		display: flex;
		flex-direction: column;
		align-items: center;
		padding: 6px 10px 4px;
		border-radius: var(--r-sm);
		cursor: ns-resize;
		outline: none;
		touch-action: none;
		user-select: none;
		transition: background 0.15s ease;
	}

	.dur-cell:hover {
		background: var(--accent-weak);
	}

	.dur-cell.is-focus {
		background: var(--accent-weak);
	}

	.dur-cell.is-focus::after {
		content: '';
		position: absolute;
		left: 8px;
		right: 8px;
		bottom: 2px;
		height: 2px;
		background: var(--accent-ink);
		border-radius: 2px;
	}

	.dur-disabled .dur-cell {
		cursor: not-allowed;
	}

	/* ── Digits + unit label ─────────────────────────────────────────── */
	.dur-digits {
		font-family: var(--font-mono);
		font-size: 18px;
		font-weight: 500;
		line-height: 1.1;
		font-variant-numeric: tabular-nums;
		color: var(--text);
	}

	.dur-cell.is-dim .dur-digits {
		color: var(--text-3);
	}

	.dur-cell.is-focus.is-dim .dur-digits {
		color: var(--text-2);
	}

	.dur-unit {
		font-size: 9.5px;
		letter-spacing: 0.12em;
		text-transform: uppercase;
		color: var(--text-3);
		margin-top: 3px;
	}

	.dur-cell.is-focus .dur-unit {
		color: var(--accent-ink);
	}

	/* ── Stepper ─────────────────────────────────────────────────────── */
	.dur-stepper {
		position: absolute;
		right: -1px;
		top: 4px;
		bottom: 4px;
		display: flex;
		flex-direction: column;
		justify-content: center;
		gap: 2px;
		opacity: 0;
		transition: opacity 0.15s ease;
	}

	.dur-cell:hover .dur-stepper,
	.dur-cell.is-focus .dur-stepper {
		opacity: 1;
	}

	.dur-stepper button {
		all: unset;
		cursor: pointer;
		font-size: 6px;
		line-height: 1;
		color: var(--text-3);
		padding: 2px 3px;
		border-radius: 3px;
	}

	.dur-stepper button:hover {
		color: var(--accent-ink);
		background: var(--accent-weak);
	}

	.dur-stepper button:disabled {
		opacity: 0.3;
		cursor: not-allowed;
	}

	/* ── Clear button ────────────────────────────────────────────────── */
	.dur-clear {
		all: unset;
		cursor: pointer;
		margin-left: auto;
		align-self: center;
		color: var(--text-3);
		font-size: 11px;
		padding: 6px 8px;
		border-radius: var(--r-sm);
		transition:
			color 0.15s ease,
			background 0.15s ease;
	}

	.dur-clear:hover:not(:disabled) {
		color: var(--text);
		background: var(--surface-2);
	}

	.dur-clear:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.dur-clear:disabled {
		opacity: 0.25;
		cursor: default;
	}

	/* ── Presets ─────────────────────────────────────────────────────── */
	.dur-presets {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		margin-top: 4px;
	}

	.dur-chip {
		all: unset;
		cursor: pointer;
		font-family: var(--font-mono);
		font-size: 11.5px;
		padding: 4px 10px;
		border-radius: var(--r-pill);
		border: 1px solid var(--border);
		color: var(--text-3);
		transition:
			color 0.15s ease,
			border-color 0.15s ease,
			background 0.15s ease;
	}

	.dur-chip:hover:not(:disabled) {
		color: var(--text);
		border-color: var(--border-strong);
	}

	.dur-chip:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.dur-chip:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}

	.dur-chip.is-on {
		color: var(--on-accent);
		background: var(--accent);
		border-color: var(--accent);
		font-weight: 600;
	}

	/* ── Footer (human + ISO) ────────────────────────────────────────── */
	.dur-foot {
		display: flex;
		align-items: baseline;
		gap: 10px;
		margin-top: 4px;
		flex-wrap: wrap;
	}

	.dur-human {
		font-size: 12.5px;
		color: var(--text-2);
	}

	.dur-iso {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	.dur-warn {
		font-size: 10.5px;
		color: var(--warn);
		letter-spacing: 0.06em;
		text-transform: uppercase;
	}

	/* Hint and error text render through the shared Field component. */

	/* ── Error state ─────────────────────────────────────────── */
	.dur-error .dur-field {
		border-color: var(--danger);
	}

	.dur-error .dur-field:focus-within {
		border-color: var(--danger);
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	@media (prefers-reduced-motion: reduce) {
		.dur-field,
		.dur-cell,
		.dur-stepper,
		.dur-clear,
		.dur-chip {
			transition: none;
		}
	}
</style>
