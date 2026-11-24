// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi } from 'vitest';
import { createWriteQueue } from './writeQueue.js';

/**
 * Unit tests for the grid's write queue: one PATCH per row, the
 * concurrency cap, the undo stack, and the failure path.
 */

/** Deferred update stub — tests release PATCHes in order. */
function deferredUpdate() {
	const pending: {
		rowId: string;
		diff: Record<string, unknown>;
		resolve: (v: unknown) => void;
		reject: (e: unknown) => void;
		done: boolean;
	}[] = [];
	const update = vi.fn(
		(rowId: string, diff: Record<string, unknown>) =>
			new Promise<unknown>((resolve, reject) => {
				pending.push({ rowId, diff, resolve, reject, done: false });
			})
	);
	return {
		update,
		pending,
		/** Resolve every outstanding PATCH — merged ops share one PATCH. */
		resolveAll(value: unknown = { meta: {} }) {
			for (const entry of pending) {
				if (!entry.done) {
					entry.done = true;
					entry.resolve(value);
				}
			}
		},
		rejectAll(reason: unknown = new Error('422')) {
			for (const entry of pending) {
				if (!entry.done) {
					entry.done = true;
					entry.reject(reason);
				}
			}
		},
		outstanding(): number {
			return pending.filter((entry) => !entry.done).length;
		}
	};
}

function flush(): Promise<void> {
	return new Promise((r) => setTimeout(r, 0));
}

describe('createWriteQueue — scheduling', () => {
	it('resolves with the row PATCH response', async () => {
		const stub = deferredUpdate();
		const queue = createWriteQueue(stub.update);
		const response = { meta: { updated_at: 'x' } };
		const promise = queue.push('row.1', { title: 'a' });
		stub.resolveAll(response);
		await expect(promise).resolves.toBe(response);
	});

	it('merges waiting ops for the same row into one PATCH', async () => {
		const stub = deferredUpdate();
		const queue = createWriteQueue(stub.update);
		const p1 = queue.push('row.1', { a: 1 });
		const p2 = queue.push('row.1', { b: 2 });
		// op1 runs; op2 waits behind it (the running PATCH cannot grow).
		expect(stub.update).toHaveBeenCalledTimes(1);
		stub.resolveAll();
		await flush();
		expect(stub.update).toHaveBeenCalledTimes(2);
		// The follow-up carries the second op only.
		expect(stub.pending[1].diff).toEqual({ b: 2 });
		stub.resolveAll();
		await Promise.all([p1, p2]);
	});

	it('sends a follow-up PATCH when the first is already in flight', async () => {
		const stub = deferredUpdate();
		const queue = createWriteQueue(stub.update);
		const p1 = queue.push('row.1', { a: 1 });
		const p2 = queue.push('row.1', { b: 2 });
		expect(stub.pending).toHaveLength(1);
		stub.resolveAll();
		await flush();
		expect(stub.update).toHaveBeenCalledTimes(2);
		expect(stub.pending[1].diff).toEqual({ b: 2 });
		stub.resolveAll();
		await Promise.all([p1, p2]);
	});

	it('runs at most `concurrency` row PATCHes at once', async () => {
		const stub = deferredUpdate();
		const queue = createWriteQueue(stub.update, 2);
		void queue.push('row.1', { a: 1 });
		void queue.push('row.2', { a: 2 });
		void queue.push('row.3', { a: 3 });
		expect(stub.outstanding()).toBe(2);
		stub.resolveAll();
		await flush();
		// row.3 started once a slot freed; nothing else waits.
		expect(stub.update).toHaveBeenCalledTimes(3);
		expect(stub.outstanding()).toBe(1);
		stub.resolveAll();
		await flush();
		expect(stub.outstanding()).toBe(0);
	});
});

describe('createWriteQueue — undo stack', () => {
	it('records an undo entry when the PATCH resolves', async () => {
		const stub = deferredUpdate();
		const queue = createWriteQueue(stub.update);
		void queue.push('row.1', { a: 2 }, { before: { a: 1 } });
		expect(queue.canUndo()).toBe(false);
		stub.resolveAll();
		await flush();
		expect(queue.canUndo()).toBe(true);
		expect(queue.popUndo()).toEqual({ rowId: 'row.1', before: { a: 1 }, after: { a: 2 } });
		expect(queue.canUndo()).toBe(false);
	});

	it('skips the record when no `before` is given (undo writes)', async () => {
		const stub = deferredUpdate();
		const queue = createWriteQueue(stub.update);
		void queue.push('row.1', { a: 1 });
		stub.resolveAll();
		await flush();
		expect(queue.canUndo()).toBe(false);
	});

	it('pops newest-first', async () => {
		const stub = deferredUpdate();
		const queue = createWriteQueue(stub.update);
		void queue.push('row.1', { a: 2 }, { before: { a: 1 } });
		void queue.push('row.1', { b: 4 }, { before: { b: 3 } });
		stub.resolveAll();
		await flush();
		stub.resolveAll();
		await flush();
		expect(queue.popUndo()?.after).toEqual({ b: 4 });
		expect(queue.popUndo()?.after).toEqual({ a: 2 });
	});
});

describe('createWriteQueue — failure path', () => {
	it('rejects the op when the PATCH fails and records no undo', async () => {
		const stub = deferredUpdate();
		const queue = createWriteQueue(stub.update);
		const promise = queue.push('row.1', { a: 2 }, { before: { a: 1 } });
		stub.rejectAll(new Error('422'));
		await expect(promise).rejects.toThrow('422');
		await flush();
		expect(queue.canUndo()).toBe(false);
	});
});
