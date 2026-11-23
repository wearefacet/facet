// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Reactive user-settings store — timezone + language + pinned doctypes,
 * persisted server-side.
 *
 * The backend owns user preferences (`user_settings` table, key registry,
 * validation) and exposes them through the self-service `/Api/settings` routes
 * (see `doc/backend/settings.md`). This module is the client-side view of that
 * API:
 *
 * - `loadSettings` — `GET /Api/settings/core` — returns the registered `core`
 *   values with backend defaults merged in for keys the user never wrote.
 * - `saveTimezone` / `saveLanguage` — `PUT /Api/settings/core/:key` — upsert a
 *   single key. The backend validates (the `auto` sentinel or a loadable IANA
 *   timezone name; language allowlist) and rejects invalid values with 422.
 * - `getPinnedDoctypes` / `togglePinnedDoctype` — read and mutate the user's
 *   pinned doctype list (stored under the `core.pinned_doctypes` key as a JSON
 *   array of qualified doctype names). `togglePinnedDoctype` updates the store
 *   optimistically and reverts if the backend rejects the write.
 * - `getShowWelcome` / `saveShowWelcome` — the `core.show_welcome` flag that
 *   gates the first-run welcome tour (`features/welcome/WelcomeTour.svelte`);
 *   the Settings page toggles it back to `true`.
 * - `displayTimezone` — the IANA zone datetimes render in: the stored
 *   `core.timezone`, or the browser zone for the `auto` sentinel / a
 *   not-yet-loaded store. The single resolver for every surface that shows
 *   or enters a datetime.
 * - `reconcileLocale` — aligns the Paraglide locale cookie with the account's
 *   effective language after every `loadSettings` (see
 *   `doc/frontend/settings.md` → Language).
 *
 * State lives in module-level `$state`, mirroring the `permissions.svelte.ts`
 * / `theme.svelte.ts` pattern (no `setContext`). It is **not** persisted to
 * `localStorage`: the backend is the source of truth, so the value shown on the
 * settings page always reflects what the server stores.
 *
 * ## Timezone "auto"
 *
 * "Automatic" is the stored default at every tier of the chain (the registry
 * default and the built-in `localization.default_timezone`): the value
 * `"auto"` persists server-side and means "follow the browser" —
 * `displayTimezone()` resolves it to
 * `Intl.DateTimeFormat().resolvedOptions().timeZone` at render time, so a
 * user who travels keeps following their device zone. Surfaces that need a
 * concrete zone for a server call (the CSV view export) resolve the sentinel
 * client-side before the request; the server never converts with `"auto"`.
 *
 * ## SSR safety
 *
 * All module state is guarded on the browser, mirroring `session.svelte.ts`:
 * on the server the load is a pass-through fetch and saves are skipped, so one
 * user's settings can never leak into another user's SSR request. `loadSettings`
 * is only ever called from client contexts (the settings page, the layout's
 * client-side effect), never from a server load function.
 */

import { apiFetch } from './session.svelte';
import { apiErrorMessage } from '$lib/http.js';
import * as m from '$lib/paraglide/messages';
import { getLocale, setLocale, type Locale } from '$lib/paraglide/runtime';

/**
 * The sentinel that means "follow the browser/system timezone". A legal
 * stored value: the backend persists it verbatim and never converts with it.
 */
export const AUTO_TIMEZONE = 'auto';

/** Values the backend registers for the `core` application scope. */
export interface CoreSettings {
	/** IANA timezone name (e.g. `"Europe/Paris"`), or the `"auto"` sentinel. */
	timezone: string;
	/** Language code, from the backend `ALLOWED_LANGUAGES` allowlist. */
	language: string;
	/** Qualified doctype names the user pinned to the top of the sidebar. */
	pinnedDoctypes: string[];
	/** CollectionView projection ids the user pinned in doctype listings. */
	pinnedCollectionViews: string[];
	/** Whether the first-run welcome tour should open on the next app load. */
	showWelcome: boolean;
}

/** Raw shape of the `GET /Api/settings/core` response body. */
interface CoreSettingsResponse {
	app: string;
	values: {
		timezone: string;
		language: string;
		pinned_doctypes: string[];
		pinned_collection_views: string[];
		/** Optional so a response that predates the key resolves to `true`. */
		show_welcome?: boolean;
	};
	/** Server-effective defaults (the `localization.*` policy) — absent on older backends. */
	defaults?: { timezone?: string; language?: string };
}

/** Shape of a `PUT /Api/settings/core/:key` response body. */
interface SettingUpdateResponse {
	app: string;
	key: string;
	value: string | string[] | boolean;
	updated_at: string;
}

let loaded = $state(false);
let timezone: string | null = $state(null);
let language: string | null = $state(null);
let pinnedDoctypes: string[] = $state([]);
let pinnedCollectionViews: string[] = $state([]);
let showWelcome: boolean | null = $state(null);
let serverDefaults: { timezone: string; language: string } | null = $state(null);

/** Whether the initial `loadSettings` call has completed (browser only). */
export function isSettingsLoaded(): boolean {
	return loaded;
}

/** Current timezone value (null until loaded). */
export function getTimezone(): string | null {
	return timezone;
}

/** Current language value (null until loaded). */
export function getLanguage(): string | null {
	return language;
}

/** The user's pinned doctype names (empty until loaded). */
export function getPinnedDoctypes(): string[] {
	return pinnedDoctypes;
}

/** The user's pinned CollectionView projection ids (empty until loaded). */
export function getPinnedCollectionViews(): string[] {
	return pinnedCollectionViews;
}

/**
 * The `core.show_welcome` flag (null until loaded). `true` opens the
 * first-run welcome tour on the next app load; the tour's dismiss checkbox
 * and final CTAs write `false`, and the Settings page writes `true` again.
 */
export function getShowWelcome(): boolean | null {
	return showWelcome;
}

/**
 * The server-effective defaults (`localization.*`) the backend resolves for
 * an account with no row — the "Server default ({value})" option label.
 * Null until the first `loadSettings` completes.
 */
export function getDefaults(): { timezone: string; language: string } | null {
	return serverDefaults;
}

/**
 * The browser's IANA timezone, e.g. `"Europe/Paris"`. Returns `"UTC"` as a
 * fallback (always valid) when the runtime cannot resolve a zone.
 */
export function systemTimezone(): string {
	if (typeof Intl === 'undefined' || typeof Intl.DateTimeFormat !== 'function') return 'UTC';
	const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
	return zone && zone.length > 0 ? zone : 'UTC';
}

/**
 * The IANA zone datetimes render in: the user's `core.timezone` setting, or
 * the browser's zone when the setting is the `auto` sentinel (or has not
 * loaded yet). The single resolver for every surface that shows or enters a
 * datetime — reading it inside a `$derived` or a template expression keeps
 * those surfaces in sync with a settings change.
 */
export function displayTimezone(): string {
	const saved = timezone;
	if (!saved || saved === AUTO_TIMEZONE) return systemTimezone();
	return saved;
}

/** Store the loaded values in module-level state. */
function setCoreSettings(values: CoreSettings, defaults?: CoreSettingsResponse['defaults']): void {
	timezone = values.timezone;
	language = values.language;
	pinnedDoctypes = values.pinnedDoctypes;
	pinnedCollectionViews = values.pinnedCollectionViews;
	showWelcome = values.showWelcome;
	serverDefaults = defaults
		? { timezone: defaults.timezone ?? 'UTC', language: defaults.language ?? 'en' }
		: null;
	loaded = true;
}

/** Drop all state. Called on logout so the next login starts clean. */
export function resetSettings(): void {
	loaded = false;
	timezone = null;
	language = null;
	pinnedDoctypes = [];
	pinnedCollectionViews = [];
	showWelcome = null;
	serverDefaults = null;
}

/**
 * Align the Paraglide locale with the account's effective language.
 *
 * The server-side `core.language` value (or the server default when the
 * account never wrote one) is the source of truth; the Paraglide cookie only
 * mirrors it so SSR renders resolve to the same language between full
 * reloads. Called after every successful `loadSettings` — the layout's boot
 * effect, the settings page mount, and `clearSetting` all land here — so a
 * stale cookie (backend re-init, another account on the same browser)
 * self-heals on the next load.
 *
 * The mirror write is verified before the reload: `setLocale` normally
 * reloads the page itself, but a silently refused cookie write (blocked or
 * overfull jar) would then reload-loop on every boot. `reload: false` plus an
 * explicit `getLocale()` check turns that failure into "stay on the current
 * locale until the write succeeds".
 *
 * No-op outside the browser.
 */
export function reconcileLocale(effective: string): void {
	if (typeof window === 'undefined') return;
	if (getLocale() === effective) return;
	setLocale(effective as Locale, { reload: false });
	if (getLocale() !== effective) return;
	window.location.reload();
}

/**
 * Fetch the `core` settings from the backend and store them.
 *
 * @param fetchFn Optional injected fetch — pass SvelteKit's `event.fetch` in
 *                load functions so cookies are forwarded during SSR.
 */
export async function loadSettings(fetchFn?: typeof fetch): Promise<CoreSettings> {
	const res = await apiFetch(
		'/Api/settings/core',
		{},
		fetchFn ? { fetch: fetchFn, redirectOnFailure: false } : undefined
	);
	if (!res.ok) {
		throw new Error(m.errors_settings_load({ status: res.status }));
	}
	const body = (await res.json()) as CoreSettingsResponse;
	const values: CoreSettings = {
		timezone: body.values.timezone,
		language: body.values.language,
		pinnedDoctypes: body.values.pinned_doctypes ?? [],
		pinnedCollectionViews: body.values.pinned_collection_views ?? [],
		// The backend registry default is `true`; a response without the key
		// (older backend) resolves to the same value.
		showWelcome: body.values.show_welcome ?? true
	};
	setCoreSettings(values, body.defaults);
	// The stored language (or its server default) outranks the locale cookie;
	// see `reconcileLocale`.
	reconcileLocale(values.language);
	return values;
}

/** Upsert the timezone preference. `"auto"` persists the follow-the-browser sentinel. */
export async function saveTimezone(tz: string, fetchFn?: typeof fetch): Promise<void> {
	await putSetting('timezone', tz, fetchFn);
}

/** Upsert the language preference. */
export async function saveLanguage(lang: string, fetchFn?: typeof fetch): Promise<void> {
	await putSetting('language', lang, fetchFn);
}

/**
 * Remove the account's row for one key so the server default applies
 * again (`DELETE /Api/settings/core/:key` — idempotent), then reload the
 * store so every surface falls back to the merged server-default values.
 */
export async function clearSetting(
	key: 'timezone' | 'language',
	fetchFn?: typeof fetch
): Promise<void> {
	const res = await apiFetch(
		`/Api/settings/core/${key}`,
		{ method: 'DELETE', headers: { 'X-Requested-With': 'XMLHttpRequest' } },
		fetchFn ? { fetch: fetchFn, redirectOnFailure: false } : undefined
	);
	if (!res.ok && res.status !== 404) {
		throw await apiErrorMessage(res, m.errors_settings_clear({ status: res.status }));
	}
	await loadSettings(fetchFn);
}

/** Persist the pinned doctype list. */
export async function savePinnedDoctypes(names: string[], fetchFn?: typeof fetch): Promise<void> {
	await putSetting('pinned_doctypes', names, fetchFn);
}

/**
 * Toggle a doctype in the pinned list and persist the change. Updates the store
 * optimistically so the sidebar re-renders immediately, then reverts if the
 * backend rejects the write.
 */
export async function togglePinnedDoctype(
	qualified: string,
	fetchFn?: typeof fetch
): Promise<void> {
	const prev = pinnedDoctypes;
	const isPinned = prev.includes(qualified);
	const next = isPinned ? prev.filter((q) => q !== qualified) : [...prev, qualified];
	pinnedDoctypes = next;
	try {
		await savePinnedDoctypes(next, fetchFn);
	} catch (e) {
		pinnedDoctypes = prev;
		throw e;
	}
}

/** Persist the pinned CollectionView projection ids. */
export async function savePinnedCollectionViews(
	viewIds: string[],
	fetchFn?: typeof fetch
): Promise<void> {
	await putSetting('pinned_collection_views', viewIds, fetchFn);
}

/**
 * Persist the `core.show_welcome` tour flag. `false` silences the popup
 * (dismiss checkbox / final CTAs); `true` re-arms it from the Settings page.
 */
export async function saveShowWelcome(v: boolean, fetchFn?: typeof fetch): Promise<void> {
	await putSetting('show_welcome', v, fetchFn);
}

/**
 * Toggle a CollectionView in the pinned list and persist the change. Updates
 * the store optimistically so the tab re-renders immediately, then reverts if
 * the backend rejects the write.
 */
export async function togglePinnedCollectionView(
	viewId: string,
	fetchFn?: typeof fetch
): Promise<void> {
	const prev = pinnedCollectionViews;
	const isPinned = prev.includes(viewId);
	const next = isPinned ? prev.filter((id) => id !== viewId) : [...prev, viewId];
	pinnedCollectionViews = next;
	try {
		await savePinnedCollectionViews(next, fetchFn);
	} catch (e) {
		pinnedCollectionViews = prev;
		throw e;
	}
}

async function putSetting(
	key: string,
	value: string | string[] | boolean,
	fetchFn?: typeof fetch
): Promise<void> {
	const res = await apiFetch(
		`/Api/settings/core/${key}`,
		{
			method: 'PUT',
			headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
			body: JSON.stringify({ value })
		},
		fetchFn ? { fetch: fetchFn, redirectOnFailure: false } : undefined
	);
	if (!res.ok) {
		throw await apiErrorMessage(res, m.errors_settings_save({ key }));
	}
	const saved = (await res.json()) as SettingUpdateResponse;
	// Prefer the canonical stored form returned by the backend.
	if (key === 'timezone') timezone = saved.value as string;
	else if (key === 'language') language = saved.value as string;
	else if (key === 'pinned_doctypes') pinnedDoctypes = saved.value as string[];
	else if (key === 'pinned_collection_views') pinnedCollectionViews = saved.value as string[];
	else if (key === 'show_welcome') showWelcome = saved.value as boolean;
}
