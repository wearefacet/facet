// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	HttpAssistantDriver,
	HttpAssistantError,
	appConversationFilters,
	buildListQuery,
	parseSseStream
} from '../../src/index.js';
import type { AssistantSseEvent } from '../../src/index.js';

// ── Helpers ────────────────────────────────────────────────────────────────

/** One recorded fetch call — the URL and the init the driver passed. */
interface FetchCall {
	url: string;
	init: RequestInit;
}

/**
 * Builds an injectable fetch that records every call and answers from
 * `handler`. The driver binds its fetch to `globalThis`, so a plain arrow
 * function works.
 */
function stubFetch(handler: (url: string, init: RequestInit) => Response): {
	fetch: typeof fetch;
	calls: FetchCall[];
} {
	const calls: FetchCall[] = [];
	const fn = ((url: string, init: RequestInit = {}) => {
		calls.push({ url: String(url), init });
		return Promise.resolve(handler(url, init));
	}) as unknown as typeof fetch;
	return { fetch: fn, calls };
}

/** The recorded call at `i`, failing the test early when it is missing. */
function call(calls: FetchCall[], i: number): FetchCall {
	const c = calls[i];
	if (!c) throw new Error(`No fetch call recorded at index ${i}`);
	return c;
}

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

/** A `ReadableStream<Uint8Array>` delivering `pieces` as separate chunks. */
function streamOf(pieces: string[]): ReadableStream<Uint8Array> {
	const encoder = new TextEncoder();
	let i = 0;
	return new ReadableStream({
		pull(controller) {
			if (i < pieces.length) {
				controller.enqueue(encoder.encode(pieces[i]!));
				i += 1;
			} else {
				controller.close();
			}
		}
	});
}

function sseResponse(text: string, pieces?: string[]): Response {
	return new Response(streamOf(pieces ?? [text]), {
		status: 200,
		headers: { 'Content-Type': 'text/event-stream' }
	});
}

async function collect(iterable: AsyncIterable<AssistantSseEvent>): Promise<AssistantSseEvent[]> {
	const out: AssistantSseEvent[] = [];
	for await (const ev of iterable) out.push(ev);
	return out;
}

// ── buildListQuery ─────────────────────────────────────────────────────────

describe('buildListQuery', () => {
	it('returns an empty string without params', () => {
		expect(buildListQuery()).toBe('');
		expect(buildListQuery({})).toBe('');
	});

	it('serializes page, items, and the joined sort', () => {
		const qs = buildListQuery({ page: 2, items: 50, sort: ['-updated_at', 'created_at'] });
		expect(decodeURIComponent(qs)).toBe('?page=2&items=50&sort=-updated_at,created_at');
	});

	it('serializes scalar filters in the filters[field__op] wire form', () => {
		const qs = buildListQuery({ page: 3, filters: { 'context.kind__eq': 'app' } });
		expect(decodeURIComponent(qs)).toBe('?page=3&filters[context.kind__eq]=app');
	});
});

describe('appConversationFilters', () => {
	it('scopes the list to the app kind and the app id', () => {
		expect(appConversationFilters('app_123')).toEqual({
			'context.kind__eq': 'app',
			'context.app_id__eq': 'app_123'
		});
	});

	it('round-trips through buildListQuery', () => {
		const qs = buildListQuery({ filters: appConversationFilters('app_123') });
		expect(decodeURIComponent(qs)).toBe(
			'?filters[context.kind__eq]=app&filters[context.app_id__eq]=app_123'
		);
	});
});

// ── parseSseStream ─────────────────────────────────────────────────────────

describe('parseSseStream', () => {
	it('yields meta, chunk, and done frames in order', async () => {
		const text =
			'event: meta\n' +
			'data: {"turn_token":"tok-1"}\n' +
			'\n' +
			'event: chunk\n' +
			'data: {"kind":"content","text":"Hi"}\n' +
			'\n' +
			'event: done\n' +
			'data: {"turn_id":"turn-1","finish_reason":"stop"}\n' +
			'\n';
		const events = await collect(parseSseStream(streamOf([text])));
		expect(events).toEqual([
			{ event: 'meta', turn_token: 'tok-1' },
			{ event: 'chunk', chunk: { kind: 'content', text: 'Hi' } },
			{ event: 'done', turn_id: 'turn-1', finish_reason: 'stop' }
		]);
	});

	it('reassembles a frame split across chunk boundaries', async () => {
		const events = await collect(
			parseSseStream(streamOf(['event: met', 'a\nda', 'ta: {"turn_token":"tok-9"}\n\n']))
		);
		expect(events).toEqual([{ event: 'meta', turn_token: 'tok-9' }]);
	});

	it('normalises CRLF line endings', async () => {
		const events = await collect(
			parseSseStream(streamOf(['event: chunk\r\ndata: {"kind":"content","text":"x"}\r\n\r\n']))
		);
		expect(events).toEqual([{ event: 'chunk', chunk: { kind: 'content', text: 'x' } }]);
	});

	it('joins multi-line data payloads with a newline', async () => {
		const events = await collect(
			parseSseStream(
				streamOf(['event: chunk\ndata: {"kind":"content",\ndata: "text":"split"}\n\n'])
			)
		);
		expect(events).toEqual([{ event: 'chunk', chunk: { kind: 'content', text: 'split' } }]);
	});

	it('maps malformed JSON data onto an error event', async () => {
		const events = await collect(parseSseStream(streamOf(['event: chunk\ndata: {oops}\n\n'])));
		expect(events).toEqual([{ event: 'error', message: 'Malformed SSE data: {oops}' }]);
	});

	it('maps an unknown event type onto an error event', async () => {
		const events = await collect(parseSseStream(streamOf(['event: ping\ndata: {}\n\n'])));
		expect(events).toEqual([{ event: 'error', message: 'Unknown SSE event: ping' }]);
	});

	it('parses the cancelled event with its empty payload', async () => {
		const events = await collect(parseSseStream(streamOf(['event: cancelled\ndata: {}\n\n'])));
		expect(events).toEqual([{ event: 'cancelled' }]);
	});

	it('skips SSE comment lines and field lines without a known field', async () => {
		const events = await collect(
			parseSseStream(
				streamOf([
					': keepalive\n',
					'event: meta\n',
					'id: ignored\n',
					'data: {"turn_token":"tok-2"}\n',
					'\n'
				])
			)
		);
		expect(events).toEqual([{ event: 'meta', turn_token: 'tok-2' }]);
	});
});

// ── HttpAssistantDriver — request shape ────────────────────────────────────

describe('HttpAssistantDriver request shape', () => {
	it('lists conversations from baseUrl with credentials included', async () => {
		const { fetch, calls } = stubFetch(() =>
			jsonResponse({ data: [], meta: { count: 0, more: false } })
		);
		const driver = new HttpAssistantDriver('https://facet.example', fetch);
		const result = await driver.listConversations({ page: 2, items: 50 });

		expect(call(calls, 0).url).toBe(
			'https://facet.example/Api/assistant/conversations?page=2&items=50'
		);
		expect(call(calls, 0).init.method).toBe('GET');
		expect(call(calls, 0).init.credentials).toBe('include');
		expect(result).toEqual({ data: [], meta: { count: 0, more: false } });
	});

	it('strips a trailing slash from baseUrl', async () => {
		const { fetch, calls } = stubFetch(() =>
			jsonResponse({ data: [], meta: { count: 0, more: false } })
		);
		const driver = new HttpAssistantDriver('https://facet.example/', fetch);
		await driver.listConversations();
		expect(call(calls, 0).url).toBe('https://facet.example/Api/assistant/conversations');
	});

	it('POSTs a flat JSON body with the CSRF header on create', async () => {
		const { fetch, calls } = stubFetch(() => jsonResponse({ data: { id: 'c1' } }));
		const driver = new HttpAssistantDriver('https://facet.example', fetch);
		const conv = await driver.createConversation({
			context: { kind: 'builder' },
			language: 'fr-CA'
		});

		const c = call(calls, 0);
		expect(c.url).toBe('https://facet.example/Api/assistant/conversations');
		expect(c.init.method).toBe('POST');
		expect(c.init.headers).toMatchObject({
			'Content-Type': 'application/json',
			'X-Requested-With': 'XMLHttpRequest'
		});
		expect(JSON.parse(c.init.body as string)).toEqual({
			context: { kind: 'builder' },
			language: 'fr-CA'
		});
		expect(conv).toEqual({ id: 'c1' });
	});

	it('sends an empty body for a workspace create without input', async () => {
		const { fetch, calls } = stubFetch(() => jsonResponse({ data: { id: 'w1' } }));
		const driver = new HttpAssistantDriver('https://facet.example', fetch);
		await driver.createWorkspaceConversation();
		expect(JSON.parse(call(calls, 0).init.body as string)).toEqual({});
	});

	it('passes the language through on a workspace create', async () => {
		const { fetch, calls } = stubFetch(() => jsonResponse({ data: { id: 'w2' } }));
		const driver = new HttpAssistantDriver('', fetch);
		await driver.createWorkspaceConversation({ language: 'de-CH' });
		expect(JSON.parse(call(calls, 0).init.body as string)).toEqual({ language: 'de-CH' });
	});

	it('streams the SSE body with the stream headers', async () => {
		const text =
			'event: meta\ndata: {"turn_token":"t"}\n\nevent: done\ndata: {"turn_id":"u","finish_reason":"stop"}\n\n';
		const { fetch, calls } = stubFetch(() => sseResponse(text));
		const driver = new HttpAssistantDriver('https://facet.example', fetch);
		const events = await collect(driver.streamAsk('c1', { content: 'hello' }));

		const c = call(calls, 0);
		expect(c.url).toBe('https://facet.example/Api/assistant/conversations/c1/stream');
		expect(c.init.method).toBe('POST');
		expect(c.init.headers).toMatchObject({
			Accept: 'text/event-stream',
			'X-Requested-With': 'XMLHttpRequest'
		});
		expect(JSON.parse(c.init.body as string)).toEqual({ content: 'hello' });
		expect(events).toEqual([
			{ event: 'meta', turn_token: 't' },
			{ event: 'done', turn_id: 'u', finish_reason: 'stop' }
		]);
	});

	it('POSTs the cancel route with an encoded turn token', async () => {
		const { fetch, calls } = stubFetch(() => jsonResponse({ ok: true }));
		const driver = new HttpAssistantDriver('https://facet.example', fetch);
		await driver.cancel('tok/1 x');

		const c = call(calls, 0);
		expect(c.url).toBe('https://facet.example/Api/assistant/cancel/tok%2F1%20x');
		expect(c.init.method).toBe('POST');
		expect(c.init.headers).toMatchObject({ 'X-Requested-With': 'XMLHttpRequest' });
	});

	it('sends the archive flag on the PATCH', async () => {
		const { fetch, calls } = stubFetch(() => jsonResponse({ data: { id: 'c1' } }));
		const driver = new HttpAssistantDriver('https://facet.example', fetch);
		await driver.setConversationArchived('c1', true);

		const c = call(calls, 0);
		expect(c.url).toBe('https://facet.example/Api/assistant/conversations/c1');
		expect(c.init.method).toBe('PATCH');
		expect(JSON.parse(c.init.body as string)).toEqual({ archived: true });
	});
});

// ── HttpAssistantDriver — error mapping ────────────────────────────────────

describe('HttpAssistantDriver error mapping', () => {
	it('throws HttpAssistantError with the backend error text', async () => {
		const { fetch } = stubFetch(() => jsonResponse({ error: 'budget exceeded' }, 429));
		const driver = new HttpAssistantDriver('', fetch);
		await expect(driver.listConversations()).rejects.toSatisfy((err: unknown) => {
			return (
				err instanceof HttpAssistantError && err.status === 429 && err.message === 'budget exceeded'
			);
		});
	});

	it('falls back to the status text on a non-JSON error body', async () => {
		const { fetch } = stubFetch(
			() => new Response('<html>boom</html>', { status: 500, statusText: 'Internal Server Error' })
		);
		const driver = new HttpAssistantDriver('', fetch);
		await expect(driver.listConversations()).rejects.toSatisfy((err: unknown) => {
			return (
				err instanceof HttpAssistantError &&
				err.status === 500 &&
				err.message === '500 Internal Server Error'
			);
		});
	});

	it('maps a 404 on getConversation to null', async () => {
		const { fetch } = stubFetch(() => jsonResponse({ error: 'not found' }, 404));
		const driver = new HttpAssistantDriver('', fetch);
		await expect(driver.getConversation('nope')).resolves.toBeNull();
	});

	it('fails a stream that never reaches 2xx, before any event', async () => {
		const { fetch, calls } = stubFetch(() => jsonResponse({ error: 'assistant disabled' }, 403));
		const driver = new HttpAssistantDriver('', fetch);
		await expect(collect(driver.streamAsk('c1', { content: 'hi' }))).rejects.toMatchObject({
			status: 403,
			message: 'assistant disabled'
		});
		expect(calls).toHaveLength(1);
	});
});
