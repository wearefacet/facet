// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Url field value normalization and validation.
 *
 * The backend's `UrlType#validate` only accepts absolute `http(s)://` URLs
 * with a plausible host, but users type bare hosts (`www.acme.tld`) — the
 * `https://` chrome in front of the field implies the scheme. Completion is
 * a shared rule, not a UI rewrite (B-294): the backend's `UrlType#normalize`
 * completes a scheme-less value whose authority is a *dotted* DNS-style
 * host at every entry point, and `ensureAbsoluteUrl` mirrors exactly that
 * rule here so the field shows what will be stored. A dotless host
 * (`not-a-url`, `localhost:3000`) is never completed — free text and
 * single-label hosts must carry their scheme explicitly. `urlAdornment`
 * renders the implied scheme while the text carries none, and `urlFieldError`
 * mirrors the backend gate so a value that could never be stored (B-174) is
 * caught at blur with a field error instead of surfacing later as a 422.
 */

const SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;

/** Whether the value already carries a scheme (`scheme://rest`). */
export function hasUrlScheme(value: string): boolean {
	return SCHEME_RE.test(value);
}

/** A dotted DNS-style authority with an optional `:port` (B-294). */
const URL_BARE_HOST_RE = /^[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+(:\d+)?$/;

/**
 * Whether the scheme-less `value` starts with a bare-host shape the backend
 * completes: a dotted, DNS-style authority. The dot separates a host the
 * user means to dereference (`www.acme.tld`, `acme.tld/path`) from free
 * text that merely reads like one (`not-a-url`) and from single-label
 * hosts (`localhost:3000`). Mirrors `UrlType#completable_bare_host?`.
 */
function completableBareHost(value: string): boolean {
	const authority = value.split(/[/?#]/, 2)[0] ?? '';
	return URL_BARE_HOST_RE.test(authority);
}

/**
 * Normalize a url value to the absolute stored form: trimmed, with `scheme`
 * (default `https://`) prepended when the user typed a dotted bare host —
 * the only scheme-less shape the backend's `UrlType#normalize` completes
 * (B-294). Any other scheme-less value passes through trimmed and is
 * refused by `urlFieldError` / the backend's 422. Empty and whitespace-only
 * values collapse to `''` — clearing the field is never turned into a URL.
 */
export function ensureAbsoluteUrl(value: string, scheme = 'https://'): string {
	const trimmed = value.trim();
	if (trimmed === '' || hasUrlScheme(trimmed)) return trimmed;
	return completableBareHost(trimmed) ? scheme + trimmed : trimmed;
}

/** A plausible host: DNS-style labels, or a bracketed IPv6 literal. */
const URL_HOST_RE = /^[A-Za-z0-9._-]+$/;
const URL_IPV6_HOST_RE = /^\[[0-9a-fA-F:.]+\]$/;

/**
 * Whether `host` passes the backend's `UrlType` gate: a DNS-style name
 * (letters, digits, dots, hyphens, underscores) or a bracketed IPv6
 * literal. WHATWG `URL` throws on a space in the host but keeps other
 * stray characters (`https://ht!tp://bad url` parses with hostname
 * `"ht!tp"`) and silently skips empty authority labels
 * (`https:///foo/bar` parses with hostname `"foo"`), so the character
 * check mirrors `UrlType#validate` (B-174).
 */
function plausibleUrlHost(host: string): boolean {
	if (host.startsWith('[')) return URL_IPV6_HOST_RE.test(host);
	return URL_HOST_RE.test(host);
}

/** The field error for a url value that can never be stored. */
const URL_FIELD_ERROR =
	'Not a valid URL (expected an absolute http(s):// address with a valid host).';

/**
 * Validate the absolute stored form of a url field value (B-174).
 *
 * Expects the post-`ensureAbsoluteUrl` value — a value that is still
 * scheme-less after it (a dotless host the backend does not complete,
 * B-294) is an error here. Blank (already collapsed to `''`) is a cleared
 * field, never an error. The message matches the tone of the backend's
 * `UrlType` 422 so the same error slot reads the same whether the value
 * was caught at blur or at save.
 */
export function urlFieldError(value: string): string | null {
	if (value === '') return null;
	// A value that is still scheme-less after completion is refused up
	// front — some shapes parse as a non-web scheme in WHATWG `URL`
	// (`localhost:3000`) and must not slip through as data.
	if (!hasUrlScheme(value)) return URL_FIELD_ERROR;
	// An empty authority (`https:///path`) parses in WHATWG `URL` with the
	// first path label as the host — reject it up front so the check mirrors
	// the backend's empty-host refusal.
	if (/^https?:\/\/\//i.test(value)) return URL_FIELD_ERROR;
	let u: URL;
	try {
		u = new URL(value);
	} catch {
		return URL_FIELD_ERROR;
	}
	if ((u.protocol !== 'http:' && u.protocol !== 'https:') || !plausibleUrlHost(u.hostname)) {
		return URL_FIELD_ERROR;
	}
	return null;
}

/**
 * The scheme adornment a url input shows for `value`: the implied scheme
 * while the text carries none (empty text included — the field reads as a
 * url before the user types), and `undefined` once the value self-describes
 * with any scheme. Rendered as non-editable input chrome, so the user sees
 * the form that will be stored instead of a silent blur rewrite.
 */
export function urlAdornment(value: string | undefined, scheme = 'https://'): string | undefined {
	if (typeof value === 'string' && value !== '' && hasUrlScheme(value)) return undefined;
	return scheme;
}
