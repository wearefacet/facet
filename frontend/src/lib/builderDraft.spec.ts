// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach } from 'vitest';
import * as m from '$lib/paraglide/messages';
import type { NavDomain } from './navTypes';

// The store routes requests through `apiFetch`; the mock stands in for the
// session layer (token refresh, 401 recovery) which no unit test needs.
vi.mock('$lib/session.svelte', () => ({ apiFetch: vi.fn() }));

// The draft install goes through the navState rebuild helpers; the tests
// observe that the store drives them, not how the fetch itself is shaped.
vi.mock('$lib/navState.svelte', () => ({
	prependDraft: vi.fn(),
	rebuildDraftNav: vi.fn(),
	setDraftNav: vi.fn(),
	setLiveNav: vi.fn(),
	setNavLiveDomains: vi.fn(),
	setLiveFromLoad: vi.fn(),
	getNavDomains: vi.fn(() => []),
	getNavLiveDomains: vi.fn(() => []),
	getNavIsDraft: vi.fn(() => false),
	getDomainLabel: vi.fn((id: string) => id)
}));

// `buildNavModel` would hit the DataSource layer from `createDoctype`;
// `domainProjectionToNavDomain` is the conversion under test here.
vi.mock('$lib/navModel', () => ({
	buildNavModel: vi.fn(),
	domainProjectionToNavDomain: vi.fn(
		(resp: { meta: { id: string } }): NavDomain => ({
			id: resp.meta.id,
			label: `Draft ${resp.meta.id}`,
			color: '#000000',
			doctypes: [],
			updatedAt: undefined
		})
	)
}));

import { apiFetch } from '$lib/session.svelte';
import { prependDraft, rebuildDraftNav } from '$lib/navState.svelte';
import { domainProjectionToNavDomain } from '$lib/navModel';
import { goto } from '$app/navigation';
import { resolve } from '$app/paths';
import {
	clearBuilderDraft,
	createDraft,
	createDraftFromSource,
	noteWsInvalidation,
	publishDraft,
	setBuilderDraft
} from './builderDraft.svelte';

const mockApiFetch = vi.mocked(apiFetch);
const mockPrependDraft = vi.mocked(prependDraft);
const mockRebuildDraftNav = vi.mocked(rebuildDraftNav);
const mockConvert = vi.mocked(domainProjectionToNavDomain);
const mockGoto = vi.mocked(goto);
const mockResolve = vi.mocked(resolve);

// `publishDraft` routes through the SvelteKit router; the identity `resolve`
// keeps the goto target readable in the assertions.
vi.mock('$app/navigation', () => ({ goto: vi.fn(), invalidateAll: vi.fn() }));
vi.mock('$app/paths', () => ({
	resolve: vi.fn((route: string) => route)
}));

const ok = (body: unknown) => Promise.resolve(new Response(JSON.stringify(body), { status: 200 }));
const status = (code: number, body: unknown) =>
	Promise.resolve(new Response(JSON.stringify(body), { status: code }));

beforeEach(() => {
	mockApiFetch.mockReset();
	mockPrependDraft.mockClear();
	mockRebuildDraftNav.mockClear();
	mockConvert.mockClear();
	mockGoto.mockClear();
	mockResolve.mockClear();
	noteWsInvalidation(null);
	clearBuilderDraft();
});

/** A deferred settle promise — drives the WS-invalidation wait by hand. */
function makeDeferred(): { promise: Promise<void>; resolve: () => void; reject: () => void } {
	let resolve!: () => void;
	let reject!: () => void;
	const promise = new Promise<void>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

describe('createDraft', () => {
	it('POSTs the draft, prepends it, and rebuilds the draft nav', async () => {
		mockApiFetch.mockReturnValue(
			ok({ data: { name: 'Logistics', draft: true }, meta: { id: '_abc' } })
		);

		const result = await createDraft({ name: 'Logistics' });

		expect(mockApiFetch).toHaveBeenCalledWith(
			'/Api/core/Domain/draft',
			expect.objectContaining({
				method: 'POST',
				body: JSON.stringify({ name: 'Logistics' })
			})
		);
		expect(mockConvert).toHaveBeenCalledWith({
			data: { name: 'Logistics', draft: true },
			meta: { id: '_abc' }
		});
		expect(mockPrependDraft).toHaveBeenCalledWith(
			expect.objectContaining({ id: '_abc', label: 'Draft _abc' })
		);
		expect(mockRebuildDraftNav).toHaveBeenCalledOnce();
		expect(result).toEqual({ error: null, draftId: '_abc' });
	});

	it('returns the backend error message on a failed POST', async () => {
		mockApiFetch.mockReturnValue(status(422, { error: 'Name already exists' }));

		const result = await createDraft({ name: 'Logistics' });

		expect(result).toEqual({ error: 'Name already exists' });
		expect(mockPrependDraft).not.toHaveBeenCalled();
		expect(mockRebuildDraftNav).not.toHaveBeenCalled();
	});

	it('falls back to the status message when the body has no error', async () => {
		mockApiFetch.mockReturnValue(status(500, {}));

		const result = await createDraft({ name: 'Logistics' });

		expect(result).toEqual({ error: m.builder_draft_failed_status({ status: 500 }) });
	});

	it('returns the network-error message when the request throws', async () => {
		mockApiFetch.mockReturnValue(Promise.reject(new Error('offline')));

		const result = await createDraft({ name: 'Logistics' });

		expect(result).toEqual({ error: m.builder_draft_network_error() });
	});

	it('waits for the recorded WS invalidation before resolving', async () => {
		mockApiFetch.mockReturnValue(ok({ data: {}, meta: { id: '_abc' } }));
		const deferred = makeDeferred();
		noteWsInvalidation(deferred.promise);

		const pending = createDraft({ name: 'Logistics' });
		let settled = false;
		void pending.then(() => {
			settled = true;
		});

		await Promise.resolve();
		await Promise.resolve();
		// The copy's invalidation burst is still in flight — the result holds.
		expect(settled).toBe(false);

		deferred.resolve();
		await expect(pending).resolves.toEqual({ error: null, draftId: '_abc' });
	});

	it('a rejected WS invalidation does not fail the draft creation', async () => {
		// The settle is an ordering courtesy: the invalidation promise is the
		// layout's `invalidateAll()`, whose failure must not block the goto.
		mockApiFetch.mockReturnValue(ok({ data: {}, meta: { id: '_abc' } }));
		noteWsInvalidation(Promise.reject(new Error('aborted')));

		await expect(createDraft({ name: 'Logistics' })).resolves.toEqual({
			error: null,
			draftId: '_abc'
		});
	});
});

/** A no-ticket publish response — the happy path of `publishDraft`. */
const publishOk = () => ok({ data: { domain: 'orders', grant_tickets: [] } });

describe('publishDraft', () => {
	it('routes to /Builder after a publish with no grant tickets', async () => {
		mockApiFetch.mockReturnValue(publishOk());
		setBuilderDraft({ id: '_abc', name: 'Logistics', isDraft: true });

		await expect(publishDraft('orders')).resolves.toEqual({ status: 'published', report: null });

		expect(mockApiFetch).toHaveBeenCalledWith(
			'/Api/core/Domain/_abc/publish',
			expect.objectContaining({
				method: 'POST',
				body: JSON.stringify({ target_name: 'orders', overwrite: false })
			}),
			{ fetch: undefined }
		);
		expect(mockGoto).toHaveBeenCalledOnce();
		expect(mockGoto).toHaveBeenCalledWith('/Builder');
	});

	it('waits for the recorded WS invalidation before routing away', async () => {
		mockApiFetch.mockReturnValue(publishOk());
		setBuilderDraft({ id: '_abc', name: 'Logistics', isDraft: true });
		const deferred = makeDeferred();
		noteWsInvalidation(deferred.promise);

		const pending = publishDraft('orders');
		let routed = false;
		void pending.then(() => {
			routed = true;
		});

		await Promise.resolve();
		await Promise.resolve();
		// The publish's invalidation burst is still in flight — the goto holds,
		// or the router would abort it and strand the dead draft editor.
		expect(mockGoto).not.toHaveBeenCalled();
		expect(routed).toBe(false);

		deferred.resolve();
		await expect(pending).resolves.toEqual({ status: 'published', report: null });
		expect(mockGoto).toHaveBeenCalledOnce();
		expect(mockGoto).toHaveBeenCalledWith('/Builder');
	});

	it('holds the navigation until a burst event recorded after the POST settles', async () => {
		vi.useFakeTimers();
		try {
			mockApiFetch.mockReturnValue(publishOk());
			setBuilderDraft({ id: '_abc', name: 'Logistics', isDraft: true });

			const pending = publishDraft('orders');
			let routed = false;
			void pending.then(() => {
				routed = true;
			});

			// The POST resolved; no burst event has landed yet.
			await vi.advanceTimersByTimeAsync(0);
			expect(mockGoto).not.toHaveBeenCalled();
			expect(routed).toBe(false);

			// A burst event lands mid-window and stays in flight — the goto
			// keeps holding across the settle windows.
			const burst = makeDeferred();
			noteWsInvalidation(burst.promise);
			await vi.advanceTimersByTimeAsync(250); // the settle window
			expect(routed).toBe(false);

			// The event settles; one more quiet window ends the wait.
			burst.resolve();
			await vi.advanceTimersByTimeAsync(250);
			await expect(pending).resolves.toEqual({ status: 'published', report: null });
			expect(mockGoto).toHaveBeenCalledOnce();
			expect(mockGoto).toHaveBeenCalledWith('/Builder');
		} finally {
			vi.useRealTimers();
		}
	});

	it('returns the grant-ticket report and keeps the route to the caller', async () => {
		const ticket = {
			producer: 'hr',
			filed: true,
			active: true,
			dropped: false,
			edges: [{ doctype: 'hr.Employee', tags: ['default'] }]
		};
		mockApiFetch.mockReturnValue(ok({ data: { domain: 'orders', grant_tickets: [ticket] } }));
		setBuilderDraft({ id: '_abc', name: 'Logistics', isDraft: true });

		await expect(publishDraft('orders')).resolves.toEqual({
			status: 'published',
			report: { domain: 'orders', grant_tickets: [ticket] }
		});
		expect(mockGoto).not.toHaveBeenCalled();
	});

	it('surfaces the 409 conflict as a distinct outcome without retrying or routing', async () => {
		mockApiFetch.mockReturnValue(status(409, { error: "Target name 'orders' is already in use" }));
		setBuilderDraft({ id: '_abc', name: 'Logistics', isDraft: true });

		await expect(publishDraft('orders')).resolves.toEqual({
			status: 'conflict',
			message: "Target name 'orders' is already in use"
		});

		// The store never retries on its own: one request, no navigation.
		expect(mockApiFetch).toHaveBeenCalledOnce();
		expect(mockGoto).not.toHaveBeenCalled();
	});

	it('publishes with overwrite only on the explicit confirmed second call', async () => {
		// First call answers the conflict; the user confirms in the dialog;
		// the second call carries `overwrite` and routes on success.
		mockApiFetch
			.mockReturnValueOnce(status(409, { error: "Target name 'orders' is already in use" }))
			.mockReturnValueOnce(publishOk());
		setBuilderDraft({ id: '_abc', name: 'Logistics', isDraft: true });

		await expect(publishDraft('orders')).resolves.toEqual({
			status: 'conflict',
			message: "Target name 'orders' is already in use"
		});
		await expect(publishDraft('orders', true)).resolves.toEqual({
			status: 'published',
			report: null
		});

		expect(mockApiFetch).toHaveBeenLastCalledWith(
			'/Api/core/Domain/_abc/publish',
			expect.objectContaining({
				body: JSON.stringify({ target_name: 'orders', overwrite: true })
			}),
			{ fetch: undefined }
		);
		expect(mockGoto).toHaveBeenCalledOnce();
		expect(mockGoto).toHaveBeenCalledWith('/Builder');
	});

	it('surfaces the version-gate rejection and does not route', async () => {
		mockApiFetch.mockReturnValue(
			status(422, { error: 'Structure changed without a version bump' })
		);
		setBuilderDraft({ id: '_abc', name: 'Logistics', isDraft: true });

		await expect(publishDraft('orders', true)).resolves.toEqual({
			status: 'error',
			message: 'Structure changed without a version bump'
		});
		expect(mockGoto).not.toHaveBeenCalled();
	});

	it('returns the no-active-draft error when no draft is set', async () => {
		await expect(publishDraft('orders')).resolves.toEqual({
			status: 'error',
			message: m.builder_no_active_draft()
		});
		expect(mockApiFetch).not.toHaveBeenCalled();
		expect(mockGoto).not.toHaveBeenCalled();
	});
});

describe('createDraftFromSource', () => {
	it('POSTs to the source-domain draft route with an empty body', async () => {
		mockApiFetch.mockReturnValue(ok({ data: { source_domain: 'crm' }, meta: { id: '_xyz' } }));

		const result = await createDraftFromSource('crm');

		expect(mockApiFetch).toHaveBeenCalledWith(
			'/Api/core/Domain/crm/draft',
			expect.objectContaining({ method: 'POST', body: '{}' })
		);
		expect(mockPrependDraft).toHaveBeenCalledWith(
			expect.objectContaining({ id: '_xyz', label: 'Draft _xyz' })
		);
		expect(mockRebuildDraftNav).toHaveBeenCalledOnce();
		expect(result).toEqual({ error: null, draftId: '_xyz' });
	});

	it('returns the backend error message on a failed POST', async () => {
		mockApiFetch.mockReturnValue(status(404, { error: 'Domain not found' }));

		const result = await createDraftFromSource('crm');

		expect(result).toEqual({ error: 'Domain not found' });
		expect(mockPrependDraft).not.toHaveBeenCalled();
	});

	it('returns the network-error message when the request throws', async () => {
		mockApiFetch.mockReturnValue(Promise.reject(new Error('offline')));

		const result = await createDraftFromSource('crm');

		expect(result).toEqual({ error: m.builder_draft_network_error() });
	});
});
