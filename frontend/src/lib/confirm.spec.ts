// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, beforeAll } from 'vitest';
import { confirm, confirmWithText, settleConfirm, getPendingConfirm } from './confirm.svelte.js';

// The store guards on `window` so SSR never touches the DOM. Install a stub
// before the tests so the client branch runs in Node.
beforeAll(() => {
	(globalThis as Record<string, unknown>).window = {};
});

describe('confirm() store', () => {
	it('resolves true when the caller confirms', async () => {
		const promise = confirm({ title: 'Delete role?', variant: 'danger' });

		expect(getPendingConfirm()?.title).toBe('Delete role?');

		settleConfirm(true);
		await expect(promise).resolves.toBe(true);
		expect(getPendingConfirm()).toBeNull();
	});

	it('resolves false when dismissed', async () => {
		const promise = confirm({ title: 'Discard?' });

		settleConfirm(false);
		await expect(promise).resolves.toBe(false);
		expect(getPendingConfirm()).toBeNull();
	});

	it('settles an earlier prompt as cancelled when a new one opens', async () => {
		const first = confirm({ title: 'First' });
		const second = confirm({ title: 'Second' });

		// The first request lost the race — it must not hang forever.
		await expect(first).resolves.toBe(false);
		expect(getPendingConfirm()?.title).toBe('Second');

		settleConfirm(true);
		await expect(second).resolves.toBe(true);
	});

	it('resolves false immediately on the server (no window)', async () => {
		// Simulate the SSR branch: the store checks `typeof window` per call,
		// so remove the stub just for this case.
		const win = (globalThis as { window?: unknown }).window;
		(globalThis as Record<string, unknown>).window = undefined;
		try {
			const promise = confirm({ title: 'Never shown' });
			await expect(promise).resolves.toBe(false);
			expect(getPendingConfirm()).toBeNull();
		} finally {
			(globalThis as { window?: unknown }).window = win;
		}
	});

	it('settling with no pending request is a no-op', async () => {
		expect(() => settleConfirm(true)).not.toThrow();
	});
});

describe('confirmWithText() store', () => {
	it('resolves ok + the captured text', async () => {
		const promise = confirmWithText({
			title: 'Force delete?',
			variant: 'danger',
			prompt: { label: 'Reason', placeholder: 'Why?' }
		});

		const pending = getPendingConfirm();
		expect(pending?.prompt?.label).toBe('Reason');
		expect(pending?.variant).toBe('danger');

		settleConfirm(true, 'security incident');
		await expect(promise).resolves.toEqual({ ok: true, text: 'security incident' });
	});

	it('resolves an empty text when settled without one', async () => {
		const promise = confirmWithText({ title: 'No prompt input' });

		settleConfirm(true);
		await expect(promise).resolves.toEqual({ ok: true, text: '' });
	});

	it('resolves an empty text when cancelled', async () => {
		const promise = confirmWithText({
			title: 'Cancelled',
			prompt: { label: 'Reason' }
		});

		settleConfirm(false, 'draft text the dialog discards');
		await expect(promise).resolves.toEqual({ ok: false, text: '' });
	});

	it('settles an earlier prompt as cancelled when a new one opens', async () => {
		const first = confirmWithText({ title: 'First', prompt: { label: 'A' } });
		const second = confirmWithText({ title: 'Second' });

		await expect(first).resolves.toEqual({ ok: false, text: '' });
		expect(getPendingConfirm()?.title).toBe('Second');

		settleConfirm(true, 'kept');
		await expect(second).resolves.toEqual({ ok: true, text: 'kept' });
	});

	it('resolves false immediately on the server (no window)', async () => {
		const win = (globalThis as { window?: unknown }).window;
		(globalThis as Record<string, unknown>).window = undefined;
		try {
			await expect(confirmWithText({ title: 'Never shown' })).resolves.toEqual({
				ok: false,
				text: ''
			});
		} finally {
			(globalThis as { window?: unknown }).window = win;
		}
	});
});
