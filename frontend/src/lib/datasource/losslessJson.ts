// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Lossless JSON parse for DataSource responses.
 *
 * `JSON.parse` rounds integer literals past `Number.MAX_SAFE_INTEGER`
 * (2^53 - 1) to the nearest double, so Int64 values (up to 2^63 - 1) lose
 * digits. The scanner walks the raw text and quotes every integer literal
 * past the safe range, so the parse delivers it as an exact decimal string.
 * All other tokens — small numbers, fractions, exponents, strings — pass
 * through unchanged.
 */

const MAX_SAFE_DIGITS = String(Number.MAX_SAFE_INTEGER);

/** Report whether a decimal digit string names a value past the safe range. */
function exceedsSafeInteger(digits: string): boolean {
	if (digits.length !== MAX_SAFE_DIGITS.length) return digits.length > MAX_SAFE_DIGITS.length;
	return digits > MAX_SAFE_DIGITS;
}

/** Return the end index of the string literal that opens at `start`. */
function scanStringEnd(text: string, start: number): number {
	let i = start + 1;
	while (i < text.length) {
		const ch = text[i];
		if (ch === '\\') i += 2;
		else if (ch === '"') return i + 1;
		else i += 1;
	}
	return i; // Unterminated — the parse rejects it, like JSON.parse would.
}

/** Return the end index of the number token that opens at `start`. */
function scanNumberEnd(text: string, start: number): number {
	let i = start + 1; // Step over the sign.
	while (i < text.length && text[i] >= '0' && text[i] <= '9') i += 1;
	if (text[i] === '.') {
		i += 1;
		while (i < text.length && text[i] >= '0' && text[i] <= '9') i += 1;
	}
	if (text[i] === 'e' || text[i] === 'E') {
		i += 1;
		if (text[i] === '+' || text[i] === '-') i += 1;
		while (i < text.length && text[i] >= '0' && text[i] <= '9') i += 1;
	}
	return i;
}

/**
 * Parse `text` and keep integers past the safe range as exact strings.
 *
 * The scanner knows string literals, so digits inside a string value never
 * change. The output goes to `JSON.parse`, which stays the validator for
 * every other grammar rule.
 */
export function parseLosslessJson(text: string): unknown {
	let out = '';
	let i = 0;
	while (i < text.length) {
		const ch = text[i];
		if (ch === '"') {
			const end = scanStringEnd(text, i);
			out += text.slice(i, end);
			i = end;
		} else if (ch === '-' || (ch >= '0' && ch <= '9')) {
			const end = scanNumberEnd(text, i);
			const literal = text.slice(i, end);
			const digits = ch === '-' ? literal.slice(1) : literal;
			// A JSON integer has no fraction and no exponent, and never starts
			// with a zero. Other spellings pass through for the parse to judge.
			const isInteger = !literal.includes('.') && !/[eE]/.test(literal);
			const isCanonical = digits.length === 1 || digits[0] !== '0';
			out += isInteger && isCanonical && exceedsSafeInteger(digits) ? `"${literal}"` : literal;
			i = end;
		} else {
			out += ch;
			i += 1;
		}
	}
	return JSON.parse(out);
}
