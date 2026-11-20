// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Key input handling shared by the configure editors.
 *
 * Keys are lowercase snake_case identifiers that must start with a letter.
 * `sanitizeKeyInput` turns raw typing into a valid partial key; `nextUniqueKey`
 * allocates a non-colliding key for a newly added row.
 */

const KEY_PATTERN_INVALID = /[^a-z0-9_]/g;
const KEY_PATTERN_LEADING = /^[^a-z]+/;

/**
 * Sanitize a raw key input: lowercase, strip every character outside
 * `[a-z0-9_]`, then strip leading non-letters so the key always starts with
 * a letter. An input with no usable characters returns `''`.
 */
export function sanitizeKeyInput(value: string): string {
	let v = value.toLowerCase().replace(KEY_PATTERN_INVALID, '');
	if (v.length > 0 && !/^[a-z]/.test(v)) {
		v = v.replace(KEY_PATTERN_LEADING, '');
	}
	return v;
}

/**
 * First key derived from `base` that no entry in `existing` already uses:
 * `base` itself when free, then `base_1`, `base_2`, …
 */
export function nextUniqueKey(existing: Iterable<string>, base: string): string {
	const taken = new Set(existing);
	if (!taken.has(base)) return base;
	let i = 1;
	while (taken.has(`${base}_${i}`)) i++;
	return `${base}_${i}`;
}
