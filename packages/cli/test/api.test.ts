// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	ApiError,
	createApi,
	type DocumentEnvelope,
	type ListEnvelope,
	requestJson
} from '../src/api.js';
import { AuthError, writeSession, type StoredSession } from '../src/auth.js';

let configHome: string;

beforeEach(() => {
	configHome = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-api-'));
	mkdirSync(configHome, { recursive: true });
	vi.stubEnv('XDG_CONFIG_HOME', configHome);
	vi.stubEnv('FACET_TOKEN', '');
});

afterEach(() => {
	vi.unstubAllEnvs();
	rmSync(configHome, { recursive: true, force: true });
});

const INSTANCE = 'https://facet.example.com';

function jsonResponse(status: number, body: unknown): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		json: async () => body,
		text: async () => JSON.stringify(body)
	} as unknown as Response;
}

function session(overrides: Partial<StoredSession> = {}): StoredSession {
	return {
		access_token: 'at-1',
		refresh_token: 'rt-1',
		client_id: '01HCLIENT',
		account: '01J9ACCOUNT',
		role: 'admin',
		expires_at: new Date(Date.now() + 3_600_000).toISOString(),
		...overrides
	};
}

const APP_LIST: ListEnvelope = {
	data: [{ data: { slug: 'brw-plans', status: 'active' }, meta: { id: 'app.App.01HAPP' } }],
	meta: { count: 1, more: false }
};

const APP_ENVELOPE: DocumentEnvelope = {
	data: { slug: 'brw-plans', host: 'plans.facet.example.com' },
	meta: { id: 'app.App.01HAPP', created_at: '2026-01-01T00:00:00Z' }
};

const DEPLOYMENT_LIST: ListEnvelope = {
	data: [{ data: { revision: 3, note: 'first' }, meta: { id: 'app.Deployment.3' } }],
	meta: { count: 1, more: false }
};

function okList(): Response {
	return jsonResponse(200, DEPLOYMENT_LIST);
}

describe('requestJson', () => {
	it('maps a 422 with details into one message', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(422, {
				error: 'validation_failed',
				details: [{ message: 'revision is read-only' }, { message: 'note is too long' }]
			})
		);

		const error = await requestJson(INSTANCE, '/Api/app/App', {
			fetchImpl: fetchImpl as unknown as typeof fetch
		}).catch((caught: unknown) => caught);

		expect(error).toBeInstanceOf(ApiError);
		const apiError = error as ApiError;
		expect(apiError.status).toBe(422);
		expect(apiError.code).toBe('validation_failed');
		expect(apiError.details).toEqual(['revision is read-only', 'note is too long']);
		expect(apiError.message).toContain('validation_failed');
		expect(apiError.message).toContain('revision is read-only');
		expect(apiError.message).toContain('note is too long');
	});

	it('accepts plain strings in details', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(422, { error: 'validation_failed', details: ['slug is taken'] })
			);

		const error = await requestJson(INSTANCE, '/Api/app/App', {
			fetchImpl: fetchImpl as unknown as typeof fetch
		}).catch((caught: unknown) => caught);

		expect((error as ApiError).details).toEqual(['slug is taken']);
	});

	it('maps a plain 403 body', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(403, { error: 'Forbidden' }));

		const error = await requestJson(INSTANCE, '/Api/app/App', {
			fetchImpl: fetchImpl as unknown as typeof fetch
		}).catch((caught: unknown) => caught);

		const apiError = error as ApiError;
		expect(apiError.status).toBe(403);
		expect(apiError.code).toBe('Forbidden');
		expect(apiError.details).toEqual([]);
	});

	it('maps a network failure to a status-0 error', async () => {
		const fetchImpl = vi.fn().mockRejectedValue(new TypeError('fetch failed'));

		const error = await requestJson(INSTANCE, '/Api/app/App', {
			fetchImpl: fetchImpl as unknown as typeof fetch
		}).catch((caught: unknown) => caught);

		const apiError = error as ApiError;
		expect(apiError.status).toBe(0);
		expect(apiError.code).toBe('network_error');
		expect(apiError.message).toContain('fetch failed');
	});
});

describe('createApi — app resolution', () => {
	it('resolves a slug to the qualified app id', async () => {
		vi.stubEnv('FACET_TOKEN', 'fct_key');
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, APP_LIST));

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		await expect(api.resolveAppId('brw-plans')).resolves.toBe('app.App.01HAPP');

		const url = String(fetchImpl.mock.calls[0]?.[0]);
		expect(url).toContain('/Api/app/App?');
		expect(url).toContain('filters%5Bslug__eq%5D=brw-plans');
	});

	it('fails with a clear message when the slug matches nothing', async () => {
		vi.stubEnv('FACET_TOKEN', 'fct_key');
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 0, more: false } }));

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		await expect(api.resolveAppId('missing')).rejects.toThrow(/No app with slug "missing"/);
	});
});

describe('createApi — deployment operations', () => {
	it('creates the app with the name and slug the schema requires', async () => {
		vi.stubEnv('FACET_TOKEN', 'fct_key');
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(201, APP_ENVELOPE));

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		await expect(api.createApp('brw-plans')).resolves.toEqual(APP_ENVELOPE);

		// `app.App` requires `name` and declares no `display_name` content
		// field, so a `display_name` body key answers 422.
		const [url, init] = fetchImpl.mock.calls[0] as unknown as [URL, RequestInit];
		expect(String(url)).toBe(`${INSTANCE}/Api/app/App`);
		expect(init.method).toBe('POST');
		expect(JSON.parse(String(init.body))).toEqual({ name: 'brw-plans', slug: 'brw-plans' });
	});

	it('lists deployments with the qualified filter and revision sort', async () => {
		vi.stubEnv('FACET_TOKEN', 'fct_key');
		const fetchImpl = vi.fn().mockResolvedValue(okList());

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		await expect(api.listDeployments('app.App.01HAPP')).resolves.toEqual(DEPLOYMENT_LIST);

		const url = String(fetchImpl.mock.calls[0]?.[0]);
		expect(url).toContain('/Api/app/Deployment?');
		expect(url).toContain('filters%5Bapp_id__eq%5D=app.App.01HAPP');
		expect(url).toContain('sort=-revision');
	});

	it('sends the rollback PATCH with the qualified deployment reference', async () => {
		vi.stubEnv('FACET_TOKEN', 'fct_key');
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, APP_ENVELOPE));

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		await expect(api.setActiveDeployment('app.App.01HAPP', 'app.Deployment.2')).resolves.toEqual(
			APP_ENVELOPE
		);

		const [url, init] = fetchImpl.mock.calls[0] as unknown as [URL, RequestInit];
		expect(String(url)).toBe(`${INSTANCE}/Api/app/App/app.App.01HAPP`);
		expect(init.method).toBe('PATCH');
		expect(init.body).toBe(JSON.stringify({ active_deployment: 'app.Deployment.2' }));
	});

	it('posts the deploy multipart body to the deploy route', async () => {
		vi.stubEnv('FACET_TOKEN', 'fct_key');
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(201, { id: '01HDEP', revision: 4, activated: true, files: 1 })
			);

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		const result = await api.deploy(
			'app.App.01HAPP',
			'MULTIPART-BYTES',
			'multipart/form-data; boundary=x'
		);

		expect(result).toEqual({ id: '01HDEP', revision: 4, activated: true, files: 1 });
		const [url, init] = fetchImpl.mock.calls[0] as unknown as [URL, RequestInit];
		expect(String(url)).toBe(`${INSTANCE}/Api/app/app.App.01HAPP/deploy`);
		expect(init.method).toBe('POST');
		expect(init.body).toBe('MULTIPART-BYTES');
		const headers = init.headers as Record<string, string>;
		expect(headers['content-type']).toBe('multipart/form-data; boundary=x');
		expect(headers['authorization']).toBe('Bearer fct_key');
	});
});

describe('createApi — 401 refresh and retry', () => {
	it('refreshes on the first 401 and retries once', async () => {
		writeSession(INSTANCE, session());
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(401, { error: 'unauthorized' }))
			.mockResolvedValueOnce(
				jsonResponse(200, {
					access_token: 'at-2',
					refresh_token: 'rt-2',
					token_type: 'Bearer',
					expires_in: 3600
				})
			)
			.mockResolvedValueOnce(jsonResponse(200, APP_ENVELOPE));

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		await expect(api.readApp('app.App.01HAPP')).resolves.toEqual(APP_ENVELOPE);

		expect(fetchImpl).toHaveBeenCalledTimes(3);
		const [firstUrl, firstInit] = fetchImpl.mock.calls[0] as unknown as [URL, RequestInit];
		expect((firstInit.headers as Record<string, string>)['authorization']).toBe('Bearer at-1');

		const [secondUrl, secondInit] = fetchImpl.mock.calls[1] as unknown as [URL, RequestInit];
		expect(String(secondUrl)).toBe(`${INSTANCE}/OAuth/token`);
		expect(String(secondInit.body)).toContain('grant_type=refresh_token');
		expect(String(secondInit.body)).toContain('refresh_token=rt-1');
		expect(String(secondInit.body)).toContain('client_id=01HCLIENT');

		const [thirdUrl, thirdInit] = fetchImpl.mock.calls[2] as unknown as [URL, RequestInit];
		expect(String(thirdUrl)).toContain('/Api/app/App/app.App.01HAPP');
		expect((thirdInit.headers as Record<string, string>)['authorization']).toBe('Bearer at-2');

		// The rotated session was persisted for the next run.
		const { readSession } = await import('../src/auth.js');
		const stored = readSession(INSTANCE);
		expect(stored?.access_token).toBe('at-2');
		expect(stored?.refresh_token).toBe('rt-2');
	});

	it('raises the re-login error when the refresh itself fails', async () => {
		writeSession(INSTANCE, session());
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(401, { error: 'unauthorized' }))
			.mockResolvedValueOnce(
				jsonResponse(400, { error: 'invalid_grant', error_description: 'Session expired' })
			);

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		const error = await api.readApp('app.App.01HAPP').catch((caught: unknown) => caught);

		expect(error).toBeInstanceOf(AuthError);
		expect((error as Error).message).toMatch(/login/);

		// No retry runs after a failed refresh.
		expect(fetchImpl).toHaveBeenCalledTimes(2);
	});

	it('raises the re-login error when the retried call 401s again', async () => {
		writeSession(INSTANCE, session());
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(401, { error: 'unauthorized' }))
			.mockResolvedValueOnce(
				jsonResponse(200, {
					access_token: 'at-2',
					refresh_token: 'rt-2',
					token_type: 'Bearer',
					expires_in: 3600
				})
			)
			.mockResolvedValue(jsonResponse(401, { error: 'unauthorized' }));

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		const error = await api.readApp('app.App.01HAPP').catch((caught: unknown) => caught);

		expect(error).toBeInstanceOf(AuthError);
		expect((error as Error).message).toMatch(/login/);

		// Refresh and retry ran exactly once — no loop.
		expect(fetchImpl).toHaveBeenCalledTimes(3);
	});

	it('treats a 401 on an env token as final', async () => {
		vi.stubEnv('FACET_TOKEN', 'fct_bad_key');
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(401, { error: 'unauthorized' }));

		const api = createApi(INSTANCE, fetchImpl as unknown as typeof fetch);
		const error = await api.readApp('app.App.01HAPP').catch((caught: unknown) => caught);

		expect(error).toBeInstanceOf(ApiError);
		expect((error as ApiError).status).toBe(401);
		expect(fetchImpl).toHaveBeenCalledTimes(1);
	});
});
