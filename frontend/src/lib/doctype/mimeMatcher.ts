// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * MIME pattern matching for `file`-typed fields.
 *
 * Mirrors `Facet::Util::MimeMatcher` on the backend so that client-side
 * rejection (file picker + drag-drop) agrees with the server-side
 * `Document::FileMimeCheck` gate. A pattern is `type/subtype` where the
 * subtype may be `*` (e.g. `image/*`, `application/pdf`); a bare `*` type
 * is rejected at schema validation time on the backend.
 */
const PATTERN_RE = /^[A-Za-z0-9!#$&^_.+-]+\/(?:\*|[A-Za-z0-9!#$&^_.+-]+)$/;

/** True when `pattern` is a well-formed `type/subtype` token. */
export function isValidMimePattern(pattern: string): boolean {
	return PATTERN_RE.test(pattern);
}

/** True when `mime` (e.g. `image/png`) satisfies any entry in `patterns`. */
export function matchesMime(mime: string, patterns: string[]): boolean {
	return patterns.some((p) => matchPattern(mime, p));
}

function matchPattern(mime: string, pattern: string): boolean {
	const slash = pattern.indexOf('/');
	if (slash < 0) return false;
	const pType = pattern.slice(0, slash);
	const pSub = pattern.slice(slash + 1);

	const mSlash = mime.indexOf('/');
	if (mSlash < 0) return false;
	const mType = mime.slice(0, mSlash);
	const mSub = mime.slice(mSlash + 1);

	return pType === mType && (pSub === '*' || pSub === mSub);
}
