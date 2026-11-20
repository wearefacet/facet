// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Notification store — the client-side view of the self-service
 * `/Api/notifications` routes (see `doc/backend/notifications.md`).
 *
 * State lives in module-level `$state`, mirroring the `settings.svelte.ts` /
 * `navCounts.svelte.ts` pattern (no `setContext` — see
 * `doc/frontend/workflow.md` → "Never use setContext / getContext").
 *
 * - `initNotifications` — called once from the root layout when the session
 *   is authenticated. Reads the account's `notifications.in_app` setting
 *   (`GET /Api/settings/notifications`); when enabled it fetches the unread
 *   badge count, subscribes once to the `/notifications` WebSocket
 *   self-subscription path (live `notified` events; the fanout channel is
 *   derived server-side from the JWT subject — see
 *   `doc/backend/notifications.md` → WebSocket delivery), and keeps a slow
 *   poll (60s, visible tabs only) as a safety net: the WS bridge has no
 *   replay, so events fired while disconnected surface on the next poll.
 *   When the setting is off, no channel starts and the bell is hidden; the
 *   backend keeps inserting notifications, so re-enabling shows what accrued
 *   while muted. `setInAppEnabled` persists the setting and starts or stops
 *   the channels to match.
 * - The list itself is lazy — fetched on first panel open and refreshed on
 *   every open, so the panel never shows stale rows after actions fired
 *   elsewhere.
 * - `fireNotificationAction` dispatches through
 *   `POST /Api/notifications/:id/actions/:key`. On success the backend has
 *   stamped `read_at` + `actioned_at` (one-shot: every action on the
 *   notification is now dead) and executed the doctype mutation — the store
 *   reflects that response locally. A 409 (`AlreadyActioned`) also stamps
 *   `actioned_at`: the server confirmed the actions are consumed, only our
 *   row was stale.
 * - Navigation to the source document is owned by the host (the layout
 *   `goto`s to `/{domain}/{doc_type}/{doc_id}`); this module only marks the
 *   row read.
 *
 * ## SSR safety
 *
 * Every entry point is a no-op on the server (`typeof window === 'undefined'`),
 * mirroring `session.svelte.ts` — one user's notifications can never leak
 * into another user's SSR request. Confirmation prompts (`action.confirm`)
 * are likewise browser-only and use `window.confirm`.
 */

// The three `new Date()` calls below are momentary timestamps (`.toISOString()`
// immediately); they are never mutated, so `svelte/prefer-svelte-reactivity`
// flags them as an over-approximation — the rule traces any construction whose
// variable might be mutated anywhere in the file. SvelteDate adds no value for
// a fire-and-forget timestamp, so plain Date stays.
import { apiFetch } from './session.svelte';
import { apiErrorMessage } from '$lib/http.js';
import * as m from '$lib/paraglide/messages';
import {
	getWebSocketClient,
	subscribeToDocument,
	type WsDocumentEvent
} from './websocket.svelte.js';
import type {
	NotificationItem,
	NotificationActionDescriptor
} from './components/primitives/surfaces/NotificationPanel.svelte';

/** Page size for the panel list — matches the API default. */
const PER_PAGE = 20;

/**
 * Badge poll interval — safety net for WS events missed while disconnected.
 * The count route is a cheap indexed query.
 */
const POLL_INTERVAL_MS = 60_000;

let items: NotificationItem[] = $state([]);
let unreadCount: number = $state(0);
let more: boolean = $state(false);
let page: number = $state(1);
let loading: boolean = $state(false);
let open: boolean = $state(false);
let initialized = false;
let inAppEnabled: boolean | null = $state(null);
let pollTimer: ReturnType<typeof setInterval> | null = null;
let wsUnsub: (() => void) | null = null;

/** Panel rows, newest first (the API's fixed order). */
export function getNotificationItems(): NotificationItem[] {
	return items;
}

/** Unread count for the bell badge. */
export function getUnreadCount(): number {
	return unreadCount;
}

/** Whether a next page exists — a full page means more rows may follow.
 *  The API's `meta.more` reports a truncated count, not a next page. */
export function hasMoreNotifications(): boolean {
	return more;
}

/** Whether a list fetch is in flight. */
export function isNotificationsLoading(): boolean {
	return loading;
}

/** Whether the panel is open. */
export function isNotificationPanelOpen(): boolean {
	return open;
}

/**
 * Whether in-app notifications are enabled for this account. `null` until the
 * preference has loaded — `bellProps` treats every non-`false` value as on, so
 * the bell never flickers off during the initial load.
 */
export function isInAppEnabled(): boolean | null {
	return inAppEnabled;
}

/**
 * The Topbar bell's prop set. This is the single wiring point for every shell
 * that renders the bell (the live AppShell and the Configure shell): the
 * count and the visibility track the store, and the handler toggles the
 * shared panel. Call it from a template so the reads stay reactive.
 */
export function bellProps(): {
	showNotifications: boolean;
	notificationsCount: number;
	onnotifications: () => void;
} {
	return {
		showNotifications: isInAppEnabled() !== false,
		notificationsCount: getUnreadCount(),
		onnotifications: toggleNotificationPanel
	};
}

/** The unread badge count, from the cheap dedicated endpoint. */
async function fetchUnreadCount(): Promise<void> {
	const res = await apiFetch('/Api/notifications/unread_count');
	if (!res.ok) return;
	const body = (await res.json()) as { count?: number };
	unreadCount = body.count ?? 0;
}

/** One page of the list. Page 1 replaces the rows; later pages append. */
async function fetchPage(target: number): Promise<void> {
	loading = true;
	try {
		const res = await apiFetch(`/Api/notifications?page=${target}&per_page=${PER_PAGE}`);
		if (!res.ok) return;
		const body = (await res.json()) as {
			data?: NotificationItem[];
		};
		const incoming = body.data ?? [];
		if (target === 1) {
			items = incoming;
		} else {
			// Dedup by id: a row created between two page fetches shifts the
			// window and would otherwise appear twice.
			const seen = new Set(items.map((i) => i.id));
			items = [...items, ...incoming.filter((i) => !seen.has(i.id))];
		}
		more = incoming.length === PER_PAGE;
		page = target;
	} finally {
		loading = false;
	}
}

/** Replaces a row in place (by id) after a successful write. */
function replaceItem(updated: NotificationItem): void {
	items = items.map((i) => (i.id === updated.id ? updated : i));
}

/** Drops the unread badge by one — only when the row was actually unread. */
function decrementUnread(item: NotificationItem): void {
	if (item.read_at === null) {
		unreadCount = Math.max(0, unreadCount - 1);
	}
}

/**
 * WS push handler — refresh the badge (and the open list) on `notified`.
 * The client dispatches every frame to every listener, so filter by event
 * name; document events from other subscriptions are not ours.
 */
function onWsEvent(event: WsDocumentEvent): void {
	if (event.event !== 'notified') return;
	fetchUnreadCount();
	if (open) fetchPage(1);
}

/**
 * Starts the badge fetch, the poll and the `/notifications` WS subscription.
 * Idempotent: a running poll timer means the channels are already up.
 */
function startChannels(): void {
	if (pollTimer !== null) return;

	fetchUnreadCount();
	pollTimer = setInterval(() => {
		if (document.visibilityState === 'visible') fetchUnreadCount();
	}, POLL_INTERVAL_MS);

	// The self-subscription path never names an account — the channel is
	// derived from the authenticated principal at the server. Subscribing
	// before the socket is open is safe: the client re-sends every active
	// subscription on connect.
	getWebSocketClient().connect();
	wsUnsub = subscribeToDocument('/notifications', onWsEvent);
}

/**
 * Stops the poll and the WS subscription, and clears the badge and the panel.
 * The shared socket stays connected — builder subscriptions ride it too.
 */
function stopChannels(): void {
	if (pollTimer !== null) {
		clearInterval(pollTimer);
		pollTimer = null;
	}
	if (wsUnsub !== null) {
		wsUnsub();
		wsUnsub = null;
	}
	unreadCount = 0;
	open = false;
}

/**
 * Fetches the `notifications` settings scope. Fails open (`true`) when the
 * scope cannot be read — the registered default is `true`, and a broken
 * settings route must not silence the bell.
 */
async function loadPreference(): Promise<boolean> {
	try {
		const res = await apiFetch('/Api/settings/notifications');
		if (!res.ok) return true;
		const body = (await res.json()) as { values?: { in_app?: boolean } };
		return body.values?.in_app ?? true;
	} catch {
		return true;
	}
}

/**
 * Returns the in-app preference, loading it once if needed. The Settings page
 * uses this so the toggle reflects the stored value even when
 * `initNotifications` has not resolved yet. An explicit `setInAppEnabled`
 * write always wins over an in-flight read.
 */
export async function ensureNotificationsPreference(): Promise<boolean> {
	if (inAppEnabled !== null) return inAppEnabled;
	const enabled = await loadPreference();
	if (inAppEnabled === null) inAppEnabled = enabled;
	return inAppEnabled;
}

/**
 * Starts the delivery channels the preference allows: the preference is read
 * once, and the badge fetch, poll and WS subscription run only when enabled.
 * Idempotent and browser-only: safe to call from an effect that re-runs on
 * route changes.
 */
export function initNotifications(): void {
	if (initialized || typeof window === 'undefined') return;
	initialized = true;
	void ensureNotificationsPreference().then((enabled) => {
		if (enabled) startChannels();
	});
}

/**
 * Persists the in-app notification preference and starts or stops the
 * delivery channels to match. Throws on a failed write so callers can show
 * an error; the local state stays unchanged then.
 */
export async function setInAppEnabled(enabled: boolean): Promise<void> {
	const res = await apiFetch('/Api/settings/notifications/in_app', {
		method: 'PUT',
		headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
		body: JSON.stringify({ value: enabled })
	});
	if (!res.ok) {
		throw await apiErrorMessage(res, m.errors_settings_save({ key: 'in_app' }));
	}
	inAppEnabled = enabled;
	if (enabled) {
		startChannels();
	} else {
		stopChannels();
	}
}

/** Drops all state, the poll timer and the WS subscription. Called on logout. */
export function resetNotifications(): void {
	stopChannels();
	// The shared socket's auth context was captured at upgrade time, so a
	// different user signing in on the same tab must get a fresh connection
	// rather than a re-subscribe on the old principal's socket. Builder
	// subscriptions re-connect on demand when their effect re-runs.
	getWebSocketClient().disconnect();
	initialized = false;
	items = [];
	unreadCount = 0;
	more = false;
	page = 1;
	loading = false;
	open = false;
	inAppEnabled = null;
}

/**
 * Toggles the panel. Opening refreshes the list and the badge, so rows
 * mutated elsewhere (another tab, a newer producer) never render stale.
 */
export async function toggleNotificationPanel(): Promise<void> {
	open = !open;
	if (open) {
		await Promise.all([fetchPage(1), fetchUnreadCount()]);
	}
}

/** Closes the panel (e.g. after navigating to a source document). */
export function closeNotificationPanel(): void {
	open = false;
}

/** Fetches the next page and appends it. */
export async function loadMoreNotifications(): Promise<void> {
	if (loading || !more) return;
	await fetchPage(page + 1);
}

/**
 * Marks one notification read via `POST /Api/notifications/:id/read`.
 * A no-op for rows that are already read. The row is updated only after
 * the API confirms, so a failed call leaves the state honest.
 */
export async function markNotificationRead(item: NotificationItem): Promise<void> {
	if (item.read_at !== null) return;

	const res = await apiFetch(`/Api/notifications/${item.id}/read`, {
		method: 'POST',
		headers: { 'X-Requested-With': 'XMLHttpRequest' }
	});
	if (!res.ok) return;

	const body = (await res.json()) as { read_at?: string };
	decrementUnread(item);
	replaceItem({ ...item, read_at: body.read_at ?? new Date().toISOString() });
}

/**
 * Marks every unread notification read via `POST /Api/notifications/read_all`.
 * The response carries no per-row timestamps, so the unread rows are stamped
 * with the local time after the API confirms.
 */
export async function markAllNotificationsRead(): Promise<void> {
	const res = await apiFetch('/Api/notifications/read_all', {
		method: 'POST',
		headers: { 'X-Requested-With': 'XMLHttpRequest' }
	});
	if (!res.ok) return;

	const now = new Date().toISOString();
	items = items.map((i) => (i.read_at === null ? { ...i, read_at: now } : i));
	unreadCount = 0;
}

/**
 * Fires one notification action. Confirmation prompts come from the
 * descriptor's `confirm` field. On success — or on 409, which proves the
 * actions are already consumed server-side — the row is stamped with the
 * response's `read_at` / `actioned_at`, which is exactly what disables the
 * panel's action buttons.
 */
export async function fireNotificationAction(
	item: NotificationItem,
	action: NotificationActionDescriptor
): Promise<void> {
	if (item.actioned_at !== null) return;
	if (action.confirm && typeof window !== 'undefined' && !window.confirm(action.confirm)) return;

	const res = await apiFetch(
		`/Api/notifications/${item.id}/actions/${encodeURIComponent(action.key)}`,
		{
			method: 'POST',
			headers: { 'X-Requested-With': 'XMLHttpRequest' },
			body: '{}'
		}
	);
	if (!res.ok && res.status !== 409) return;

	const now = new Date().toISOString();
	const body = (await res.json()) as { read_at?: string; actioned_at?: string };
	const wasUnread = item.read_at === null;
	replaceItem({
		...item,
		read_at: body.read_at ?? item.read_at ?? now,
		actioned_at: body.actioned_at ?? now
	});
	if (wasUnread) unreadCount = Math.max(0, unreadCount - 1);
}
