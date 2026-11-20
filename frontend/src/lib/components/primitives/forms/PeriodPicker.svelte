<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import Field from './Field.svelte';
	import Button from '../actions/Button.svelte';
	import DatetimePicker from './DatetimePicker.svelte';
	import type { PeriodValue } from '$lib/doctype/types.js';

	/**
	 * PeriodPicker — form entry for a `{start, end}` range field.
	 *
	 * Two modes mirror the two backend range types:
	 * - `mode: 'datetime'` (a `period` field) — each bound edits through the
	 *   timezone-aware `DatetimePicker`; wall-clock entry converts through the
	 *   user's `core.timezone`, committed bounds are UTC `...Z`.
	 * - `mode: 'date'` (a `dateperiod` field) — each bound is a date-granularity
	 *   `DatetimePicker`; calendar dates commit verbatim, never converted.
	 *
	 * One label covers the pair; the committed value is the complete
	 * `{start, end}` object — the same atomicity the backend enforces (both
	 * bounds required, so a half-filled range is not representable).
	 */

	let {
		label,
		value = $bindable(''),
		mode = 'datetime',
		timezone,
		disabled = false,
		required = false,
		helper,
		error,
		onchange
	}: {
		label?: string;
		/** The bound range. `''` = "not set"; otherwise the complete `{start, end}` pair. */
		value?: PeriodValue;
		/** `datetime` edits UTC timestamp bounds (`period` fields); `date` edits
		 *  `YYYY-MM-DD` calendar-date bounds (`dateperiod` fields). */
		mode?: 'datetime' | 'date';
		/** IANA timezone used for wall-clock entry of the timestamp bounds.
		 *  Defaults to the user's `core.timezone` setting (`auto` → browser
		 *  zone). Ignored in `date` mode — calendar dates never convert. */
		timezone?: string;
		disabled?: boolean;
		required?: boolean;
		helper?: string;
		error?: string;
		onchange?: (v: PeriodValue) => void;
	} = $props();

	// Per-bound committed strings (`''` = bound not set). The pair commits to
	// `value` only when both are complete — see the commit rule below.
	let startVal = $state('');
	let endVal = $state('');

	// Plain-`let` shadow of the last value this component wrote to the parent
	// (the MoneyInput pattern). The seeding effect compares against it so our
	// own writebacks never re-seed the bound editors mid-edit.
	let lastEmittedKey: string | undefined = undefined;

	/** Unique id root for the Start/End sub-labels (`$props.id()`). */
	const uid = $props.id();
	const startLabelId = `${uid}-start`;
	const endLabelId = `${uid}-end`;

	/**
	 * Translate the two bound editors into the bound range and write it.
	 *
	 * Commit rule (the range-level contract of `DatetimePicker`): the value
	 * commits as `{start, end}` only when both bounds are complete, and as
	 * `''` when both are cleared. A partial edit (one bound set, one empty)
	 * is not a representable range — the last committed value holds until the
	 * edit completes either way, so a half-typed edit never wipes a set range.
	 * Called from user-action handlers only, never from a reactive effect.
	 */
	function emit() {
		const both = startVal !== '' && endVal !== '';
		const none = startVal === '' && endVal === '';
		if (!both && !none) return;
		const next: PeriodValue = both ? { start: startVal, end: endVal } : '';
		const key = JSON.stringify(next);
		if (key === lastEmittedKey) return;
		lastEmittedKey = key;
		value = next;
		onchange?.(next);
	}

	// Seed the bound editors from the bound value. Runs on mount and on
	// genuine external resets (form reset, programmatic clear) only.
	$effect(() => {
		const v = value;
		const key = JSON.stringify(v ?? '');
		if (key === lastEmittedKey) return;
		lastEmittedKey = key;
		const obj = v && typeof v === 'object' ? (v as { start?: unknown; end?: unknown }) : null;
		startVal = obj && typeof obj.start === 'string' ? obj.start : '';
		endVal = obj && typeof obj.end === 'string' ? obj.end : '';
	});

	function onClear() {
		if (disabled) return;
		startVal = '';
		endVal = '';
		emit();
	}

	// ── Order hint ──────────────────────────────────────────────────────────
	//
	// A client-side mirror of the backend's bound-order rule, rendered on the
	// End control. The backend stays the source of truth — a 422 still
	// surfaces through the shared `error` (fieldErrors attribute per-bound
	// errors to the one top-level field).

	const orderError = $derived.by(() => {
		if (startVal === '' || endVal === '') return undefined;
		const s = Date.parse(startVal);
		const e = Date.parse(endVal);
		// Incomplete or malformed bounds commit as ''/hold — no order verdict.
		if (Number.isNaN(s) || Number.isNaN(e)) return undefined;
		if (mode === 'date') return s > e ? m.period_order_inclusive() : undefined;
		return s >= e ? m.period_order_exclusive() : undefined;
	});

	const hasError = $derived(Boolean(error || orderError));
	const granularity = $derived(mode === 'date' ? 'date' : 'datetime');

	const committedText = $derived.by(() => {
		const v = value;
		if (v && typeof v === 'object' && v.start && v.end) return `${v.start} → ${v.end}`;
		return m.doc_dt_not_set();
	});

	const clearDisabled = $derived(disabled || (startVal === '' && endVal === ''));
</script>

<div class="pp-wrap" class:pp-error={hasError}>
	<Field {label} {required} {helper} {error} id={uid}>
		{#snippet children(meta)}
			<div
				class="pp-box"
				class:pp-disabled={disabled}
				role="group"
				aria-label={label ?? m.period_group_aria()}
				aria-describedby={meta.describedBy}
			>
				<div class="pp-bound" role="group" aria-labelledby={startLabelId}>
					<span class="pp-bound-label" id={startLabelId}>{m.period_start()}</span>
					<DatetimePicker
						compact
						{disabled}
						{granularity}
						{timezone}
						bind:value={startVal}
						onchange={() => emit()}
					/>
				</div>
				<span class="pp-sep" aria-hidden="true">→</span>
				<div class="pp-bound" role="group" aria-labelledby={endLabelId}>
					<span class="pp-bound-label" id={endLabelId}>{m.period_end()}</span>
					<DatetimePicker
						compact
						{disabled}
						{granularity}
						{timezone}
						bind:value={endVal}
						onchange={() => emit()}
					/>
				</div>
			</div>

			{#if orderError}
				<span class="pp-order-err" role="alert">{orderError}</span>
			{/if}

			<div class="pp-foot">
				<span class="pp-committed">{committedText}</span>
			</div>

			<div class="pp-actions">
				<Button variant="secondary" size="sm" onclick={onClear} disabled={clearDisabled}>
					{m.common_clear()}
				</Button>
			</div>
		{/snippet}
	</Field>
</div>

<style>
	/* ── Wrap ───────────────────────────────────────────────────────────── */
	.pp-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
		position: relative;
	}

	/* ── Box ── one frame over the pair, matching .dtp-field ────────────── */
	.pp-box {
		display: flex;
		align-items: center;
		gap: 16px;
		padding: 6px 10px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		width: fit-content;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.pp-box:focus-within {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.pp-error .pp-box {
		border-color: var(--danger);
	}

	.pp-error .pp-box:focus-within {
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	/* ── Bounds ─────────────────────────────────────────────────────────── */
	.pp-bound {
		display: flex;
		align-items: center;
		gap: 7px;
	}

	.pp-bound-label {
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--text-3);
		white-space: nowrap;
	}

	.pp-sep {
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text-3);
	}

	/* ── Disabled state ── the embedded pickers dim themselves
	   (.dtp-disabled); the box only adds the muted surface and cursor. */
	.pp-disabled {
		cursor: not-allowed;
		background: var(--surface-2);
	}

	/* ── Order hint ── the backend's message family on the End control ──── */
	.pp-order-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	/* ── Footer & actions ── same conventions as DatetimePicker ─────────── */
	.pp-foot {
		display: flex;
		gap: 10px;
		align-items: baseline;
		flex-wrap: wrap;
		font-size: 11.5px;
		color: var(--text-3);
	}

	.pp-committed {
		font-family: var(--font-mono);
	}

	.pp-actions {
		display: flex;
		gap: 6px;
	}
</style>
