// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import { staticKey } from '../src/auth/provider.js';
import { createFacetClient, type FacetClient } from '../src/client.js';
import { ApiError, DeletedError } from '../src/errors.js';

const BASE = 'https://facet.example.com';

function jsonResponse(status: number, body: unknown, statusText = ''): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		statusText,
		text: async () => JSON.stringify(body)
	} as unknown as Response;
}

/** One error response with no JSON body, as a gateway answers. */
function statusResponse(status: number, statusText: string): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		statusText,
		text: async () => ''
	} as unknown as Response;
}

function redirectResponse(location: string): Response {
	const headers = new Headers();
	headers.set('location', location);
	return {
		ok: false,
		status: 302,
		statusText: 'Found',
		headers,
		text: async () => ''
	} as unknown as Response;
}

function bytesResponse(bytes: Uint8Array): Response {
	return {
		ok: true,
		status: 200,
		statusText: '',
		headers: new Headers(),
		arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length)
	} as unknown as Response;
}

function asFetch(mock: ReturnType<typeof vi.fn>): typeof fetch {
	return mock as unknown as typeof fetch;
}

function callOf(mock: ReturnType<typeof vi.fn>, index: number): { url: URL; init: RequestInit } {
	const call = mock.mock.calls[index];
	if (!call) {
		throw new Error(`fetch was not called a ${index + 1}. time`);
	}
	return { url: call[0] as URL, init: call[1] as RequestInit };
}

function makeClient(mock: ReturnType<typeof vi.fn>): FacetClient {
	return createFacetClient({ baseUrl: BASE, auth: staticKey('fct_key'), fetchImpl: asFetch(mock) });
}

function pngFile(name = 'logo.png'): File {
	return new File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], name, { type: 'image/png' });
}

describe('upload', () => {
	it('posts one multipart file part to /Api/core/artifacts', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(201, { id: 'art_1', filename: 'logo.png', mime_type: 'image/png', size: 4 })
			);
		const artifacts = makeClient(fetchImpl).artifacts;
		const file = pngFile();
		const result = await artifacts.upload(file);

		const { url, init } = callOf(fetchImpl, 0);
		expect(String(url)).toBe(`${BASE}/Api/core/artifacts`);
		expect(init.method).toBe('POST');
		expect((init.headers as Record<string, string>)['content-type']).toBeUndefined();
		const form = init.body as FormData;
		expect(form).toBeInstanceOf(FormData);
		const part = form.get('file');
		expect(part).toBeInstanceOf(File);
		expect((part as File).name).toBe('logo.png');
		expect(result).toEqual({ id: 'art_1', filename: 'logo.png' });
	});

	it('honors a filename override and falls back for nameless blobs', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(201, { id: 'art_1', filename: 'x' }));
		const artifacts = makeClient(fetchImpl).artifacts;
		await artifacts.upload(pngFile(), { filename: 'renamed.png' });
		let form = callOf(fetchImpl, 0).init.body as FormData;
		expect((form.get('file') as File).name).toBe('renamed.png');

		const blob = new Blob([new Uint8Array([1])]);
		await artifacts.upload(blob);
		form = callOf(fetchImpl, 1).init.body as FormData;
		expect((form.get('file') as File).name).toBe('upload');
	});

	it('uploadAsUrn returns the urn:facet:artifact string', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(201, { id: 'art_9', filename: 'f.bin' }));
		const urn = await makeClient(fetchImpl).artifacts.uploadAsUrn(pngFile());
		expect(urn).toBe('urn:facet:artifact:art_9');
	});

	it('maps 413 to a typed ApiError with the status', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(413, { error: 'payload_too_large' }, 'Payload Too Large'));
		const error = await makeClient(fetchImpl)
			.artifacts.upload(pngFile())
			.catch((e: unknown) => e);
		expect(error).toBeInstanceOf(ApiError);
		expect((error as ApiError).status).toBe(413);
	});
});

describe('metadata, grants, and revoke', () => {
	it('show hits GET /Api/core/artifacts/:id', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(200, {
				id: 'art_1',
				filename: 'logo.png',
				mime_type: 'image/png',
				size: 4,
				sha256: 'ab12',
				url: 'https://files.example.com/a/sig',
				expires_at: '2026-01-01T00:01:00Z'
			})
		);
		const meta = await makeClient(fetchImpl).artifacts.show('art_1');
		const { url, init } = callOf(fetchImpl, 0);
		expect(String(url)).toBe(`${BASE}/Api/core/artifacts/art_1`);
		expect(init.method).toBe('GET');
		expect(meta.id).toBe('art_1');
		expect(meta.url).toBe('https://files.example.com/a/sig');
	});

	it('grant posts to /Api/core/artifacts/:id/grant with no body', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(201, { grant_id: 'g_1', artifact_id: 'art_1', url: 'https://f/a' })
			);
		const grant = await makeClient(fetchImpl).artifacts.grant('art_1');
		const { url, init } = callOf(fetchImpl, 0);
		expect(String(url)).toBe(`${BASE}/Api/core/artifacts/art_1/grant`);
		expect(init.method).toBe('POST');
		expect(init.body).toBeUndefined();
		expect(grant.grant_id).toBe('g_1');
	});

	it('publish posts the owner_id the server requires', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(201, {
				grant_id: 'g_2',
				artifact_id: 'art_1',
				url: 'https://f/p',
				permanent: true
			})
		);
		const grant = await makeClient(fetchImpl).artifacts.publish('art_1', { ownerId: 'own_1' });
		const { url, init } = callOf(fetchImpl, 0);
		expect(String(url)).toBe(`${BASE}/Api/core/artifacts/art_1/publish`);
		expect(init.method).toBe('POST');
		expect(JSON.parse(String(init.body))).toEqual({ owner_id: 'own_1' });
		expect(grant.permanent).toBe(true);
	});

	it('revoke hits DELETE /Api/core/artifacts/grants/:gid', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(204, undefined));
		await makeClient(fetchImpl).artifacts.revoke('g_1');
		const { url, init } = callOf(fetchImpl, 0);
		expect(String(url)).toBe(`${BASE}/Api/core/artifacts/grants/g_1`);
		expect(init.method).toBe('DELETE');
	});

	it('maps the gateway 410 to DeletedError and 403 to ApiError', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(410, { error: 'Artifact deleted' }))
			.mockResolvedValueOnce(jsonResponse(403, { error: 'Forbidden' }, 'Forbidden'));
		const artifacts = makeClient(fetchImpl).artifacts;
		const deleted = await artifacts.show('art_1').catch((e: unknown) => e);
		expect(deleted).toBeInstanceOf(DeletedError);
		const denied = await artifacts.grant('art_1').catch((e: unknown) => e);
		expect(denied).toBeInstanceOf(ApiError);
		expect((denied as ApiError).status).toBe(403);
	});
});

describe('download', () => {
	it('follows the 302 to the signed URL and returns the bytes', async () => {
		const bytes = new Uint8Array([1, 2, 3, 4]);
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(redirectResponse('https://files.example.com/a/g_sig'))
			.mockResolvedValueOnce(bytesResponse(bytes));
		const result = await makeClient(fetchImpl).artifacts.download('art_1');

		const first = callOf(fetchImpl, 0);
		expect(String(first.url)).toBe(`${BASE}/Api/core/artifacts/art_1/download`);
		expect(first.init.method).toBe('GET');
		expect((first.init.headers as Record<string, string>)['authorization']).toBe('Bearer fct_key');
		// The credential never rides the redirect target: the signed URL
		// authorizes itself.
		const second = callOf(fetchImpl, 1);
		expect(String(second.url)).toBe('https://files.example.com/a/g_sig');
		expect((second.init.headers as Record<string, string>)['authorization']).toBeUndefined();
		expect(new Uint8Array(result)).toEqual(bytes);
	});

	it('returns the body of a final response when fetch followed the redirect itself', async () => {
		const bytes = new Uint8Array([9, 8]);
		const fetchImpl = vi.fn().mockResolvedValue(bytesResponse(bytes));
		const result = await makeClient(fetchImpl).artifacts.download('art_1');
		expect(fetchImpl).toHaveBeenCalledTimes(1);
		expect(new Uint8Array(result)).toEqual(bytes);
	});

	it('maps the gateway 403 on the download route', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(403, { error: 'Forbidden' }, 'Forbidden'));
		const error = await makeClient(fetchImpl)
			.artifacts.download('art_1')
			.catch((e: unknown) => e);
		expect(error).toBeInstanceOf(ApiError);
		expect((error as ApiError).status).toBe(403);
	});
});

describe('downloadUrl', () => {
	it('builds the gateway URL with no network call', () => {
		const fetchImpl = vi.fn();
		const artifacts = makeClient(fetchImpl).artifacts;
		expect(artifacts.downloadUrl('art_1')).toBe(`${BASE}/Api/core/artifacts/art_1/download`);
		expect(artifacts.downloadUrl('art_1', { appId: 'app_1' })).toBe(
			`${BASE}/Api/core/artifacts/art_1/download?app=app_1`
		);
		expect(fetchImpl).not.toHaveBeenCalled();
	});
});

describe('file fields on document handles', () => {
	it('create with files builds the $content plus file-part body', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(201, { data: { name: 'Acme' }, meta: {} }));
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');
		const file = pngFile();
		await companies.create({ name: 'Acme' }, { files: { logo: file } });

		const { url, init } = callOf(fetchImpl, 0);
		expect(String(url)).toBe(`${BASE}/Api/crm/Company`);
		expect(init.method).toBe('POST');
		expect((init.headers as Record<string, string>)['content-type']).toBeUndefined();
		const form = init.body as FormData;
		expect(JSON.parse(String(form.get('$content')))).toEqual({ name: 'Acme' });
		const part = form.get('logo');
		expect(part).toBeInstanceOf(File);
		expect((part as File).name).toBe('logo.png');
	});

	it('update with files keys parts by the normalized field path', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { data: {}, meta: {} }));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc('c1');
		const first = pngFile('a.png');
		const second = pngFile('b.png');
		await doc.update({ name: 'Acme' }, { files: { logo: first, 'items[0].file': second } });

		const { init } = callOf(fetchImpl, 0);
		expect(init.method).toBe('PATCH');
		expect(String(callOf(fetchImpl, 0).url)).toBe(`${BASE}/Api/crm/Company/c1`);
		const form = init.body as FormData;
		expect(JSON.parse(String(form.get('$content')))).toEqual({ name: 'Acme' });
		expect(form.get('logo')).toBeInstanceOf(File);
		const nested = form.get('items[0].file');
		expect(nested).toBeInstanceOf(File);
		expect((nested as File).name).toBe('b.png');
	});

	it('create without files keeps the JSON body', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(201, { data: { name: 'Acme' }, meta: {} }));
		await makeClient(fetchImpl).domain('crm').doctype('Company').create({ name: 'Acme' });
		const { init } = callOf(fetchImpl, 0);
		expect(init.headers).toMatchObject({ 'content-type': 'application/json' });
		expect(JSON.parse(String(init.body))).toEqual({ name: 'Acme' });
	});
});
