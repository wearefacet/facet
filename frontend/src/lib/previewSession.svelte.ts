// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Preview-session state bridge.
 *
 * The Builder "Preview" toggle issues a short-lived capability token scoped
 * to a draft domain. While a preview session is active, `apiFetch` injects
 * every outgoing request with `Authorization: Bearer <token>`, and the
 * backend's `RBAC::PreviewEnforcer` authorises operations purely on
 * draft-domain identity.
 *
 * The token lives in **two** client-side stores:
 *
 *   1. `sessionStorage` (under `facet.preview-session`) — read by the in-memory
 *      reactive store on hydration so a same-tab client-side navigation
 *      preserves the preview principal across SvelteKit route loads.
 *   2. A JS-readable cookie `facet.preview-session` — read by
 *      `hooks.server.ts` on a **full reload (F5)** of a live URL during
 *      preview. The hook forwards it to `event.locals.previewSession`, which
 *      the root `+layout.ts` re-injects into `setPreviewSession` before any
 *      SSR `apiFetch` call. `apiFetch` then overlays the Bearer header, the
 *      AuthHandler holds a precedence rule that lets a `typ: "preview"` Bearer
 *      header win over the `auth_token` cookie (so the draft reads are
 *      authorised even though the cookie session still travels with the
 *      request via SvelteKit's `event.fetch` cookie forwarding).
 *
 * The cookie is intentionally **not** HttpOnly: JavaScript writes and clears
 * it (the token travels in the JWT bearer header over TLS, and the cookie
 * carries the same payload as `sessionStorage`). The cookie is scoped to the
 * whole origin and expires when the token does — Safari's "less than 24h"
 * cookie clamp does not apply because the value is short and the path is
 * first-party.
 *
 * Mirrors the module-level-$state pattern of `navState.svelte.ts`,
 * `permissions.svelte.ts`, `theme.svelte.ts` — no `setContext`.
 */

import { doctypeRegistryCache, domainListCache } from './datasource/clientCache.js';

const STORAGE_KEY = 'facet.preview-session';
const COOKIE_KEY = 'facet.preview-session';

export interface PreviewSession {
	/** Draft domain id (`_abc`-style) the token is scoped to. */
	draftId: string;
	/** Short-lived JWT issued by `POST /Api/core/Domain/:id/preview-session`. */
	token: string;
	/** Unix seconds; the backend's `ACCESS_TOKEN_EXP` (15min by default). */
	expiresAt: number;
}

let session = $state<PreviewSession | null>(null);

/**
 * Drops the singleton definition caches alongside the auth-surface switch.
 *
 * While a preview session is active, every `apiFetch` carries the preview
 * Bearer, so `core.DocType` / `core.Domain` list responses are scoped to the
 * bound draft (`PreviewEnforcer.list_where_clauses`). Cached snapshots are
 * therefore principal-scoped, not just time-scoped: they must drop when the
 * overlay engages (the pre-preview snapshots understate the draft) and when
 * it clears (the preview-scoped snapshots would understate the live domains
 * for up to the 60s TTL). No-op on the server — the caches are browser-only.
 */
function invalidatePrincipalScopedCaches(): void {
	doctypeRegistryCache.invalidate();
	domainListCache.invalidate();
}

// On first client access, hydrate from sessionStorage so a reload of an
// in-preview URL keeps the preview principal. SSR runs with `session = null`.
if (typeof window !== 'undefined') {
	const stored = window.sessionStorage.getItem(STORAGE_KEY);
	if (stored) {
		try {
			const parsed = JSON.parse(stored) as PreviewSession;
			// Drop expired tokens at hydration so a stale value from a long-ago
			// tab does not poison the first request — the backend would 401
			// and we'd silently fall back, but explicit drop is less noisy.
			if (parsed.expiresAt > Math.floor(Date.now() / 1000)) {
				session = parsed;
			} else {
				window.sessionStorage.removeItem(STORAGE_KEY);
				clearPreviewCookie();
			}
		} catch {
			window.sessionStorage.removeItem(STORAGE_KEY);
			clearPreviewCookie();
		}
	}
}

export function getPreviewSession(): PreviewSession | null {
	return session;
}

export function isPreviewActive(): boolean {
	return session !== null;
}

// ── Pure URL predicates ─────────────────────────────────────────────────

/**
 * True while the current URL is a builder preview route
 * (`/Builder/{draft}/preview...`) — the URL-derived half of the Build/Preview
 * segmented toggle. Independent of the token store: the toggle shows preview
 * state as soon as the entry route mounts, before the token lands.
 */
export function builderPreviewActive(pathname: string): boolean {
	return /\/Builder\/[^/]+\/(preview)(\/|$)/.test(pathname);
}

/**
 * True when the active preview session's bound draft no longer matches the
 * current URL — the user has left both the draft's live URL and the entry
 * redirect, so the session must be cleared.
 *
 * Valid while in the live URL of the bound draft (`/{draftId}`,
 * `/{draftId}/Widget/...`) OR while the brief redirect through
 * `/Builder/{draftId}/preview/...` is in flight (the redirect page issues
 * the token then navigates to the live URL — clearing during it would cancel
 * the preview before it started). The `/Builder/{draftId}/preview/*` path is
 * the entry point; the preview is fully active once the user lands on
 * `/{draftId}`.
 */
export function previewExpired(session: PreviewSession, pathname: string): boolean {
	const inLive = pathname === `/${session.draftId}` || pathname.startsWith(`/${session.draftId}/`);
	const inEntry = pathname.startsWith(`/Builder/${session.draftId}/preview`);
	return !inLive && !inEntry;
}

export function setPreviewSession(next: PreviewSession): void {
	session = next;
	invalidatePrincipalScopedCaches();
	if (typeof window !== 'undefined') {
		try {
			window.sessionStorage.setItem(STORAGE_KEY, JSON.stringify(next));
		} catch {
			/* storage disabled (private mode) — swallow */
		}
		writePreviewCookie(next);
	}
}

export function clearPreviewSession(): void {
	session = null;
	invalidatePrincipalScopedCaches();
	if (typeof window !== 'undefined') {
		try {
			window.sessionStorage.removeItem(STORAGE_KEY);
		} catch {
			/* storage disabled (private mode) — swallow */
		}
		clearPreviewCookie();
	}
}

/**
 * Writes the preview session as a JS-readable cookie. Read by
 * `hooks.server.ts` on a full reload so SSR `apiFetch` calls can overlay the
 * Bearer token before any draft-domain fetch leaves the server. The cookie's
 * `max-age` mirrors the token TTL so an expired token disappears on its own.
 */
function writePreviewCookie(next: PreviewSession): void {
	if (typeof document === 'undefined') return;
	const maxAge = Math.max(0, next.expiresAt - Math.floor(Date.now() / 1000));
	const value = encodeURIComponent(JSON.stringify(next));
	// `sameSite=Lax` so the cookie travels on same-origin navigations (incl.
	// full reloads) but is not attached to cross-site requests. `secure` is
	// omitted to keep local `http://localhost` dev working; production sits
	// behind TLS where the bearer header (not the cookie) is the auth source.
	document.cookie = `${COOKIE_KEY}=${value}; Max-Age=${maxAge}; Path=/; SameSite=Lax`;
}

function clearPreviewCookie(): void {
	if (typeof document === 'undefined') return;
	document.cookie = `${COOKIE_KEY}=; Max-Age=0; Path=/; SameSite=Lax`;
}
