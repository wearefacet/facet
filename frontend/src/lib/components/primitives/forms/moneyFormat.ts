// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure formatting for `MoneyInput`: the decimal-shape check, the display
 * grouping, and the caret mapping across a re-format. The component keeps
 * the DOM reads and writes, the currency picker, and the typeahead state.
 */

/**
 * Decimal-shape check, the same rule as the backend `MoneyType#validate`:
 * optional sign, at least one digit, one optional `.` + digits. An empty
 * amount is not a shape error — it means "cleared". This is a courtesy check
 * before the round-trip; the backend re-validates.
 */
export const DECIMAL_RE = /^-?\d+(\.\d+)?$/;

/**
 * Thousand-grouping separator (`'`, the design's Swiss/European style; it
 * does not collide with the decimal `.`). Display only — the raw amount and
 * the emitted value never contain it.
 */
export const SEP = "'";

/**
 * Format a raw decimal string with `'` between every 3 integer-part digits.
 * `raw` has the canonical shape `[-]?\d+(\.\d+)?` as typed. A partial decimal
 * (for example `12.`) is valid while the user types the fraction; it comes
 * back unchanged, so the trailing `.` stays. Text that is not a decimal (a
 * currency typeahead query) also comes back unchanged.
 */
export function formatAmount(raw: string): string {
	if (raw === '') return '';
	// A typeahead query (any leading letter) is not a decimal — show as-is.
	if (!DECIMAL_RE.test(raw)) return raw;
	// Split sign / integer / fractional. `match` is guaranteed by the regex.
	const m = /^(-?)(\d*)(\.\d*)?$/.exec(raw)!;
	const sign = m[1] ?? '';
	let intPart = m[2] ?? '';
	const fracPart = m[3] ?? '';
	if (intPart.length > 3) {
		// Group from the right so the leftmost group may be shorter (1'234'567).
		const groups: string[] = [];
		for (let i = intPart.length; i > 0; i -= 3) {
			groups.unshift(intPart.slice(Math.max(0, i - 3), i));
		}
		intPart = groups.join(SEP);
	}
	return sign + intPart + fracPart;
}

/**
 * Map the caret across a re-format.
 *
 * Count the significant characters (everything except `SEP`) to the left of
 * the old caret in the old text. Put the new caret after the same count of
 * significant characters in the new text. A mid-string edit keeps its
 * position when grouping inserts a separator. When the new text is shorter,
 * the caret lands at its end. When several positions match the count, the
 * earliest one wins.
 */
export function caretAfterFormat(oldText: string, oldCaret: number, newText: string): number {
	const significantBefore = oldText.slice(0, oldCaret).split(SEP).join('').length;
	let placed = 0;
	let sig = 0;
	while (placed < newText.length && sig < significantBefore) {
		if (newText[placed] !== SEP) sig++;
		placed++;
	}
	return placed;
}
