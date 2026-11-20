// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { HttpAssistantError } from '../../src/driver/errors.js';
import {
	createMockAssistant,
	MOCK_APP_ID,
	MockAssistantDriver,
	type AssistantScript
} from '../../src/index.js';
import {
	cleanupDom,
	createInlineElement,
	createWindowElement,
	clickSend,
	importElements,
	typeMessage
} from './helpers.js';

/**
 * DOM tests for the two custom-element mounts, driven by the scripted mock
 * driver. Covers the Phase 4 test set: each mount renders, a mocked turn
 * streams (content + tool bar + done), cancel mid-stream, markdown + code
 * render, history replay, archive toggle round-trip, the 403 empty state,
 * and the floating window's persisted open state.
 */

const ENVELOPE = (rows: unknown[], total: number): string =>
	JSON.stringify({ ok: true, data: { data: rows, meta: { total } } });

const SHIPMENT_ROW = {
	data: {},
	meta: { id: 'core.doc_ship_1', domain: 'logistics', doc_type: 'Shipment' }
};

/** A turn with text, a schema tool bar, and a resolved list_documents surface. */
const richScript: AssistantScript = {
	match: (content) => /hello/.test(content),
	chunks: [
		{ kind: 'content', text: 'Here is the schema. ', delayMs: 5 },
		{
			kind: 'tool_call',
			name: 'get_schema',
			detail: 'logistics',
			status: 'running',
			delayMs: 5
		},
		{
			kind: 'tool_call',
			name: 'get_schema',
			detail: 'logistics',
			result: '{"ok":true,"data":{}}',
			status: 'ok',
			delayMs: 5
		},
		{
			kind: 'tool_call',
			name: 'list_documents',
			detail: 'logistics.Shipment',
			status: 'running',
			delayMs: 5
		},
		{
			kind: 'tool_call',
			name: 'list_documents',
			status: 'ok',
			result: ENVELOPE([SHIPMENT_ROW], 1),
			delayMs: 5
		},
		{ kind: 'content', text: 'Done.', delayMs: 5 }
	],
	outcome: { kind: 'done', finish_reason: 'stop' },
	usage: { prompt_tokens: 10, completion_tokens: 8, total_tokens: 18 }
};

const markdownScript: AssistantScript = {
	match: (content) => /markdown/.test(content),
	chunks: [
		{
			kind: 'content',
			text: 'Bold **text** and code:\n\n```ts\nconst x = 1;\n```\n',
			delayMs: 5
		}
	],
	outcome: { kind: 'done', finish_reason: 'stop' }
};

const slowScript: AssistantScript = {
	match: (content) => /slow/.test(content),
	chunks: [
		{ kind: 'content', text: 'Starting… ', delayMs: 80 },
		{ kind: 'content', text: 'still working. ', delayMs: 300 },
		{ kind: 'content', text: 'almost there.', delayMs: 300 }
	],
	outcome: { kind: 'done', finish_reason: 'stop' }
};

beforeEach(() => {
	cleanupDom();
});

describe('inline element — <facet-assistant>', () => {
	it('mounts the chat panel into its shadow root', async () => {
		await importElements();
		const el = createInlineElement({ appId: MOCK_APP_ID, driver: createMockAssistant() });
		document.body.appendChild(el);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.chat-panel')).toBeTruthy();
		});
		// Rail + composer + empty hint render.
		expect(el.shadowRoot?.querySelector('.cl')).toBeTruthy();
		expect(el.shadowRoot?.querySelector('textarea')).toBeTruthy();
		expect(el.shadowRoot?.textContent).toContain('Pick a conversation');
		// The token sheet is injected into the shadow root once.
		expect(el.shadowRoot?.querySelectorAll('style[data-facet-shadow]')).toHaveLength(1);
		// No window chrome on the inline mount.
		expect(el.shadowRoot?.querySelector('.assistant-window')).toBeNull();
	});

	it('streams a mocked turn: user bubble, tool bar, rows surface, done', async () => {
		await importElements();
		const driver = createMockAssistant([richScript]);
		const el = createInlineElement({ appId: MOCK_APP_ID, driver });
		document.body.appendChild(el);

		await vi.waitFor(() => expect(el.shadowRoot?.querySelector('textarea')).toBeTruthy());
		typeMessage(el.shadowRoot!, 'hello there');
		clickSend(el.shadowRoot!);

		// The user bubble appears once the conversation exists (async create).
		await vi.waitFor(() => {
			expect(el.shadowRoot?.textContent).toContain('hello there');
		});

		// The schema tool bar streams in while the turn runs.
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.trace')?.textContent).toContain('get_schema');
		});
		// The resolved list_documents chunk renders as the data-only rows card.
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.rows-card')?.textContent).toContain(
				'logistics.Shipment'
			);
		});
		// Done: the full reply text is present and the turn is no longer
		// streaming (caret gone, button back to send — not stop). The button
		// itself stays disabled while the composer is empty.
		await vi.waitFor(() => {
			expect(el.shadowRoot?.textContent).toContain('Done.');
		});
		expect(el.shadowRoot?.querySelector('.md-caret')).toBeNull();
		expect(el.shadowRoot?.querySelector('.send.stop')).toBeNull();
	});

	it('renders markdown and highlighted code in the reply', async () => {
		await importElements();
		const driver = createMockAssistant([markdownScript]);
		const el = createInlineElement({ appId: MOCK_APP_ID, driver });
		document.body.appendChild(el);

		await vi.waitFor(() => expect(el.shadowRoot?.querySelector('textarea')).toBeTruthy());
		typeMessage(el.shadowRoot!, 'markdown please');
		clickSend(el.shadowRoot!);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.md strong')?.textContent).toBe('text');
		});
		const code = el.shadowRoot?.querySelector('.md-code code');
		expect(code?.textContent).toContain('const x = 1;');
	});

	it('cancels a streaming turn mid-flight', async () => {
		await importElements();
		const driver = createMockAssistant([slowScript]);
		const el = createInlineElement({ appId: MOCK_APP_ID, driver });
		document.body.appendChild(el);

		await vi.waitFor(() => expect(el.shadowRoot?.querySelector('textarea')).toBeTruthy());
		typeMessage(el.shadowRoot!, 'slow request');
		clickSend(el.shadowRoot!);

		// While the turn streams, the send button doubles as the stop button.
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.send.stop')).toBeTruthy();
		});
		clickSend(el.shadowRoot!);

		// The cancelled note lands on the turn and the composer frees up.
		await vi.waitFor(() => {
			expect(el.shadowRoot?.textContent).toContain('Cancelled.');
		});
		expect(el.shadowRoot?.querySelector('.md-caret')).toBeNull();
	});

	it('replays a past conversation from the rail (history)', async () => {
		await importElements();
		const driver = createMockAssistant([richScript]);
		const conv = await driver.createAppConversation();
		await driver.recordTurn(conv.id, {
			request_messages: [{ role: 'user', content: 'Past question' }],
			response_messages: [{ role: 'assistant', content: 'Past **answer**' }],
			usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 }
		});
		const el = createInlineElement({ appId: MOCK_APP_ID, driver });
		document.body.appendChild(el);

		// The rail lists the conversation; selecting it replays the stored turns.
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.cl-row')).toBeTruthy();
		});
		const row = el.shadowRoot!.querySelector<HTMLButtonElement>('.cl-row')!;
		row.click();

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.md strong')?.textContent).toBe('answer');
		});
		expect(el.shadowRoot?.textContent).toContain('Past question');
	});

	it('archives and unarchives through the rail toggle', async () => {
		await importElements();
		const driver = createMockAssistant([richScript]);
		await driver.createAppConversation();
		const el = createInlineElement({ appId: MOCK_APP_ID, driver });
		document.body.appendChild(el);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.cl-row')).toBeTruthy();
		});

		// Archive: the row leaves the live list.
		el.shadowRoot!.querySelector<HTMLButtonElement>('.cl-row-action')!.click();
		await vi.waitFor(() => {
			expect(el.shadowRoot?.textContent).toContain('No conversations yet.');
		});
		const archived = await driver.listConversations({
			filters: { archived__eq: 'true' }
		});
		expect(archived.data).toHaveLength(1);

		// Swap the rail to the archived view; the row is back.
		el.shadowRoot!.querySelector<HTMLButtonElement>('.cl-icon-btn[aria-pressed]')!.click();
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.cl-row')).toBeTruthy();
		});

		// Unarchive: back to the live list.
		el.shadowRoot!.querySelector<HTMLButtonElement>('.cl-row-action')!.click();
		await vi.waitFor(() => {
			expect(el.shadowRoot?.textContent).toContain('No archived conversations.');
		});
	});

	it('shows the usage meter when the caller has a finite budget', async () => {
		await importElements();
		const driver = createMockAssistant([richScript], {
			usage: {
				total: 60,
				budget: 100,
				window_start: new Date().toISOString(),
				window_days: 30
			}
		});
		const el = createInlineElement({ appId: MOCK_APP_ID, driver });
		document.body.appendChild(el);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.usage-meter')?.textContent).toContain(
				'60% of the 30-day budget used'
			);
		});
	});

	it('renders the 403 denial state and hides the composer', async () => {
		await importElements();
		class DeniedDriver extends MockAssistantDriver {
			override createAppConversation(): ReturnType<MockAssistantDriver['createAppConversation']> {
				return Promise.reject(
					new HttpAssistantError(403, 'Forbidden', 'assistant disabled for app')
				);
			}
		}
		const el = createInlineElement({ appId: MOCK_APP_ID, driver: new DeniedDriver() });
		document.body.appendChild(el);

		await vi.waitFor(() => expect(el.shadowRoot?.querySelector('textarea')).toBeTruthy());
		typeMessage(el.shadowRoot!, 'hello?');
		clickSend(el.shadowRoot!);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.denied')?.textContent).toContain(
				'Assistant unavailable'
			);
		});
		// The composer hides — nothing to type into while denied.
		expect(el.shadowRoot?.querySelector('textarea')).toBeNull();
	});
});

describe('floating element — <facet-assistant-window>', () => {
	it('mounts the window shell with the panel inside, open by default', async () => {
		await importElements();
		const el = createWindowElement({ appId: MOCK_APP_ID, driver: createMockAssistant() });
		document.body.appendChild(el);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.assistant-window')).toBeTruthy();
		});
		expect(el.shadowRoot?.querySelector('.chat-panel')).toBeTruthy();
		expect(el.isOpen).toBe(true);
	});

	it('close() hides the window and persists the open state; open() restores it', async () => {
		await importElements();
		const el = createWindowElement({ appId: MOCK_APP_ID, driver: createMockAssistant() });
		document.body.appendChild(el);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.assistant-window')).toBeTruthy();
		});

		el.close();
		expect(el.isOpen).toBe(false);
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.assistant-window')).toBeNull();
		});
		expect(window.sessionStorage.getItem('facet.assistant.app.open')).toBe('false');

		el.open();
		expect(el.isOpen).toBe(true);
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.assistant-window')).toBeTruthy();
		});
		expect(window.sessionStorage.getItem('facet.assistant.app.open')).toBe('true');

		el.toggle();
		expect(el.isOpen).toBe(false);
		expect(window.sessionStorage.getItem('facet.assistant.app.open')).toBe('false');
	});

	it('minimizing the maximized window shrinks it to the title bar', async () => {
		await importElements();
		const el = createWindowElement({ appId: MOCK_APP_ID, driver: createMockAssistant() });
		document.body.appendChild(el);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.assistant-window')).toBeTruthy();
		});
		const win = el.shadowRoot!.querySelector<HTMLElement>('.assistant-window')!;
		const headerButton = (label: string): HTMLButtonElement => {
			const btn = win.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`);
			if (!btn) throw new Error(`header button not found: ${label}`);
			return btn;
		};

		// Maximize, then minimize. The minimized window must be the docked
		// title bar (40px) — the full-viewport empty box here is the
		// regression: the maximized geometry used to win while the body was
		// hidden.
		headerButton('Maximize assistant').click();
		await vi.waitFor(() => {
			expect(headerButton('Restore assistant')).toBeTruthy();
		});
		headerButton('Collapse assistant').click();
		await vi.waitFor(() => {
			expect(win.style.height).toBe('40px');
		});

		// Maximize survives under the minimize — expand returns to the
		// maximized box (viewport minus a 16px gap on each side), not the
		// floating default.
		headerButton('Expand assistant').click();
		await vi.waitFor(() => {
			expect(win.style.height).toBe(`${window.innerHeight - 32}px`);
		});
		expect(headerButton('Restore assistant')).toBeTruthy();
	});

	it('a persisted closed state keeps the window shut on the next mount', async () => {
		await importElements();
		window.sessionStorage.setItem('facet.assistant.app.open', 'false');
		const el = createWindowElement({ appId: MOCK_APP_ID, driver: createMockAssistant() });
		document.body.appendChild(el);

		// Let effects settle.
		await new Promise((r) => setTimeout(r, 10));
		expect(el.shadowRoot?.querySelector('.assistant-window')).toBeNull();

		el.open();
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.assistant-window')).toBeTruthy();
		});
	});
});
