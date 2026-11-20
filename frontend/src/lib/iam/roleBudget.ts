// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure mapping between the role form's budget controls and the stored
 * `assistant_token_budget` value. The Unlimited checkbox owns the null:
 * checked means no cap (the save sends an explicit `null`), unchecked means
 * the input must hold a non-negative integer.
 */

/**
 * Formats a stored budget for the text input. `null`/`undefined`
 * (unlimited) maps to the empty string.
 */
export function budgetToInput(value: number | null | undefined): string {
	return value == null ? '' : String(value);
}

/**
 * Whether the current input may be saved. A checked Unlimited box
 * short-circuits (there is nothing to validate); otherwise the trimmed
 * input must be digits only.
 */
export function budgetInputValid(unlimited: boolean, input: string): boolean {
	if (unlimited) return true;
	return /^\d+$/.test(input.trim());
}

/**
 * Maps the form state onto the stored value. Unlimited maps to an explicit
 * `null` (the update pipeline restores explicit nulls from the patch).
 * Unchecked and valid maps to the number. Unchecked and invalid maps to
 * `null` — callers must validate first.
 */
export function budgetInputToValue(unlimited: boolean, input: string): number | null {
	if (unlimited) return null;
	const trimmed = input.trim();
	return /^\d+$/.test(trimmed) ? Number(trimmed) : null;
}
