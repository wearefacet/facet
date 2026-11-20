// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import { staticKey, type TokenProvider } from '../src/auth/provider.js';
import { ApiError, AuthError, DeletedError, NetworkError, NotFoundError } from '../src/errors.js';
import { requestJson } from '../src/http.js';

const BASE = 'https://facet.example.com';

function jsonResponse(status: number, body: unknown, statusText = ''): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		statusText,
		text: async () => JSON.stringify(body)
	} as unknown as Response;
}

function textResponse(status: number, text: string, statusText = ''): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		statusText,
		text: async () => text
	} as unknown as Response;
}

function asFetch(mock: ReturnType<typeof vi.fn>): typeof fetch {
	return mock as unknown as typeof fetch;
}

function headersOf(mock: ReturnType<typeof vi.fn>): Record<string, string> {
	const init = mock.mock.calls[0]?.[1] as RequestInit;
	return init.headers as Record<string, string>;
}

const noToken: TokenProvider = { getToken: async () => null };

describe('requestJson — URL join', () => {
	it('joins the base URL and the path', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { ok: true }));
		await requestJson(BASE, '/Api/crm/Company', { fetchImpl: asFetch(fetchImpl) });
		expect(String(fetchImpl.mock.calls[0]?.[0])).toBe(`${BASE}/Api/crm/Company`);
	});

	it('does not double a trailing slash on the base URL', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { ok: true }));
		await requestJson(`${BASE}/`, '/Api/crm/Company', { fetchImpl: asFetch(fetchImpl) });
		expect(String(fetchImpl.mock.calls[0]?.[0])).toBe(`${BASE}/Api/crm/Company`);
	});

	it('resolves an absolute path against the origin, not a base path', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { ok: true }));
		await requestJson(`${BASE}/prefix`, '/Api/crm/Company', { fetchImpl: asFetch(fetchImpl) });
		expect(String(fetchImpl.mock.calls[0]?.[0])).toBe(`${BASE}/Api/crm/Company`);
	});
});

describe('requestJson — bearer header', () => {
	it('sends the bearer header when the provider returns a token', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { ok: true }));
		await requestJson(BASE, '/Api/crm/Company', {
			auth: staticKey('fct_key'),
			fetchImpl: asFetch(fetchImpl)
		});
		const headers = headersOf(fetchImpl);
		expect(headers['authorization']).toBe('Bearer fct_key');
		expect(headers['accept']).toBe('application/json');
	});

	it('sends no bearer header without a provider', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { ok: true }));
		await requestJson(BASE, '/OAuth/client-info?slug=demo', { fetchImpl: asFetch(fetchImpl) });
		expect(headersOf(fetchImpl)['authorization']).toBeUndefined();
	});

	it('raises AuthError before the request when the provider returns no token', async () => {
		const fetchImpl = vi.fn();
		const error = await requestJson(BASE, '/Api/crm/Company', {
			auth: noToken,
			fetchImpl: asFetch(fetchImpl)
		}).catch((caught: unknown) => caught);
		expect(error).toBeInstanceOf(AuthError);
		expect(fetchImpl).not.toHaveBeenCalled();
	});
});

describe('requestJson — bodies', () => {
	it('serializes a JSON body with the JSON content type', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { ok: true }));
		await requestJson(BASE, '/Api/crm/Company', {
			method: 'POST',
			json: { name: 'Acme' },
			auth: staticKey('fct_key'),
			fetchImpl: asFetch(fetchImpl)
		});
		const init = fetchImpl.mock.calls[0]?.[1] as RequestInit;
		expect(init.method).toBe('POST');
		expect(init.body).toBe(JSON.stringify({ name: 'Acme' }));
		expect((init.headers as Record<string, string>)['content-type']).toBe('application/json');
	});

	it('returns the parsed JSON body', async () => {
		const payload = { data: { name: 'Acme' }, meta: { id: 'crm.Company.1' } };
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, payload));
		await expect(
			requestJson(BASE, '/Api/crm/Company/1', { fetchImpl: asFetch(fetchImpl) })
		).resolves.toEqual(payload);
	});

	it('returns undefined for a 204 response', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(textResponse(204, ''));
		await expect(
			requestJson(BASE, '/Api/crm/Company/1', { method: 'DELETE', fetchImpl: asFetch(fetchImpl) })
		).resolves.toBeUndefined();
	});

	it('returns undefined for an empty body', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(textResponse(200, ''));
		await expect(
			requestJson(BASE, '/Api/crm/Company/1', { fetchImpl: asFetch(fetchImpl) })
		).resolves.toBeUndefined();
	});

	it('raises when a success body is not JSON', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(textResponse(200, '<html>hello</html>'));
		const error = await requestJson(BASE, '/Api/crm/Company/1', {
			fetchImpl: asFetch(fetchImpl)
		}).catch((caught: unknown) => caught);
		expect(error).toBeInstanceOf(ApiError);
		expect((error as ApiError).status).toBe(200);
		expect((error as ApiError).message).toContain('not JSON');
	});
});

describe('requestJson — error mapping', () => {
	it('maps a 422 with string details into a typed error', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(422, { error: 'validation_failed', details: ['slug is taken'] })
			);
		const error = await requestJson(BASE, '/Api/crm/Company', {
			fetchImpl: asFetch(fetchImpl)
		}).catch((caught: unknown) => caught);
		expect(error).toBeInstanceOf(ApiError);
		const apiError = error as ApiError;
		expect(apiError.status).toBe(422);
		expect(apiError.details).toEqual([{ message: 'slug is taken' }]);
		expect(apiError.message).toContain('validation_failed');
		expect(apiError.message).toContain('slug is taken');
	});

	it('maps {message} detail items into structured details', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(422, {
				error: 'validation_failed',
				details: [{ field: 'name', message: 'name is required', code: 'required' }]
			})
		);
		const error = await requestJson(BASE, '/Api/crm/Company', {
			fetchImpl: asFetch(fetchImpl)
		}).catch((caught: unknown) => caught);
		expect(error).toBeInstanceOf(ApiError);
		expect((error as ApiError).details).toEqual([
			{ field: 'name', message: 'name is required', code: 'required' }
		]);
	});

	it('maps a 404 to NotFoundError', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(404, { error: 'unknown_document' }));
		const error = await requestJson(BASE, '/Api/crm/Company/1', {
			fetchImpl: asFetch(fetchImpl)
		}).catch((caught: unknown) => caught);
		expect(error).toBeInstanceOf(NotFoundError);
		expect((error as NotFoundError).status).toBe(404);
	});

	it('maps a 410 tombstone to DeletedError with meta filled', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(410, {
				error: 'document_deleted',
				display_name: 'Acme Corp',
				deleted_at: '2026-01-01T12:00:00Z'
			})
		);
		const error = await requestJson(BASE, '/Api/crm/Company/1', {
			fetchImpl: asFetch(fetchImpl)
		}).catch((caught: unknown) => caught);
		expect(error).toBeInstanceOf(DeletedError);
		const deleted = error as DeletedError;
		expect(deleted.status).toBe(410);
		expect(deleted.displayName).toBe('Acme Corp');
		expect(deleted.deletedAt).toBe('2026-01-01T12:00:00Z');
		expect(deleted.meta).toEqual({
			display_name: 'Acme Corp',
			deleted_at: '2026-01-01T12:00:00Z'
		});
	});

	it('keeps the status text when an error body is not JSON', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(textResponse(502, '<html>Bad Gateway</html>', 'Bad Gateway'));
		const error = await requestJson(BASE, '/Api/crm/Company', {
			fetchImpl: asFetch(fetchImpl)
		}).catch((caught: unknown) => caught);
		expect(error).toBeInstanceOf(ApiError);
		expect((error as ApiError).status).toBe(502);
		expect((error as ApiError).details).toEqual([]);
		expect((error as ApiError).message).toContain('Bad Gateway');
	});
});

describe('requestJson — network failures', () => {
	it('maps a fetch throw to NetworkError', async () => {
		const fetchImpl = vi.fn().mockRejectedValue(new TypeError('fetch failed'));
		const error = await requestJson(BASE, '/Api/crm/Company', {
			fetchImpl: asFetch(fetchImpl)
		}).catch((caught: unknown) => caught);
		expect(error).toBeInstanceOf(NetworkError);
		expect((error as NetworkError).status).toBe(0);
		expect((error as NetworkError).message).toContain('fetch failed');
	});
});

describe('requestJson — 401 refresh', () => {
	it('retries once with the fresh token when the provider refreshes', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(401, { error: 'token_expired' }))
			.mockResolvedValueOnce(jsonResponse(200, { ok: true }));
		const auth: TokenProvider = {
			getToken: async () => 'stale',
			refreshOn401: async () => 'fresh'
		};

		const res = await requestJson(BASE, '/Api/crm/Company', {
			auth,
			fetchImpl: asFetch(fetchImpl)
		});

		expect(res).toEqual({ ok: true });
		const headers = (init: RequestInit) => init.headers as Record<string, string>;
		expect(headers(fetchImpl.mock.calls[0]?.[1] as RequestInit)['authorization']).toBe(
			'Bearer stale'
		);
		expect(headers(fetchImpl.mock.calls[1]?.[1] as RequestInit)['authorization']).toBe(
			'Bearer fresh'
		);
	});

	it('surfaces the 401 when the provider has no refresh', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(401, { error: 'token_expired' }));
		await expect(
			requestJson(BASE, '/Api/crm/Company', {
				auth: staticKey('fct_k'),
				fetchImpl: asFetch(fetchImpl)
			})
		).rejects.toBeInstanceOf(ApiError);
		expect(fetchImpl).toHaveBeenCalledTimes(1);
	});

	it('propagates the AuthError from a failed refresh', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(401, { error: 'token_expired' }));
		const auth: TokenProvider = {
			getToken: async () => 'stale',
			refreshOn401: async () => {
				throw new AuthError('Sign in again.');
			}
		};
		await expect(
			requestJson(BASE, '/Api/crm/Company', { auth, fetchImpl: asFetch(fetchImpl) })
		).rejects.toBeInstanceOf(AuthError);
		expect(fetchImpl).toHaveBeenCalledTimes(1);
	});
});
