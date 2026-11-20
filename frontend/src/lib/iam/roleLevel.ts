// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure mapping between the role form's level input and the stored `level`
 * value. The field is a required integer, 0 through 100.
 */

/**
 * Parses the level text input into its number. Returns `null` when the
 * input is empty, not a whole number, or outside the 0–100 range.
 */
export function parseLevelInput(input: string): number | null {
	const trimmed = input.trim();
	if (!/^\d+$/.test(trimmed)) return null;
	const value = Number(trimmed);
	return value >= 0 && value <= 100 ? value : null;
}

/**
 * Formats a stored level for the text input. `null`/`undefined` maps to
 * the empty string.
 */
export function levelToInput(value: number | null | undefined): string {
	return value == null ? '' : String(value);
}
