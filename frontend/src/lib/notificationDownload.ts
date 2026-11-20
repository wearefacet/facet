// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * The reserved `data.download` notification key.
 *
 * Job producers (document export, portable-domain export) stage the
 * same-origin download path of the finished file in the notification's
 * `data` object. The panel renders a Download affordance from it, and the
 * shell honors it on a row click instead of navigating to the source
 * document.
 *
 * The field is producer-writable — the Lua `notification.send` helper takes
 * arbitrary `data` — so the client accepts a value only when it is a
 * same-origin path: it must start with `/` and must not be protocol-relative
 * (`//`, `/\` — the WHATWG URL parser reads a backslash as a slash). An
 * absolute or malformed value renders nothing and never navigates.
 */
export function notificationDownloadUrl(
	item: { data?: Record<string, unknown> } | null | undefined
): string | null {
	const raw = item?.data?.['download'];
	if (typeof raw !== 'string') return null;
	if (!raw.startsWith('/') || raw[1] === '/' || raw[1] === '\\') return null;
	return raw;
}
