// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { NotificationItem } from './components/primitives/surfaces/NotificationPanel.svelte';

// The store routes every request through `apiFetch`; the mock stands in for
// the session layer (token refresh, 401 recovery) which no unit test needs.
vi.mock('./session.svelte', () => ({ apiFetch: vi.fn() }));

// The WebSocket client talks to a real socket; the gate tests only need to
// observe connect/subscribe calls. Type-only exports (`WsDocumentEvent`) are
// erased at compile time and need no mock entry.
vi.mock('./websocket.svelte.js', () => ({
	getWebSocketClient: vi.fn(() => ({ connect: vi.fn(), disconnect: vi.fn() })),
	subscribeToDocument: vi.fn(() => vi.fn())
}));

import { apiFetch } from './session.svelte';
import { subscribeToDocument } from './websocket.svelte.js';
import {
	toggleNotificationPanel,
	closeNotificationPanel,
	loadMoreNotifications,
	markNotificationRead,
	markAllNotificationsRead,
	fireNotificationAction,
	resetNotifications,
	getNotificationItems,
	getUnreadCount,
	hasMoreNotifications,
	isNotificationPanelOpen,
	initNotifications,
	isInAppEnabled,
	setInAppEnabled,
	ensureNotificationsPreference,
	bellProps
} from './notifications.svelte';

const mockApiFetch = vi.mocked(apiFetch);

const item = (over: Partial<NotificationItem> = {}): NotificationItem => ({
	id: '01JITEM1',
	domain: 'hr',
	doc_type: 'LeaveRequest',
	doc_id: '01JDOC1',
	kind: 'leave_pending',
	icon: null,
	title: 'Untitled',
	body: '',
	actions: [],
	read_at: null,
	actioned_at: null,
	created_at: new Date().toISOString(),
	...over
});

/**
 * Routes every mocked request to its canned response — one router per test,
 * so the mock always matches the URL, never the call order (the store fires
 * the list fetch and the badge count concurrently on panel open).
 */
function serve(pages: NotificationItem[][], opts: { unread?: number } = {}) {
	mockApiFetch.mockImplementation((input) => {
		const url = String(input);
		if (url.includes('unread_count')) {
			return Promise.resolve(
				new Response(JSON.stringify({ count: opts.unread ?? 0 }), { status: 200 })
			);
		}
		const pageMatch = url.match(/page=(\d+)/);
		const pageIndex = pageMatch ? Number(pageMatch[1]) - 1 : 0;
		const rows = pageMatch ? (pages[pageIndex] ?? []) : [];
		return Promise.resolve(
			new Response(JSON.stringify({ data: rows, meta: { count: rows.length, more: false } }), {
				status: 200
			})
		);
	});
}

const ok = (body: unknown) => Promise.resolve(new Response(JSON.stringify(body), { status: 200 }));
const status = (code: number, body: unknown) =>
	Promise.resolve(new Response(JSON.stringify(body), { status: code }));

beforeEach(() => {
	mockApiFetch.mockReset();
	resetNotifications();
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('notifications store', () => {
	it('opens the panel, fetches page 1 and the unread count', async () => {
		serve([[item({ id: 'a' }), item({ id: 'b' })]], { unread: 2 });

		await toggleNotificationPanel();

		expect(isNotificationPanelOpen()).toBe(true);
		expect(getUnreadCount()).toBe(2);
		expect(getNotificationItems().map((i) => i.id)).toEqual(['a', 'b']);
		expect(hasMoreNotifications()).toBe(false);

		const urls = mockApiFetch.mock.calls.map((c) => String(c[0]));
		expect(urls).toContain('/Api/notifications/unread_count');
		expect(urls).toContain('/Api/notifications?page=1&per_page=20');
	});

	it('bellProps exposes the shared bell wiring and opens the panel through it', async () => {
		serve([[item()]], { unread: 3 });

		const props = bellProps();
		// The bell stays on until the preference is explicitly false.
		expect(props.showNotifications).toBe(true);
		expect(props.notificationsCount).toBe(0);
		expect(props.onnotifications).toBe(toggleNotificationPanel);

		await props.onnotifications();

		expect(isNotificationPanelOpen()).toBe(true);
		expect(bellProps().notificationsCount).toBe(3);
	});

	it('appends later pages and dedupes by id', async () => {
		// A full first page (20 rows, the API's `per_page`) keeps the "next
		// page exists" signal on; page 2 repeats `b` to exercise the dedupe.
		const firstPage = [
			item({ id: 'a' }),
			item({ id: 'b' }),
			...Array.from({ length: 18 }, (_, i) => item({ id: `pad-${i}` }))
		];
		serve([firstPage, [item({ id: 'b' }), item({ id: 'c' })]]);

		await toggleNotificationPanel();
		expect(hasMoreNotifications()).toBe(true);
		await loadMoreNotifications();

		const ids = getNotificationItems().map((i) => i.id);
		expect(ids.slice(0, 2)).toEqual(['a', 'b']);
		expect(ids).toContain('c');
		expect(new Set(ids).size).toBe(ids.length);
		expect(hasMoreNotifications()).toBe(false);
	});

	it('marks one notification read and drops the badge by one', async () => {
		const row = item();
		serve([[row]], { unread: 1 });
		let readCalled = false;
		mockApiFetch.mockImplementation((input) => {
			const url = String(input);
			if (url.endsWith('/read')) {
				readCalled = true;
				return ok({ id: row.id, read_at: '2026-01-01T00:00:00Z' });
			}
			if (url.includes('unread_count')) {
				return ok({ count: 1 });
			}
			return ok({ data: [row], meta: { count: 1, more: false } });
		});

		await toggleNotificationPanel();
		await markNotificationRead(getNotificationItems()[0]);

		expect(readCalled).toBe(true);
		expect(mockApiFetch).toHaveBeenCalledWith(
			'/Api/notifications/01JITEM1/read',
			expect.objectContaining({ method: 'POST', headers: { 'X-Requested-With': 'XMLHttpRequest' } })
		);
		expect(getUnreadCount()).toBe(0);
		expect(getNotificationItems()[0].read_at).toBe('2026-01-01T00:00:00Z');

		// Already-read rows are a no-op — no second request.
		await markNotificationRead(getNotificationItems()[0]);
		expect(mockApiFetch.mock.calls.filter((c) => String(c[0]).endsWith('/read')).length).toBe(1);
	});

	it('marks all read and zeroes the badge', async () => {
		const a = item({ id: 'a' });
		const b = item({ id: 'b', read_at: '2026-01-01T00:00:00Z' });
		serve([[a, b]], { unread: 1 });
		let readAllCalled = false;
		mockApiFetch.mockImplementation((input) => {
			if (String(input).includes('read_all')) {
				readAllCalled = true;
				return ok({ marked: 1 });
			}
			return status(200, { data: [], meta: { count: 0, more: false } });
		});

		await toggleNotificationPanel();
		await markAllNotificationsRead();

		expect(readAllCalled).toBe(true);
		expect(getUnreadCount()).toBe(0);
		expect(getNotificationItems().every((i) => i.read_at !== null)).toBe(true);
	});

	it('stamps the action response and drops the unread badge (one-shot)', async () => {
		const pending = item({ actions: [{ key: 'approve', label: 'Approve' }] });
		serve([[pending]], { unread: 1 });
		let actionCalled = false;
		mockApiFetch.mockImplementation((input) => {
			if (String(input).includes('/actions/')) {
				actionCalled = true;
				return ok({ result: {}, read_at: 'R', actioned_at: 'A' });
			}
			return status(200, { data: [pending], meta: { count: 1, more: false } });
		});

		await toggleNotificationPanel();
		await fireNotificationAction(pending, { key: 'approve', label: 'Approve' });

		expect(actionCalled).toBe(true);
		expect(mockApiFetch).toHaveBeenCalledWith(
			'/Api/notifications/01JITEM1/actions/approve',
			expect.objectContaining({ method: 'POST', headers: { 'X-Requested-With': 'XMLHttpRequest' } })
		);
		const row = getNotificationItems()[0];
		expect(row.read_at).toBe('R');
		expect(row.actioned_at).toBe('A');
		expect(getUnreadCount()).toBe(0);
	});

	it('treats 409 as "already actioned" and stamps the row locally', async () => {
		const pending = item({ actions: [{ key: 'approve', label: 'Approve' }] });
		serve([[pending]], { unread: 1 });
		mockApiFetch.mockImplementation((input) => {
			if (String(input).includes('/actions/')) {
				return status(409, { error: 'Notification action already used' });
			}
			return status(200, { data: [pending], meta: { count: 1, more: false } });
		});

		await toggleNotificationPanel();
		await fireNotificationAction(pending, { key: 'approve', label: 'Approve' });

		expect(getNotificationItems()[0].actioned_at).not.toBeNull();
	});

	it('skips the request for an already-actioned item', async () => {
		const done = item({ actioned_at: '2026-01-01T00:00:00Z' });
		serve([[done]]);

		await toggleNotificationPanel();
		await fireNotificationAction(done, { key: 'approve', label: 'Approve' });

		expect(mockApiFetch.mock.calls.filter((c) => String(c[0]).includes('/actions/')).length).toBe(
			0
		);
	});

	it('does not fire a declined confirmation', async () => {
		const pending = item({
			actions: [{ key: 'reject', label: 'Reject', confirm: 'Reject this request?' }]
		});
		serve([[pending]]);
		vi.stubGlobal('window', { confirm: () => false });

		await toggleNotificationPanel();
		await fireNotificationAction(pending, {
			key: 'reject',
			label: 'Reject',
			confirm: 'Reject this request?'
		});

		expect(mockApiFetch.mock.calls.filter((c) => String(c[0]).includes('/actions/')).length).toBe(
			0
		);
		expect(getNotificationItems()[0].actioned_at).toBeNull();
	});

	it('fires an accepted confirmation', async () => {
		const pending = item({
			actions: [{ key: 'approve', label: 'Approve', confirm: 'Approve this request?' }]
		});
		serve([[pending]]);
		vi.stubGlobal('window', { confirm: () => true });
		let actionCalled = false;
		mockApiFetch.mockImplementation((input) => {
			if (String(input).includes('/actions/')) {
				actionCalled = true;
				return ok({ result: {}, read_at: 'R', actioned_at: 'A' });
			}
			return status(200, { data: [pending], meta: { count: 1, more: false } });
		});

		await toggleNotificationPanel();
		await fireNotificationAction(pending, {
			key: 'approve',
			label: 'Approve',
			confirm: 'Approve this request?'
		});

		expect(actionCalled).toBe(true);
	});

	it('resets all state', async () => {
		serve([[item()]], { unread: 1 });

		await toggleNotificationPanel();
		resetNotifications();

		expect(isNotificationPanelOpen()).toBe(false);
		expect(getNotificationItems()).toEqual([]);
		expect(getUnreadCount()).toBe(0);
	});

	it('closeNotificationPanel hides the panel without a request', async () => {
		serve([[item()]]);
		await toggleNotificationPanel();
		mockApiFetch.mockClear();

		closeNotificationPanel();

		expect(isNotificationPanelOpen()).toBe(false);
		expect(mockApiFetch).not.toHaveBeenCalled();
	});
});

describe('notifications preference gate', () => {
	/** Stubs the browser globals `initNotifications` requires in the node environment. */
	function stubBrowser(): void {
		vi.stubGlobal('window', {});
		vi.stubGlobal('document', { visibilityState: 'visible' });
	}

	/** Routes `/Api/settings/notifications` to the given `in_app` value plus optional failures. */
	function servePreference(inApp: boolean | number, opts: { failPut?: boolean } = {}): void {
		mockApiFetch.mockImplementation((input, init) => {
			const url = String(input);
			if (url === '/Api/settings/notifications') {
				return ok({ app: 'notifications', values: { in_app: inApp } });
			}
			if (url === '/Api/settings/notifications/in_app') {
				if (opts.failPut) return status(422, { error: 'must be a boolean' });
				expect(init?.method).toBe('PUT');
				expect(init?.headers).toEqual(
					expect.objectContaining({ 'X-Requested-With': 'XMLHttpRequest' })
				);
				expect(JSON.parse(String(init?.body))).toEqual({ value: !inApp });
				return ok({ app: 'notifications', key: 'in_app', value: !inApp });
			}
			if (url.includes('unread_count')) {
				return ok({ count: 1 });
			}
			return ok({ data: [], meta: { count: 0, more: false } });
		});
	}

	beforeEach(() => {
		stubBrowser();
	});

	it('reports the preference as unloaded before init and after reset', () => {
		expect(isInAppEnabled()).toBeNull();
		resetNotifications();
		expect(isInAppEnabled()).toBeNull();
	});

	it('starts no channel when the preference is off', async () => {
		servePreference(false);

		initNotifications();
		await vi.waitFor(() => expect(isInAppEnabled()).toBe(false));

		const urls = mockApiFetch.mock.calls.map((c) => String(c[0]));
		expect(urls).not.toContain('/Api/notifications/unread_count');
		expect(subscribeToDocument).not.toHaveBeenCalled();
	});

	it('bellProps hides the bell only when the preference is explicitly off', async () => {
		servePreference(false);

		initNotifications();
		await vi.waitFor(() => expect(isInAppEnabled()).toBe(false));

		expect(bellProps().showNotifications).toBe(false);
		expect(bellProps().notificationsCount).toBe(0);
	});

	it('starts the channels when the preference is on', async () => {
		servePreference(true);

		initNotifications();
		await vi.waitFor(() => expect(isInAppEnabled()).toBe(true));

		const urls = mockApiFetch.mock.calls.map((c) => String(c[0]));
		expect(urls).toContain('/Api/notifications/unread_count');
		expect(subscribeToDocument).toHaveBeenCalledWith('/notifications', expect.any(Function));
	});

	it('fails open when the scope cannot be read', async () => {
		mockApiFetch.mockImplementation(() => status(500, { error: 'boom' }));

		initNotifications();
		await vi.waitFor(() => expect(isInAppEnabled()).toBe(true));
		expect(mockApiFetch.mock.calls.map((c) => String(c[0]))).toContain(
			'/Api/notifications/unread_count'
		);
	});

	it('enable after a disabled init starts the channels', async () => {
		servePreference(false);
		initNotifications();
		await vi.waitFor(() => expect(isInAppEnabled()).toBe(false));

		servePreference(false);
		await setInAppEnabled(true);

		expect(isInAppEnabled()).toBe(true);
		expect(mockApiFetch.mock.calls.map((c) => String(c[0]))).toContain(
			'/Api/notifications/unread_count'
		);
		expect(subscribeToDocument).toHaveBeenCalledWith('/notifications', expect.any(Function));
	});

	it('disable stops the channels and clears the badge', async () => {
		servePreference(true);
		initNotifications();
		await vi.waitFor(() => expect(getUnreadCount()).toBe(1));

		servePreference(true);
		await setInAppEnabled(false);

		expect(isInAppEnabled()).toBe(false);
		expect(getUnreadCount()).toBe(0);
		expect(isNotificationPanelOpen()).toBe(false);
		// The WS subscription was torn down with the channels.
		const unsub = vi.mocked(subscribeToDocument).mock.results[0]?.value;
		expect(unsub).toBeDefined();
		expect(unsub).toHaveBeenCalled();
	});

	it('a failed write keeps the preference and the channels unchanged', async () => {
		servePreference(true);
		initNotifications();
		await vi.waitFor(() => expect(isInAppEnabled()).toBe(true));

		servePreference(true, { failPut: true });
		await expect(setInAppEnabled(false)).rejects.toThrow();

		expect(isInAppEnabled()).toBe(true);
	});

	it('an explicit write wins over an in-flight preference read', async () => {
		let releaseRead: ((v: boolean) => void) | undefined;
		mockApiFetch.mockImplementation((input) => {
			const url = String(input);
			if (url === '/Api/settings/notifications') {
				return new Promise((resolve) => {
					releaseRead = (v: boolean) =>
						resolve(new Response(JSON.stringify({ values: { in_app: v } }), { status: 200 }));
				});
			}
			if (url === '/Api/settings/notifications/in_app') {
				return ok({ value: true });
			}
			return ok({ count: 0 });
		});

		const pending = ensureNotificationsPreference();
		await setInAppEnabled(true);
		// The stale read resolves to the pre-write value; the store keeps the write.
		releaseRead?.(false);
		await pending;

		expect(isInAppEnabled()).toBe(true);
	});

	it('reset clears the preference and stops the channels', async () => {
		servePreference(true);
		initNotifications();
		await vi.waitFor(() => expect(isInAppEnabled()).toBe(true));

		resetNotifications();

		expect(isInAppEnabled()).toBeNull();
	});
});
