// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Conversation auto-title derivation — the frontend mirror of
 * `Assistant::Title` (`src/assistant/title.cr`). The mock turn store uses
 * it to reproduce the backend's first-turn auto-title; the live title is
 * always server-derived, so no real caller derives titles here.
 */

/** Maximum stored title length, ellipsis included. Mirrors the backend. */
export const MAX_TITLE_LENGTH = 60;

/**
 * Derives the title from a first user message: collapse all whitespace
 * runs into single spaces, trim, cap at 60 characters with an ellipsis.
 * Returns `null` when the message carries no usable text.
 */
export function titleFromContent(content: string | null | undefined): string | null {
	const value = content?.replace(/\s+/g, ' ').trim();
	if (!value) return null;
	return value.length > MAX_TITLE_LENGTH ? `${value.slice(0, MAX_TITLE_LENGTH - 1)}…` : value;
}
