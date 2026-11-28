<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import Field from './Field.svelte';
	import Button from '../actions/Button.svelte';
	import CalendarPanel from './CalendarPanel.svelte';
	import { displayTimezone } from '$lib/settings.svelte';
	import { nowWall, type CalendarCell } from './calendarGrid.js';
	import {
		daysInMonth,
		isValidWall,
		utcIsoToWall,
		wallToUtcIso,
		wallToUtcMs,
		zoneOffsetLabel,
		type Wall
	} from '$lib/zonedTime.js';
	import { Popover } from 'bits-ui';

	type SegKey = 'y' | 'm' | 'd' | 'h' | 'mi';

	let {
		label,
		value = $bindable(''),
		timezone,
		disabled = false,
		required = false,
		helper,
		error,
		compact = false,
		granularity = 'datetime',
		onchange
	}: {
		label?: string;
		/** Committed value. `granularity: 'datetime'` — a UTC RFC-3339 timestamp
		 *  (`...Z`); `granularity: 'date'` — a `YYYY-MM-DD` calendar date. `''`
		 *  means "not set". */
		value?: string;
		/** IANA timezone used for wall-clock entry. Defaults to the user's `core.timezone` setting (`auto` → browser zone). */
		timezone?: string;
		disabled?: boolean;
		required?: boolean;
		helper?: string;
		error?: string;
		/** Compact embed mode: renders the bare segment field only — no label,
		 * footer, or actions. For filter chips and inline grid cells. A `label`
		 * still feeds the group's aria-label. */
		compact?: boolean;
		/** Entry granularity. `'datetime'` (default) edits the full
		 *  `YYYY-MM-DD HH:MM` segments and commits UTC instants. `'date'` hides
		 *  the time segments, the quick time slots, and the footer readout: the
		 *  user edits a calendar date, the committed value is `YYYY-MM-DD`
		 *  verbatim — a calendar date is not an instant, so it never converts
		 *  through a timezone. */
		granularity?: 'datetime' | 'date';
		onchange?: (iso: string) => void;
	} = $props();

	const SEG_ORDER: SegKey[] = ['y', 'm', 'd', 'h', 'mi'];
	/** Segments visible in `granularity: 'date'` mode — the calendar date only. */
	const DATE_SEGS: SegKey[] = ['y', 'm', 'd'];
	/** Separators for the date-only segment row (`YYYY–MM–DD`). */
	const DATE_SEPARATORS: string[] = ['–', '–'];
	const SEG_LEN: Record<SegKey, number> = { y: 4, m: 2, d: 2, h: 2, mi: 2 };
	const SEG_PLACEHOLDER: Record<SegKey, string> = {
		y: 'YYYY',
		m: 'MM',
		d: 'DD',
		h: 'HH',
		mi: 'MM'
	};
	const SEG_NAME: Record<SegKey, string> = {
		y: 'year',
		m: 'month',
		d: 'day',
		h: 'hour',
		mi: 'minute'
	};
	/** Separator rendered after each segment, in `SEG_ORDER` sequence:
	 *  `YYYY–MM–DD␣␣HH:MM` (the wide gap opens the time part). */
	const SEG_SEPARATORS: string[] = ['–', '–', '\u00a0\u00a0', ':'];

	/** IANA timezone for wall-clock entry. Defaults to the user's display
	 * timezone (`displayTimezone()` — the saved `core.timezone`, with the
	 * `auto` sentinel or a not-yet-loaded setting resolving to the browser
	 * zone). */
	const tz = $derived(timezone ?? displayTimezone());

	/** Date-only entry (`granularity: 'date'`): segments carry a literal
	 *  calendar date; committed values are `YYYY-MM-DD`, never converted. */
	const dateOnly = $derived(granularity === 'date');
	const segsShown = $derived(dateOnly ? DATE_SEGS : SEG_ORDER);
	const sepsShown = $derived(dateOnly ? DATE_SEPARATORS : SEG_SEPARATORS);

	function pad2(n: number): string {
		return String(n).padStart(2, '0');
	}

	// Segment inputs, keyed by segment. `$state` so `bind:this` writes are
	// reactive — Svelte warns on a binding to a plain object property.
	const els = $state<Record<SegKey, HTMLInputElement | null>>({
		y: null,
		m: null,
		d: null,
		h: null,
		mi: null
	});

	let segs = $state<Record<SegKey, string>>({ y: '', m: '', d: '', h: '', mi: '' });

	// Popover open state. The view month and the today highlight live in
	// `CalendarPanel.svelte`.
	let panelOpen = $state(false);

	// The ISO string we last wrote to `value` ourselves. The sync effect
	// ignores our own emits and only reacts to genuinely external changes
	// (see workflow.md → the equality-guard trap in writeback effects).
	let lastEmitted = '';

	// Sync the segments when the value changes externally (e.g. preselected
	// value, programmatic clear, form reset).
	$effect(() => {
		const v = value ?? '';
		if (v === lastEmitted) return;
		lastEmitted = v;
		if (dateOnly) {
			// A calendar date is a literal `YYYY-MM-DD` string — parse it
			// directly, never through a timezone conversion.
			const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
			segs = match
				? { y: match[1], m: match[2], d: match[3], h: '', mi: '' }
				: { y: '', m: '', d: '', h: '', mi: '' };
			return;
		}
		const w = utcIsoToWall(v, tz);
		segs = w
			? {
					y: String(w.y).padStart(4, '0'),
					m: pad2(w.m),
					d: pad2(w.d),
					h: pad2(w.h),
					mi: pad2(w.mi)
				}
			: { y: '', m: '', d: '', h: '', mi: '' };
	});

	function parsedWall(): Wall | null {
		// The date segments must be complete in both granularities.
		if (DATE_SEGS.some((k) => segs[k].length !== SEG_LEN[k])) return null;
		const dateWall: Wall = {
			y: Number(segs.y),
			m: Number(segs.m),
			d: Number(segs.d),
			h: 0,
			mi: 0
		};
		if (dateOnly) {
			// Calendar validity (leap months included) reuses the wall check —
			// an impossible date (Feb 30) cannot be committed.
			return isValidWall(dateWall) ? dateWall : null;
		}
		// A complete date with an untouched time is the whole value — midnight,
		// the calendar day-pick precedent. A half-entered time (hour without
		// minute, or the reverse) is a partial edit: null.
		if (segs.h === '' && segs.mi === '') {
			return isValidWall(dateWall) ? dateWall : null;
		}
		if (segs.h.length !== SEG_LEN.h || segs.mi.length !== SEG_LEN.mi) return null;
		const w: Wall = {
			y: dateWall.y,
			m: dateWall.m,
			d: dateWall.d,
			h: Number(segs.h),
			mi: Number(segs.mi)
		};
		return isValidWall(w) ? w : null;
	}

	function commit() {
		// `parsedWall()` null = a partial edit: the last committed value holds
		// and nothing emits — a partial edit never wipes a set value. Only the
		// explicit Clear action emits ''.
		const w = parsedWall();
		if (!w) return;
		if (dateOnly) {
			const ymd = `${segs.y}-${segs.m}-${segs.d}`;
			if (ymd !== lastEmitted) {
				lastEmitted = ymd;
				value = ymd;
				onchange?.(ymd);
			}
			return;
		}
		const iso = wallToUtcIso(w, tz);
		if (iso !== lastEmitted) {
			lastEmitted = iso;
			value = iso;
			onchange?.(iso);
		}
	}

	/** Spread a fill-style entry over the segments, starting at the segment
	 * the event delivered. Digits top up a segment with room, then overflow
	 * into the next ones. A full segment in the path takes the next digits —
	 * continued typing over a selected segment behaves the same way. */
	function distribute(key: SegKey, raw: string) {
		let rest = raw;
		let lastTouched: SegKey | null = null;
		for (let i = segsShown.indexOf(key); i < segsShown.length && rest.length > 0; i++) {
			const k = segsShown[i];
			if (segs[k].length < len(k)) {
				const take = rest.slice(0, len(k) - segs[k].length);
				rest = rest.slice(take.length);
				segs[k] = clampSeg(k, segs[k] + take);
			} else {
				const take = rest.slice(0, len(k));
				rest = rest.slice(take.length);
				segs[k] = clampSeg(k, take);
			}
			lastTouched = k;
		}
		if (lastTouched === null) return;
		normalizeDay();
		// The paste sat in one input. Every segment input now shows its own share.
		for (const k of segsShown) {
			const el = els[k];
			if (el) el.value = segs[k];
		}
		const next = nextKey(lastTouched);
		if (next) focusSeg(next);
	}

	/** Digits only, cut to the segment's length. Finished segments are clamped
	 * to their valid range so an impossible date can never be committed. */
	function clampSeg(key: SegKey, raw: string): string {
		const v = digits(raw).slice(0, SEG_LEN[key]);
		if (key === 'y' || v.length < len(key)) return v;
		let n = Number(v);
		if (key === 'm') n = Math.max(1, Math.min(12, n));
		else if (key === 'd')
			n = Math.max(1, Math.min(daysInMonth(Number(segs.y) || 1, Number(segs.m) || 1), n));
		else if (key === 'h') n = Math.min(23, n);
		else n = Math.min(59, n);
		return pad2(n);
	}

	function len(key: SegKey): number {
		return SEG_LEN[key];
	}

	function digits(s: string): string {
		return s.replace(/\D/g, '');
	}

	function focusSeg(key: SegKey) {
		els[key]?.focus();
	}

	function nextKey(key: SegKey): SegKey | null {
		const i = SEG_ORDER.indexOf(key);
		return i < SEG_ORDER.length - 1 ? SEG_ORDER[i + 1] : null;
	}

	function prevKey(key: SegKey): SegKey | null {
		const i = SEG_ORDER.indexOf(key);
		return i > 0 ? SEG_ORDER[i - 1] : null;
	}

	/** Keep the day inside the month when the month or year changes. */
	function normalizeDay() {
		const dim = daysInMonth(Number(segs.y) || 1, Number(segs.m) || 1);
		if (segs.d.length === SEG_LEN.d && Number(segs.d) > dim) {
			segs.d = pad2(dim);
			if (els.d) els.d.value = segs.d;
		}
	}

	function oninput(key: SegKey, e: Event) {
		const input = e.currentTarget as HTMLInputElement;
		// Fill-style entry (paste, autofill, programmatic fill): one event
		// carries more digits than the segment holds. Spread them over the
		// segments — the per-segment cut dropped the rest, so the value never
		// committed. Per-segment typing keeps the path below.
		const raw = digits(input.value);
		if (raw.length > len(key)) {
			distribute(key, raw);
			commit();
			return;
		}
		const v = clampSeg(key, input.value);
		segs[key] = v;
		input.value = v;
		if (key === 'm' || key === 'y') normalizeDay();
		if (v.length === len(key)) {
			const next = nextKey(key);
			if (next) focusSeg(next);
		}
		commit();
	}

	function bump(key: SegKey, delta: number) {
		const base = utcIsoToWall(new Date().toISOString(), tz);
		let n = segs[key] ? Number(segs[key]) : base ? base[key] : 0;
		if (key === 'y') n = Math.max(1, Math.min(9999, n + delta));
		else if (key === 'm') n = Math.max(1, Math.min(12, n + delta));
		else if (key === 'd')
			n = Math.max(
				1,
				Math.min(
					daysInMonth(Number(segs.y) || (base ? base.y : 1), Number(segs.m) || (base ? base.m : 1)),
					n + delta
				)
			);
		else if (key === 'h') n = (((n + delta) % 24) + 24) % 24;
		else n = (((n + delta) % 60) + 60) % 60;
		segs[key] = key === 'y' ? String(n).padStart(4, '0') : pad2(n);
		if (els[key]) els[key].value = segs[key];
		if (key === 'm' || key === 'y') normalizeDay();
		commit();
	}

	function onkeydown(key: SegKey, e: KeyboardEvent) {
		if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
			e.preventDefault();
			bump(key, e.key === 'ArrowUp' ? 1 : -1);
		} else if (e.key === 'ArrowLeft') {
			e.preventDefault();
			const prev = prevKey(key);
			if (prev) focusSeg(prev);
		} else if (e.key === 'ArrowRight') {
			e.preventDefault();
			const next = nextKey(key);
			if (next) focusSeg(next);
		}
	}

	function onfocus(e: Event) {
		(e.currentTarget as HTMLInputElement).select();
	}

	function selectDay(cell: CalendarCell) {
		if (disabled) return;
		segs.y = String(cell.y).padStart(4, '0');
		segs.m = pad2(cell.m);
		segs.d = pad2(cell.d);
		if (dateOnly) {
			// Date granularity: the day pick is the whole commit — there is no
			// time to preserve.
			if (els.y) els.y.value = segs.y;
			if (els.m) els.m.value = segs.m;
			if (els.d) els.d.value = segs.d;
			commit();
			return;
		}
		// When no hour has been taken, default to midnight.
		if (segs.h === '' || segs.mi === '') {
			segs.h = '00';
			segs.mi = '00';
		}
		if (els.y) els.y.value = segs.y;
		if (els.m) els.m.value = segs.m;
		if (els.d) els.d.value = segs.d;
		if (els.h) els.h.value = segs.h;
		if (els.mi) els.mi.value = segs.mi;
		commit();
	}

	function selectSlot(hhmm: string) {
		if (disabled || dateOnly) return;
		const w = parsedWall() ?? nowWall(tz);
		segs.y = String(w.y).padStart(4, '0');
		segs.m = pad2(w.m);
		segs.d = pad2(w.d);
		segs.h = hhmm.slice(0, 2);
		segs.mi = hhmm.slice(3, 5);
		if (els.y) els.y.value = segs.y;
		if (els.m) els.m.value = segs.m;
		if (els.d) els.d.value = segs.d;
		if (els.h) els.h.value = segs.h;
		if (els.mi) els.mi.value = segs.mi;
		commit();
	}

	function onNow() {
		if (disabled) return;
		if (dateOnly) {
			// "Now" on a date field commits today's calendar date in the
			// display zone — never an instant.
			const w = nowWall(tz);
			if (!w) return;
			const ymd = `${String(w.y).padStart(4, '0')}-${pad2(w.m)}-${pad2(w.d)}`;
			lastEmitted = ymd;
			value = ymd;
			onchange?.(ymd);
			segs.y = String(w.y).padStart(4, '0');
			segs.m = pad2(w.m);
			segs.d = pad2(w.d);
			if (els.y) els.y.value = segs.y;
			if (els.m) els.m.value = segs.m;
			if (els.d) els.d.value = segs.d;
			return;
		}
		const iso = new Date().toISOString();
		lastEmitted = iso;
		value = iso;
		onchange?.(iso);
		const w = utcIsoToWall(iso, tz);
		if (w) {
			segs = {
				y: String(w.y).padStart(4, '0'),
				m: pad2(w.m),
				d: pad2(w.d),
				h: pad2(w.h),
				mi: pad2(w.mi)
			};
		}
	}

	function onClear() {
		if (disabled) return;
		lastEmitted = '';
		value = '';
		onchange?.('');
		segs = { y: '', m: '', d: '', h: '', mi: '' };
	}

	const hasError = $derived(Boolean(error));
	const wall = $derived(parsedWall());
	// Render from the parsed wall — a complete date with an untouched time
	// parses as midnight while its segments are still empty.
	const localText = $derived(
		wall
			? `${String(wall.y).padStart(4, '0')}-${pad2(wall.m)}-${pad2(wall.d)} ${pad2(wall.h)}:${pad2(wall.mi)}`
			: m.doc_dt_not_set()
	);
	// The offset label for the wall time.
	const zoneText = $derived(
		zoneOffsetLabel(tz, wall ? (wallToUtcMs(wall, tz) ?? undefined) : undefined)
	);
	function segWidth(key: SegKey): string {
		return key === 'y' ? 'dtp-seg dtp-seg-y' : 'dtp-seg';
	}
</script>

<div class="dtp-wrap" class:dtp-error={hasError} class:dtp-compact={compact}>
	<Field
		label={compact ? undefined : label}
		{required}
		helper={compact ? undefined : helper}
		{error}
		id={label ? `dtp-${label}` : undefined}
		forId={label ? `dtp-${label}` : undefined}
	>
		{#snippet children(meta)}
			<div
				class="dtp-field"
				class:dtp-disabled={disabled}
				role="group"
				aria-label={label ?? (dateOnly ? m.doc_dt_date_aria() : m.doc_dt_aria())}
			>
				{#each segsShown as segKey, i (segKey)}
					{#if i > 0}
						<span class="dtp-sep" aria-hidden="true">{sepsShown[i - 1]}</span>
					{/if}
					<input
						id={segKey === 'y' && label ? `dtp-${label}` : undefined}
						class={segWidth(segKey)}
						type="text"
						inputmode="numeric"
						placeholder={SEG_PLACEHOLDER[segKey]}
						aria-label={SEG_NAME[segKey]}
						maxlength={SEG_LEN[segKey]}
						{disabled}
						aria-invalid={segKey === 'y' ? hasError || undefined : undefined}
						aria-describedby={meta.describedBy}
						value={segs[segKey]}
						{onfocus}
						oninput={(e) => oninput(segKey, e)}
						onkeydown={(e) => onkeydown(segKey, e)}
						bind:this={els[segKey]}
					/>
				{/each}
				<Popover.Root bind:open={panelOpen}>
					<Popover.Trigger
						class="dtp-cal-btn"
						aria-label={m.doc_dt_open_calendar_aria()}
						{disabled}
					>
						<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
							<rect
								x="1.5"
								y="2.5"
								width="13"
								height="12"
								rx="1.5"
								fill="none"
								stroke="currentColor"
								stroke-width="1.3"
							/>
							<line x1="1.5" y1="6" x2="14.5" y2="6" stroke="currentColor" stroke-width="1.3" />
							<line x1="5" y1="1" x2="5" y2="4" stroke="currentColor" stroke-width="1.3" />
							<line x1="11" y1="1" x2="11" y2="4" stroke="currentColor" stroke-width="1.3" />
						</svg>
					</Popover.Trigger>
					<CalendarPanel
						open={panelOpen}
						{disabled}
						{tz}
						{wall}
						{dateOnly}
						slotH={segs.h}
						slotMi={segs.mi}
						onselectday={selectDay}
						onselectslot={selectSlot}
					/>
				</Popover.Root>
			</div>

			{#if !compact}
				{#if !dateOnly}
					<div class="dtp-foot">
						<span class="dtp-local">{localText} ({zoneText})</span>
						<span class="dtp-utc">{value || '—'}</span>
					</div>
				{/if}

				<div class="dtp-actions">
					<Button variant="secondary" size="sm" onclick={onNow} {disabled}>{m.doc_dt_now()}</Button>
					<Button
						variant="secondary"
						size="sm"
						onclick={onClear}
						disabled={disabled || (!value && !SEG_ORDER.some((k) => segs[k]))}
					>
						{m.common_clear()}
					</Button>
				</div>
			{/if}
		{/snippet}
	</Field>
</div>

<style>
	/* ── Wrap ───────────────────────────────────────────────────────────── */
	.dtp-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
		position: relative;
	}

	/* ── Calendar toggle ────────────────────────────────────────────────── */
	/* Trigger class passed as prop to a component: use :global() to avoid pruning. */
	:global(.dtp-cal-btn) {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		margin-left: 4px;
		padding: 0;
		color: var(--text-3);
		background: none;
		border: none;
		border-radius: var(--r-sm);
		cursor: pointer;
		transition:
			color 0.1s,
			background 0.1s;
	}

	:global(.dtp-cal-btn:hover:not(:disabled)) {
		color: var(--text);
		background: var(--sunken);
	}

	:global(.dtp-cal-btn:disabled) {
		cursor: not-allowed;
		opacity: 0.5;
	}

	:global(.dtp-cal-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	/* ── Field ── matches design-guideline .inp ──────────────── */
	/* ── Field ── matches design-guideline .inp ──────────────────────────── */
	.dtp-field {
		display: inline-flex;
		align-items: center;
		gap: 2px;
		padding: 6px 9px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		width: fit-content;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.dtp-field:focus-within {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	/* ── Segments ── data is mono, per the design guideline ─────────────── */
	.dtp-seg {
		font-family: var(--font-mono);
		font-size: 13px;
		line-height: 1.5;
		color: var(--text);
		background: none;
		border: none;
		outline: none;
		text-align: center;
		padding: 0;
	}

	.dtp-seg-y {
		width: 44px;
	}

	.dtp-seg:not(.dtp-seg-y) {
		width: 26px;
	}

	.dtp-seg::placeholder {
		color: var(--text-3);
	}

	.dtp-sep {
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text-3);
	}

	/* ── Disabled state ─────────────────────────────────────────────────── */
	.dtp-disabled {
		opacity: 0.5;
		cursor: not-allowed;
		background: var(--surface-2);
	}

	.dtp-disabled .dtp-seg {
		cursor: not-allowed;
	}

	/* ── Footer ─────────────────────────────────────────────────────────── */
	.dtp-foot {
		display: flex;
		gap: 10px;
		align-items: baseline;
		flex-wrap: wrap;
		font-size: 11.5px;
		color: var(--text-3);
	}

	.dtp-utc {
		font-family: var(--font-mono);
	}

	/* ── Actions ───────────────────────────────────────────── */
	.dtp-actions {
		display: flex;
		gap: 6px;
	}
	/* The Now / Clear buttons are the shared `Button` primitive now. */

	/* ── Helper & error text ────────────────────────────────────────────── */
	/* Helper and error text render through the shared Field component. */

	.dtp-error .dtp-field {
		border-color: var(--danger);
	}

	.dtp-error .dtp-field:focus-within {
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	/* ── Compact embed mode ── no chrome of its own; the host (filter chip,
	   grid cell) provides the frame. */
	.dtp-compact .dtp-field {
		background: none;
		border: none;
		padding: 0;
	}

	.dtp-compact .dtp-field:focus-within {
		border-radius: var(--r-sm);
		box-shadow: 0 0 0 2px var(--accent-weak);
	}
</style>
